# MinIO media backend — IO submodule portion
#
# Defines MinIOMedia, its S3 backend interface, and implements DataFrame I/O and AsyncLogger support. The streaming
# writer and reader live in minio_streaming.jl. Dataset and parameters dispatch (which reference parent-module symbols
# like _write_dataset_impl, parameters_from_dict, etc.) live in the MinIOMedia sections of src/dataset.jl and
# src/parameters.jl.
#
# AWSS3 and AWS are MyJuliaToolbox's own dependencies (Project.toml): MinIOMedia uses them whatever the project that
# loads MyJuliaToolbox lists.

import AWS
import AWSS3
using Arrow
using CSV
using DataFrames
using Dates
using JSON

# ──────────────────────────────────────────────────────────────────────────────
# Custom AWS config — wires a non-AWS endpoint into AWS.jl's request pipeline
# ──────────────────────────────────────────────────────────────────────────────

"""
    _MinIOAWSConfig

Internal AWS config that routes every S3 call to a user-supplied endpoint URL
instead of the AWS regional endpoints.

Implements the three abstract methods that AWS.jl dispatches on:
- `AWS.region(cfg)`
- `AWS.credentials(cfg)`
- `AWS.generate_service_url(cfg, service, resource)`

They are defined below, once, at load time.
"""
mutable struct _MinIOAWSConfig <: AWS.AbstractAWSConfig
    endpoint::String    # e.g. "http://localhost:9000" or "https://minio.example.com"
    region::String      # MinIO ignores region, but AWS SDK requires a value
    credentials::Any    # AWS.AWSCredentials

    _MinIOAWSConfig(endpoint, region, credentials) =
        new(rstrip(endpoint, '/'), region, credentials)
end

# The AWS.jl extension points, which route every S3 call to the configured endpoint. They are defined at load
# time: methods added while a MinIOMedia is constructed would be invisible to the task that goes on to use it.
AWS.region(cfg::_MinIOAWSConfig) = cfg.region
AWS.credentials(cfg::_MinIOAWSConfig) = cfg.credentials

# `resource` is already the "/bucket/key" path portion.
AWS.generate_service_url(cfg::_MinIOAWSConfig, ::String, resource::String) =
    string(cfg.endpoint, resource)

# ──────────────────────────────────────────────────────────────────────────────
# S3 backend interface
#
# Every MinIO call goes through these functions, so the offline tests can swap the AWSS3 calls for an in-memory
# store. A backend implements: _backend_put, _backend_begin_upload, _backend_upload_part, _backend_complete_upload,
# _backend_abort_upload, _backend_get_range, _backend_object_size, _backend_exists, _backend_list, _backend_delete.
# ──────────────────────────────────────────────────────────────────────────────

"""
    _S3Backend

The object store a `MinIOMedia` talks to: one bucket. `_AWSS3Backend` is the real one; tests define in-memory ones.
"""
abstract type _S3Backend end

"""
    _AWSS3Backend(config, bucket)

The backend that sends each call to an S3-compatible server through AWSS3.jl.
"""
struct _AWSS3Backend <: _S3Backend
    config::_MinIOAWSConfig
    bucket::String
end

"""Put `data` whole as the object `key`, in one request."""
function _backend_put(backend::_AWSS3Backend, key::String, data::Vector{UInt8}, content_type::String)
    AWSS3.s3_put(backend.config, backend.bucket, key, data, content_type)
    return nothing
end

"""Begin a multipart upload of `key`; returns its upload id."""
function _backend_begin_upload(backend::_AWSS3Backend, key::String, content_type::String)
    arguments = Dict{String, Any}("headers" => Dict{String, Any}("Content-Type" => content_type))
    upload = AWSS3.s3_begin_multipart_upload(backend.config, backend.bucket, key, arguments)
    return String(upload["UploadId"])
end

"""The upload description AWSS3's multipart functions take."""
_aws_upload(backend::_AWSS3Backend, key::String, upload_id::String) =
    Dict{String, Any}("Bucket" => backend.bucket, "Key" => key, "UploadId" => upload_id)

"""Upload `data` as part `part_number` of the upload `upload_id`; returns the part's ETag."""
function _backend_upload_part(backend::_AWSS3Backend, key::String, upload_id::String, part_number::Int,
                              data::Vector{UInt8})
    return String(AWSS3.s3_upload_part(backend.config, _aws_upload(backend, key, upload_id), part_number, data))
end

"""Complete the upload `upload_id` from its parts' ETags, in part order."""
function _backend_complete_upload(backend::_AWSS3Backend, key::String, upload_id::String, etags::Vector{String})
    AWSS3.s3_complete_multipart_upload(backend.config, _aws_upload(backend, key, upload_id), etags)
    return nothing
end

"""Abort the upload `upload_id`, so the server drops its parts."""
function _backend_abort_upload(backend::_AWSS3Backend, key::String, upload_id::String)
    AWSS3.S3.abort_multipart_upload(backend.bucket, key, upload_id; aws_config = backend.config)
    return nothing
end

"""Bytes `first_byte` to `last_byte` (1-based, inclusive) of the object `key`."""
function _backend_get_range(backend::_AWSS3Backend, key::String, first_byte::Int, last_byte::Int)
    return AWSS3.s3_get(backend.config, backend.bucket, key; raw = true, byte_range = first_byte:last_byte)
end

"""The size in bytes of the object `key`, from a HEAD request."""
function _backend_object_size(backend::_AWSS3Backend, key::String)
    headers = AWSS3.s3_get_meta(backend.config, backend.bucket, key)
    for (name, value) in headers
        lowercase(String(name)) == "content-length" && return parse(Int, value)
    end
    throw(ErrorException("MinIO: no Content-Length in the HEAD response for $key"))
end

"""Whether the object `key` exists."""
_backend_exists(backend::_AWSS3Backend, key::String) = AWSS3.s3_exists(backend.config, backend.bucket, key)

"""
    _backend_list(backend, prefix; recursive) -> Vector{String}

The keys that start with `prefix`. Without `recursive`, only those with no `/` after the prefix: one level, as
`readdir` lists a folder.
"""
function _backend_list(backend::_AWSS3Backend, prefix::String; recursive::Bool)
    delimiter = recursive ? "" : "/"
    objects = AWSS3.s3_list_objects(backend.config, backend.bucket, prefix; delimiter = delimiter)
    return [string(object["Key"]) for object in objects]
end

"""Delete the object `key`."""
function _backend_delete(backend::_AWSS3Backend, key::String)
    AWSS3.s3_delete(backend.config, backend.bucket, key)
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# MinIOMedia
# ──────────────────────────────────────────────────────────────────────────────

"""Default bytes per multipart part and per ranged GET."""
const _MINIO_DEFAULT_PART_SIZE = 64 * 1024 * 1024

"""S3's minimum size for every part of a multipart upload but the last."""
const _MINIO_MIN_PART_SIZE = 5 * 1024 * 1024

"""
    MinIOMedia(bucket; endpoint, access_key, secret_key, region, prefix, format, tls_verify, part_size)

An `iSourceMedia` backend backed by a MinIO (or any S3-compatible) object store.

Each object is stored at key `{prefix}/{filename}` inside `bucket`.
An empty `prefix` stores objects directly at the bucket root.

# Arguments
| Name         | Default                   | Description |
|---|---|---|
| `bucket`     | —                         | Target bucket (create first with `minio_create_bucket!`) |
| `endpoint`   | `"http://localhost:9000"` | Server base URL |
| `access_key` | env `MINIO_ACCESS_KEY`    | Access-key ID |
| `secret_key` | env `MINIO_SECRET_KEY`    | Secret key |
| `region`     | `"us-east-1"`             | Region tag (MinIO ignores it) |
| `prefix`     | `""`                      | Logical directory prefix inside the bucket |
| `format`     | `:auto`                   | Default DataFrame format: `:auto`, `:csv`, `:arrow` |
| `tls_verify` | `true`                    | Set `false` to skip TLS cert checks (dev/self-signed only) |
| `part_size`  | `64 MiB`                  | Bytes buffered per multipart part and per ranged GET (at least 5 MiB) |

# Streaming
Objects are written as they are produced, through a buffer of `part_size` bytes: an object that fits in one buffer is
put in one request; a larger one is a multipart upload, one part per full buffer (one part uploads while the next
fills, so at most `2 * part_size` bytes are buffered). Above 1,000 parts the part size doubles every 1,000 parts, so
an object stays under S3's 10,000 parts. Reads fetch the object in ranged GETs of `part_size` bytes into one buffer of
the object's size. No temporary file is written either way.

# Credential resolution order
1. Explicit constructor arguments
2. `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` environment variables
3. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables

# Example
```julia
using MyJuliaToolbox

media = MinIOMedia("analytics";
            endpoint   = "https://minio.example.com",
            access_key = ENV["MINIO_ACCESS_KEY"],
            secret_key = ENV["MINIO_SECRET_KEY"],
            prefix     = "datasets/2025/q1")

write_dataframe(media, "prices.arrow", df)
df2 = read_dataframe(media, "prices.arrow")
```
"""
struct MinIOMedia <: iSourceMedia
    bucket::String
    prefix::String
    format::Symbol
    _config::_MinIOAWSConfig
    part_size::Int
    _backend::_S3Backend

    function MinIOMedia(
        bucket::String;
        endpoint::String   = "http://localhost:9000",
        access_key::String = get(ENV, "MINIO_ACCESS_KEY",
                             get(ENV, "AWS_ACCESS_KEY_ID", "")),
        secret_key::String = get(ENV, "MINIO_SECRET_KEY",
                             get(ENV, "AWS_SECRET_ACCESS_KEY", "")),
        region::String     = "us-east-1",
        prefix::String     = "",
        format::Symbol     = :auto,
        tls_verify::Bool   = true,
        part_size::Integer = _MINIO_DEFAULT_PART_SIZE,
        backend::Union{_S3Backend, Nothing} = nothing,
    )
        isempty(access_key) && throw(ArgumentError(
            "MinIOMedia: access_key is empty. " *
            "Pass it explicitly or set MINIO_ACCESS_KEY."))
        isempty(secret_key) && throw(ArgumentError(
            "MinIOMedia: secret_key is empty. " *
            "Pass it explicitly or set MINIO_SECRET_KEY."))
        format in (:auto, :csv, :arrow) || throw(ArgumentError(
            "Unsupported format: $format. Use :auto, :csv, or :arrow."))
        part_size >= _MINIO_MIN_PART_SIZE || throw(ArgumentError(
            "MinIOMedia: part_size must be at least 5 MiB ($(_MINIO_MIN_PART_SIZE) bytes), got $part_size."))

        if !tls_verify
            # WARNING: disables TLS certificate verification globally for this process.
            # Only use for development against self-signed certificates.
            ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "**"
        end

        creds   = AWS.AWSCredentials(access_key, secret_key)
        cfg     = _MinIOAWSConfig(endpoint, region, creds)
        clean   = rstrip(lstrip(prefix, '/'), '/')
        store   = isnothing(backend) ? _AWSS3Backend(cfg, bucket) : backend
        new(bucket, clean, format, cfg, Int(part_size), store)
    end
end

Base.show(io::Base.IO, m::MinIOMedia) = print(io,
    "MinIOMedia($(repr(m.bucket)), endpoint=$(m._config.endpoint), " *
    "prefix=$(repr(m.prefix)), format=$(m.format))")

# ──────────────────────────────────────────────────────────────────────────────
# Key helpers
# ──────────────────────────────────────────────────────────────────────────────

"""
    _minio_key(media, relative_path) -> String

Build the full S3 object key by joining `media.prefix` and `relative_path`
with a `/`.  Always uses forward slashes regardless of OS.
"""
function _minio_key(media::MinIOMedia, relative_path::String)
    rel = replace(relative_path, '\\' => '/')
    isempty(media.prefix) && return rel
    return "$(media.prefix)/$(lstrip(rel, '/'))"
end

"""
    _minio_object_key(media, filename) -> String

The key of the object a data frame call names: `filename` under the media's prefix; without `filename` (`nothing`),
the prefix itself, as a `FileSystemMedia` without `filename` names its own path.
"""
function _minio_object_key(media::MinIOMedia, filename::Union{AbstractString, Nothing})
    isnothing(filename) || return _minio_key(media, String(filename))
    isempty(media.prefix) && throw(ArgumentError(
        "MinIOMedia: no filename and an empty prefix; pass filename=<name> or a prefix naming the object"))
    return media.prefix
end

"""
    _minio_object_name(key) -> String

The last part of an object's key: the name a local file holding the object gets, whose extension gives the format.
"""
_minio_object_name(key::AbstractString) = String(last(split(replace(key, '\\' => '/'), '/')))

"""
    _minio_content_type(filename) -> String

The content type an object gets from its name's extension.
"""
function _minio_content_type(filename::AbstractString)
    name = lowercase(filename)
    endswith(name, ".gz") && return "application/gzip"
    any(extension -> endswith(name, extension), (".arrow", ".feather")) && return "application/vnd.apache.arrow.file"
    any(extension -> endswith(name, extension), (".csv", ".txt")) && return "text/csv"
    endswith(name, ".tsv") && return "text/tab-separated-values"
    endswith(name, ".xlsx") && return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    endswith(name, ".json") && return "application/json"
    return "application/octet-stream"
end

# ──────────────────────────────────────────────────────────────────────────────
# Low-level S3 wrappers (through the media's backend)
# ──────────────────────────────────────────────────────────────────────────────

"""The whole object `key`, fetched in ranged GETs of `media.part_size` bytes."""
function _s3_get_bytes(media::MinIOMedia, key::String)::Vector{UInt8}
    return _read_object_bytes(media._backend, key; chunk_size = media.part_size)
end

"""Put `data` whole as the object `key`, in one request (for small objects: JSON, parameters)."""
function _s3_put_bytes(media::MinIOMedia, key::String, data::Vector{UInt8};
                        content_type::String = "application/octet-stream")
    _backend_put(media._backend, key, data, content_type)
    return nothing
end

"""Whether the object `key` exists."""
function _s3_exists(media::MinIOMedia, key::String)::Bool
    return _backend_exists(media._backend, key)
end

"""Every key under `prefix`, nested ones included."""
function _s3_list_keys(media::MinIOMedia, prefix::String)::Vector{String}
    return _backend_list(media._backend, prefix; recursive = true)
end

"""The keys one level under `prefix` (which ends in `/`, or is empty for the bucket root), as `readdir` lists."""
function _s3_list_level(media::MinIOMedia, prefix::String)::Vector{String}
    return _backend_list(media._backend, prefix; recursive = false)
end

"""Delete the object `key` from the media's bucket."""
function _s3_delete(media::MinIOMedia, key::String)
    _backend_delete(media._backend, key)
    return nothing
end

"""
    _stream_object(write_body, media, key; content_type)

Call `write_body(io)` with an IO that uploads what it is given to the object `key` as it arrives (see
`_with_multipart_writer`).
"""
function _stream_object(write_body::Function, media::MinIOMedia, key::String; content_type::String)
    return _with_multipart_writer(write_body, media._backend, key;
                                  content_type = content_type, part_size = media.part_size)
end

# ──────────────────────────────────────────────────────────────────────────────
# DataFrame I/O
# ──────────────────────────────────────────────────────────────────────────────

# A MinIO object holds what a local file of the same name holds: the formats, their inference from the extension and
# the bytes are those of `write_dataframe(path)` and `read_dataframe(path)` (an Arrow object is in the Arrow file
# format, readable from its footer). The bytes are streamed to and from the server, with no temporary file.

"""
    _dataframe_bytes(filename, df; format, kwargs...) -> Vector{UInt8}

The bytes `write_dataframe(path, df)` writes into a local file named `filename`, written in memory.
"""
function _dataframe_bytes(filename::String, df::DataFrame; format::Symbol, kwargs...)
    buffer = IOBuffer()
    _write_dataframe_stream(buffer, filename, df; format = format, kwargs...)
    return take!(buffer)
end

"""
    _dataframe_from_bytes(filename, data; format, kwargs...) -> DataFrame

The data frame `read_dataframe(path)` reads from a local file named `filename` holding `data`, read in memory.
"""
function _dataframe_from_bytes(filename::String, data::Vector{UInt8}; format::Symbol, kwargs...)
    return _read_dataframe_bytes(filename, data; format = format, kwargs...)
end

"""
    read_dataframe(media::MinIOMedia, filename; format=media.format, kwargs...) -> DataFrame

Download `filename` from the media's prefix and read it as `read_dataframe(path)` reads a local file of that name:
the same formats (CSV, TSV, gzipped CSV, Arrow, Feather, Excel), inferred from the extension unless `format` says.
The object is fetched in ranged GETs of `media.part_size` bytes into one buffer, with no temporary file.
"""
function read_dataframe(media::MinIOMedia, filename::AbstractString; format::Symbol = media.format, kwargs...)
    key = _minio_object_key(media, filename)
    return _dataframe_from_bytes(_minio_object_name(key), _s3_get_bytes(media, key); format = format, kwargs...)
end

"""
    read_dataframe(media::MinIOMedia; filename=nothing, format=media.format, kwargs...) -> DataFrame

As `read_dataframe(::FileSystemMedia; filename)`: the object `filename` names under the prefix; without `filename`,
the object whose key is the prefix.
"""
function read_dataframe(media::MinIOMedia; filename::Union{AbstractString, Nothing} = nothing,
                        format::Symbol = media.format, kwargs...)
    key = _minio_object_key(media, filename)
    return _dataframe_from_bytes(_minio_object_name(key), _s3_get_bytes(media, key); format = format, kwargs...)
end

"""
    write_dataframe(media::MinIOMedia, filename, df; format=media.format, overwrite=false, atomic=true, kwargs...)

Write `df` as `write_dataframe(path, df)` writes a local file of that name, streamed to `filename` under the media's
prefix (a multipart upload once it outgrows `media.part_size`). Raises `ArgumentError` if the object already exists
and `overwrite=false`. `atomic` is accepted as for a file: an object is complete or absent, as a failed upload is
aborted.
"""
function write_dataframe(media::MinIOMedia, filename::AbstractString, df::DataFrame; format::Symbol = media.format,
                         overwrite::Bool = false, atomic::Bool = true, kwargs...)
    return _write_object(media, _minio_object_key(media, filename), df; format = format, overwrite = overwrite,
                         kwargs...)
end

"""
    write_dataframe(media::MinIOMedia, df; filename=nothing, format=media.format, overwrite=false, atomic=true, kwargs...)

As `write_dataframe(::FileSystemMedia, df; filename)`: the object `filename` names under the prefix; without
`filename`, the object whose key is the prefix.
"""
function write_dataframe(media::MinIOMedia, df::DataFrame; filename::Union{AbstractString, Nothing} = nothing,
                         format::Symbol = media.format, overwrite::Bool = false, atomic::Bool = true, kwargs...)
    return _write_object(media, _minio_object_key(media, filename), df; format = format, overwrite = overwrite,
                         kwargs...)
end

"""
    _write_object(media, key, df; format, overwrite, kwargs...)

Stream `df` to `key` with the bytes a local file of the key's name would hold; refuses an existing object unless
`overwrite`.
"""
function _write_object(media::MinIOMedia, key::String, df::DataFrame; format::Symbol, overwrite::Bool, kwargs...)
    !overwrite && _s3_exists(media, key) && throw(ArgumentError(
        "Object already exists: $key. Pass overwrite=true to overwrite."))
    name = _minio_object_name(key)
    _stream_object(media, key; content_type = _minio_content_type(name)) do io
        _write_dataframe_stream(io, name, df; format = format, kwargs...)
    end
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# Async logger sink
#
# S3 / MinIO does not support byte-range appends.  Records are accumulated in
# an in-process buffer (one buffer per MinIOMedia instance, keyed by object id)
# and streamed as one JSONL object on stop_logger! / minio_flush_log_buffer!.
#
# Alternatively pass `batch_logs=false` to write one object per record
# (simpler, but one HTTP PUT per line).
# ──────────────────────────────────────────────────────────────────────────────

const _MINIO_LOG_BUFFERS = Dict{UInt, Vector{LogRecord}}()
const _MINIO_LOG_LOCK    = ReentrantLock()

"""The buffer of records waiting for upload to `media`, created empty on first use."""
function _minio_log_buffer!(media::MinIOMedia)::Vector{LogRecord}
    id = objectid(media)
    lock(_MINIO_LOG_LOCK) do
        get!(_MINIO_LOG_BUFFERS, id, LogRecord[])
    end
end

"""
    write_log_record(media::MinIOMedia, record::LogRecord; batch_logs=true)

Buffer a log record for later upload.  When `batch_logs=true` (default),
records are held in memory and uploaded as one JSONL object when
`minio_flush_log_buffer!` is called or when the logger is stopped.

When `batch_logs=false` each record is uploaded immediately as its own object
(key: `{prefix}/logs/{date}/{timestamp_ns}.jsonl`).
"""
function write_log_record(media::MinIOMedia, record::LogRecord;
                           batch_logs::Bool = true, kwargs...)
    if batch_logs
        lock(_MINIO_LOG_LOCK) do
            push!(_minio_log_buffer!(media), record)
        end
    else
        _minio_upload_log_records(media, [record])
    end
    return nothing
end

"""
    minio_flush_log_buffer!(media::MinIOMedia)

Upload all buffered log records to MinIO as a single JSONL object and clear
them from the in-memory buffer.  Called automatically by `stop_logger!` when the
sink is a `MinIOMedia`; can also be called explicitly for periodic flushing.
Records stay buffered if the upload fails.

Object key: `{prefix}/logs/{yyyy-mm-dd}/{timestamp_ns}.jsonl`
"""
function minio_flush_log_buffer!(media::MinIOMedia)
    records = lock(_MINIO_LOG_LOCK) do
        copy(_minio_log_buffer!(media))
    end
    isempty(records) && return nothing
    _minio_upload_log_records(media, records)
    lock(_MINIO_LOG_LOCK) do
        # records pushed during the upload follow the uploaded ones: drop only those uploaded
        deleteat!(_minio_log_buffer!(media), 1:length(records))
    end
    return nothing
end

"""A `MinIOMedia` sink uploads its buffered records when the logger stops."""
_finalize_log_sink(media::MinIOMedia) = minio_flush_log_buffer!(media)

"""Stream `records` as one JSONL object under `{prefix}/logs/{date}/`."""
function _minio_upload_log_records(media::MinIOMedia, records::Vector{LogRecord})
    date  = Dates.format(now(), "yyyy-mm-dd")
    key   = _minio_key(media, "logs/$date/$(time_ns()).jsonl")
    _stream_object(media, key; content_type = "application/x-ndjson") do io
        for record in records
            write(io, _log_record_to_jsonl(record), '\n')
        end
    end
    return nothing
end

"""One log record as a JSON line (without the newline)."""
function _log_record_to_jsonl(record::LogRecord)
    return JSON.json(Dict{String,Any}(
        "timestamp" => string(record.timestamp),
        "level"     => string(record.level),
        "message"   => record.message,
        "metadata"  => isnothing(record.metadata) ? nothing : string(record.metadata),
    ))
end

# ──────────────────────────────────────────────────────────────────────────────
# Bucket management
# ──────────────────────────────────────────────────────────────────────────────

"""
    minio_create_bucket!(media::MinIOMedia)

Create the bucket referenced by `media` if it does not already exist.
No-op if the bucket is already present.
"""
function minio_create_bucket!(media::MinIOMedia)
    media.bucket in AWSS3.s3_list_buckets(media._config) ||
        AWSS3.s3_create_bucket(media._config, media.bucket)
    return nothing
end

"""
    minio_list_objects(media::MinIOMedia; prefix=media.prefix) -> Vector{String}

List all object keys under `prefix` in the media's bucket.
"""
function minio_list_objects(media::MinIOMedia; prefix::String = media.prefix)
    p = isempty(prefix) ? "" : prefix * "/"
    return _s3_list_keys(media, p)
end

export MinIOMedia, minio_create_bucket!, minio_list_objects, minio_flush_log_buffer!
