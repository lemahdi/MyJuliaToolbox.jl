# Streaming to and from an S3 backend — IO submodule portion
#
# `_MultipartWriter` uploads what it is written as it arrives: one PUT for an object that fits in one buffer, else a
# multipart upload, one part per full buffer. `_read_object_bytes` fetches an object in ranged GETs into one buffer
# of the object's size. `_write_dataframe_stream` and `_read_dataframe_bytes` give the formats a local file of the
# object's name would have. No temporary file is written.

using Arrow
using CSV
using CodecZlib
using DataFrames
using XLSX

"""S3's largest part."""
const _MINIO_MAX_PART_SIZE = 5 * 1024^3

"""Parts uploaded at one part size before the size doubles (keeps an upload under S3's 10,000 parts)."""
const _MINIO_PARTS_PER_SIZE_STEP = 1000

"""
    _part_size(base_size, part_number) -> Int

The size of part `part_number`: `base_size` for the first 1,000 parts, doubled for each further 1,000, at most
5 GiB. With 64 MiB parts an object reaches 62.5 GiB before the size first doubles; 10,000 parts hold far more than
S3's 5 TiB object limit.
"""
function _part_size(base_size::Int, part_number::Int)
    doublings = min((part_number - 1) ÷ _MINIO_PARTS_PER_SIZE_STEP, 20)
    return min(base_size * 2^doublings, _MINIO_MAX_PART_SIZE)
end

"""Mebibytes per second for `bytes` moved in `seconds` (0 for an instant transfer)."""
_mib_per_second(bytes::Integer, seconds::Real) = seconds > 0 ? round(bytes / 1024^2 / seconds; digits = 1) : 0.0

# ──────────────────────────────────────────────────────────────────────────────
# Writer
# ──────────────────────────────────────────────────────────────────────────────

"""
    _MultipartWriter(backend, key; content_type, part_size)

A write-only `IO` that uploads to the object `key` what it is given, as it arrives.

Bytes fill a buffer of `part_size` bytes. When the buffer is full and more bytes come, the upload begins (with
`content_type`) and the buffer goes as part 1, uploaded by a task while a second buffer fills; each later full buffer
waits for the part before it, then goes as the next part. So at most two buffers (`2 * part_size` bytes) are held.
`close` puts the object in one request if no part went yet (an object of at most `part_size` bytes), else uploads
the last part and completes the upload. `position` is the number of bytes written.

Use it through `_with_multipart_writer`, which aborts the upload when anything throws.
"""
mutable struct _MultipartWriter <: Base.IO
    backend::_S3Backend
    key::String
    content_type::String
    base_part_size::Int
    buffer::Vector{UInt8}                # the buffer being filled; its length is the current part size
    filled::Int                          # bytes of `buffer` holding data
    spare::Union{Vector{UInt8}, Nothing} # the second buffer, when no part upload holds it
    in_flight::Union{Task, Nothing}      # the part upload under way, returning (etag, buffer)
    upload_id::Union{String, Nothing}
    etags::Vector{String}
    parts_started::Int
    bytes_written::Int
    bytes_uploaded::Int
    peak_buffered_bytes::Int             # most bytes held in buffers at once
    started_ns::UInt64
    closed::Bool
end

function _MultipartWriter(backend::_S3Backend, key::String; content_type::String, part_size::Int)
    first_buffer = Vector{UInt8}(undef, _part_size(part_size, 1))
    return _MultipartWriter(backend, key, content_type, part_size, first_buffer, 0, nothing, nothing, nothing,
                            String[], 0, 0, 0, length(first_buffer), time_ns(), false)
end

Base.isopen(writer::_MultipartWriter) = !writer.closed
Base.iswritable(writer::_MultipartWriter) = !writer.closed
Base.isreadable(::_MultipartWriter) = false
Base.position(writer::_MultipartWriter) = writer.bytes_written
Base.flush(::_MultipartWriter) = nothing

"""Throw unless `writer` still takes bytes."""
function _check_writable(writer::_MultipartWriter)
    writer.closed && throw(ArgumentError("MinIO writer for $(writer.key) is closed"))
    return nothing
end

function Base.unsafe_write(writer::_MultipartWriter, pointer_in::Ptr{UInt8}, byte_count::UInt)
    _check_writable(writer)
    remaining = Int(byte_count)
    offset = 0
    while remaining > 0
        writer.filled == length(writer.buffer) && _ship_full_buffer!(writer)
        chunk = min(length(writer.buffer) - writer.filled, remaining)
        buffer = writer.buffer
        GC.@preserve buffer unsafe_copyto!(pointer(buffer, writer.filled + 1), pointer_in + offset, chunk)
        writer.filled += chunk
        writer.bytes_written += chunk
        offset += chunk
        remaining -= chunk
    end
    return Int(byte_count)
end

function Base.write(writer::_MultipartWriter, byte::UInt8)
    _check_writable(writer)
    writer.filled == length(writer.buffer) && _ship_full_buffer!(writer)
    writer.filled += 1
    writer.buffer[writer.filled] = byte
    writer.bytes_written += 1
    return 1
end

"""Bytes held in the writer's buffers right now (the one filling, the spare, the one uploading)."""
function _buffered_bytes(writer::_MultipartWriter)
    spare_bytes = isnothing(writer.spare) ? 0 : length(writer.spare)
    in_flight_bytes = isnothing(writer.in_flight) ? 0 : _part_size(writer.base_part_size, writer.parts_started)
    return length(writer.buffer) + spare_bytes + in_flight_bytes
end

"""
    _upload_part_logged(backend, key, upload_id, part_number, data, total_before) -> (etag, data)

Upload `data` as part `part_number` and log it; returns the ETag and the buffer, free again.
"""
function _upload_part_logged(backend, key::String, upload_id::String, part_number::Int, data::Vector{UInt8},
                             total_before::Int)
    part_started = time_ns()
    etag = _backend_upload_part(backend, key, upload_id, part_number, data)
    seconds = (time_ns() - part_started) / 1e9
    @info "MinIO part uploaded" key part = part_number bytes = length(data) total_bytes = total_before + length(data) seconds = round(seconds; digits = 3) mib_s = _mib_per_second(length(data), seconds)
    return (etag, data)
end

"""The value of `task`, or the error it threw (not wrapped in a `TaskFailedException`)."""
function _fetch_unwrapped(task::Task)
    try
        return fetch(task)
    catch failure
        failure isa TaskFailedException && throw(failure.task.exception)
        rethrow()
    end
end

"""Wait for the part upload under way, if any: record its ETag and take its buffer back as the spare."""
function _wait_in_flight!(writer::_MultipartWriter)
    task = writer.in_flight
    isnothing(task) && return nothing
    writer.in_flight = nothing
    etag, data = _fetch_unwrapped(task)
    push!(writer.etags, etag)
    writer.bytes_uploaded += length(data)
    writer.spare = data
    return nothing
end

"""
    _ship_full_buffer!(writer)

Send the full buffer as the next part (beginning the upload on the first one) and go on filling the other buffer,
grown to the next part's size.
"""
function _ship_full_buffer!(writer::_MultipartWriter)
    if isnothing(writer.upload_id)
        writer.upload_id = _backend_begin_upload(writer.backend, writer.key, writer.content_type)
    end
    _wait_in_flight!(writer)
    writer.parts_started += 1
    data = writer.buffer
    total_before = writer.bytes_uploaded
    writer.in_flight = Threads.@spawn _upload_part_logged(writer.backend, writer.key, writer.upload_id,
                                                          writer.parts_started, data, total_before)
    next_buffer = something(writer.spare, UInt8[])
    writer.spare = nothing
    resize!(next_buffer, _part_size(writer.base_part_size, writer.parts_started + 1))
    writer.buffer = next_buffer
    writer.filled = 0
    writer.peak_buffered_bytes = max(writer.peak_buffered_bytes, _buffered_bytes(writer))
    return nothing
end

"""
    close(writer::_MultipartWriter)

Finish the object: one PUT if no part went yet, else the last part and the completion. A second `close` does
nothing.
"""
function Base.close(writer::_MultipartWriter)
    writer.closed && return nothing
    writer.closed = true
    if isnothing(writer.upload_id)
        _backend_put(writer.backend, writer.key, resize!(writer.buffer, writer.filled), writer.content_type)
        writer.bytes_uploaded = writer.filled
        part_count = 1
    else
        _wait_in_flight!(writer)
        writer.parts_started += 1
        last_part = resize!(writer.buffer, writer.filled)
        etag, _ = _upload_part_logged(writer.backend, writer.key, writer.upload_id, writer.parts_started, last_part,
                                      writer.bytes_uploaded)
        push!(writer.etags, etag)
        writer.bytes_uploaded += length(last_part)
        _backend_complete_upload(writer.backend, writer.key, writer.upload_id, writer.etags)
        part_count = length(writer.etags)
    end
    seconds = (time_ns() - writer.started_ns) / 1e9
    @info "MinIO object written" key = writer.key parts = part_count bytes = writer.bytes_uploaded seconds = round(seconds; digits = 3) mib_s = _mib_per_second(writer.bytes_uploaded, seconds)
    writer.buffer = UInt8[]
    writer.spare = nothing
    return nothing
end

"""
    _abort!(writer)

Give up the object after a failure: wait for the part upload under way (ignoring its error) and abort the upload,
so the server drops its parts. An abort that fails is logged, not thrown: the first error is the one to report.
"""
function _abort!(writer::_MultipartWriter)
    writer.closed = true
    task = writer.in_flight
    writer.in_flight = nothing
    if !isnothing(task)
        try
            wait(task)
        catch
        end
    end
    if !isnothing(writer.upload_id)
        try
            _backend_abort_upload(writer.backend, writer.key, writer.upload_id)
            @info "MinIO upload aborted" key = writer.key parts = writer.parts_started
        catch abort_error
            @warn "MinIO upload abort failed; the server keeps its parts until it expires them" key = writer.key upload_id = writer.upload_id exception = abort_error
        end
    end
    writer.buffer = UInt8[]
    writer.spare = nothing
    return nothing
end

"""
    _with_multipart_writer(write_body, backend, key; content_type, part_size)

Call `write_body(writer)` with a `_MultipartWriter` to `key`, then close it, which puts or completes the object. If
anything throws, the upload is aborted and the error rethrown, so the object is either complete or not written.
Returns the writer (closed).
"""
function _with_multipart_writer(write_body::Function, backend::_S3Backend, key::String; content_type::String,
                                part_size::Int)
    writer = _MultipartWriter(backend, key; content_type = content_type, part_size = part_size)
    try
        write_body(writer)
        close(writer)
    catch
        _abort!(writer)
        rethrow()
    end
    return writer
end

# ──────────────────────────────────────────────────────────────────────────────
# Reader
# ──────────────────────────────────────────────────────────────────────────────

"""
    _read_object_bytes(backend, key; chunk_size) -> Vector{UInt8}

The object `key` whole: its size from a HEAD, then ranged GETs of `chunk_size` bytes copied into one buffer of that
size. Each GET is logged.
"""
function _read_object_bytes(backend::_S3Backend, key::String; chunk_size::Int)
    started = time_ns()
    total_bytes = _backend_object_size(backend, key)
    bytes = Vector{UInt8}(undef, total_bytes)
    offset = 0
    part_number = 0
    while offset < total_bytes
        part_number += 1
        last_byte = min(offset + chunk_size, total_bytes)
        part_started = time_ns()
        chunk = _backend_get_range(backend, key, offset + 1, last_byte)
        length(chunk) == last_byte - offset || throw(ErrorException(
            "MinIO: range $(offset + 1)-$last_byte of $key gave $(length(chunk)) bytes; the object changed while read"))
        copyto!(bytes, offset + 1, chunk, 1, length(chunk))
        offset = last_byte
        seconds = (time_ns() - part_started) / 1e9
        @info "MinIO range downloaded" key part = part_number bytes = length(chunk) total_bytes = offset seconds = round(seconds; digits = 3) mib_s = _mib_per_second(length(chunk), seconds)
    end
    seconds = (time_ns() - started) / 1e9
    @info "MinIO object read" key parts = part_number bytes = total_bytes seconds = round(seconds; digits = 3) mib_s = _mib_per_second(total_bytes, seconds)
    return bytes
end

# ──────────────────────────────────────────────────────────────────────────────
# Formats: what a local file of the object's name holds
# ──────────────────────────────────────────────────────────────────────────────

"""
    _object_format(filename, format) -> (kind, gzipped)

The format a local file named `filename` gets from `write_dataframe(path)` and `read_dataframe(path)`: `kind` is
`:csv`, `:arrow`, `:excel`, `:xls` (refused) or `:unknown`; `gzipped` is true for a `.gz` name. The rules are the
path functions' own, in their order: a `.csv` name is CSV whatever `format` says.
"""
function _object_format(filename::AbstractString, format::Symbol)
    extension = lowercase(splitext(filename)[2])
    gzipped = extension == ".gz"
    if gzipped
        extension = lowercase(splitext(filename[1:end-3])[2])
    end
    (format == :csv || extension in (".csv", ".tsv", ".txt")) && return (:csv, gzipped)
    (format == :arrow || extension in (".arrow", ".feather")) && return (:arrow, gzipped)
    (format == :excel || extension == ".xlsx") && return (:excel, gzipped)
    extension == ".xls" && return (:xls, gzipped)
    return (:unknown, gzipped)
end

"""
    _write_dataframe_stream(io, filename, df; format, kwargs...)

Write into `io` the bytes `write_dataframe(path, df; format)` writes into a local file named `filename`: CSV (gzipped
for a `.gz` name), an Arrow file (`ARROW1` at both ends, one record batch, the same bytes), or Excel. `io` needs only
`write` and `position`: the Arrow file writer writes its footer at the end, without seeking. `io` is left open.
"""
function _write_dataframe_stream(io::Base.IO, filename::AbstractString, df::DataFrame; format::Symbol, kwargs...)
    kind, gzipped = _object_format(filename, format)
    if kind == :csv
        _write_csv_stream(io, df, gzipped; kwargs...)
    elseif kind == :arrow
        gzipped && throw(ArgumentError("Gzipped Arrow writing is not supported; write to uncompressed .arrow files"))
        Arrow.write(io, _normalize_enum_columns_for_arrow(df); file = true, ntasks = 1, kwargs...)
    elseif kind == :excel
        gzipped && throw(ArgumentError("Gzipped Excel writing is not supported; write to uncompressed .xlsx files"))
        _write_excel_stream(io, df; kwargs...)
    elseif kind == :xls
        throw(ArgumentError("Legacy .xls format is not supported for writing; use .xlsx instead"))
    else
        extension = lowercase(splitext(filename)[2])
        throw(ArgumentError("Unsupported file extension for writing: $extension; specify format=:csv, format=:arrow, or format=:excel"))
    end
    return nothing
end

"""
    _NonClosingIO(inner)

Passes writes to `inner` but ignores `close`: a gzip stream closes the IO it wraps when it ends, and the caller still
needs that IO (to close or read it itself).
"""
struct _NonClosingIO{T <: Base.IO} <: Base.IO
    inner::T
end

Base.unsafe_write(io::_NonClosingIO, pointer_in::Ptr{UInt8}, byte_count::UInt) =
    Base.unsafe_write(io.inner, pointer_in, byte_count)
Base.write(io::_NonClosingIO, byte::UInt8) = write(io.inner, byte)
Base.isopen(io::_NonClosingIO) = isopen(io.inner)
Base.iswritable(io::_NonClosingIO) = iswritable(io.inner)
Base.position(io::_NonClosingIO) = position(io.inner)
Base.flush(io::_NonClosingIO) = flush(io.inner)
Base.close(::_NonClosingIO) = nothing

"""Write `df` as CSV into `io`, through a gzip stream when `gzipped`; `io` is left open."""
function _write_csv_stream(io::Base.IO, df::DataFrame, gzipped::Bool; kwargs...)
    if gzipped
        compressor = CodecZlib.GzipCompressorStream(_NonClosingIO(io))
        CSV.write(compressor, df; kwargs...)
        close(compressor)
    else
        CSV.write(io, df; kwargs...)
    end
    return nothing
end

"""
Write `df` as an Excel workbook into `io`. The workbook is built in memory first (XLSX writes a zip archive), then
copied: Excel objects are small, and XLSX's writing to a stream is not relied on.
"""
function _write_excel_stream(io::Base.IO, df::DataFrame; kwargs...)
    sheet = string(get(kwargs, :sheet, "Sheet1"))
    workbook = IOBuffer()
    XLSX.writetable(workbook, collect(eachcol(df)), names(df); sheetname = sheet)
    write(io, take!(workbook))
    return nothing
end

"""
    _read_dataframe_bytes(filename, data; format, kwargs...) -> DataFrame

The data frame `read_dataframe(path; format)` reads from a local file named `filename` holding `data`, read from
memory: Arrow straight from the bytes, CSV (gzipped for a `.gz` name), Excel; an unknown extension is tried as Arrow,
then CSV, as for a file.
"""
function _read_dataframe_bytes(filename::AbstractString, data::Vector{UInt8}; format::Symbol, kwargs...)
    kind, gzipped = _object_format(filename, format)
    if kind == :csv
        return _read_csv_bytes(data, gzipped; kwargs...)
    elseif kind == :arrow
        gzipped && throw(ArgumentError("Gzipped Arrow files are not supported; please provide an uncompressed .arrow file"))
        return DataFrame(Arrow.Table(data; kwargs...))
    elseif kind == :excel
        gzipped && throw(ArgumentError("Gzipped Excel files are not supported; please provide an uncompressed .xlsx file"))
        return _read_excel_bytes(data; kwargs...)
    elseif kind == :xls
        throw(ArgumentError("Legacy .xls format is not supported; please convert to .xlsx"))
    end
    try
        return DataFrame(Arrow.Table(data; kwargs...))
    catch
        return _read_csv_bytes(data, gzipped; kwargs...)
    end
end

"""Read CSV bytes, through a gzip stream when `gzipped`."""
function _read_csv_bytes(data::Vector{UInt8}, gzipped::Bool; kwargs...)
    gzipped || return CSV.read(data, DataFrame; kwargs...)
    return CSV.read(CodecZlib.GzipDecompressorStream(IOBuffer(data)), DataFrame; kwargs...)
end

"""Read an Excel workbook's sheet (`sheet` keyword, the first by default) from its bytes."""
function _read_excel_bytes(data::Vector{UInt8}; kwargs...)
    options = Dict(kwargs)
    sheet = get(options, :sheet, 1)
    remaining = filter(option -> option[1] != :sheet, options)
    return DataFrame(XLSX.readtable(IOBuffer(data), sheet; remaining...))
end
