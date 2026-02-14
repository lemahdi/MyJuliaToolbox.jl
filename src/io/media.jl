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
    DatabaseSource(connection; query::Union{String,Nothing}=nothing, params=nothing)

A media source that reads from a database.

# Arguments
- `connection`: Database connection object
- `query::Union{String,Nothing}`: SQL query to execute (optional, can be provided to read_dataframe instead)
- `params`: Optional query parameters

# Note
You can provide a query here or pass a table name to read_dataframe.
"""
struct DatabaseSource <: MediaSource
    connection::Any
    query::Union{String,Nothing}
    params::Any
    
    function DatabaseSource(connection; query::Union{String,Nothing}=nothing, params=nothing)
        new(connection, query, params)
    end
end



