using Test
using MyJuliaToolbox.IO
using DataFrames
using SQLite

@testset "SQLDumpSource Tests" begin
    # Create a temporary SQL dump file for testing
    temp_dir = mktempdir()
    
    # ====================================================================
    # MySQL Dump Tests
    # ====================================================================
    @testset "MySQL Dump" begin
        mysql_dump = joinpath(temp_dir, "test_mysql.sql")
        
        # Create a sample MySQL dump
        open(mysql_dump, "w") do f
            write(f, """
            DROP TABLE IF EXISTS users;
            CREATE TABLE users (
                id int(11) NOT NULL AUTO_INCREMENT,
                name varchar(100) DEFAULT NULL,
                age int(11) DEFAULT NULL,
                salary decimal(10,2) DEFAULT NULL,
                PRIMARY KEY (id),
                KEY idx_age (age)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

            INSERT INTO users VALUES (1,'Alice',30,50000.00),(2,'Bob',25,45000.00),(3,'Charlie',35,60000.00);

            DROP TABLE IF EXISTS products;
            CREATE TABLE products (
                id int(11) NOT NULL AUTO_INCREMENT,
                name varchar(200) DEFAULT NULL,
                price decimal(8,2) DEFAULT NULL,
                PRIMARY KEY (id)
            ) ENGINE=InnoDB;

            INSERT INTO products VALUES (1,'Widget',9.99),(2,'Gadget',19.99);
            """)
        end
        
        @testset "Constructor" begin
            # Valid construction
            source = SQLDumpSource(mysql_dump, db_type=:mysql)
            @test source.path == mysql_dump
            @test source.db_type == :mysql
            @test source.in_memory == true
            
            # Invalid db_type
            @test_throws ArgumentError SQLDumpSource(mysql_dump, db_type=:oracle)
            
            # Non-existent file
            @test_throws ArgumentError SQLDumpSource("nonexistent.sql")
        end
        
        @testset "List Tables" begin
            source = SQLDumpSource(mysql_dump, db_type=:mysql)
            tables_df = read_dataframe(source)
            
            @test nrow(tables_df) == 2
            @test "users" in tables_df.name
            @test "products" in tables_df.name
        end
        
        @testset "Read Table" begin
            source = SQLDumpSource(mysql_dump, db_type=:mysql)
            
            # Read users table
            users_df = read_dataframe(source, table="users")
            @test nrow(users_df) == 3
            @test ncol(users_df) == 4
            @test names(users_df) == ["id", "name", "age", "salary"]
            @test users_df.name == ["Alice", "Bob", "Charlie"]
            @test users_df.age == [30, 25, 35]
            
            # Read products table
            products_df = read_dataframe(source, table="products")
            @test nrow(products_df) == 2
            @test ncol(products_df) == 3
            @test products_df.name == ["Widget", "Gadget"]
        end
        
        @testset "Custom Query" begin
            source = SQLDumpSource(mysql_dump, db_type=:mysql)
            
            # Query with WHERE clause
            df = read_dataframe(source, query="SELECT * FROM users WHERE age > 30")
            @test nrow(df) == 1
            @test df.name[1] == "Charlie"
            
            # Query with aggregation
            df = read_dataframe(source, query="SELECT COUNT(*) as count FROM products")
            @test nrow(df) == 1
            @test df.count[1] == 2
        end
        
        @testset "Type Conversions" begin
            source = SQLDumpSource(mysql_dump, db_type=:mysql)
            users_df = read_dataframe(source, table="users")
            
            # Check that data types are correctly converted
            @test typeof(users_df.id[1]) <: Integer
            @test typeof(users_df.name[1]) <: AbstractString
            @test typeof(users_df.age[1]) <: Integer
            @test typeof(users_df.salary[1]) <: Real
        end
    end
    
    # ====================================================================
    # PostgreSQL Dump Tests
    # ====================================================================
    @testset "PostgreSQL Dump" begin
        pg_dump = joinpath(temp_dir, "test_postgres.sql")
        
        # Create a sample PostgreSQL dump
        open(pg_dump, "w") do f
            write(f, """
            DROP TABLE IF EXISTS employees;
            CREATE TABLE employees (
                id serial PRIMARY KEY,
                name character varying(100),
                department character varying(50),
                salary numeric(10,2)
            );

            INSERT INTO employees VALUES (1,'John Doe','Engineering',75000.00),(2,'Jane Smith','Marketing',65000.00);
            """)
        end
        
        @testset "Constructor" begin
            source = SQLDumpSource(pg_dump, db_type=:postgresql)
            @test source.path == pg_dump
            @test source.db_type == :postgresql
        end
        
        @testset "Read Table" begin
            source = SQLDumpSource(pg_dump, db_type=:postgresql)
            
            # Read employees table
            employees_df = read_dataframe(source, table="employees")
            @test nrow(employees_df) == 2
            @test ncol(employees_df) == 4
            @test employees_df.name == ["John Doe", "Jane Smith"]
            @test employees_df.department == ["Engineering", "Marketing"]
        end
    end
    
    # ====================================================================
    # Edge Cases
    # ====================================================================
    @testset "Edge Cases" begin
        edge_dump = joinpath(temp_dir, "test_edge.sql")
        
        # Dump with comments, empty lines, and various SQL commands
        open(edge_dump, "w") do f
            write(f, """
            -- This is a comment
            /* Multi-line
               comment */
            
            SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
            SET time_zone = "+00:00";
            
            DROP TABLE IF EXISTS test_table;
            CREATE TABLE test_table (
                id int(11) NOT NULL AUTO_INCREMENT,
                value varchar(50),
                PRIMARY KEY (id)
            );
            
            LOCK TABLES test_table WRITE;
            INSERT INTO test_table VALUES (1,'test');
            UNLOCK TABLES;
            """)
        end
        
        @testset "Handles Various SQL Commands" begin
            source = SQLDumpSource(edge_dump, db_type=:mysql)
            
            # Should successfully parse despite SET, LOCK, UNLOCK commands
            tables_df = read_dataframe(source)
            @test nrow(tables_df) == 1
            @test tables_df.name[1] == "test_table"
            
            df = read_dataframe(source, table="test_table")
            @test nrow(df) == 1
            @test df.value[1] == "test"
        end
    end
    
    # Cleanup
    rm(temp_dir, recursive=true, force=true)
end
