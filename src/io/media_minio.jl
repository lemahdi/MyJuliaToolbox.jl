# MinIO media backend — IO submodule portion
#
# Defines MinIOMedia and implements DataFrame I/O and AsyncLogger support.
# Dataset and parameters dispatch (which reference parent-module symbols like
# _write_dataset_impl, parameters_from_dict, etc.) live in src/minio_extensions.jl,
# which is included at the MyJuliaToolbox top-level after both io.jl and dataset.jl.
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
# MinIOMedia
# ──────────────────────────────────────────────────────────────────────────────

"""
    MinIOMedia(bucket; endpoint, access_key, secret_key, region, prefix, format, tls_verify)

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
    )
        isempty(access_key) && throw(ArgumentError(
            "MinIOMedia: access_key is empty. " *
            "Pass it explicitly or set MINIO_ACCESS_KEY."))
        isempty(secret_key) && throw(ArgumentError(
            "MinIOMedia: secret_key is empty. " *
            "Pass it explicitly or set MINIO_SECRET_KEY."))
        format in (:auto, :csv, :arrow) || throw(ArgumentError(
            "Unsupported format: $format. Use :auto, :csv, or :arrow."))

        if !tls_verify
            # WARNING: disables TLS certificate verification globally for this process.
            # Only use for development against self-signed certificates.
            ENV["JULIA_SSL_NO_VERIFY_HOSTS"] = "**"
        end

        creds   = AWS.AWSCredentials(access_key, secret_key)
        cfg     = _MinIOAWSConfig(endpoint, region, creds)
        clean   = rstrip(lstrip(prefix, '/'), '/')
        new(bucket, clean, format, cfg)
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
# Low-level S3 wrappers (thin pass-throughs to AWSS3.jl)
# ──────────────────────────────────────────────────────────────────────────────

function _s3_get_bytes(media::MinIOMedia, key::String)::Vector{UInt8}
    return AWSS3.s3_get(media._config, media.bucket, key; raw = true)
end

function _s3_put_bytes(media::MinIOMedia, key::String, data::Vector{UInt8};
                        content_type::String = "application/octet-stream")
    AWSS3.s3_put(media._config, media.bucket, key, data, content_type)
    return nothing
end

function _s3_exists(media::MinIOMedia, key::String)::Bool
    return AWSS3.s3_exists(media._config, media.bucket, key)
end

function _s3_list_keys(media::MinIOMedia, prefix::String)::Vector{String}
    objects = AWSS3.s3_list_objects(media._config, media.bucket, prefix; delimiter="")
    return [string(o["Key"]) for o in objects]
end

"""Delete the object `key` from the media's bucket."""
function _s3_delete(media::MinIOMedia, key::String)
    AWSS3.s3_delete(media._config, media.bucket, key)
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# DataFrame I/O
# ──────────────────────────────────────────────────────────────────────────────

# A MinIO object holds what a local file of the same name holds: each call goes through `read_dataframe(path)` or
# `write_dataframe(path)` on a temporary file, so the formats, their inference from the extension and the bytes are
# those of a `FileSystemMedia` (an Arrow object is in the Arrow file format, readable from its footer).

"""
    _dataframe_bytes(filename, df; format, kwargs...) -> Vector{UInt8}

The bytes `write_dataframe(path, df)` writes into a local file named `filename`, written in a temporary folder.
"""
function _dataframe_bytes(filename::String, df::DataFrame; format::Symbol, kwargs...)
    folder = mktempdir()
    try
        path = joinpath(folder, filename)
        write_dataframe(path, df; format = format, overwrite = true, atomic = false, kwargs...)
        return read(path)
    finally
        rm(folder; recursive = true, force = true)
    end
end

"""
    _dataframe_from_bytes(filename, data; format, kwargs...) -> DataFrame

The data frame `read_dataframe(path)` reads from a local file named `filename` holding `data`, in a temporary folder.
"""
function _dataframe_from_bytes(filename::String, data::Vector{UInt8}; format::Symbol, kwargs...)
    folder = mktempdir()
    try
        path = joinpath(folder, filename)
        write(path, data)
        return read_dataframe(path; format = format, kwargs...)
    finally
        GC.gc()
        rm(folder; recursive = true, force = true)
    end
end

"""
    read_dataframe(media::MinIOMedia, filename; format=media.format, kwargs...) -> DataFrame

Download `filename` from the media's prefix and read it as `read_dataframe(path)` reads a local file of that name:
the same formats (CSV, TSV, gzipped CSV, Arrow, Feather, Excel), inferred from the extension unless `format` says.
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

Write `df` as `write_dataframe(path, df)` writes a local file of that name, then upload it as `filename` under the
media's prefix. Raises `ArgumentError` if the object already exists and `overwrite=false`. `atomic` is accepted as for
a file: an object is put whole or not at all.
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

Upload `df` under `key` with the bytes a local file of the key's name would hold; refuses an existing object unless
`overwrite`.
"""
function _write_object(media::MinIOMedia, key::String, df::DataFrame; format::Symbol, overwrite::Bool, kwargs...)
    !overwrite && _s3_exists(media, key) && throw(ArgumentError(
        "Object already exists: $key. Pass overwrite=true to overwrite."))
    name = _minio_object_name(key)
    _s3_put_bytes(media, key, _dataframe_bytes(name, df; format = format, kwargs...);
                  content_type = _minio_content_type(name))
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# Async logger sink
#
# S3 / MinIO does not support byte-range appends.  Records are accumulated in
# an in-process buffer (one buffer per MinIOMedia instance, keyed by object id)
# and flushed as a single JSONL PUT on stop_logger! / minio_flush_log_buffer!.
#
# Alternatively pass `batch_logs=false` to write one object per record
# (simpler, but one HTTP PUT per line).
# ──────────────────────────────────────────────────────────────────────────────

const _MINIO_LOG_BUFFERS = Dict{UInt, Vector{LogRecord}}()
const _MINIO_LOG_LOCK    = ReentrantLock()

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
the in-memory buffer.  Called automatically by `stop_logger!` when the sink
is a `MinIOMedia`; can also be called explicitly for periodic flushing.

Object key: `{prefix}/logs/{yyyy-mm-dd}/{timestamp_ns}.jsonl`
"""
function minio_flush_log_buffer!(media::MinIOMedia)
    records = lock(_MINIO_LOG_LOCK) do
        buf = _minio_log_buffer!(media)
        r   = copy(buf)
        empty!(buf)
        r
    end
    isempty(records) || _minio_upload_log_records(media, records)
    return nothing
end

function _minio_upload_log_records(media::MinIOMedia, records::Vector{LogRecord})
    lines = join((_log_record_to_jsonl(r) for r in records), '\n')
    date  = Dates.format(now(), "yyyy-mm-dd")
    key   = _minio_key(media, "logs/$date/$(time_ns()).jsonl")
    _s3_put_bytes(media, key, Vector{UInt8}(lines * "\n");
                  content_type = "application/x-ndjson")
    return nothing
end

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
