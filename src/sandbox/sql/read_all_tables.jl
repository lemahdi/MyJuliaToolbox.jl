# Example: Read all tables from a MySQL SQL dump using MyJuliaToolbox
# This script demonstrates using SQLDumpMedia to load and query SQL dump files

using MyJuliaToolbox.IO
using DataFrames
using SQLite

# Path to the SQL file
sql_file_path = raw"E:\Users\mahdi\source\repos\RSU\db\rsu_exit_2026-02-09_19-48-45.sql"

println("=== Reading All Tables from SQL Dump File ===\n")
println("SQL File: $sql_file_path\n")

# Create a SQLDumpMedia
# This automatically handles MySQL→SQLite conversion
println("Creating SQLDumpMedia...")
source = SQLDumpMedia(sql_file_path, db_type=:mysql)
println("✓ SQLDumpMedia created\n")

# Option 1: Get list of all tables (no table/query parameter)
println("Retrieving table names...")
tables_df = read_dataframe(source)

if nrow(tables_df) == 0
    println("No tables found in the SQL dump.")
    exit(0)
end

table_names = tables_df.name
println("Found $(length(table_names)) tables:\n")
for (i, tbl) in enumerate(table_names)
    println("  $i. $tbl")
end
println()

# Option 2: Read each table by name
println("Reading all tables...")
println("=" ^ 80)

dfs = Dict{String,DataFrame}()
for table_name in table_names
    try
        # Read table using the table parameter
        df = read_dataframe(source, table=table_name)
        
        println("\n📊 Table: $table_name")
        println("-" ^ 80)
        println("Rows: $(nrow(df))")
        println("Columns: $(ncol(df))")
        println("Column names: $(join(names(df), ", "))")
        
        # Show first few rows if table has data
        if nrow(df) > 0
            println("\nFirst $(min(3, nrow(df))) rows:")
            println(first(df, min(3, nrow(df))))
        else
            println("\n(Empty table)")
        end
        push!(dfs, table_name => df)
        
    catch e
        println("\n⚠  Error reading table '$table_name': $e")
    end
end

# Option 3: Use custom SQL query
println("\n" * "=" ^ 80)
println("\n📊 Custom Query Example")
println("-" ^ 80)

# Example: Query a specific table with filtering (if it exists)
if "amot_maj" in table_names
    try
        custom_df = read_dataframe(source, query="SELECT * FROM amot_maj LIMIT 5")
        println("Results from: SELECT * FROM amot_maj LIMIT 5")
        println("\nRows: $(nrow(custom_df))")
        println(custom_df)
    catch e
        println("Error executing custom query: $e")
    end
end

println("\n" * "=" ^ 80)
println("✓ Successfully demonstrated SQLDumpMedia!")
println("\nUsage Summary:")
println("  # Create source")
println("  source = SQLDumpMedia(\"dump.sql\", db_type=:mysql)")
println()
println("  # List all tables")
println("  tables = read_dataframe(source)")
println()
println("  # Read specific table")
println("  df = read_dataframe(source, table=\"table_name\")")
println()
println("  # Execute custom query")
println("  df = read_dataframe(source, query=\"SELECT * FROM table_name WHERE ...\")")

