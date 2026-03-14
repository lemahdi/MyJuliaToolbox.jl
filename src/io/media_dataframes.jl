# Additional read_dataframe methods for iSourceMedia types
# This file extends the read_dataframe function to work with iSourceMedia objects

using SQLite

"""
    read_dataframe(source::FileSystemMedia; kwargs...) -> DataFrame

Read a DataFrame from a FileSystemMedia.

# Arguments
- `source::FileSystemMedia`: The file system source to read from
- `kwargs...`: Additional keyword arguments passed to the underlying reader
"""
function read_dataframe(source::FileSystemMedia; kwargs...)
    kwargs_dict = Dict(kwargs)
    filename = get(kwargs_dict, :filename, nothing)
    passthrough_kwargs = (; (k => v for (k, v) in kwargs if k != :filename)...)
    if isnothing(filename)
        return read_dataframe(source.path; format=source.format, passthrough_kwargs...)
    end
    full_path = joinpath(source.path, filename)
    return read_dataframe(full_path; format=source.format, passthrough_kwargs...)
end

function read_dataframe(source::FileSystemMedia, filename::AbstractString; kwargs...)
    full_path = joinpath(source.path, filename)
    return read_dataframe(full_path; format=source.format, kwargs...)
end

"""
    read_dataframe(source::DatabaseMedia; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...) -> DataFrame

Read a DataFrame from a DatabaseMedia.

# Arguments
- `source::DatabaseMedia`: The database source to read from  
- `table::Union{String,Nothing}`: Table name to read from
- `query::Union{String,Nothing}`: SQL query to execute
- `kwargs...`: Additional keyword arguments (currently unused)

# Note
Provide one of: `table` parameter or `query` parameter.
"""
function read_dataframe(source::DatabaseMedia; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...)
    if isnothing(table) && isnothing(query)
        error("For DatabaseMedia, provide either query=<sql> or table=<table_name>")
    end
    if !isnothing(table) && !isnothing(query)
        error("Provide only one of query or table for DatabaseMedia reads")
    end

    sql_query = if isnothing(query)
        safe_table = _validated_table_identifier(String(table); field="table name")
        "SELECT * FROM $safe_table"
    else
        query
    end

    return _with_database_connection(source) do conn
        if source.db_type == :sqlite && conn isa SQLite.DB
            return SQLite.DBInterface.execute(conn, sql_query) |> DataFrame
        end
        error("Database reading not implemented for db_type=$(source.db_type), connection=$(typeof(conn))")
    end
end

function read_dataframe(source::DatabaseMedia, query::AbstractString; kwargs...)
    return read_dataframe(source; query=String(query), kwargs...)
end

function _validated_table_identifier(identifier::String; field::String="identifier")
    if match(r"^[A-Za-z_][A-Za-z0-9_]*$", identifier) === nothing
        throw(ArgumentError("Invalid $field '$identifier'. Use only letters, digits, and underscore."))
    end
    return identifier
end

function _sqlite_table_exists(conn::SQLite.DB, table_name::String)
    result = SQLite.DBInterface.execute(
        conn,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1",
        (table_name,),
    ) |> DataFrame
    return nrow(result) > 0
end

function _next_available_table_name(conn::SQLite.DB, base_name::String)
    candidate = base_name
    suffix = 1
    while _sqlite_table_exists(conn, candidate)
        candidate = "$(base_name)_$(suffix)"
        suffix += 1
    end
    return candidate
end

function write_dataframe(source::FileSystemMedia, filename::AbstractString, df::DataFrame; format::Symbol=source.format, overwrite::Bool=false, atomic::Bool=true, kwargs...)
    mkpath(source.path)
    full_path = joinpath(source.path, filename)
    write_dataframe(full_path, df; format=format, overwrite=overwrite, atomic=atomic, kwargs...)
    return nothing
end

function write_dataframe(source::FileSystemMedia, df::DataFrame; format::Symbol=source.format, overwrite::Bool=false, atomic::Bool=true, kwargs...)
    kwargs_dict = Dict(kwargs)
    filename = get(kwargs_dict, :filename, nothing)
    passthrough_kwargs = (; (k => v for (k, v) in kwargs if k != :filename)...)
    if isnothing(filename)
        write_dataframe(source.path, df; format=format, overwrite=overwrite, atomic=atomic, passthrough_kwargs...)
    else
        write_dataframe(source, filename, df; format=format, overwrite=overwrite, atomic=atomic, passthrough_kwargs...)
    end
    return nothing
end

function write_dataframe(source::DatabaseMedia, table::AbstractString, df::DataFrame; kwargs...)
    table_name = _validated_table_identifier(String(table); field="table name")

    return _with_database_connection(source) do conn
        if source.db_type == :sqlite && conn isa SQLite.DB
            final_table = table_name
            if _sqlite_table_exists(conn, final_table)
                final_table = _next_available_table_name(conn, table_name)
                @warn "Table '$table_name' already exists. Writing to '$final_table' instead."
            end

            SQLite.load!(df, conn, final_table)
            return nothing
        end
        error("Database writing not implemented for db_type=$(source.db_type), connection=$(typeof(conn))")
    end
end

function write_dataframe(source::DatabaseMedia, df::DataFrame; kwargs...)
    table = get(Dict(kwargs), :table, nothing)
    if isnothing(table)
        error("For DatabaseMedia writes, provide table=<table_name> or use write_dataframe(source, table, df)")
    end
    return write_dataframe(source, String(table), df; kwargs...)
end

function write_dataframe(source::ConsoleMedia, df::DataFrame; format::Symbol=:csv, kwargs...)
    write_dataframe(source.stream, df; format=format, kwargs...)
    return nothing
end

function write_dataframe(source::SQLDumpMedia, df::DataFrame; kwargs...)
    throw(ArgumentError("SQLDumpMedia is read-only and cannot be used as a write_dataframe sink"))
end

function write_dataframe(source::SQLDumpMedia, target::AbstractString, df::DataFrame; kwargs...)
    throw(ArgumentError("SQLDumpMedia is read-only and cannot be used as a write_dataframe sink"))
end

function write_dataframe(source::iSourceMedia, df::DataFrame; kwargs...)
    error("write_dataframe not implemented for iSourceMedia type: $(typeof(source))")
end

function write_dataframe(source::iSourceMedia, target::AbstractString, df::DataFrame; kwargs...)
    error("write_dataframe not implemented for iSourceMedia type: $(typeof(source))")
end

"""
    read_dataframe(source::SQLDumpMedia; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...) -> DataFrame

Read a DataFrame from a SQLDumpMedia by loading the SQL dump into SQLite and querying it.

# Arguments
- `source::SQLDumpMedia`: The SQL dump source to read from
- `table::Union{String,Nothing}`: Table name to read from (optional)
- `query::Union{String,Nothing}`: SQL query to execute (optional)
- `kwargs...`: Additional keyword arguments (currently unused)

# Returns
- `DataFrame`: The queried data as a DataFrame

# Note
- If neither `table` nor `query` is provided, returns a DataFrame listing all available tables
- The SQL dump is loaded into a SQLite database with automatic syntax conversion
- For MySQL dumps, converts AUTO_INCREMENT, KEY definitions, and data types
"""
function read_dataframe(source::SQLDumpMedia; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...)
    if !isnothing(table) && !isnothing(query)
        error("Cannot provide both 'table' and 'query'. Choose one.")
    end

    # Create SQLite database
    db = source.in_memory ? SQLite.DB() : SQLite.DB(tempname() * ".db")

    try
        # Load the SQL dump
        _load_sql_dump!(db, source.path, source.db_type)

        # If no table or query specified, return list of tables
        if isnothing(table) && isnothing(query)
            tables_query = "SELECT name FROM sqlite_master WHERE type='table' AND name != 'sqlite_sequence' ORDER BY name"
            return SQLite.DBInterface.execute(db, tables_query) |> DataFrame
        end

        # Build the query
        sql_query = if !isnothing(table)
                safe_table = _validated_table_identifier(String(table); field="table name")
                "SELECT * FROM $safe_table"
        else
            query
        end

        # Execute query and return DataFrame
        return SQLite.DBInterface.execute(db, sql_query) |> DataFrame
    finally
        SQLite.close(db)
    end
end

"""
    _unescape_mysql_string_values(stmt::String) -> String

Single-pass conversion of MySQL backslash escape sequences to their SQLite equivalents.

MySQL uses backslash escaping inside string literals; SQLite does not.
Conversions applied:
- `\\'` → `''`  (escaped single quote → SQLite literal quote)
- `\\\\` → `\\`  (escaped backslash → literal backslash)
- `\\n` → newline
- `\\r` → carriage return
- `\\t` → tab
- `\\b` → backspace
- `\\0` → (dropped; SQLite TEXT cannot store null bytes)
- Any other `\\X` → `X` (pass through the escaped character)
"""
function _unescape_mysql_string_values(stmt::String)
    buf = IOBuffer()
    i = firstindex(stmt)
    while i <= ncodeunits(stmt)
        c = stmt[i]
        if c == '\\'
            j = nextind(stmt, i)
            if j <= ncodeunits(stmt)
                next_c = stmt[j]
                if next_c == '\''
                    write(buf, "''")
                elseif next_c == '\\'
                    write(buf, '\\')
                elseif next_c == 'n'
                    write(buf, '\n')
                elseif next_c == 'r'
                    write(buf, '\r')
                elseif next_c == 't'
                    write(buf, '\t')
                elseif next_c == 'b'
                    write(buf, '\b')
                elseif next_c == '0'
                    nothing  # null byte — silently dropped
                else
                    write(buf, next_c)  # unknown escape: keep the escaped char
                end
                i = nextind(stmt, j)
            else
                write(buf, c)  # trailing backslash: keep as-is
                i = nextind(stmt, i)
            end
        else
            write(buf, c)
            i = nextind(stmt, i)
        end
    end
    return String(take!(buf))
end

"""
    _load_sql_dump!(db, path::String, db_type::Symbol)

Internal function to load a SQL dump file into a SQLite database with syntax conversion.
"""
function _load_sql_dump!(db, path::String, db_type::Symbol)
    in_create_table = false
    table_columns = String[]
    table_name = ""
    
    open(path, "r") do file
        for line in eachline(file)
            line = strip(line)
            
            # Skip comments, empty lines, and DB-specific commands
            if isempty(line) || startswith(line, "--") || startswith(line, "/*") ||
               occursin(r"^(LOCK|UNLOCK|SET)\s", line)
                continue
            end
            
            # Skip DROP TABLE
            if occursin(r"^DROP TABLE IF EXISTS", line)
                continue
            end
            
            # Detect CREATE TABLE start
            m = match(r"^CREATE TABLE\s+[`\"]?(\w+)[`\"]?", line)
            if m !== nothing
                in_create_table = true
                table_name = m.captures[1]
                table_columns = String[]
                continue
            end
            
            if in_create_table
                # Remove backticks and quotes
                line = replace(line, r"[`\"]" => "")
                
                # Skip KEY/INDEX/CONSTRAINT definitions
                if occursin(r"^\s*PRIMARY\s+KEY\s*\(", line) ||
                   occursin(r"^\s*KEY\s+", line) ||
                   occursin(r"^\s*UNIQUE\s+(KEY|INDEX)", line) ||
                   occursin(r"^\s*INDEX\s+", line) ||
                   occursin(r"^\s*CONSTRAINT\s+", line) ||
                   occursin(r"^\s*FOREIGN\s+KEY", line)
                    continue
                end
                
                # Handle end of CREATE TABLE
                if occursin(r"^\)", line)
                    # Build the complete CREATE TABLE statement
                    if !isempty(table_columns)
                        table_def = "CREATE TABLE $table_name (\n  " * 
                                    join(table_columns, ",\n  ") * "\n)"
                        
                        try
                            SQLite.execute(db, table_def)
                        catch e
                            @warn "Failed to create table $table_name: $(first(string(e), 100))"
                        end
                    end
                    
                    in_create_table = false
                    table_columns = String[]
                    table_name = ""
                    continue
                end
                
                # Convert MySQL/PostgreSQL types to SQLite
                if db_type == :mysql
                    line = _convert_mysql_to_sqlite(line)
                elseif db_type == :postgresql
                    line = _convert_postgresql_to_sqlite(line)
                end
                
                # Remove trailing comma and add to columns list
                cleaned = strip(replace(line, r",\s*$" => ""))
                if !isempty(cleaned)
                    push!(table_columns, cleaned)
                end
                
            elseif occursin(r"^INSERT INTO", line)
                # Handle INSERT statements
                stmt = replace(line, r"[`\"]" => "")
                stmt = _unescape_mysql_string_values(stmt)

                try
                    SQLite.execute(db, stmt)
                catch e
                    @warn "Failed to execute INSERT for table: $e"
                end
            end
        end
    end
end

"""
    _convert_mysql_to_sqlite(line::String) -> String

Convert MySQL column definition to SQLite syntax.
"""
function _convert_mysql_to_sqlite(line::String)
    # Convert data types (including with size specifications like int(11))
    line = replace(line, r"\bint\([^)]+\)" => "INTEGER")
    line = replace(line, r"\btinyint\([^)]+\)" => "INTEGER")
    line = replace(line, r"\bsmallint\([^)]+\)" => "INTEGER")
    line = replace(line, r"\bmediumint\([^)]+\)" => "INTEGER")
    line = replace(line, r"\bbigint\([^)]+\)" => "INTEGER")
    line = replace(line, r"\bint\b" => "INTEGER")
    line = replace(line, r"\btinyint\b" => "INTEGER")
    line = replace(line, r"\bsmallint\b" => "INTEGER")
    line = replace(line, r"\bmediumint\b" => "INTEGER")
    line = replace(line, r"\bbigint\b" => "INTEGER")
    line = replace(line, r"\bdecimal\([^)]+\)" => "REAL")
    line = replace(line, r"\bnumeric\([^)]+\)" => "REAL")
    line = replace(line, r"\bdouble\b" => "REAL")
    line = replace(line, r"\bfloat\b" => "REAL")
    line = replace(line, r"\bvarchar\([^)]+\)" => "TEXT")
    line = replace(line, r"\bchar\([^)]+\)" => "TEXT")
    line = replace(line, r"\btext\b" => "TEXT")
    line = replace(line, r"\btinytext\b" => "TEXT")
    line = replace(line, r"\bmediumtext\b" => "TEXT")
    line = replace(line, r"\blongtext\b" => "TEXT")
    line = replace(line, r"\bdate\b" => "TEXT")
    line = replace(line, r"\bdatetime\b" => "TEXT")
    line = replace(line, r"\btimestamp\b" => "TEXT")
    
    # Handle AUTO_INCREMENT (must be PRIMARY KEY AUTOINCREMENT in SQLite)
    if occursin("AUTO_INCREMENT", line)
        # Remove AUTO_INCREMENT and NOT NULL, will add PRIMARY KEY AUTOINCREMENT
        line = replace(line, r"\s+NOT\s+NULL\s+AUTO_INCREMENT" => " PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\s+AUTO_INCREMENT" => " PRIMARY KEY AUTOINCREMENT")
    else
        # For non-auto-increment columns, remove NOT NULL
        line = replace(line, r"\s+NOT\s+NULL" => "")
    end
    
    # Remove MySQL-specific keywords
    line = replace(line, " UNSIGNED" => "")
    line = replace(line, r"\s+DEFAULT\s+NULL" => "")
    line = replace(line, r"\s+COLLATE\s+\w+" => "")
    line = replace(line, r"\s+CHARACTER\s+SET\s+\w+" => "")
    line = replace(line, r"\s+ON\s+UPDATE\s+CURRENT_TIMESTAMP" => "")
    
    return line
end

"""
    _convert_postgresql_to_sqlite(line::String) -> String

Convert PostgreSQL column definition to SQLite syntax.
"""
function _convert_postgresql_to_sqlite(line::String)
    # Handle serial types - they include auto-increment and primary key functionality
    # Remove any explicit PRIMARY KEY since serial already implies it
    if occursin(r"\b(big)?serial\b", line)
        line = replace(line, r"\bserial\s+PRIMARY\s+KEY" => "INTEGER PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\bbigserial\s+PRIMARY\s+KEY" => "INTEGER PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\bsmallserial\s+PRIMARY\s+KEY" => "INTEGER PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\bserial\b" => "INTEGER PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\bbigserial\b" => "INTEGER PRIMARY KEY AUTOINCREMENT")
        line = replace(line, r"\bsmallserial\b" => "INTEGER PRIMARY KEY AUTOINCREMENT")
    end
    
    # Convert other PostgreSQL data types to SQLite
    line = replace(line, r"\binteger\b" => "INTEGER")
    line = replace(line, r"\bbigint\b" => "INTEGER")
    line = replace(line, r"\bsmallint\b" => "INTEGER")
    line = replace(line, r"\bnumeric\([^)]+\)" => "REAL")
    line = replace(line, r"\bdecimal\([^)]+\)" => "REAL")
    line = replace(line, r"\breal\b" => "REAL")
    line = replace(line, r"\bdouble\s+precision\b" => "REAL")
    line = replace(line, r"\bcharacter\s+varying\([^)]+\)" => "TEXT")
    line = replace(line, r"\bvarchar\([^)]+\)" => "TEXT")
    line = replace(line, r"\bchar\([^)]+\)" => "TEXT")
    line = replace(line, r"\btext\b" => "TEXT")
    line = replace(line, r"\btimestamp\b" => "TEXT")
    line = replace(line, r"\bdate\b" => "TEXT")
    line = replace(line, r"\bboolean\b" => "INTEGER")
    line = replace(line, r"\bjson\b" => "TEXT")
    line = replace(line, r"\bjsonb\b" => "TEXT")
    line = replace(line, r"\buuid\b" => "TEXT")
    
    # Remove PostgreSQL-specific keywords
    line = replace(line, r"\s+NOT\s+NULL" => "")
    line = replace(line, r"\s+DEFAULT\s+NULL" => "")
    line = replace(line, r"\s+DEFAULT\s+nextval\([^)]+\)" => "")
    
    return line
end

"""
# Arguments
- `source::iSourceMedia`: Any media source type
- `kwargs...`: Additional keyword arguments
"""
function read_dataframe(source::iSourceMedia; kwargs...)
    error("read_dataframe not implemented for iSourceMedia type: $(typeof(source))")
end
