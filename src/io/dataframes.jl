# Dataframe IO helpers for MyJuliaToolbox

using CSV
using DataFrames
using Arrow
using Tables
using CodecZlib

# Import iSourceMedia types from media.jl (will be included after this file)
# We'll add methods after media.jl is loaded

export read_csv_to_df, read_arrow_to_df, read_dataframe, write_dataframe

"""
    read_csv_to_df(path; kwargs...)

Read a CSV file at `path` and return a `DataFrame`. Additional keyword arguments are forwarded to `CSV.read`.
"""
function read_csv_to_df(path::AbstractString; kwargs...)
    return CSV.read(path, DataFrame; kwargs...)
end

"""
    read_arrow_to_df(path; kwargs...)

Read an Arrow file at `path` and return a `DataFrame`. Additional keyword arguments are forwarded to `Arrow.Table`.
"""
function read_arrow_to_df(path::AbstractString; kwargs...)
    tbl = Arrow.Table(path; kwargs...)
    return DataFrame(tbl)
end

"""
    read_dataframe(src; format=:auto, kwargs...)

Factory to read various input types into a `DataFrame`.

Supported inputs:
- `path::AbstractString` — dispatched by file extension (`.csv`, `.tsv` => CSV; `.arrow` => Arrow). If `format==:auto` it will try Arrow then CSV for unknown extensions.
- `df::DataFrame` — returns the same object.
- `tbl` — any Tables.jl-compatible table — converts to `DataFrame(tbl)`.
- `io::IO` — use `format` keyword to specify `:csv` or `:arrow`, or `:auto` to try Arrow then CSV.
"""
function read_dataframe(df::DataFrame; format::Symbol = :auto, kwargs...)
    return df
end

function read_dataframe(tbl; format::Symbol = :auto, kwargs...)
    # Handle SQL format for database connections
    if format == :sql
        # Extract SQL-specific parameters
        table = get(Dict(kwargs), :table, nothing)
        query = get(Dict(kwargs), :query, nothing)
        
        # Create a DatabaseMedia without query (will be passed to read_dataframe)
        source = DatabaseMedia(tbl)
        
        # Call the DatabaseMedia version of read_dataframe with table/query parameters
        return read_dataframe(source; table=table, query=query)
    elseif Tables.istable(tbl)
        return DataFrame(tbl)
    else
        error("Unsupported input type for read_dataframe: $(typeof(tbl))")
    end
end

function read_dataframe(path::AbstractString; format::Symbol = :auto, kwargs...)
    p = path
    ext = lowercase(splitext(p)[2])
    # handle compression wrappers like .gz
    is_gz = false
    if ext == ".gz"
        is_gz = true
        p = p[1:end-3]
        ext = lowercase(splitext(p)[2])
    end

    # quick extension-based dispatch
    if format == :csv || ext in (".csv", ".tsv", ".txt")
        if is_gz
            open(path, "r") do f
                gz = CodecZlib.GzipDecompressorStream(f)
                return CSV.read(gz, DataFrame; kwargs...)
            end
        else
            return read_csv_to_df(path; kwargs...)
        end
    elseif format == :arrow || ext in (".arrow", ".feather")
        if is_gz
            error("Gzipped Arrow files are not supported; please provide an uncompressed .arrow file")
        end
        return read_arrow_to_df(path; kwargs...)
    else
        # try Arrow first, then CSV
        try
            return read_arrow_to_df(path; kwargs...)
        catch
            try
                if is_gz
                    open(path, "r") do f
                        gz = CodecZlib.GzipDecompressorStream(f)
                        return CSV.read(gz, DataFrame; kwargs...)
                    end
                else
                    return read_csv_to_df(path; kwargs...)
                end
            catch err
                rethrow(err)
            end
        end
    end
end

function read_dataframe(io::Base.IO; format::Symbol = :auto, kwargs...)
    if format == :sql
        # For SQL format, io should be a database connection
        # Extract SQL-specific parameters
        table = get(Dict(kwargs), :table, nothing)
        query = get(Dict(kwargs), :query, nothing)
        
        # Create a DatabaseMedia without query (will be passed to read_dataframe)
        source = DatabaseMedia(io)
        
        # Call the DatabaseMedia version of read_dataframe with table/query parameters
        return read_dataframe(source; table=table, query=query)
    elseif format == :arrow
        tbl = Arrow.Table(io; kwargs...)
        return DataFrame(tbl)
    elseif format == :csv
        return CSV.read(io, DataFrame; kwargs...)
    else
        # try Arrow first
        try
            tbl = Arrow.Table(io; kwargs...)
            return DataFrame(tbl)
        catch
            return CSV.read(io, DataFrame; kwargs...)
        end
    end
end

"""
    write_dataframe(path_or_io, df; format=:auto, overwrite=false, atomic=true, kwargs...)

Write `df::DataFrame` to `path_or_io`.
- If `path_or_io` is a *path* (string), the format is inferred from the file extension
  (`.csv`, `.tsv`, `.txt` → CSV; `.arrow`, `.feather` → Arrow) unless `format` is provided.
  By default `atomic=true`: data is written to a temporary file in the same directory and
  then renamed into place (safer against partial writes). Use `overwrite=true` to allow
  replacing an existing file. Set `atomic=false` to opt out of atomic writes.
- If an IO object is provided, you must specify `format` when it cannot be inferred.
"""
function write_dataframe(path::AbstractString, df::DataFrame; format::Symbol = :auto, overwrite::Bool=false, atomic::Bool=true, kwargs...)
    if isfile(path) && !overwrite
        error("File already exists: $path. Pass overwrite=true to overwrite.")
    end

    p = path
    ext = lowercase(splitext(p)[2])
    is_gz = false
    if ext == ".gz"
        is_gz = true
        p = p[1:end-3]
        ext = lowercase(splitext(p)[2])
    end

    # helper to perform final move of a temporary file into place
    function _finalize_temp(tmp_path)
        try
            if overwrite
                mv(tmp_path, path; force=true)
            else
                mv(tmp_path, path)
            end
        finally
            # tmp_path should not exist after successful mv; if it does, try to remove it
            if isfile(tmp_path)
                try
                    rm(tmp_path; force=true)
                catch
                    # ignore
                end
            end
        end
    end

    # perform atomic or direct write depending on `atomic`
    if atomic
        dir = dirname(path)
        final_ext = is_gz ? string(ext, ".gz") : ext
        tmp_path = tempname(dir) * final_ext
        try
            if format == :csv || ext in (".csv", ".tsv", ".txt")
                if is_gz
                    open(tmp_path, "w") do f
                        gz = CodecZlib.GzipCompressorStream(f)
                        CSV.write(gz, df; kwargs...)
                        close(gz)
                    end
                else
                    CSV.write(tmp_path, df; kwargs...)
                end
            elseif format == :arrow || ext in (".arrow", ".feather")
                if is_gz
                    error("Gzipped Arrow writing is not supported; write to uncompressed .arrow files")
                end
                Arrow.write(tmp_path, df; kwargs...)
            else
                error("Unsupported file extension for writing: $ext; specify format=:csv or format=:arrow")
            end
            _finalize_temp(tmp_path)
        catch err
            # ensure temporary file is removed if something goes wrong
            if isfile(tmp_path)
                try
                    rm(tmp_path; force=true)
                catch
                    # ignore
                end
            end
            rethrow(err)
        end
    else
        # non-atomic path
        if format == :csv || ext in (".csv", ".tsv", ".txt")
            if is_gz
                open(path, "w") do f
                    gz = CodecZlib.GzipCompressorStream(f)
                    CSV.write(gz, df; kwargs...)
                    close(gz)
                end
            else
                CSV.write(path, df; kwargs...)
            end
        elseif format == :arrow || ext in (".arrow", ".feather")
            if is_gz
                error("Gzipped Arrow writing is not supported; write to uncompressed .arrow files")
            end
            Arrow.write(path, df; kwargs...)
        else
            error("Unsupported file extension for writing: $ext; specify format=:csv or format=:arrow")
        end
    end

    return nothing
end

function write_dataframe(io::Base.IO, df::DataFrame; format::Symbol = :auto, kwargs...)
    if format == :arrow
        Arrow.write(io, df; kwargs...)
    elseif format == :csv
        CSV.write(io, df; kwargs...)
    else
        # Default to CSV for IO if not specified
        CSV.write(io, df; kwargs...)
    end
    return nothing
end

# Note: Additional read_dataframe methods for iSourceMedia types
# will be defined after media.jl is included in io.jl
