# Dataset interface for managing data collections
# Provides an abstraction layer for different dataset implementations

using DataFrames
using JSON

const _DATASET_PARAMETER_REF_KIND = "mjt_iParameters_ref"
const _DATASET_PARAMETERS_DIR = "parameters"
const _DATASET_INFO_KIND = "mjt_dataset_info"
const _DATASET_INFO_FILE = "data_info.json"

# Cache mapping serialized type names to their resolved Julia Type objects.
# Avoids repeated Meta.parse + module traversal on every read_dataset call.
const _DATASET_TYPE_CACHE = Dict{String, Type}()

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
    for field_name in fieldnames(typeof(dataset))
        value = getfield(dataset, field_name)
        if value isa DataFrame
            file_name = "$(field_name).$(ext)"
            IO.write_dataframe(source, file_name, value; format=type, overwrite=overwrite, atomic=atomic)
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
    return read_dataset(IO.FileSystemMedia(path); type=type)
end

function read_dataset(::Type{T}, source::IO.iSourceMedia; type::Symbol=:arrow) where {T <: iDataSet}
    loaded = _read_dataset_impl(source; type=type)
    return _dataset_from_attributes(T, loaded.attributes, source)
end

function read_dataset(::Type{T}, path::AbstractString; type::Symbol=:arrow) where {T <: iDataSet}
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
        target_type = _dataset_parameter_target_type(iParameters, value)
        return read_parameters(target_type, source, _dataset_parameter_file(value), _dataset_parameter_relative_path(value))
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

function _dataset_from_attributes(::Type{T}, attributes::Dict{Symbol,Any}, source::Union{IO.iSourceMedia,Nothing}=nothing) where {T <: iDataSet}
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
        push!(values, _dataset_convert_value(field_type, attributes[field_name], source))
    end

    return T(values...)
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

function _dataset_convert_key(::Type{String}, key)
    return string(key)
end

function _dataset_convert_key(::Type{Symbol}, key)
    return Symbol(key)
end

function _dataset_convert_key(::Type{K}, key) where {K}
    return convert(K, key)
end
