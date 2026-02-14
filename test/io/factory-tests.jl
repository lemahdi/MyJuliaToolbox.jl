using MyJuliaToolbox
using Test
using DataFrames
using Arrow
using Tables
using SQLite

@testset "Factory tests" begin
    @testset "read_dataframe factory behaviors" begin
        csvfile = tempname() * ".csv"
        open(csvfile, "w") do io
            write(io, "x,y\n10,20\n")
        end
        df_csv = read_dataframe(csvfile)
        @test isa(df_csv, DataFrame)
        @test names(df_csv) == ["x", "y"]

        arrowfile = tempname() * ".arrow"
        df_in = DataFrame(a = [7, 8], b = [9, 10])
        Arrow.write(arrowfile, df_in)
        df_arrow = read_dataframe(arrowfile)
        @test isa(df_arrow, DataFrame)
        @test names(df_arrow) == ["a", "b"]

        # reading from DataFrame returns the same object
        df0 = DataFrame(m = [1])
        df_out = read_dataframe(df0)
        @test df_out === df0

        # reading from Tables (Arrow.Table)
        tbl = Arrow.Table(arrowfile)
        df_tbl = read_dataframe(tbl)
        @test isa(df_tbl, DataFrame)
        @test nrow(df_tbl) == 2

        # reading from IO with explicit format
        open(csvfile, "r") do io
            dfi = read_dataframe(io, format = :csv)
            @test isa(dfi, DataFrame)
            @test names(dfi) == ["x", "y"]
        end

        open(arrowfile, "r") do io
            dfa = read_dataframe(io, format = :arrow)
            @test isa(dfa, DataFrame)
            @test names(dfa) == ["a", "b"]
        end
        
        # reading from database connection with SQL format
        db = SQLite.DB()
        test_data = DataFrame(id = [1, 2, 3], name = ["Alice", "Bob", "Charlie"])
        SQLite.load!(test_data, db, "test_table")
        
        # Test with table parameter
        df_sql_table = read_dataframe(db, format = :sql, table = "test_table")
        @test isa(df_sql_table, DataFrame)
        @test nrow(df_sql_table) == 3
        @test names(df_sql_table) == ["id", "name"]
        
        # Test with query parameter
        df_sql_query = read_dataframe(db, format = :sql, query = "SELECT * FROM test_table WHERE id > 1")
        @test isa(df_sql_query, DataFrame)
        @test nrow(df_sql_query) == 2
        @test df_sql_query.id == [2, 3]
    end
end