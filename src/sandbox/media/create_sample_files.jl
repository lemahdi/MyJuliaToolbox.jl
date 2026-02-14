# Script to create sample data files for media interface examples
# Run with: julia --project=../../.. src/sandbox/media/create_sample_files.jl

using DataFrames
using CSV
using Arrow
using SQLite

println("Creating sample data files...")

# Create sample DataFrame
df = DataFrame(
    id = 1:10,
    name = ["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry", "Ivy", "Jack"],
    age = [25, 30, 35, 28, 32, 45, 29, 38, 27, 41],
    city = ["New York", "London", "Paris", "Tokyo", "Berlin", "Sydney", "Toronto", "Madrid", "Rome", "Amsterdam"],
    salary = [50000, 60000, 75000, 55000, 62000, 85000, 58000, 72000, 53000, 78000]
)

# Get the directory of this script
script_dir = @__DIR__

# Create CSV file
csv_path = joinpath(script_dir, "sample_data.csv")
CSV.write(csv_path, df)
println("✓ Created: $csv_path")

# Create Arrow file
arrow_path = joinpath(script_dir, "sample_data.arrow")
Arrow.write(arrow_path, df)
println("✓ Created: $arrow_path")

# Create SQLite database
db_path = joinpath(script_dir, "sample_data.db")
db = SQLite.DB(db_path)

# Create and populate users table
SQLite.load!(df, db, "users")
println("✓ Created: $db_path (with 'users' table)")

# Create a second table with product data
products_df = DataFrame(
    product_id = 1:8,
    product_name = ["Laptop", "Mouse", "Keyboard", "Monitor", "Headphones", "Webcam", "Desk", "Chair"],
    category = ["Electronics", "Accessories", "Accessories", "Electronics", "Audio", "Electronics", "Furniture", "Furniture"],
    price = [999.99, 29.99, 79.99, 349.99, 149.99, 89.99, 299.99, 199.99],
    in_stock = [true, true, false, true, true, false, true, true]
)

SQLite.load!(products_df, db, "products")
println("✓ Added 'products' table to database")

# Verify the database
result_users = SQLite.DBInterface.execute(db, "SELECT * FROM users LIMIT 5") |> DataFrame
println("\nSample data from 'users' table:")
println(result_users)

result_products = SQLite.DBInterface.execute(db, "SELECT * FROM products LIMIT 5") |> DataFrame
println("\nSample data from 'products' table:")
println(result_products)

println("\n✓ All sample files created successfully!")
println("\nFiles created:")
println("  - sample_data.csv")
println("  - sample_data.arrow")
println("  - sample_data.db")
