# Media interface for reading data from files or databases
# Provides an abstraction layer to read data from different sources and return DataFrames

using DataFrames

export iMediaSource, FileSystemSource, DatabaseSource, SQLDumpSource

"""
    abstract type iMediaSource

Abstract base type for media data sources. Concrete implementations should define
how to read data from specific sources (filesystem, database, etc.).
"""
abstract type iMediaSource end

"""
    FileSystemSource(path::String; format::Symbol=:auto)

A media source that reads from the file system.

# Arguments
- `path::String`: Path to the file
- `format::Symbol`: Format of the file (`:csv`, `:arrow`, `:auto`). Default is `:auto`
"""
struct FileSystemSource <: iMediaSource
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
struct DatabaseSource <: iMediaSource
    connection::Any
    query::Union{String,Nothing}
    params::Any
    
    function DatabaseSource(connection; query::Union{String,Nothing}=nothing, params=nothing)
        new(connection, query, params)
    end
end

"""
    SQLDumpSource(path::String; db_type::Symbol=:mysql, in_memory::Bool=true)

A media source that reads from SQL dump files (MySQL, PostgreSQL, etc.).

This source loads a SQL dump file into a SQLite database (in-memory by default)
with automatic syntax conversion from the source database type to SQLite.

# Arguments
- `path::String`: Path to the SQL dump file
- `db_type::Symbol`: Type of source database (`:mysql` or `:postgresql`). Default is `:mysql`
- `in_memory::Bool`: Whether to use an in-memory SQLite database. Default is `true`

# Example
```julia
source = SQLDumpSource("dump.sql", db_type=:mysql)
df = read_dataframe(source, table="users")
```

# Note
For complex databases with advanced features, consider using dedicated conversion tools
like mysql2sqlite or pg2sqlite before loading with DatabaseSource.
"""
struct SQLDumpSource <: iMediaSource
    path::String
    db_type::Symbol
    in_memory::Bool
    
    function SQLDumpSource(path::String; db_type::Symbol=:mysql, in_memory::Bool=true)
        if !isfile(path)
            throw(ArgumentError("SQL dump file not found: $path"))
        end
        if !(db_type in [:mysql, :postgresql])
            throw(ArgumentError("Unsupported db_type: $db_type. Must be :mysql or :postgresql"))
        end
        new(path, db_type, in_memory)
    end
end
