# Parameters interface for configuration management
# Provides an abstraction layer for different parameter implementations

using JSON

export iParameters, parameters_from_dict, parameters_from_json, read_parameters

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

    source_root = isdir(source.path) ? source.path : dirname(source.path)
    full_path = isempty(relative_path) ? joinpath(source_root, file_name) : joinpath(source_root, relative_path, file_name)

    if !isfile(full_path)
        throw(ArgumentError("Parameter file not found: $full_path"))
    end

    return parameters_from_json(T, full_path)
end

function _read_parameters_impl(::Type{T}, source::IO.iSourceMedia, file_name::AbstractString, relative_path::AbstractString) where {T <: iParameters}
    throw(ArgumentError("read_parameters is not implemented for media source type $(typeof(source))."))
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
