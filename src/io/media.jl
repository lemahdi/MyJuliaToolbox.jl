# Media interface for reading and writing data across different media backends
# Provides an abstraction layer to read from and write to files, databases, dumps, and streams

using DataFrames

export iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia

"""
    abstract type iSourceMedia

Abstract base type for media backends. Concrete implementations should define
how they support reading, writing, or both for specific media types
(filesystem, database, dump files, console streams, etc.).
"""
abstract type iSourceMedia end

"""
    FileSystemMedia(path::String; format::Symbol=:auto)

A media backend for file-system paths. Depending on the operation, it can be used
for reading (e.g. `read_dataframe`) and writing (e.g. logger/file sinks).

# Arguments
- `path::String`: Path to the file
- `format::Symbol`: Format of the file (`:csv`, `:arrow`, `:auto`). Default is `:auto`
"""
struct FileSystemMedia <: iSourceMedia
    path::String
    format::Symbol
    
    FileSystemMedia(path::String; format::Symbol=:auto) = new(path, format)
end

"""
    DatabaseMedia(connection; query::Union{String,Nothing}=nothing, params=nothing)

A media backend for database connections. Depending on the operation, it can be
used for reading (queries/tables) and writing (e.g. logger database sinks).

# Arguments
- `connection`: Database connection object
- `query::Union{String,Nothing}`: SQL query to execute (optional, can be provided to read_dataframe instead)
- `params`: Optional query parameters

# Note
You can provide a query here or pass a table name to read_dataframe.
"""
struct DatabaseMedia <: iSourceMedia
    connection::Any
    query::Union{String,Nothing}
    params::Any
    
    function DatabaseMedia(connection; query::Union{String,Nothing}=nothing, params=nothing)
        new(connection, query, params)
    end
end

"""
    SQLDumpMedia(path::String; db_type::Symbol=:mysql, in_memory::Bool=true)

A media backend that reads from SQL dump files (MySQL, PostgreSQL, etc.).

This source loads a SQL dump file into a SQLite database (in-memory by default)
with automatic syntax conversion from the source database type to SQLite.

# Arguments
- `path::String`: Path to the SQL dump file
- `db_type::Symbol`: Type of source database (`:mysql` or `:postgresql`). Default is `:mysql`
- `in_memory::Bool`: Whether to use an in-memory SQLite database. Default is `true`

# Example
```julia
source = SQLDumpMedia("dump.sql", db_type=:mysql)
df = read_dataframe(source, table="users")
```

# Note
For complex databases with advanced features, consider using dedicated conversion tools
like mysql2sqlite or pg2sqlite before loading with DatabaseMedia.
"""
struct SQLDumpMedia <: iSourceMedia
    path::String
    db_type::Symbol
    in_memory::Bool
    
    function SQLDumpMedia(path::String; db_type::Symbol=:mysql, in_memory::Bool=true)
        if !isfile(path)
            throw(ArgumentError("SQL dump file not found: $path"))
        end
        if !(db_type in [:mysql, :postgresql])
            throw(ArgumentError("Unsupported db_type: $db_type. Must be :mysql or :postgresql"))
        end
        new(path, db_type, in_memory)
    end
end

"""
    ConsoleMedia(; stream::Base.IO=stdout)

A media backend that writes to a console-like stream.

# Arguments
- `stream::Base.IO`: Output stream to write logs/messages to. Default is `stdout`.
"""
struct ConsoleMedia <: iSourceMedia
    stream::Base.IO
end

ConsoleMedia(; stream::Base.IO=stdout) = ConsoleMedia(stream)
