# MinIO media backend — IO submodule portion
#
# Defines MinIOMedia and implements DataFrame I/O and AsyncLogger support.
# Dataset and parameters dispatch (which reference parent-module symbols like
# _write_dataset_impl, parameters_from_dict, etc.) live in src/minio_extensions.jl,
# which is included at the MyJuliaToolbox top-level after both io.jl and dataset.jl.
#
# Required packages (add to Project.toml before using):
#   AWSS3 = "1c724243-ef5b-5fd7-8eda-4d50c531a078"
#   AWS   = "fbe9abb3-538b-5e4e-ba9e-0f9b42bc2d2e"

import AWS
using Arrow
using CSV
using DataFrames
using Dates
using JSON

# ──────────────────────────────────────────────────────────────────────────────
# Lazy-load guard
# ──────────────────────────────────────────────────────────────────────────────
function _require_awss3()
    if !isdefined(Main, :AWSS3)
        try
            Base.require(Main, :AWSS3)
        catch
            throw(ArgumentError(
                "MinIOMedia requires AWSS3.jl. Add it to your project:\n" *
                "  pkg> add AWSS3\n  pkg> add AWS"
            ))
        end
    end
end

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
using AWSS3, AWS, MyJuliaToolbox

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
        _require_awss3()

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

        aws_mod = Base.require(Main, :AWS)
        creds   = aws_mod.AWSCredentials(access_key, secret_key)
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

function _minio_infer_format(filename::String, default::Symbol)
    default != :auto && return default
    lf = lowercase(filename)
    endswith(lf, ".arrow")  && return :arrow
    endswith(lf, ".csv")    && return :csv
    endswith(lf, ".csv.gz") && return :csv
    throw(ArgumentError(
        "Cannot infer format from \"$filename\". " *
        "Pass format=:arrow or format=:csv explicitly, or rename the file."))
end

# ──────────────────────────────────────────────────────────────────────────────
# Low-level S3 wrappers (thin pass-throughs to AWSS3.jl)
# ──────────────────────────────────────────────────────────────────────────────

function _s3_get_bytes(media::MinIOMedia, key::String)::Vector{UInt8}
    awss3 = Base.require(Main, :AWSS3)
    return awss3.s3_get(media._config, media.bucket, key; raw = true)
end

function _s3_put_bytes(media::MinIOMedia, key::String, data::Vector{UInt8};
                        content_type::String = "application/octet-stream")
    awss3 = Base.require(Main, :AWSS3)
    awss3.s3_put(media._config, media.bucket, key, data, content_type)
    return nothing
end

function _s3_exists(media::MinIOMedia, key::String)::Bool
    awss3 = Base.require(Main, :AWSS3)
    return awss3.s3_exists(media._config, media.bucket, key)
end

function _s3_list_keys(media::MinIOMedia, prefix::String)::Vector{String}
    awss3 = Base.require(Main, :AWSS3)
    objects = awss3.s3_list_objects(media._config, media.bucket, prefix; delimiter="")
    return [string(o["Key"]) for o in objects]
end

# ──────────────────────────────────────────────────────────────────────────────
# DataFrame I/O
# ──────────────────────────────────────────────────────────────────────────────

"""
    read_dataframe(media::MinIOMedia, filename; format=:auto, kwargs...) -> DataFrame

Download `filename` from the MinIO bucket and deserialise it as a DataFrame.
Format is inferred from the file extension unless overridden.
"""
function read_dataframe(media::MinIOMedia, filename::AbstractString;
                         format::Symbol = :auto, kwargs...)
    key  = _minio_key(media, String(filename))
    fmt  = _minio_infer_format(String(filename),
                                media.format == :auto ? format : media.format)
    data = _s3_get_bytes(media, key)
    # Call Arrow/CSV directly to avoid LSP ambiguity with the Base.IO overloads.
    if fmt == :arrow
        return DataFrame(Arrow.Table(IOBuffer(data); kwargs...))
    else
        return CSV.read(IOBuffer(data), DataFrame; kwargs...)
    end
end

"""
    write_dataframe(media::MinIOMedia, filename, df; format=:auto, overwrite=false, kwargs...)

Serialise `df` in-memory and upload it as `filename` to the MinIO bucket.
Raises `ArgumentError` if the object already exists and `overwrite=false`.
"""
function write_dataframe(media::MinIOMedia, filename::AbstractString, df::DataFrame;
                          format::Symbol = :auto,
                          overwrite::Bool = false,
                          kwargs...)
    key = _minio_key(media, String(filename))
    fmt = _minio_infer_format(String(filename),
                               media.format == :auto ? format : media.format)

    !overwrite && _s3_exists(media, key) && throw(ArgumentError(
        "Object already exists: $key. Pass overwrite=true to overwrite."))

    buf = IOBuffer()
    if fmt == :arrow
        Arrow.write(buf, _normalize_enum_columns_for_arrow(df); kwargs...)
    else
        CSV.write(buf, df; kwargs...)
    end
    content_type = fmt == :arrow ? "application/vnd.apache.arrow.stream" : "text/csv"
    _s3_put_bytes(media, key, take!(buf); content_type)
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
    awss3 = Base.require(Main, :AWSS3)
    media.bucket in awss3.s3_list_buckets(media._config) ||
        awss3.s3_create_bucket(media._config, media.bucket)
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
