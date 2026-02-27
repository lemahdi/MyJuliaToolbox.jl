# Example usage of the Media interface for reading data from different sources
# Run with: julia --project=../../.. src/sandbox/media/media_example.jl
#
# NOTE: Run create_sample_files.jl first to generate the sample data files

using MyJuliaToolbox.IO
using DataFrames
using SQLite

println("=== Media Interface Examples ===\n")

# ====================================================================
# Example 1: Reading from File System (CSV)
# ====================================================================
println("Example 1: Reading from CSV file")
println("-" ^ 50)

# Use existing sample CSV file
sample_csv_path = joinpath(@__DIR__, "sample_data.csv")
println("Reading from: $sample_csv_path")

# Read using FileSystemMedia
csv_source = FileSystemMedia(sample_csv_path, format=:csv)
df_csv = read_dataframe(csv_source)
println("\nData read from CSV (first 5 rows):")
println(first(df_csv, 5))
println()

# ====================================================================
# Example 2: Reading from File System (Arrow)
# ====================================================================
println("\nExample 2: Reading from Arrow file")
println("-" ^ 50)

# Use existing sample Arrow file
sample_arrow_path = joinpath(@__DIR__, "sample_data.arrow")
println("Reading from: $sample_arrow_path")

# Read using FileSystemMedia with auto-detection
arrow_source = FileSystemMedia(sample_arrow_path)  # format=:auto by default
df_arrow = read_dataframe(arrow_source)
println("\nData read from Arrow (first 5 rows):")
println(first(df_arrow, 5))
println()

# ====================================================================
# Example 3: Reading with explicit format specification
# ====================================================================
println("\nExample 3: Reading with explicit format")
println("-" ^ 50)

# You can explicitly specify the format even if the extension suggests otherwise
csv_source_explicit = FileSystemMedia(sample_csv_path, format=:csv)
df_explicit = read_dataframe(csv_source_explicit)
println("Data read with explicit format specification:")
println(first(df_explicit, 3))
println()

# ====================================================================
# Example 4: Reading from SQLite Database
# ====================================================================
println("\nExample 4: Reading from SQLite Database")
println("-" ^ 50)

# Connect to the sample SQLite database
sample_db_path = joinpath(@__DIR__, "sample_data.db")
println("Connecting to: $sample_db_path")

db = SQLite.DB(sample_db_path)

# Read entire table using DatabaseMedia with table parameter in read_dataframe
println("\nReading entire 'users' table:")
table_source = DatabaseMedia(db)
df_table = read_dataframe(table_source, table="users")
println(first(df_table, 5))

# Read with custom query using DatabaseMedia
println("\nQuerying users with age > 30 (query in DatabaseMedia):")
query_source = DatabaseMedia(db, query="SELECT * FROM users WHERE age > 30")
df_query = read_dataframe(query_source)
println(df_query)

# Read with query passed directly to read_dataframe
println("\nQuerying users with age <= 30 (query as parameter):")
plain_source = DatabaseMedia(db)
df_query_param = read_dataframe(plain_source, query="SELECT * FROM users WHERE age <= 30")
println(df_query_param)

println("\nNote: You can pass 'table', 'query' to read_dataframe() or set 'query' in DatabaseMedia!")
println()

# ====================================================================
# Example 5: Reading from SQL Dump Files
# ====================================================================
println("\nExample 5: Reading from SQL Dump Files")
println("-" ^ 50)

# Use existing sample SQL dump file
dump_path = joinpath(@__DIR__, "sample_dump.sql")
println("Reading from: $dump_path")

# Create SQLDumpMedia
dump_source = SQLDumpMedia(dump_path, db_type=:mysql)

# List all tables in the dump
println("\nListing tables in dump:")
tables_df = read_dataframe(dump_source)
println(tables_df)

# Read specific table
println("\nReading 'products' table:")
products_df = read_dataframe(dump_source, table="products")
println(products_df)

# Custom query
println("\nQuerying products with price > 10:")
expensive_df = read_dataframe(dump_source, query="SELECT * FROM products WHERE price > 10")
println(expensive_df)

println()

# ====================================================================
# Example 6: Using in a generic data pipeline
# ====================================================================
println("\nExample 6: Generic data pipeline")
println("-" ^ 50)

function process_data(source::iSourceMedia; table=nothing, query=nothing)
    # Read data from any source using read_dataframe
    df = if !isnothing(table)
        read_dataframe(source, table=table)
    elseif !isnothing(query)
        read_dataframe(source, query=query)
    else
        read_dataframe(source)
    end
    
    # Process the data (example: filter and transform)
    processed = filter(row -> row.age > 28, df)
    processed.age_category = map(age -> age < 30 ? "Young" : "Mature", processed.age)
    
    return processed
end

# Use the same function with different sources
println("Processing CSV source:")
result_csv = process_data(csv_source)
println(result_csv)

println("\nProcessing Arrow source:")
result_arrow = process_data(arrow_source)
println(result_arrow)

# Also works with database
db_source = DatabaseMedia(db)
println("\nProcessing database source:")
result_db = process_data(db_source, table="users")
println(result_db)

# Also works with SQL dumps
println("\nProcessing SQL dump source (different schema):")
# The products table has different columns, so we just display it as-is
result_dump = read_dataframe(dump_source, table="products")
println("Products table:")
println(result_dump)

# ====================================================================
# Summary
# ====================================================================
println("\n" * "=" ^ 50)
println("All examples completed successfully!")
println("\nThe sample files remain in the media folder for future use.")
println("To regenerate them, run: julia --project=../../.. create_sample_files.jl")
