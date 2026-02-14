# Media interface for reading data from files or databases
# Provides an abstraction layer to read data from different sources and return DataFrames

using DataFrames

export MediaSource, FileSystemSource, DatabaseSource

"""
    abstract type MediaSource

Abstract base type for media data sources. Concrete implementations should define
how to read data from specific sources (filesystem, database, etc.).
"""
abstract type MediaSource end

"""
    FileSystemSource(path::String; format::Symbol=:auto)

A media source that reads from the file system.

# Arguments
- `path::String`: Path to the file
- `format::Symbol`: Format of the file (`:csv`, `:arrow`, `:auto`). Default is `:auto`
"""
struct FileSystemSource <: MediaSource
    path::String
    format::Symbol
    
    FileSystemSource(path::String; format::Symbol=:auto) = new(path, format)
end

"""
    DatabaseSource(connection; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, params=nothing)

A media source that reads from a database.

# Arguments
- `connection`: Database connection object
- `table::Union{String,Nothing}`: Table name to read from (alternative to query)
- `query::Union{String,Nothing}`: SQL query to execute (alternative to table)
- `params`: Optional query parameters

# Note
Provide either `table` or `query`, not both.
"""
struct DatabaseSource <: MediaSource
    connection::Any
    table::Union{String,Nothing}
    query::Union{String,Nothing}
    params::Any
    
    function DatabaseSource(connection; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, params=nothing)
        if isnothing(table) && isnothing(query)
            error("Must provide either 'table' or 'query' argument")
        end
        if !isnothing(table) && !isnothing(query)
            error("Cannot provide both 'table' and 'query' arguments")
        end
        new(connection, table, query, params)
    end
end


