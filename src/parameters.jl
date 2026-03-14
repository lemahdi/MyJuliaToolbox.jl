# Parameters interface for configuration management
# Provides an abstraction layer for different parameter implementations

using JSON
using Downloads

export iParameters, parameters_from_dict, parameters_from_json, read_parameters, write_parameters

"""
    abstract type iParameters

Abstract base type for parameter configurations. Concrete implementations should define
how to store, validate, and access configuration parameters for algorithms, models, or workflows.

# Implementation Guidelines
Subtypes should typically implement:
- Parameter validation
- Default value handling
- Parameter serialization/deserialization
- Parameter access methods

# Example
```julia
struct ModelParameters <: iParameters
    learning_rate::Float64
    epochs::Int
    batch_size::Int
end
```
"""
abstract type iParameters end

"""
    parameters_from_json(::Type{T}, path::AbstractString) where {T <: iParameters}

Load a JSON configuration file and construct a concrete `iParameters` subtype.
Nested structs are supported as long as their fields are also representable in JSON.
"""
function parameters_from_json(::Type{T}, path::AbstractString) where {T <: iParameters}
    data = JSON.parsefile(path)
    return parameters_from_dict(T, data)
end

"""
    parameters_from_dict(::Type{T}, data::AbstractDict) where {T <: iParameters}

Construct a concrete `iParameters` subtype from a dictionary.
The dictionary keys are expected to match field names in `T`.
"""
function parameters_from_dict(::Type{T}, data::AbstractDict) where {T <: iParameters}
    return _construct_from_dict(T, data)
end

"""
    write_parameters(path::AbstractString, params::iParameters; overwrite::Bool=false, pretty::Bool=true)

Write `params` to a JSON file at `path`.

# Arguments
- `path`: Destination JSON file path
- `params`: Parameter object to serialize
- `overwrite`: Whether to overwrite an existing file (default: `false`)
- `pretty`: Whether to pretty-print JSON output (default: `true`)
"""
function write_parameters(path::AbstractString, params::iParameters; overwrite::Bool=false, pretty::Bool=true)
    if lowercase(splitext(path)[2]) != ".json"
        throw(ArgumentError("Invalid parameter file '$path': expected a .json file."))
    end

    if isfile(path) && !overwrite
        throw(ArgumentError("Parameter file already exists: $path. Pass overwrite=true to overwrite."))
    end

    dir = dirname(path)
    if !isempty(dir)
        mkpath(dir)
    end

    payload = _parameter_to_json_value(params)
    open(path, "w") do io
        if pretty
            JSON.print(io, payload, 2)
        else
            JSON.print(io, payload)
        end
    end

    return nothing
end

"""
    write_parameters(source::IO.iSourceMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString=""; overwrite::Bool=false, pretty::Bool=true)

Write `params` as JSON resolved from the provided media source.
"""
function write_parameters(source::IO.iSourceMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString=""; overwrite::Bool=false, pretty::Bool=true)
    return _write_parameters_impl(source, file_name, params, relative_path; overwrite=overwrite, pretty=pretty)
end

function _write_parameters_impl(source::IO.FileSystemMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString; overwrite::Bool=false, pretty::Bool=true)
    full_path = _resolve_parameters_location(source.path, file_name, relative_path)
    if _is_url(full_path)
        throw(ArgumentError("write_parameters does not support URL destinations: $full_path"))
    end
    return write_parameters(full_path, params; overwrite=overwrite, pretty=pretty)
end

function _write_parameters_impl(source::IO.DatabaseMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString; overwrite::Bool=false, pretty::Bool=true)
    isnothing(source.parameters_locator) && throw(ArgumentError("DatabaseMedia requires `parameters_locator` to write parameter files."))
    full_path = _resolve_parameters_location(source.parameters_locator, file_name, relative_path)
    if _is_url(full_path)
        throw(ArgumentError("write_parameters does not support URL destinations: $full_path"))
    end
    return write_parameters(full_path, params; overwrite=overwrite, pretty=pretty)
end

function _write_parameters_impl(source::IO.SQLDumpMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString; overwrite::Bool=false, pretty::Bool=true)
    isnothing(source.parameters_locator) && throw(ArgumentError("SQLDumpMedia requires `parameters_locator` to write parameter files."))
    full_path = _resolve_parameters_location(source.parameters_locator, file_name, relative_path)
    if _is_url(full_path)
        throw(ArgumentError("write_parameters does not support URL destinations: $full_path"))
    end
    return write_parameters(full_path, params; overwrite=overwrite, pretty=pretty)
end

function _write_parameters_impl(source::IO.iSourceMedia, file_name::AbstractString, params::iParameters, relative_path::AbstractString; overwrite::Bool=false, pretty::Bool=true)
    throw(ArgumentError("write_parameters is not implemented for media source type $(typeof(source))."))
end

"""
    read_parameters(::Type{T}, source::IO.iSourceMedia, file_name::AbstractString, relative_path::AbstractString="") where {T <: iParameters}

Read parameter configuration from a JSON file resolved from the provided media source and
construct a concrete `iParameters` subtype.

# Arguments
- `T`: Target parameter type
- `source`: Media source (currently supports `IO.FileSystemMedia`)
- `file_name`: Configuration file name (must be `.json`)
- `relative_path`: Optional relative path under the source root
"""
function read_parameters(::Type{T}, source::IO.iSourceMedia, file_name::AbstractString, relative_path::AbstractString="") where {T <: iParameters}
    return _read_parameters_impl(T, source, file_name, relative_path)
end

function _read_parameters_impl(::Type{T}, source::IO.FileSystemMedia, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    if lowercase(splitext(file_name)[2]) != ".json"
        throw(ArgumentError("Invalid parameter file '$file_name': expected a .json file."))
    end

    full_path = _resolve_parameters_location(source.path, file_name, relative_path)

    if _is_url(full_path)
        return _parameters_from_url(T, full_path)
    end

    if !isfile(full_path)
        throw(ArgumentError("Parameter file not found: $full_path"))
    end

    return parameters_from_json(T, full_path)
end

function _read_parameters_impl(::Type{T}, source::IO.DatabaseMedia, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    if lowercase(splitext(file_name)[2]) != ".json"
        throw(ArgumentError("Invalid parameter file '$file_name': expected a .json file."))
    end

    isnothing(source.parameters_locator) && throw(ArgumentError("DatabaseMedia requires `parameters_locator` to read parameter files."))
    return _read_parameters_from_locator(T, source.parameters_locator, file_name, relative_path)
end

function _read_parameters_impl(::Type{T}, source::IO.SQLDumpMedia, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    if lowercase(splitext(file_name)[2]) != ".json"
        throw(ArgumentError("Invalid parameter file '$file_name': expected a .json file."))
    end

    isnothing(source.parameters_locator) && throw(ArgumentError("SQLDumpMedia requires `parameters_locator` to read parameter files."))

    return _read_parameters_from_locator(T, source.parameters_locator, file_name, relative_path)
end

function _read_parameters_from_locator(::Type{T}, locator::AbstractString, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    full_path = _resolve_parameters_location(locator, file_name, relative_path)

    if _is_url(full_path)
        return _parameters_from_url(T, full_path)
    end

    if !isfile(full_path)
        throw(ArgumentError("Parameter file not found: $full_path"))
    end

    return parameters_from_json(T, full_path)
end

function _read_parameters_impl(::Type{T}, source::IO.iSourceMedia, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    throw(ArgumentError("read_parameters is not implemented for media source type $(typeof(source))."))
end

function _resolve_parameters_location(locator::AbstractString, file_name::AbstractString, relative_path::AbstractString)
    if _is_url(locator)
        if _looks_like_json_file(locator)
            return locator
        end
        relative_file = isempty(relative_path) ? String(file_name) : string(strip(relative_path, '/'), "/", file_name)
        return string(rstrip(locator, '/'), "/", relative_file)
    end

    if _looks_like_json_file(locator)
        return locator
    end

    source_root = isdir(locator) ? locator : dirname(locator)
    return isempty(relative_path) ? joinpath(source_root, file_name) : joinpath(source_root, relative_path, file_name)
end

function _is_url(value::AbstractString)
    return startswith(value, "http://") || startswith(value, "https://")
end

function _looks_like_json_file(value::AbstractString)
    return lowercase(splitext(value)[2]) == ".json"
end

function _parameters_from_url(::Type{T}, url::AbstractString) where {T <: iParameters}
    temp_dir = mktempdir()
    try
        temp_path = joinpath(temp_dir, "params.json")
        Downloads.download(url, temp_path)
        return parameters_from_json(T, temp_path)
    finally
        rm(temp_dir; recursive=true, force=true)
    end
end

function _parameter_to_json_value(value)
    if value isa iParameters
        payload = Dict{String,Any}()
        for field_name in fieldnames(typeof(value))
            payload[string(field_name)] = _parameter_to_json_value(getfield(value, field_name))
        end
        return payload
    elseif value isa AbstractVector
        return [_parameter_to_json_value(v) for v in value]
    elseif value isa AbstractDict
        converted = Dict{String,Any}()
        for (k, v) in value
            converted[string(k)] = _parameter_to_json_value(v)
        end
        return converted
    else
        return value
    end
end

function _construct_from_dict(::Type{T}, data::AbstractDict) where {T}
    object_fields = fieldnames(T)
    object_keys = Set(string(name) for name in object_fields)

    for key in keys(data)
        key_str = string(key)
        if !(key_str in object_keys)
            throw(ArgumentError("Unexpected key '$key_str' for type $(T)."))
        end
    end

    values = Any[]
    for field_name in object_fields
        key = string(field_name)
        if !haskey(data, key)
            throw(ArgumentError("Missing key '$key' for type $(T)."))
        end

        field_type = fieldtype(T, field_name)
        push!(values, _convert_value(field_type, data[key]))
    end

    return T(values...)
end

function _convert_value(::Type{T}, value) where {T}
    if value === nothing
        if T >: Nothing
            return nothing
        end
        throw(ArgumentError("Cannot assign null to non-nullable field of type $(T)."))
    end

    if T <: iParameters
        value isa AbstractDict || throw(ArgumentError("Expected object for nested parameter type $(T)."))
        return _construct_from_dict(T, value)
    end

    if T <: AbstractVector
        value isa AbstractVector || throw(ArgumentError("Expected array for type $(T)."))
        element_type = eltype(T)
        converted_items = [_convert_value(element_type, item) for item in value]
        return convert(T, converted_items)
    end

    if isstructtype(T) && !(T <: Number) && !(T <: AbstractString)
        value isa AbstractDict || throw(ArgumentError("Expected object for struct type $(T)."))
        return _construct_from_dict(T, value)
    end

    if Base.isconcretetype(T) && parentmodule(T) === Base && T <: Integer
        return convert(T, value)
    end

    if Base.isconcretetype(T) && parentmodule(T) === Base && T <: AbstractFloat
        return convert(T, value)
    end

    return convert(T, value)
end

function _convert_value(::Type{Union{Nothing, S}}, value) where {S}
    return value === nothing ? nothing : _convert_value(S, value)
end
