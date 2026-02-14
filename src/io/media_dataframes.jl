# Additional read_dataframe methods for MediaSource types
# This file extends the read_dataframe function to work with MediaSource objects

"""
    read_dataframe(source::FileSystemSource; kwargs...) -> DataFrame

Read a DataFrame from a FileSystemSource.

# Arguments
- `source::FileSystemSource`: The file system source to read from
- `kwargs...`: Additional keyword arguments passed to the underlying reader
"""
function read_dataframe(source::FileSystemSource; kwargs...)
    # Use the path-based read_dataframe function with the format from the source
    return read_dataframe(source.path; format=source.format, kwargs...)
end

"""
    read_dataframe(source::DatabaseSource; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...) -> DataFrame

Read a DataFrame from a DatabaseSource.

# Arguments
- `source::DatabaseSource`: The database source to read from  
- `table::Union{String,Nothing}`: Table name to read from
- `query::Union{String,Nothing}`: SQL query to execute
- `kwargs...`: Additional keyword arguments (currently unused)

# Note
Provide one of: `table` parameter, `query` parameter, or set `query` in DatabaseSource.
"""
function read_dataframe(source::DatabaseSource; table::Union{String,Nothing}=nothing, query::Union{String,Nothing}=nothing, kwargs...)
    # Count how many query sources are provided
    num_sources = count(!isnothing, [table, query, source.query])
    
    if num_sources == 0
        error("Must provide either 'table' parameter, 'query' parameter, or 'query' in DatabaseSource")
    end
    if num_sources > 1
        error("Cannot provide multiple query sources. Choose one of: 'table' parameter, 'query' parameter, or 'query' in DatabaseSource")
    end
    
    sql_query = if !isnothing(table)
        "SELECT * FROM $(table)"
    elseif !isnothing(query)
        query
    else
        source.query
    end
    
    # Try to detect the database type and use appropriate method
    # Check if it's SQLite
    if isdefined(Main, :SQLite) && typeof(source.connection) <: Main.SQLite.DB
        # SQLite implementation
        return Main.SQLite.DBInterface.execute(source.connection, sql_query, source.params === nothing ? [] : source.params) |> DataFrame
    else
        # Generic template for other databases
        error("""
    Database reading not implemented for connection type: $(typeof(source.connection))
    
    Please use read_dataframe with appropriate database-specific code.
    Common implementations:
    
    For SQLite:
        using SQLite
        SQLite.DBInterface.execute(source.connection, query) |> DataFrame
    
    For PostgreSQL:
        using LibPQ
        DataFrame(execute(source.connection, query))
    
    For MySQL:
        using MySQL, DBInterface
        DBInterface.execute(source.connection, query) |> DataFrame
    """)
    end
end

"""
    read_dataframe(source::MediaSource; kwargs...) -> DataFrame

Generic method to read a DataFrame from any MediaSource.

# Arguments
- `source::MediaSource`: Any media source type
- `kwargs...`: Additional keyword arguments
"""
function read_dataframe(source::MediaSource; kwargs...)
    error("read_dataframe not implemented for MediaSource type: $(typeof(source))")
end
