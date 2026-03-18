# Media interface for reading and writing data across different media backends
# Provides an abstraction layer to read from and write to files, databases, dumps, and streams

using DataFrames
using SQLite

export iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia, ArchiveMedia

# SQLite reserved keywords that must not be used as bare (unquoted) identifiers.
# Source: https://www.sqlite.org/lang_keywords.html
const _SQL_RESERVED_KEYWORDS = Set{String}([
    "ABORT", "ACTION", "ADD", "AFTER", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC",
    "ATTACH", "AUTOINCREMENT", "BEFORE", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE",
    "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE",
    "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT",
    "DEFERRABLE", "DEFERRED", "DELETE", "DESC", "DETACH", "DISTINCT", "DROP", "EACH",
    "ELSE", "END", "ESCAPE", "EXCEPT", "EXCLUSIVE", "EXISTS", "EXPLAIN", "FAIL", "FOR",
    "FOREIGN", "FROM", "FULL", "GLOB", "GROUP", "HAVING", "IF", "IGNORE", "IMMEDIATE",
    "IN", "INDEX", "INDEXED", "INITIALLY", "INNER", "INSERT", "INSTEAD", "INTERSECT",
    "INTO", "IS", "ISNULL", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "MATCH", "NATURAL",
    "NO", "NOT", "NOTNULL", "NULL", "OF", "OFFSET", "ON", "OR", "ORDER", "OUTER",
    "PLAN", "PRAGMA", "PRIMARY", "QUERY", "RAISE", "RECURSIVE", "REFERENCES", "REGEXP",
    "REINDEX", "RELEASE", "RENAME", "REPLACE", "RESTRICT", "RIGHT", "ROLLBACK", "ROW",
    "SAVEPOINT", "SELECT", "SET", "TABLE", "TEMP", "TEMPORARY", "THEN", "TO",
    "TRANSACTION", "TRIGGER", "UNION", "UNIQUE", "UPDATE", "USING", "VACUUM", "VALUES",
    "VIEW", "VIRTUAL", "WHEN", "WHERE", "WITH", "WITHOUT",
])

"""
    abstract type iSourceMedia

Abstract base type for all media backends. Subtypes represent a specific
storage or transport mechanism (file system, database, SQL dump, console, …).

## Implementing a new media type

Declare your struct as a subtype of `iSourceMedia`:

```julia
struct MyMedia <: iSourceMedia
    # your fields
end
```

Then add methods for the operations you want to support. All methods are
optional — unimplemented ones fall back to a descriptive `ArgumentError`.

| Operation | Method signature to implement |
|---|---|
| Read a DataFrame | `read_dataframe(m::MyMedia; kwargs...) -> DataFrame` |
| Write a DataFrame | `write_dataframe(m::MyMedia, filename, df; kwargs...)` |
| Write a log record | `write_log_record(m::MyMedia, record::LogRecord; kwargs...)` |
| Read dataset | `_read_dataset_impl(m::MyMedia; type) -> LoadedDataSet` |
| Write dataset | `_write_dataset_impl(m::MyMedia, dataset; kwargs...)` |

## Read-only vs write-only

A read-only media type (e.g. `SQLDumpMedia`) should implement only the read
methods and explicitly throw `ArgumentError` in the write methods:

```julia
write_dataframe(m::MyMedia, args...; kwargs...) =
    throw(ArgumentError("MyMedia is read-only"))
```

## Existing concrete types

| Type | Read | Write | Notes |
|---|---|---|---|
| `FileSystemMedia` | ✓ CSV/Arrow | ✓ CSV/Arrow | format inferred from extension |
| `DatabaseMedia` | ✓ SQLite | ✓ SQLite | pass `table=` or `query=` |
| `SQLDumpMedia` | ✓ (converted to in-memory SQLite) | ✗ | read-only |
| `ConsoleMedia` | ✗ | ✓ log/CSV to stream | write-only |
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

"""
    ArchiveMedia(path::String)
    ArchiveMedia(path::String; format::Symbol)

A media backend for archive files. Supports reading and writing datasets packed into
`.zip` or `.tar.gz` (`.tgz`) archives.

The archive format is inferred from the file extension by default:
- `.zip`    → `:zip`
- `.tar.gz` / `.tgz` → `:tar_gz`

# Arguments
- `path::String`: Path to the archive file (need not exist yet for writes)
- `format::Symbol`: Override the detected format (`:zip` or `:tar_gz`)

# Example
```julia
# Write
write_dataset(ArchiveMedia("output.zip"), dataset; overwrite=true)

# Read
dataset = read_dataset(ArchiveMedia("output.zip"))
dataset = read_dataset(MyDataSet, "output.tar.gz")
```
"""
struct ArchiveMedia <: iSourceMedia
    path::String
    format::Symbol

    function ArchiveMedia(path::String; format::Symbol=_archive_format_from_path(path))
        if !(format in (:zip, :tar_gz))
            throw(ArgumentError("Unsupported archive format: $format. Supported: :zip, :tar_gz"))
        end
        new(path, format)
    end
end

function _archive_format_from_path(path::String)
    lp = lowercase(path)
    endswith(lp, ".zip")    && return :zip
    endswith(lp, ".tar.gz") && return :tar_gz
    endswith(lp, ".tgz")    && return :tar_gz
    throw(ArgumentError(
        "Cannot determine archive format from path: \"$path\". " *
        "Supported extensions: .zip, .tar.gz, .tgz. " *
        "Use ArchiveMedia(path; format=:zip) to specify explicitly."
    ))
end
