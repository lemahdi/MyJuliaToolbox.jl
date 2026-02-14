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

# Read using FileSystemSource
csv_source = FileSystemSource(sample_csv_path, format=:csv)
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

# Read using FileSystemSource with auto-detection
arrow_source = FileSystemSource(sample_arrow_path)  # format=:auto by default
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
csv_source_explicit = FileSystemSource(sample_csv_path, format=:csv)
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

# Read entire table using DatabaseSource with table parameter
println("\nReading entire 'users' table:")
table_source = DatabaseSource(db, table="users")
df_table = read_dataframe(table_source)
println(first(df_table, 5))

# Read with custom query using DatabaseSource
println("\nQuerying users with age > 30:")
query_source = DatabaseSource(db, query="SELECT * FROM users WHERE age > 30")
df_query = read_dataframe(query_source)
println(df_query)

println("\nNote: DatabaseSource now supports both 'table' and 'query' parameters!")
println("Use read_dataframe() to read from any MediaSource.")
println()

# ====================================================================
# Example 5: Using in a generic data pipeline
# ====================================================================
println("\nExample 5: Generic data pipeline")
println("-" ^ 50)

function process_data(source::MediaSource)
    # Read data from any source using read_dataframe
    df = read_dataframe(source)
    
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

# ====================================================================
# Summary
# ====================================================================
println("\n" * "=" ^ 50)
println("All examples completed successfully!")
println("\nThe sample files remain in the media folder for future use.")
println("To regenerate them, run: julia --project=../../.. create_sample_files.jl")
