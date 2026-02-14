using SQLite
using DataFrames

# Test multi-row INSERT
db = SQLite.DB()

# Create test table
SQLite.execute(db, "CREATE TABLE test (id INTEGER, name TEXT)")

# Test INSERT with multiple rows
try
    SQLite.execute(db, "INSERT INTO test VALUES (1,'test'),(2,'data')")
    println("✓ Multi-row INSERT succeeded")
    println(SQLite.Query(db, "SELECT * FROM test") |> DataFrame)
catch e
    println("✗ Multi-row INSERT failed: $e")
end

# Test INSERT with quoted text containing special characters
SQLite.execute(db, "CREATE TABLE test2 (id INTEGER, text TEXT)")
try
    SQLite.execute(db, "INSERT INTO test2 VALUES (1,'L\\'oriental')")
    println("\n✓ Quoted text with apostrophe succeeded")
    println(SQLite.Query(db, "SELECT * FROM test2") |> DataFrame)
catch e
    println("\n✗ Quoted text failed: $e")
end
