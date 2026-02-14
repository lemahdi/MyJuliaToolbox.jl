using MyJuliaToolbox.IO
using SQLite
using DataFrames

# Query an empty table from the SQL dump
dump_path = raw"E:\Users\mahdi\source\repos\RSU\db\rsu_exit_2026-02-09_19-48-45.sql"
source = SQLDumpSource(dump_path, db_type=:mysql)

# Query the amot_rescoring_cm table (which we expect to be empty)
df = read_dataframe(source, table="amot_rescoring_cm")

println("Table: amot_rescoring_cm")
println("Rows: ", nrow(df))
println("Columns: ", ncol(df))
println("Column names: ", names(df))
println()

if nrow(df) > 0
    println("First 10 rows:")
    println(first(df, 10))
else
    println("Table is empty (no INSERT statements in the dump file)")
end
