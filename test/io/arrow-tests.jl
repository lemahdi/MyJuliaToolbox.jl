using MyJuliaToolbox
using Test
using DataFrames
using Arrow

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
end