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
    read_dataframe(source::DatabaseSource; kwargs...) -> DataFrame

Read a DataFrame from a DatabaseSource.

# Arguments
- `source::DatabaseSource`: The database source to read from  
- `kwargs...`: Additional keyword arguments (currently unused)
"""
function read_dataframe(source::DatabaseSource; kwargs...)
    # Construct the query based on table or query field
    sql_query = if !isnothing(source.table)
        "SELECT * FROM $(source.table)"
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
