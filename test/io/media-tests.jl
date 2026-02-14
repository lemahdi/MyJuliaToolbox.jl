# Tests for Media interface (FileSystemSource, DatabaseSource, read_dataframe)

using Test
using MyJuliaToolbox.IO
using DataFrames
using CSV
using Arrow
using SQLite

@testset "Media tests" begin
    # Create temporary directory for test files
    temp_dir = mktempdir()
    
    try
        # Create sample data
        test_df = DataFrame(
            id = 1:5,
            name = ["Alice", "Bob", "Charlie", "Diana", "Eve"],
            age = [25, 30, 35, 28, 32],
            score = [85.5, 92.3, 78.9, 88.1, 95.7]
        )
    
    # ==================================================================
    # FileSystemSource Tests
    # ==================================================================
    
    @testset "FileSystemSource - CSV" begin
        csv_path = joinpath(temp_dir, "test.csv")
        CSV.write(csv_path, test_df)
        
        # Test with explicit format
        source = FileSystemSource(csv_path, format=:csv)
        @test source.path == csv_path
        @test source.format == :csv
        
        df = read_dataframe(source)
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age
        
        # Test with auto format
        source_auto = FileSystemSource(csv_path)
        @test source_auto.format == :auto
        df_auto = read_dataframe(source_auto)
        @test nrow(df_auto) == 5
    end
    
    @testset "FileSystemSource - Arrow" begin
        arrow_path = joinpath(temp_dir, "test.arrow")
        Arrow.write(arrow_path, test_df)
        
        # Test with explicit format
        source = FileSystemSource(arrow_path, format=:arrow)
        @test source.path == arrow_path
        @test source.format == :arrow
        
        df = read_dataframe(source)
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age
        
        # Test with auto format
        source_auto = FileSystemSource(arrow_path)
        df_auto = read_dataframe(source_auto)
        @test nrow(df_auto) == 5
    end
    
    # ==================================================================
    # DatabaseSource Tests
    # ==================================================================
    
    @testset "DatabaseSource - Constructor" begin
        db = SQLite.DB()  # In-memory database
        
        # Test with query only
        source_query = DatabaseSource(db, query="SELECT * FROM users")
        @test source_query.query == "SELECT * FROM users"
        @test isnothing(source_query.params)
        
        # Test with query and params
        source_params = DatabaseSource(db, query="SELECT * FROM users WHERE age > ?", params=[25])
        @test source_params.query == "SELECT * FROM users WHERE age > ?"
        @test source_params.params == [25]
        
        # Test with no query (table will be passed to read_dataframe)
        source_no_query = DatabaseSource(db)
        @test isnothing(source_no_query.query)
    end
    
    @testset "DatabaseSource - SQLite read with table" begin
        db = SQLite.DB()  # In-memory database
        
        # Create table and insert data
        SQLite.load!(test_df, db, "test_users")
        
        # Read using table parameter in read_dataframe
        source = DatabaseSource(db)
        df = read_dataframe(source, table="test_users")
        
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age
    end
    
    @testset "DatabaseSource - SQLite read with query" begin
        db = SQLite.DB()  # In-memory database
        
        # Create table and insert data
        SQLite.load!(test_df, db, "test_users")
        
        # Read using query parameter
        source = DatabaseSource(db, query="SELECT * FROM test_users WHERE age > 28")
        df = read_dataframe(source)
        
        @test df isa DataFrame
        @test nrow(df) == 3  # Bob (30), Charlie (35), Eve (32)
        @test all(df.age .> 28)
        
        # Test with ORDER BY
        source_ordered = DatabaseSource(db, query="SELECT * FROM test_users ORDER BY age DESC")
        df_ordered = read_dataframe(source_ordered)
        @test df_ordered.age == sort(test_df.age, rev=true)
    end
    
    @testset "DatabaseSource - SQLite with multiple tables" begin
        db = SQLite.DB()  # In-memory database
        
        # Create first table
        SQLite.load!(test_df, db, "users")
        
        # Create second table
        products_df = DataFrame(
            product_id = 1:3,
            product_name = ["Laptop", "Mouse", "Keyboard"],
            price = [999.99, 29.99, 79.99]
        )
        SQLite.load!(products_df, db, "products")
        
        # Read from first table
        source_users = DatabaseSource(db)
        df_users = read_dataframe(source_users, table="users")
        @test nrow(df_users) == 5
        @test "name" in names(df_users)
        
        # Read from second table
        source_products = DatabaseSource(db)
        df_products = read_dataframe(source_products, table="products")
        @test nrow(df_products) == 3
        @test "product_name" in names(df_products)
        
        # JOIN query
        SQLite.execute(db, "CREATE TABLE purchases (user_id INTEGER, product_id INTEGER)")
        SQLite.execute(db, "INSERT INTO purchases VALUES (1, 1), (2, 2), (1, 3)")
        
        join_query = """
            SELECT u.name, p.product_name, p.price 
            FROM purchases pu 
            JOIN users u ON pu.user_id = u.id 
            JOIN products p ON pu.product_id = p.product_id
        """
        source_join = DatabaseSource(db, query=join_query)
        df_join = read_dataframe(source_join)
        @test nrow(df_join) == 3
        @test "name" in names(df_join)
        @test "product_name" in names(df_join)
    end
    
    # ==================================================================
    # Integration Tests
    # ==================================================================
    
    @testset "Media - Generic processing function" begin
        # Function that works with any MediaSource
        function count_adults(source::MediaSource; table=nothing)
            if isnothing(table)
                df = read_dataframe(source)
            else
                df = read_dataframe(source, table=table)
            end
            return count(row -> row.age >= 30, eachrow(df))
        end
        
        # Test with CSV
        csv_path = joinpath(temp_dir, "test.csv")
        csv_source = FileSystemSource(csv_path)
        @test count_adults(csv_source) == 3  # Bob, Charlie, Eve
        
        # Test with Arrow
        arrow_path = joinpath(temp_dir, "test.arrow")
        arrow_source = FileSystemSource(arrow_path)
        @test count_adults(arrow_source) == 3
        
        # Test with Database
        db = SQLite.DB()
        SQLite.load!(test_df, db, "users")
        db_source = DatabaseSource(db)
        @test count_adults(db_source, table="users") == 3
    end
    
    finally
        # Cleanup - try to remove, but don't fail if it's locked
        try
            rm(temp_dir, recursive=true, force=true)
        catch
            # Ignore cleanup errors on Windows (file locks)
        end
    end
end
