# Dataset interface for managing data collections
# Provides an abstraction layer for different dataset implementations

using DataFrames
using JSON

export iDataSet, LoadedDataSet, write_dataset, read_dataset

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
    for field_name in fieldnames(typeof(dataset))
        value = getfield(dataset, field_name)
        if value isa DataFrame
            file_name = "$(field_name).$(ext)"
            IO.write_dataframe(source, file_name, value; format=type, overwrite=overwrite, atomic=atomic)
        else
            payload[string(field_name)] = _dataset_to_json_value(value)
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
    return _read_dataset_impl(source; type=type)
end

function read_dataset(::Type{T}, source::IO.iSourceMedia; type::Symbol=:arrow) where {T <: iDataSet}
    loaded = read_dataset(source; type=type)
    return _dataset_from_attributes(T, loaded.attributes)
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
            attributes[Symbol(k)] = v
        end
    end

    return LoadedDataSet(attributes)
end

function _read_dataset_impl(source::IO.iSourceMedia; type::Symbol=:arrow)
    throw(ArgumentError("read_dataset is only implemented for FileSystemMedia. Received: $(typeof(source))"))
end

function _dataset_to_json_value(value)
    if value isa AbstractVector
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

function _dataset_from_attributes(::Type{T}, attributes::Dict{Symbol,Any}) where {T <: iDataSet}
    expected_fields = fieldnames(T)
    expected_set = Set(expected_fields)

    for key in keys(attributes)
        if !(key in expected_set)
            throw(ArgumentError("Unexpected attribute '$key' for dataset type $(T)."))
        end
    end

    values = Any[]
    for field_name in expected_fields
        if !haskey(attributes, field_name)
            throw(ArgumentError("Missing attribute '$field_name' for dataset type $(T)."))
        end
        field_type = fieldtype(T, field_name)
        push!(values, _dataset_convert_value(field_type, attributes[field_name]))
    end

    return T(values...)
end

function _dataset_convert_value(::Type{Any}, value)
    return value
end

function _dataset_convert_value(::Type{T}, value) where {T}
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

    if T <: AbstractVector
        value isa AbstractVector || throw(ArgumentError("Expected array for field type $(T), got $(typeof(value))."))
        element_type = eltype(T)
        converted_items = [_dataset_convert_value(element_type, item) for item in value]
        return convert(T, converted_items)
    end

    if T <: AbstractDict
        value isa AbstractDict || throw(ArgumentError("Expected object for field type $(T), got $(typeof(value))."))
        dict_out = Dict{keytype(T), valtype(T)}()
        for (k, v) in value
            converted_key = _dataset_convert_key(keytype(T), k)
            converted_value = _dataset_convert_value(valtype(T), v)
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
        return _dataset_from_attributes(T, as_symbol_dict)
    end

    if T <: Symbol
        return Symbol(value)
    end

    return convert(T, value)
end

function _dataset_convert_value(::Type{Union{Nothing, S}}, value) where {S}
    return value === nothing ? nothing : _dataset_convert_value(S, value)
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
