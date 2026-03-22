# Tests for Media interface (FileSystemMedia, DatabaseMedia, read_dataframe)

using Test
using MyJuliaToolbox.IO
using DataFrames
using CSV
using Arrow
using SQLite
using XLSX

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
    # FileSystemMedia Tests
    # ==================================================================
    
    @testset "FileSystemMedia - CSV" begin
        csv_path = joinpath(temp_dir, "test.csv")
        CSV.write(csv_path, test_df)

        # Test with folder path + filename
        source = FileSystemMedia(temp_dir, format=:csv)
        @test source.path == temp_dir
        @test source.format == :csv

        df = read_dataframe(source, "test.csv")
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age

        # write via media source + filename
        write_dataframe(source, "written.csv", test_df)
        df_written = read_dataframe(source, "written.csv")
        @test nrow(df_written) == 5
        @test df_written.name == test_df.name

        # Test with auto format
        source_auto = FileSystemMedia(temp_dir)
        @test source_auto.format == :auto
        df_auto = read_dataframe(source_auto, "test.csv")
        @test nrow(df_auto) == 5
    end
    
    @testset "FileSystemMedia - Arrow" begin
        arrow_path = joinpath(temp_dir, "test.arrow")
        Arrow.write(arrow_path, test_df)

        # Test with explicit format
        source = FileSystemMedia(temp_dir, format=:arrow)
        @test source.path == temp_dir
        @test source.format == :arrow

        df = read_dataframe(source, "test.arrow")
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age

        write_dataframe(source, "written.arrow", test_df)
        df_written = read_dataframe(source, "written.arrow")
        @test nrow(df_written) == 5

        # Test with auto format
        source_auto = FileSystemMedia(temp_dir)
        df_auto = read_dataframe(source_auto, "test.arrow")
        @test nrow(df_auto) == 5
    end

    @testset "FileSystemMedia - Excel (.xlsx)" begin
        xlsx_path = joinpath(temp_dir, "test.xlsx")
        XLSX.writetable(xlsx_path, collect(eachcol(test_df)), names(test_df))

        # Test read via FileSystemMedia
        source = FileSystemMedia(temp_dir)
        df = read_dataframe(source, "test.xlsx")
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test string.(df.name) == test_df.name

        # Test write via FileSystemMedia
        write_dataframe(source, "written.xlsx", test_df)
        df_written = read_dataframe(source, "written.xlsx")
        @test nrow(df_written) == 5
        @test string.(df_written.name) == test_df.name

        # Test write with explicit format=:excel
        source_excel = FileSystemMedia(temp_dir, format=:excel)
        write_dataframe(source_excel, "written_fmt.xlsx", test_df)
        df_fmt = read_dataframe(source_excel, "written_fmt.xlsx")
        @test nrow(df_fmt) == 5

        # Test write with custom sheet name and read it back
        write_dataframe(source, "sheeted.xlsx", test_df; sheet="People")
        df_sheet = read_dataframe(source, "sheeted.xlsx"; sheet="People")
        @test nrow(df_sheet) == 5

        # Test overwrite protection
        @test_throws ArgumentError write_dataframe(source, "written.xlsx", test_df)
        write_dataframe(source, "written.xlsx", test_df; overwrite=true)
        @test nrow(read_dataframe(source, "written.xlsx")) == 5

        # Test that .xls throws an error
        @test_throws ArgumentError read_dataframe(joinpath(temp_dir, "legacy.xls"))
        @test_throws ArgumentError write_dataframe(joinpath(temp_dir, "legacy.xls"), test_df)
    end
    
    # ==================================================================
    # DatabaseMedia Tests
    # ==================================================================
    
    @testset "DatabaseMedia - Constructor" begin
        db = SQLite.DB()  # In-memory database

        # path/url constructor
        source_path = DatabaseMedia(":memory:", db_type=:sqlite)
        @test source_path.db_type == :sqlite
        @test source_path.locator == ":memory:"
        @test source_path.connection isa SQLite.DB
        @test source_path.parameters_locator === nothing

        # compatibility constructor with connection object
        source_conn = DatabaseMedia(db)
        @test source_conn.db_type == :sqlite
        @test source_conn.connection === db
        @test source_conn.parameters_locator === nothing

        SQLite.close(source_path.connection)
        SQLite.close(db)
    end

    @testset "DatabaseMedia - SQLite read/write with locator" begin
        db_path = joinpath(temp_dir, "locator_source.db")
        source = DatabaseMedia(db_path, db_type=:sqlite)

        @test source.connection isa SQLite.DB

        # write using table name
        write_dataframe(source, "users", test_df)

        # read by table
        df_table = read_dataframe(source, table="users")
        @test df_table isa DataFrame
        @test nrow(df_table) == 5
        @test df_table.name == test_df.name

        # read by query
        df_query = read_dataframe(source, query="SELECT * FROM users WHERE age >= 30 ORDER BY age")
        @test nrow(df_query) == 3
        @test all(df_query.age .>= 30)

        # duplicate write should generate a new table name
        write_dataframe(source, "users", test_df)
        tables = SQLite.DBInterface.execute(source.connection, "SELECT name FROM sqlite_master WHERE type='table'") |> DataFrame
        @test "users" in tables.name
        @test "users_1" in tables.name

        SQLite.close(source.connection)
    end
    
    @testset "DatabaseMedia - SQLite read with table" begin
        db = SQLite.DB()  # In-memory database
        
        # Create table and insert data
        SQLite.load!(test_df, db, "test_users")
        
        # Read using table parameter in read_dataframe
        source = DatabaseMedia(db)
        df = read_dataframe(source, table="test_users")
        
        @test df isa DataFrame
        @test nrow(df) == 5
        @test ncol(df) == 4
        @test df.name == test_df.name
        @test df.age == test_df.age
    end
    
    @testset "DatabaseMedia - SQLite read with query" begin
        db = SQLite.DB()  # In-memory database
        
        # Create table and insert data
        SQLite.load!(test_df, db, "test_users")
        
        # Read using query in read_dataframe
        source = DatabaseMedia(db)
        df = read_dataframe(source, query="SELECT * FROM test_users WHERE age > 28")
        
        @test df isa DataFrame
        @test nrow(df) == 3  # Bob (30), Charlie (35), Eve (32)
        @test all(df.age .> 28)
        
        # Test with ORDER BY
        source_ordered = DatabaseMedia(db)
        df_ordered = read_dataframe(source_ordered, query="SELECT * FROM test_users ORDER BY age DESC")
        @test df_ordered.age == sort(test_df.age, rev=true)
        
        # Test with explicit query parameter in read_dataframe
        source_no_query = DatabaseMedia(db)
        df_query_param = read_dataframe(source_no_query, query="SELECT * FROM test_users WHERE age < 30")
        @test nrow(df_query_param) == 2  # Alice (25), Diana (28)
        @test all(df_query_param.age .< 30)
    end
    
    @testset "DatabaseMedia - SQLite with multiple tables" begin
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
        source_users = DatabaseMedia(db)
        df_users = read_dataframe(source_users, table="users")
        @test nrow(df_users) == 5
        @test "name" in names(df_users)
        
        # Read from second table
        source_products = DatabaseMedia(db)
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
        source_join = DatabaseMedia(db)
        df_join = read_dataframe(source_join, query=join_query)
        @test nrow(df_join) == 3
        @test "name" in names(df_join)
        @test "product_name" in names(df_join)

        # write with duplicate table name generates a new name
        write_source = DatabaseMedia(db)
        write_dataframe(write_source, "users", test_df)
        tables = SQLite.DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table'") |> DataFrame
        @test "users_1" in tables.name
    end

    @testset "Other iSourceMedia write behavior" begin
        # ConsoleMedia writes DataFrame content to stream as CSV by default
        buffer = IOBuffer()
        console_source = ConsoleMedia(stream=buffer)
        write_dataframe(console_source, test_df)
        output = String(take!(buffer))
        @test occursin("id,name,age,score", output)
        @test occursin("Alice", output)

        # SQLDumpMedia is read-only and must reject writes
        dump_path = joinpath(temp_dir, "readonly_dump.sql")
        open(dump_path, "w") do io
            write(io, "CREATE TABLE t (id int(11));")
        end
        dump_source = SQLDumpMedia(dump_path, db_type=:mysql)
        @test_throws ArgumentError write_dataframe(dump_source, test_df)
        @test_throws ArgumentError write_dataframe(dump_source, "t", test_df)

        # Generic fallback for unknown media subtype
        struct DummyMedia <: iSourceMedia end
        dummy = DummyMedia()
        @test_throws ArgumentError write_dataframe(dummy, test_df)
        @test_throws ArgumentError write_dataframe(dummy, "target", test_df)
    end
    
    # ==================================================================
    # Integration Tests
    # ==================================================================
    
    @testset "Media - Generic processing function" begin
        # Function that works with any iSourceMedia
        function count_adults(source::iSourceMedia; filename=nothing, table=nothing, query=nothing)
            if source isa FileSystemMedia
                if isnothing(filename)
                    error("filename is required for FileSystemMedia")
                end
                df = read_dataframe(source, filename)
            elseif source isa DatabaseMedia
                if !isnothing(query)
                    df = read_dataframe(source, query=query)
                elseif !isnothing(table)
                    df = read_dataframe(source, table=table)
                else
                    error("table or query is required for DatabaseMedia")
                end
            else
                df = read_dataframe(source)
            end
            return count(row -> row.age >= 30, eachrow(df))
        end
        
        # Test with CSV
        csv_path = joinpath(temp_dir, "test.csv")
        csv_source = FileSystemMedia(temp_dir)
        @test count_adults(csv_source, filename="test.csv") == 3  # Bob, Charlie, Eve
        
        # Test with Arrow
        arrow_path = joinpath(temp_dir, "test.arrow")
        arrow_source = FileSystemMedia(temp_dir)
        @test count_adults(arrow_source, filename="test.arrow") == 3
        
        # Test with Database
        db = SQLite.DB()
        SQLite.load!(test_df, db, "users")
        db_source = DatabaseMedia(db)
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
