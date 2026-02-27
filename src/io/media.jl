# Media interface for reading and writing data across different media backends
# Provides an abstraction layer to read from and write to files, databases, dumps, and streams

using DataFrames
using SQLite

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
    DatabaseMedia(locator::String; db_type::Symbol=:sqlite, parameters_locator::Union{String,Nothing}=nothing)
    DatabaseMedia(connection; db_type::Symbol=:sqlite, parameters_locator::Union{String,Nothing}=nothing)

A media backend for database sources. Depending on the operation, it can be
used for reading (queries) and writing (tables).

# Arguments
- `locator::String`: Database path/URL (for example `"test.db"`, `":memory:"`, or `"sqlite:///tmp/test.db"`)
- `db_type::Symbol`: Database type. Currently supported: `:sqlite`
- `parameters_locator::Union{String,Nothing}`: Optional path/URL root used by `read_parameters`
- `connection`: Optional pre-opened database connection for compatibility

# Note
For `read_dataframe`, pass `query` (or `table`) to the function call.
When constructed from `locator`, the database connection is opened immediately.
"""
struct DatabaseMedia <: iSourceMedia
    locator::Union{String,Nothing}
    db_type::Symbol
    connection::Any
    parameters_locator::Union{String,Nothing}

    function DatabaseMedia(locator::String; db_type::Symbol=:sqlite, parameters_locator::Union{String,Nothing}=nothing)
        if !(db_type in [:sqlite])
            throw(ArgumentError("Unsupported db_type: $db_type. Currently supported: :sqlite"))
        end
        db_path = _sqlite_path_from_locator(locator)
        conn = SQLite.DB(db_path)
        new(locator, db_type, conn, parameters_locator)
    end

    function DatabaseMedia(connection; db_type::Symbol=:sqlite, parameters_locator::Union{String,Nothing}=nothing)
        if !(db_type in [:sqlite])
            throw(ArgumentError("Unsupported db_type: $db_type. Currently supported: :sqlite"))
        end
        new(nothing, db_type, connection, parameters_locator)
    end
end

function _sqlite_path_from_locator(locator::String)
    if startswith(locator, "sqlite:///")
        return locator[11:end]
    elseif startswith(locator, "sqlite://")
        return locator[10:end]
    else
        return locator
    end
end

function _open_database_connection(source::DatabaseMedia)
    if source.connection !== nothing
        return source.connection, false
    end

    if source.db_type == :sqlite
        if isnothing(source.locator)
            throw(ArgumentError("DatabaseMedia requires a locator or a pre-opened connection"))
        end
        db_path = _sqlite_path_from_locator(source.locator)
        return SQLite.DB(db_path), true
    end

    throw(ArgumentError("Unsupported db_type: $(source.db_type). Currently supported: :sqlite"))
end

function _with_database_connection(source::DatabaseMedia, f::Function)
    conn, should_close = _open_database_connection(source)
    try
        return f(conn)
    finally
        if should_close && conn isa SQLite.DB
            SQLite.close(conn)
        end
    end
end

function _with_database_connection(f::Function, source::DatabaseMedia)
    return _with_database_connection(source, f)
end

"""
    SQLDumpMedia(path::String; db_type::Symbol=:mysql, in_memory::Bool=true, parameters_locator::Union{String,Nothing}=nothing)

A media backend that reads from SQL dump files (MySQL, PostgreSQL, etc.).

This source loads a SQL dump file into a SQLite database (in-memory by default)
with automatic syntax conversion from the source database type to SQLite.

# Arguments
- `path::String`: Path to the SQL dump file
- `db_type::Symbol`: Type of source database (`:mysql` or `:postgresql`). Default is `:mysql`
- `in_memory::Bool`: Whether to use an in-memory SQLite database. Default is `true`
- `parameters_locator::Union{String,Nothing}`: Optional path/URL root used by `read_parameters`

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
    parameters_locator::Union{String,Nothing}
    
    function SQLDumpMedia(path::String; db_type::Symbol=:mysql, in_memory::Bool=true, parameters_locator::Union{String,Nothing}=nothing)
        if !isfile(path)
            throw(ArgumentError("SQL dump file not found: $path"))
        end
        if !(db_type in [:mysql, :postgresql])
            throw(ArgumentError("Unsupported db_type: $db_type. Must be :mysql or :postgresql"))
        end
        new(path, db_type, in_memory, parameters_locator)
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
