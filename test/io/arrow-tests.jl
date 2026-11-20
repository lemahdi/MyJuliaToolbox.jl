using MyJuliaToolbox
using Test
using DataFrames
using Arrow

# At top level: an enum defined inside a @testset is not found by name on Julia's pre-release
# (UndefVarError: `Status` not defined in `Main`).
@enum ArrowTestStatus PENDING DONE

@testset "Arrow tests" begin
    @testset "read_arrow_to_df and Arrow roundtrips" begin
        arrowfile = tempname() * ".arrow"
        df_in = DataFrame(a = [1, 3], b = [2, 4])
        Arrow.write(arrowfile, df_in)
        df = read_arrow_to_df(arrowfile)
        @test isa(df, DataFrame)
        @test names(df) == ["a", "b"]
        @test nrow(df) == 2
        @test df.a[2] == 3

        # Arrow round-trip with complex types
        using Dates
        df_complex = DataFrame(d = Date(2020,1,1) .+ Day.(0:1), x = [1.5, missing], s = ["a", "b"], b = [true, false])
        farrow2 = tempname() * ".arrow"
        write_dataframe(farrow2, df_complex, overwrite=true)
        dfc = read_dataframe(farrow2)
        @test nrow(dfc) == nrow(df_complex)
        @test eltype(dfc.d) == eltype(df_complex.d)
        @test isequal(dfc.d, df_complex.d)
        @test isequal(dfc.x, df_complex.x)
    end

    @testset "Arrow write supports enum columns" begin
        df_enum = DataFrame(
            id = [1, 2, 3],
            status = Union{Missing,ArrowTestStatus}[PENDING, missing, DONE],
        )

        farrow = tempname() * ".arrow"
        write_dataframe(farrow, df_enum, overwrite=true)

        df_out = read_dataframe(farrow)
        @test df_out.id == df_enum.id
        @test isequal(df_out.status, Union{Missing,String}["PENDING", missing, "DONE"])
    end

    @testset "Arrow write turns text of other string types into String" begin
        df_text = DataFrame(
            mixed = Union{String,SubString{String}}["a", SubString("bcd", 1, 2), "e"],
            mixed_missing = Union{Missing,String,SubString{String}}[missing, "x", SubString("yz", 2, 2)],
            substrings = [SubString("hello", 1, 1), SubString("world", 2, 3), SubString("ab", 2, 2)],
            plain = ["p", "q", "r"],
            all_missing = [missing, missing, missing],
        )

        farrow = tempname() * ".arrow"
        write_dataframe(farrow, df_text, overwrite=true)

        table = Arrow.Table(farrow)
        for column_name in (:mixed, :mixed_missing, :substrings, :plain)
            @test !(getproperty(table, column_name) isa Arrow.DenseUnion)
        end
        @test eltype(table.mixed) == String
        @test eltype(table.mixed_missing) == Union{Missing,String}
        @test eltype(table.substrings) == String
        @test eltype(table.plain) == String

        df_out = read_dataframe(farrow)
        @test df_out.mixed == ["a", "bc", "e"]
        @test isequal(df_out.mixed_missing, [missing, "x", "z"])
        @test df_out.substrings == ["h", "or", "b"]
        @test all(ismissing, df_out.all_missing)
        @test eltype(df_text.mixed) == Union{String,SubString{String}}
    end
end