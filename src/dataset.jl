# Dataset interface for managing data collections
# Provides an abstraction layer for different dataset implementations

using DataFrames
using JSON
using ZipFile
using Tar
using CodecZlib

const _DATASET_PARAMETER_REF_KIND = "mjt_iParameters_ref"
const _DATASET_PARAMETERS_DIR = "parameters"
const _DATASET_INFO_KIND = "mjt_dataset_info"
const _DATASET_INFO_FILE = "data_info.json"

# Cache mapping serialized type names to their resolved Julia Type objects.
# Avoids repeated Meta.parse + module traversal on every read_dataset call.
const _DATASET_TYPE_CACHE = Dict{String, Type}()

export iDataSet, LoadedDataSet, write_dataset, read_dataset, nonpersisted_fields

"""
    abstract type iDataSet

Abstract base type for dataset implementations. Concrete implementations should define
how to manage and access collections of data (e.g., in-memory datasets, lazy datasets, etc.).

# Implementation Guidelines
Subtypes should typically implement:
- Data access methods (e.g., iteration, indexing)
- Data transformation operations
- Metadata management
- Data validation

# Example
```julia
struct MyDataSet <: iDataSet
    data::DataFrame
    metadata::Dict{String,Any}
end
```
"""
abstract type iDataSet end

"""
    nonpersisted_fields(::Type{T}) -> Tuple{Vararg{Symbol}}

Return the field names of `T` that `write_dataset` should skip and `read_dataset`
should tolerate as absent (defaulting to a sensible zero value).

Override this for any concrete `iDataSet` subtype that has optional or
intentionally-omitted fields:

```julia
nonpersisted_fields(::Type{MyDataSet}) = (:cached_scores_df,)
```

**Automatic defaults by field type**
- `DataFrame` → `DataFrame()`
- `Union{Nothing, T}` → `nothing`

Any other type requires the field to actually be present on disk.
"""
nonpersisted_fields(::Type{<:iDataSet}) = ()

"""
    LoadedDataSet(attributes::Dict{Symbol,Any})

Concrete `iDataSet` returned by `read_dataset`.
Stores all loaded entries in `attributes`.
"""
struct LoadedDataSet <: iDataSet
    attributes::Dict{Symbol,Any}
end

"""
    write_dataset(source::IO.iSourceMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)

Write dataset fields into a media destination.

- `DataFrame` fields are written as `<fieldname>.<ext>` where extension is based on `type`
- All other fields are serialized into `data.json`
- Dataset type metadata is saved into `data_info.json` for auto-typed reads

Supported media sources:
- `IO.FileSystemMedia`
- `IO.ConsoleMedia`
"""
function write_dataset(source::IO.iSourceMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)
    return _write_dataset_impl(source, dataset; type=type, overwrite=overwrite, atomic=atomic, pretty=pretty)
end

function _write_dataset_impl(source::IO.FileSystemMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)
    if !(type in (:arrow, :csv))
        throw(ArgumentError("Unsupported dataset type: $type. Supported values are :arrow and :csv."))
    end

    ext = type == :arrow ? "arrow" : "csv"

    if isfile(source.path)
        throw(ArgumentError("Expected a directory path for FileSystemMedia, got a file: $(source.path)"))
    end
    mkpath(source.path)

    payload = Dict{String,Any}()
    parameter_counter = Ref(0)
    np_fields = Set(nonpersisted_fields(typeof(dataset)))
    for field_name in fieldnames(typeof(dataset))
        field_name in np_fields && continue
        value = getfield(dataset, field_name)
        field_t = fieldtype(typeof(dataset), field_name)
        if value isa DataFrame
            nrow(value) == 0 && continue   # skip empty DataFrames — absent on read-back means empty
            file_name = "$(field_name).$(ext)"
            IO.write_dataframe(source, file_name, value; format=type, overwrite=overwrite, atomic=atomic)
        elseif value isa iParameters
            write_parameters(source, "$(field_name).json", value, _DATASET_PARAMETERS_DIR; overwrite=overwrite, pretty=pretty)
            if _parameters_field_needs_type_ref(field_t)
                payload[string(field_name)] = Dict(
                    "__kind__" => _DATASET_PARAMETER_REF_KIND,
                    "type" => string(typeof(value)),
                    "file" => "$(field_name).json",
                    "relative_path" => _DATASET_PARAMETERS_DIR,
                )
            end
        else
            payload[string(field_name)] = _dataset_to_json_value(value, source, parameter_counter; overwrite=overwrite, pretty=pretty)
        end
    end

    json_path = joinpath(source.path, "data.json")
    if isfile(json_path) && !overwrite
        throw(ArgumentError("File already exists: $json_path. Pass overwrite=true to overwrite."))
    end

    open(json_path, "w") do io
        if pretty
            JSON.print(io, payload, 2)
        else
            JSON.print(io, payload)
        end
    end

    _write_dataset_info(source.path, typeof(dataset); overwrite=overwrite, pretty=pretty)

    return nothing
end

function _write_dataset_impl(source::IO.ConsoleMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)
    payload = Dict{String,Any}()

    for field_name in fieldnames(typeof(dataset))
        value = getfield(dataset, field_name)
        if value isa DataFrame
            println(source.stream, "### $(field_name)")
            show(source.stream, MIME("text/plain"), value)
            println(source.stream)
        else
            payload[string(field_name)] = _dataset_to_json_value(value)
        end
    end

    if !isempty(payload)
        println(source.stream, "### data.json")
        if pretty
            JSON.print(source.stream, payload, 2)
        else
            JSON.print(source.stream, payload)
        end
        println(source.stream)
    end

    return nothing
end

function _write_dataset_impl(source::IO.iSourceMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)
    throw(ArgumentError("write_dataset is only implemented for FileSystemMedia and ConsoleMedia. Received: $(typeof(source))"))
end

"""
    read_dataset(source::IO.iSourceMedia; type::Symbol=:arrow)

Read dataset artifacts from media source and return a `LoadedDataSet`.

Supported media source:
- `IO.FileSystemMedia`
"""
function read_dataset(source::IO.iSourceMedia; type::Symbol=:arrow)
    loaded = _read_dataset_impl(source; type=type)
    if loaded isa LoadedDataSet && source isa IO.FileSystemMedia
        declared_type = _read_dataset_declared_type(source)
        if !isnothing(declared_type)
            return _dataset_from_attributes(declared_type, loaded.attributes, source)
        end
    end
    return loaded
end

function read_dataset(path::AbstractString; type::Symbol=:arrow)
    _is_archive_path(path) && return read_dataset(IO.ArchiveMedia(path); type=type)
    return read_dataset(IO.FileSystemMedia(path); type=type)
end

function read_dataset(::Type{T}, source::IO.iSourceMedia; type::Symbol=:arrow) where {T <: iDataSet}
    loaded = _read_dataset_impl(source; type=type)
    return _dataset_from_attributes(T, loaded.attributes, source)
end

function read_dataset(::Type{T}, path::AbstractString; type::Symbol=:arrow) where {T <: iDataSet}
    _is_archive_path(path) && return read_dataset(T, IO.ArchiveMedia(path); type=type)
    return read_dataset(T, IO.FileSystemMedia(path); type=type)
end

function _write_dataset_info(base_path::AbstractString, dataset_type::Type; overwrite::Bool=false, pretty::Bool=true)
    info_path = joinpath(base_path, _DATASET_INFO_FILE)
    if isfile(info_path) && !overwrite
        throw(ArgumentError("File already exists: $info_path. Pass overwrite=true to overwrite."))
    end

    payload = Dict(
        "__kind__" => _DATASET_INFO_KIND,
        "dataset_type" => string(dataset_type),
    )

    open(info_path, "w") do io
        if pretty
            JSON.print(io, payload, 2)
        else
            JSON.print(io, payload)
        end
    end

    return nothing
end

function _read_dataset_declared_type(source::IO.FileSystemMedia)
    info_path = joinpath(source.path, _DATASET_INFO_FILE)
    if !isfile(info_path)
        return nothing
    end

    info = JSON.parsefile(info_path)
    info isa AbstractDict || return nothing
    haskey(info, "dataset_type") || return nothing

    kind = haskey(info, "__kind__") ? string(info["__kind__"]) : _DATASET_INFO_KIND
    kind == _DATASET_INFO_KIND || return nothing

    resolved = _dataset_resolve_type_from_name(string(info["dataset_type"]))
    resolved <: iDataSet || throw(ArgumentError("Resolved dataset type $(resolved) is not a subtype of iDataSet."))
    Base.isconcretetype(resolved) || throw(ArgumentError("Resolved dataset type $(resolved) must be concrete."))
    return resolved
end

function _read_dataset_impl(source::IO.FileSystemMedia; type::Symbol=:arrow)
    if !(type in (:arrow, :csv))
        throw(ArgumentError("Unsupported dataset type: $type. Supported values are :arrow and :csv."))
    end

    if !isdir(source.path)
        throw(ArgumentError("Directory not found for dataset read: $(source.path)"))
    end

    ext = type == :arrow ? ".arrow" : ".csv"
    attributes = Dict{Symbol,Any}()

    for entry in readdir(source.path)
        full_path = joinpath(source.path, entry)
        if isfile(full_path) && lowercase(splitext(entry)[2]) == ext
            key = Symbol(splitext(entry)[1])
            attributes[key] = IO.read_dataframe(full_path; format=type)
        end
    end

    json_path = joinpath(source.path, "data.json")
    if isfile(json_path)
        json_data = JSON.parsefile(json_path)
        for (k, v) in json_data
            attributes[Symbol(k)] = _dataset_decode_json_value(v, source)
        end
    end

    return LoadedDataSet(attributes)
end

function _read_dataset_impl(source::IO.iSourceMedia; type::Symbol=:arrow)
    throw(ArgumentError("read_dataset is only implemented for FileSystemMedia. Received: $(typeof(source))"))
end

# ──────────────────────────────────────────────────────────────────────────────
# ArchiveMedia support
# ──────────────────────────────────────────────────────────────────────────────

"""
    read_dataset(source::IO.ArchiveMedia; type::Symbol=:arrow)

Read a dataset from an archive. For `.zip`: reads Arrow/CSV entries directly into
in-memory `IOBuffer`s — no temp directory, no disk I/O. For `.tar.gz`: extracts to
a temporary directory (sequential stream requires full decompression).
"""
function read_dataset(source::IO.ArchiveMedia; type::Symbol=:arrow)
    isfile(source.path) || throw(ArgumentError("Archive file not found: $(source.path)"))
    if source.format == :zip
        declared_type = _read_archive_declared_type(source)
        loaded = _read_dataset_from_zip(source.path, declared_type; type=type)
        if !isnothing(declared_type)
            return _dataset_from_attributes(declared_type, loaded.attributes, nothing)
        end
        return loaded
    else
        _with_archive_extracted(source) do tmp_media
            read_dataset(tmp_media; type=type)
        end
    end
end

"""
    read_dataset(::Type{T}, source::IO.ArchiveMedia; type::Symbol=:arrow)

Typed variant of archive read. For `.zip`: reads Arrow/CSV entries directly into
`IOBuffer`s — non-persisted fields declared via `nonpersisted_fields(T)` are skipped
entirely (not read from the archive at all). For `.tar.gz`: extracts to a temp directory.
"""
function read_dataset(::Type{T}, source::IO.ArchiveMedia; type::Symbol=:arrow) where {T <: iDataSet}
    isfile(source.path) || throw(ArgumentError("Archive file not found: $(source.path)"))
    if source.format == :zip
        loaded = _read_dataset_from_zip(source.path, T; type=type)
        return _dataset_from_attributes(T, loaded.attributes, nothing)
    else
        _with_archive_extracted(source; skip_files=_np_skip_files(T, type)) do tmp_media
            read_dataset(T, tmp_media; type=type)
        end
    end
end

"""
    _write_dataset_impl(source::IO.ArchiveMedia, dataset::iDataSet; kwargs...)

Write `dataset` into a temporary directory, then pack it into the archive at
`source.path`. Supports `:zip` and `:tar_gz` formats.
"""
function _write_dataset_impl(source::IO.ArchiveMedia, dataset::iDataSet; type::Symbol=:arrow, overwrite::Bool=false, atomic::Bool=true, pretty::Bool=true)
    if isfile(source.path) && !overwrite
        throw(ArgumentError("Archive already exists: $(source.path). Pass overwrite=true to overwrite."))
    end

    tmp_dir = mktempdir()
    try
        tmp_media = IO.FileSystemMedia(tmp_dir)
        _write_dataset_impl(tmp_media, dataset; type=type, overwrite=true, atomic=false, pretty=pretty)

        if atomic
            tmp_archive = source.path * ".tmp"
            try
                _pack_dir_to_archive(tmp_dir, tmp_archive, source.format)
                mv(tmp_archive, source.path; force=true)
            catch
                isfile(tmp_archive) && rm(tmp_archive; force=true)
                rethrow()
            end
        else
            _pack_dir_to_archive(tmp_dir, source.path, source.format)
        end
    finally
        rm(tmp_dir; recursive=true, force=true)
    end

    return nothing
end

function _is_archive_path(path::AbstractString)
    lp = lowercase(path)
    return endswith(lp, ".zip") || endswith(lp, ".tar.gz") || endswith(lp, ".tgz")
end

# ── Internal helpers ──────────────────────────────────────────────────────────

# Returns the set of archive file names (e.g. "scores.arrow") to skip for type T.
function _np_skip_files(::Nothing, type::Symbol)
    return Set{String}()
end

function _np_skip_files(::Type{T}, type::Symbol) where {T <: iDataSet}
    fields = nonpersisted_fields(T)
    isempty(fields) && return Set{String}()
    ext = type == :arrow ? "arrow" : "csv"
    return Set{String}(string(fn, ".", ext) for fn in fields)
end

# Peek at data_info.json inside a zip archive to resolve the declared dataset type.
# Returns nothing for tar.gz (sequential stream — not worth two passes).
function _read_archive_declared_type(source::IO.ArchiveMedia)
    source.format == :zip || return nothing
    r = ZipFile.Reader(source.path)
    try
        prefix = _zip_strip_prefix(r.files)
        for f in r.files
            norm = replace(f.name, '\\' => '/')
            endswith(norm, '/') && continue
            rel = isempty(prefix) ? norm : (startswith(norm, prefix) ? norm[length(prefix)+1:end] : norm)
            rel == _DATASET_INFO_FILE || continue
            info = JSON.parse(String(read(f)))
            info isa AbstractDict || return nothing
            haskey(info, "dataset_type") || return nothing
            get(info, "__kind__", _DATASET_INFO_KIND) == _DATASET_INFO_KIND || return nothing
            try
                resolved = _dataset_resolve_type_from_name(string(info["dataset_type"]))
                return (resolved <: iDataSet && Base.isconcretetype(resolved)) ? resolved : nothing
            catch
                return nothing
            end
        end
    finally
        close(r)
    end
    return nothing
end

# Read a zip archive directly into memory — no temp-dir, no disk I/O.
# Arrow/CSV entries are buffered in seekable IOBuffers; JSON entries are parsed in-place.
# target_type may be nothing (untyped) or a concrete iDataSet subtype (typed).
function _read_dataset_from_zip(zip_path::String, target_type::Union{Type,Nothing}; type::Symbol=:arrow)
    np_fields = isnothing(target_type) ? Set{Symbol}() : Set(nonpersisted_fields(target_type))
    ext = "." * (type == :arrow ? "arrow" : "csv")

    r = ZipFile.Reader(zip_path)
    attributes  = Dict{Symbol,Any}()
    json_buffers = Dict{String,String}()   # rel_path => raw JSON string

    try
        prefix = _zip_strip_prefix(r.files)
        for f in r.files
            norm = replace(f.name, '\\' => '/')
            endswith(norm, '/') && continue
            rel = isempty(prefix) ? norm : (startswith(norm, prefix) ? norm[length(prefix)+1:end] : norm)
            isempty(rel) && continue

            if lowercase(splitext(rel)[2]) == ext
                key = Symbol(splitext(basename(rel))[1])
                key in np_fields && continue        # skip non-persisted fields entirely
                buf = IOBuffer(read(f))             # read(f) reads exactly uncompressedsize bytes
                attributes[key] = IO.read_dataframe(buf; format=type)
            elseif endswith(lowercase(rel), ".json")
                json_buffers[rel] = String(read(f))
            end
        end
    finally
        close(r)
    end

    # Decode data.json — parameter refs resolved from in-memory json_buffers
    if haskey(json_buffers, "data.json")
        for (k, v) in JSON.parse(json_buffers["data.json"])
            attributes[Symbol(k)] = _dataset_decode_json_value_zip(v, json_buffers)
        end
    end

    return LoadedDataSet(attributes)
end

# Variant of _dataset_decode_json_value that resolves iParameters refs from
# in-memory json_buffers (keyed by relative path) rather than from disk.
function _dataset_decode_json_value_zip(value, json_buffers::Dict{String,String})
    if _is_dataset_parameter_reference(value)
        rel_path = _dataset_parameter_relative_path(value)
        file     = _dataset_parameter_file(value)
        json_key = isempty(rel_path) ? file : rel_path * "/" * file
        param_data = JSON.parse(json_buffers[json_key])
        try
            target_type = _dataset_parameter_target_type(iParameters, value)
            return parameters_from_dict(target_type, param_data)
        catch
            # type not loaded in this session — return raw parsed dict
            return param_data
        end
    elseif value isa AbstractVector
        return [_dataset_decode_json_value_zip(v, json_buffers) for v in value]
    elseif value isa AbstractDict
        decoded = Dict{String,Any}()
        for (k, v) in value
            decoded[string(k)] = _dataset_decode_json_value_zip(v, json_buffers)
        end
        return decoded
    else
        return value
    end
end

function _with_archive_extracted(f::Function, source::IO.ArchiveMedia; skip_files::Set{String}=Set{String}())
    tmp_dir = mktempdir()
    try
        _unpack_archive_to_dir(source.path, tmp_dir, source.format; skip_files=skip_files)
        return f(IO.FileSystemMedia(tmp_dir))
    finally
        GC.gc()   # flush Arrow memory-mapped handles before cleanup
        try
            rm(tmp_dir; recursive=true, force=true)
        catch e
            e isa Base.IOError || rethrow()
            # Windows keeps file handles open on memory-mapped Arrow files even after GC.
            # Silently ignore ENOTEMPTY; the OS will purge the temp dir when handles close.
        end
    end
end

function _pack_dir_to_archive(source_dir::String, archive_path::String, format::Symbol)
    if format == :zip
        _pack_dir_to_zip(source_dir, archive_path)
    elseif format == :tar_gz
        _pack_dir_to_tar_gz(source_dir, archive_path)
    else
        throw(ArgumentError("Unsupported archive format: $format. Supported: :zip, :tar_gz"))
    end
end

function _unpack_archive_to_dir(archive_path::String, dest_dir::String, format::Symbol; skip_files::Set{String}=Set{String}())
    if format == :zip
        _unpack_zip_to_dir(archive_path, dest_dir; skip_files=skip_files)
    elseif format == :tar_gz
        _unpack_tar_gz_to_dir(archive_path, dest_dir; skip_files=skip_files)
    else
        throw(ArgumentError("Unsupported archive format: $format. Supported: :zip, :tar_gz"))
    end
end

function _pack_dir_to_zip(source_dir::String, zip_path::String)
    w = ZipFile.Writer(zip_path)
    try
        for (root, _, files) in walkdir(source_dir)
            for file_name in files
                full_path = joinpath(root, file_name)
                rel_path  = relpath(full_path, source_dir)
                entry_name = replace(rel_path, '\\' => '/')
                f = ZipFile.addfile(w, entry_name; method=ZipFile.Deflate)
                write(f, read(full_path))
            end
        end
    finally
        close(w)
    end
end

function _zip_strip_prefix(files)
    # If every entry shares the same top-level directory, return it (with trailing slash).
    # Many zip tools wrap everything in a root folder; strip it so extraction lands flat.
    isempty(files) && return ""
    first_parts = split(replace(files[1].name, '\\' => '/'), '/')
    length(first_parts) < 2 && return ""
    root = first_parts[1]
    for f in files
        parts = split(replace(f.name, '\\' => '/'), '/')
        (length(parts) < 2 || parts[1] != root) && return ""
    end
    return root * "/"
end

function _unpack_zip_to_dir(zip_path::String, dest_dir::String; skip_files::Set{String}=Set{String}())
    r = ZipFile.Reader(zip_path)
    try
        prefix = _zip_strip_prefix(r.files)
        buf = Vector{UInt8}(undef, 2 * 1024 * 1024)   # 2 MB scratch buffer
        for f in r.files
            norm_name = replace(f.name, '\\' => '/')
            endswith(norm_name, '/') && continue   # directory entry
            rel_name = isempty(prefix) ? norm_name : (startswith(norm_name, prefix) ? norm_name[length(prefix)+1:end] : norm_name)
            isempty(rel_name) && continue
            basename(rel_name) in skip_files && continue   # skip non-persisted fields
            dest_path = joinpath(dest_dir, rel_name)
            mkpath(dirname(dest_path))
            open(dest_path, "w") do out
                while !eof(f)
                    n = readbytes!(f, buf)
                    write(out, @view buf[1:n])
                end
            end
        end
    finally
        close(r)
    end
end

function _pack_dir_to_tar_gz(source_dir::String, tar_gz_path::String)
    open(tar_gz_path, "w") do file_io
        gz_io = GzipCompressorStream(file_io)
        try
            Tar.create(source_dir, gz_io)
        finally
            close(gz_io)
        end
    end
end

function _unpack_tar_gz_to_dir(tar_gz_path::String, dest_dir::String; skip_files::Set{String}=Set{String}())
    open(tar_gz_path, "r") do file_io
        gz_io = GzipDecompressorStream(file_io)
        try
            if isempty(skip_files)
                Tar.extract(gz_io, dest_dir)
            else
                Tar.extract(hdr -> !(basename(hdr.path) in skip_files), gz_io, dest_dir)
            end
        finally
            close(gz_io)
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# MinIOMedia support
# ──────────────────────────────────────────────────────────────────────────────

"""
    _write_dataset_impl(source::IO.MinIOMedia, dataset::iDataSet; kwargs...)

Write `dataset` to MinIO by serialising to a temporary local directory via
`FileSystemMedia`, then uploading every produced file as an S3 object.

When `atomic=true` (default), any upload failure triggers a best-effort
deletion of already-uploaded keys so the bucket is not left partially written.
S3/MinIO has no native multi-object atomic commit, so this is a cleanup
heuristic rather than a true transaction.
"""
function _write_dataset_impl(source::IO.MinIOMedia, dataset::iDataSet;
                              type::Symbol    = :arrow,
                              overwrite::Bool = false,
                              atomic::Bool    = true,
                              pretty::Bool    = true)
    type in (:arrow, :csv) || throw(ArgumentError(
        "Unsupported dataset type: $type. Supported: :arrow, :csv."))

    tmp_dir = mktempdir()
    try
        _write_dataset_impl(IO.FileSystemMedia(tmp_dir), dataset;
                            type=type, overwrite=true, atomic=false, pretty=pretty)

        uploaded = String[]
        try
            for (root, _, files) in walkdir(tmp_dir)
                for fname in files
                    local_path   = joinpath(root, fname)
                    rel_path     = replace(relpath(local_path, tmp_dir), '\\' => '/')
                    key          = IO._minio_key(source, rel_path)

                    if !overwrite && IO._s3_exists(source, key)
                        throw(ArgumentError(
                            "Object already exists: $key. Pass overwrite=true to overwrite."))
                    end

                    content_type = IO._minio_content_type(fname)
                    IO._s3_put_bytes(source, key, read(local_path); content_type)
                    push!(uploaded, key)
                end
            end
        catch
            if atomic
                for key in uploaded
                    try IO._s3_delete(source, key) catch; end
                end
            end
            rethrow()
        end
    finally
        rm(tmp_dir; recursive=true, force=true)
    end
    return nothing
end

"""
    _with_downloaded_prefix(read_folder, source::IO.MinIOMedia)

Download every object under `source.prefix` into a temporary folder, each at its path relative to the prefix, and
return `read_folder(folder)`, called while the folder exists; the folder is removed after. Throws `ArgumentError` when
the prefix holds no object.
"""
function _with_downloaded_prefix(read_folder::Function, source::IO.MinIOMedia)
    search_prefix = isempty(source.prefix) ? "" : source.prefix * "/"
    all_keys      = IO._s3_list_keys(source, search_prefix)

    isempty(all_keys) && throw(ArgumentError(
        "No objects found at bucket=$(source.bucket), prefix=$(repr(source.prefix)). " *
        "Has the dataset been written yet?"))

    tmp_dir = mktempdir()
    try
        for key in all_keys
            rel  = isempty(source.prefix) ? key :
                   startswith(key, search_prefix) ? key[length(search_prefix)+1:end] : key
            dest = joinpath(tmp_dir, replace(rel, '/' => Base.Filesystem.path_separator[1]))
            mkpath(dirname(dest))
            write(dest, IO._s3_get_bytes(source, key))
        end
        return read_folder(tmp_dir)
    finally
        GC.gc()
        rm(tmp_dir; recursive=true, force=true)
    end
end

"""Refuse a dataset type other than `:arrow` and `:csv`, as the folder reads do."""
function _check_dataset_type(type::Symbol)
    type in (:arrow, :csv) || throw(ArgumentError("Unsupported dataset type: $type. Supported: :arrow, :csv."))
    return nothing
end

"""
    _read_dataset_impl(source::IO.MinIOMedia; type=:arrow) -> LoadedDataSet

The objects under `source.prefix` downloaded to a temporary folder, then read as a `FileSystemMedia`.
"""
function _read_dataset_impl(source::IO.MinIOMedia; type::Symbol = :arrow)
    _check_dataset_type(type)
    return _with_downloaded_prefix(folder -> _read_dataset_impl(IO.FileSystemMedia(folder); type=type), source)
end

"""
    read_dataset(source::IO.MinIOMedia; type=:arrow)

Read the dataset under the media's prefix as `read_dataset(::FileSystemMedia)` reads a folder: the objects are
downloaded to a temporary folder first, so the concrete type comes from `data_info.json` and each `iParameters` field
from `parameters/`, as for a folder (a type that cannot be resolved is refused, as for a folder).
"""
function read_dataset(source::IO.MinIOMedia; type::Symbol = :arrow)
    _check_dataset_type(type)
    return _with_downloaded_prefix(folder -> read_dataset(IO.FileSystemMedia(folder); type=type), source)
end

"""
    read_dataset(::Type{T}, source::IO.MinIOMedia; type=:arrow)

Typed variant: the dataset under the media's prefix read as `read_dataset(T, ::FileSystemMedia)` reads a folder.
"""
function read_dataset(::Type{T}, source::IO.MinIOMedia; type::Symbol = :arrow) where {T <: iDataSet}
    _check_dataset_type(type)
    return _with_downloaded_prefix(folder -> read_dataset(T, IO.FileSystemMedia(folder); type=type), source)
end

function _dataset_to_json_value(value)
    if value === nothing
        return nothing
    elseif value isa AbstractVector
        return [_dataset_to_json_value(v) for v in value]
    elseif value isa AbstractDict
        converted = Dict{String,Any}()
        for (k, v) in value
            converted[string(k)] = _dataset_to_json_value(v)
        end
        return converted
    elseif isstructtype(typeof(value)) && !(value isa Number) && !(value isa AbstractString) && !(value isa Symbol)
        converted = Dict{String,Any}()
        for field_name in fieldnames(typeof(value))
            converted[string(field_name)] = _dataset_to_json_value(getfield(value, field_name))
        end
        return converted
    elseif value isa Symbol
        return string(value)
    else
        return value
    end
end

function _dataset_to_json_value(value, source::IO.FileSystemMedia, parameter_counter::Base.RefValue{Int}; overwrite::Bool=false, pretty::Bool=true)
    if value === nothing
        return nothing
    elseif value isa iParameters
        parameter_counter[] += 1
        file_name = "params_$(parameter_counter[]).json"
        write_parameters(source, file_name, value, _DATASET_PARAMETERS_DIR; overwrite=overwrite, pretty=pretty)
        return Dict(
            "__kind__" => _DATASET_PARAMETER_REF_KIND,
            "type" => string(typeof(value)),
            "file" => file_name,
            "relative_path" => _DATASET_PARAMETERS_DIR,
        )
    elseif value isa AbstractVector
        return [_dataset_to_json_value(v, source, parameter_counter; overwrite=overwrite, pretty=pretty) for v in value]
    elseif value isa AbstractDict
        converted = Dict{String,Any}()
        for (k, v) in value
            converted[string(k)] = _dataset_to_json_value(v, source, parameter_counter; overwrite=overwrite, pretty=pretty)
        end
        return converted
    elseif isstructtype(typeof(value)) && !(value isa Number) && !(value isa AbstractString) && !(value isa Symbol)
        converted = Dict{String,Any}()
        for field_name in fieldnames(typeof(value))
            converted[string(field_name)] = _dataset_to_json_value(getfield(value, field_name), source, parameter_counter; overwrite=overwrite, pretty=pretty)
        end
        return converted
    elseif value isa Symbol
        return string(value)
    else
        return value
    end
end

function _dataset_decode_json_value(value, source::IO.iSourceMedia)
    if _is_dataset_parameter_reference(value)
        try
            target_type = _dataset_parameter_target_type(iParameters, value)
            return read_parameters(target_type, source, _dataset_parameter_file(value), _dataset_parameter_relative_path(value))
        catch
            # type not loaded in this session — read raw JSON and return dict
            return read_parameters_raw(source, _dataset_parameter_file(value), _dataset_parameter_relative_path(value))
        end
    elseif value isa AbstractVector
        return [_dataset_decode_json_value(v, source) for v in value]
    elseif value isa AbstractDict
        decoded = Dict{String,Any}()
        for (k, v) in value
            decoded[string(k)] = _dataset_decode_json_value(v, source)
        end
        return decoded
    else
        return value
    end
end

# Read a parameters file and return the raw parsed Dict without type reconstruction.
# Used as a fallback when the concrete iParameters type cannot be resolved in the
# current session (e.g., untyped read_dataset called without loading the type definition).
function read_parameters_raw(source::IO.FileSystemMedia, file_name::AbstractString, relative_path::AbstractString="")
    full_path = joinpath(source.path, relative_path, file_name)
    isfile(full_path) || throw(ArgumentError("Parameter file not found: $full_path"))
    return JSON.parsefile(full_path)
end

function _is_dataset_parameter_reference(value)
    value isa AbstractDict || return false
    return haskey(value, "__kind__") && string(value["__kind__"]) == _DATASET_PARAMETER_REF_KIND && haskey(value, "file")
end

function _dataset_parameter_file(ref::AbstractDict)
    return string(ref["file"])
end

function _dataset_parameter_relative_path(ref::AbstractDict)
    return haskey(ref, "relative_path") ? string(ref["relative_path"]) : _DATASET_PARAMETERS_DIR
end

function _dataset_parameter_target_type(::Type{ExpectedT}, ref::AbstractDict) where {ExpectedT}
    if Base.isconcretetype(ExpectedT)
        return ExpectedT
    end

    haskey(ref, "type") || throw(ArgumentError("Missing parameter type metadata in dataset parameter reference."))
    resolved = _dataset_resolve_type_from_name(string(ref["type"]))

    resolved <: ExpectedT || throw(ArgumentError("Resolved parameter type $(resolved) is incompatible with expected type $(ExpectedT)."))
    Base.isconcretetype(resolved) || throw(ArgumentError("Resolved parameter type $(resolved) must be concrete."))

    return resolved
end

function _dataset_resolve_type_from_name(type_name::AbstractString)
    cache_key = String(type_name)
    haskey(_DATASET_TYPE_CACHE, cache_key) && return _DATASET_TYPE_CACHE[cache_key]
    expr = Meta.parse(cache_key)
    resolved = _dataset_resolve_type_expr(expr)
    resolved isa Type || throw(ArgumentError("Resolved value for '$type_name' is not a type."))
    _DATASET_TYPE_CACHE[cache_key] = resolved
    return resolved
end

function _dataset_resolve_type_expr(expr::Symbol)
    # 1. Main namespace (user code loaded at top level)
    isdefined(Main, expr) && return getfield(Main, expr)
    # 2. This module
    isdefined(@__MODULE__, expr) && return getfield(@__MODULE__, expr)
    # 3. All currently loaded packages — catches types defined in any using'd module
    for mod in values(Base.loaded_modules)
        if isdefined(mod, expr)
            val = getfield(mod, expr)
            val isa Type && return val
        end
    end
    throw(ArgumentError("Unable to resolve symbol '$expr'. Make sure the package that defines it is loaded."))
end

function _dataset_resolve_type_expr(expr::Expr)
    expr.head == :. || throw(ArgumentError("Unsupported type expression '$(expr)' in dataset parameter reference."))
    length(expr.args) == 2 || throw(ArgumentError("Unsupported dotted type expression '$(expr)' in dataset parameter reference."))

    left = _dataset_resolve_type_expr(expr.args[1])
    right_node = expr.args[2]
    right_symbol = right_node isa QuoteNode ? right_node.value : right_node
    right_symbol isa Symbol || throw(ArgumentError("Unsupported identifier in type expression '$(expr)'."))
    isdefined(left, right_symbol) || throw(ArgumentError("Unable to resolve '$right_symbol' in type expression '$(expr)'."))
    return getfield(left, right_symbol)
end

function _try_load_parameters_field(::Type{T}, field_name::Symbol, source::IO.FileSystemMedia) where {T <: iParameters}
    file = "$(field_name).json"
    params_path = joinpath(source.path, _DATASET_PARAMETERS_DIR, file)
    isfile(params_path) || return (false, nothing)
    Base.isconcretetype(T) || throw(ArgumentError("Cannot deserialize abstract iParameters field type $(T) for field '$field_name'. Use a concrete subtype."))
    return (true, read_parameters(T, source, file, _DATASET_PARAMETERS_DIR))
end

function _try_load_parameters_field(::Type{Union{Nothing, S}}, field_name::Symbol, source::IO.FileSystemMedia) where {S <: iParameters}
    file = "$(field_name).json"
    params_path = joinpath(source.path, _DATASET_PARAMETERS_DIR, file)
    !isfile(params_path) && return (true, nothing)
    Base.isconcretetype(S) || throw(ArgumentError("Cannot deserialize abstract iParameters field type $(S) for field '$field_name'. Use a concrete subtype."))
    return (true, read_parameters(S, source, file, _DATASET_PARAMETERS_DIR))
end

function _try_load_parameters_field(::Type{T}, field_name::Symbol, source) where {T}
    return (false, nothing)
end

function _dataset_from_attributes(::Type{T}, attributes::Dict{Symbol,Any}, source::Union{IO.iSourceMedia,Nothing}=nothing) where {T <: iDataSet}
    expected_fields = fieldnames(T)
    expected_set = Set(expected_fields)
    np_fields = Set(nonpersisted_fields(T))

    for key in keys(attributes)
        if !(key in expected_set)
            throw(ArgumentError("Unexpected attribute '$key' for dataset type $(T)."))
        end
    end

    values = Any[]
    for field_name in expected_fields
        field_type = fieldtype(T, field_name)
        if haskey(attributes, field_name)
            push!(values, _dataset_convert_value(field_type, attributes[field_name], source))
        elseif field_name in np_fields
            push!(values, _nonpersisted_default(field_type, field_name, T))
        else
            found, loaded = isnothing(source) ? (false, nothing) : _try_load_parameters_field(field_type, field_name, source)
            if found
                push!(values, loaded)
            elseif field_type <: DataFrame
                push!(values, DataFrame())   # absent = was 0-row when written; restore as empty
            else
                throw(ArgumentError("Missing attribute '$field_name' for dataset type $(T)."))
            end
        end
    end

    return T(values...)
end

function _nonpersisted_default(::Type{T}, field_name::Symbol, dataset_type::Type) where {T}
    T <: DataFrame && return DataFrame()
    Nothing <: T  && return nothing
    throw(ArgumentError(
        "Non-persisted field '$field_name' of type $T in $(dataset_type) has no automatic default. " *
        "Only DataFrame and Union{Nothing,…} fields are defaulted automatically."
    ))
end

function _dataset_convert_value(::Type{Any}, value, source::Union{IO.iSourceMedia,Nothing}=nothing)
    return value
end

function _dataset_convert_value(::Type{T}, value, source::Union{IO.iSourceMedia,Nothing}=nothing) where {T}
    if value === nothing
        if T >: Nothing
            return nothing
        end
        throw(ArgumentError("Cannot assign null to non-nullable field of type $(T)."))
    end

    if T <: DataFrame
        value isa DataFrame || throw(ArgumentError("Expected DataFrame for field type $(T), got $(typeof(value))."))
        return value
    end

    if T <: iParameters
        if value isa iParameters
            value isa T || throw(ArgumentError("Expected value compatible with $(T), got $(typeof(value))."))
            return value
        end

        if _is_dataset_parameter_reference(value)
            isnothing(source) && throw(ArgumentError("Cannot load iParameters dataset field without source context."))
            parameter_type = _dataset_parameter_target_type(T, value)
            return read_parameters(parameter_type, source, _dataset_parameter_file(value), _dataset_parameter_relative_path(value))
        end

        value isa AbstractDict || throw(ArgumentError("Expected object or parameter reference for field type $(T), got $(typeof(value))."))
        Base.isconcretetype(T) || throw(ArgumentError("Cannot deserialize abstract iParameters field of type $(T) without parameter reference metadata."))
        return parameters_from_dict(T, value)
    end

    if T <: AbstractVector
        value isa AbstractVector || throw(ArgumentError("Expected array for field type $(T), got $(typeof(value))."))
        element_type = eltype(T)
        converted_items = [_dataset_convert_value(element_type, item, source) for item in value]
        return convert(T, converted_items)
    end

    if T <: AbstractDict
        value isa AbstractDict || throw(ArgumentError("Expected object for field type $(T), got $(typeof(value))."))
        dict_out = Dict{keytype(T), valtype(T)}()
        for (k, v) in value
            converted_key = _dataset_convert_key(keytype(T), k)
            converted_value = _dataset_convert_value(valtype(T), v, source)
            dict_out[converted_key] = converted_value
        end
        return dict_out
    end

    if T <: iDataSet || (isstructtype(T) && !(T <: Number) && !(T <: AbstractString) && !(T <: Symbol))
        value isa AbstractDict || throw(ArgumentError("Expected object for field type $(T), got $(typeof(value))."))
        as_symbol_dict = Dict{Symbol,Any}()
        for (k, v) in value
            as_symbol_dict[Symbol(k)] = v
        end
        return _dataset_from_attributes(T, as_symbol_dict, source)
    end

    if T <: Symbol
        return Symbol(value)
    end

    return convert(T, value)
end

function _dataset_convert_value(::Type{Union{Nothing, S}}, value, source::Union{IO.iSourceMedia,Nothing}=nothing) where {S}
    return value === nothing ? nothing : _dataset_convert_value(S, value, source)
end

function _parameters_field_needs_type_ref(::Type{T}) where {T <: iParameters}
    return !Base.isconcretetype(T)
end

function _parameters_field_needs_type_ref(::Type{Union{Nothing, S}}) where {S <: iParameters}
    return !Base.isconcretetype(S)
end

function _parameters_field_needs_type_ref(::Type{T}) where {T}
    return false
end

function _dataset_convert_key(::Type{String}, key)
    return string(key)
end

function _dataset_convert_key(::Type{Symbol}, key)
    return Symbol(key)
end

function _dataset_convert_key(::Type{K}, key) where {K}
    return convert(K, key)
end
