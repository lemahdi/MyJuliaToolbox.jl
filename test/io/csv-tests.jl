using MyJuliaToolbox
using Test
using CSV
using DataFrames

@testset "CSV tests" begin
    @testset "read_csv_to_df" begin
        csvfile = tempname() * ".csv"
        open(csvfile, "w") do io
            write(io, "a,b\n1,2\n3,4\n")
        end
        df = read_csv_to_df(csvfile)
        @test isa(df, DataFrame)
        @test names(df) == ["a", "b"]
        @test nrow(df) == 2
        @test df.a[1] == 1
    end

    @testset "write/read CSV and gz" begin
        dfw = DataFrame(p = [5,6], q = [7,8])

        # write CSV by extension
        fcsv = tempname() * ".csv"
        write_dataframe(fcsv, dfw)
        dfwr = read_dataframe(fcsv)
        @test names(dfwr) == names(dfw)
        @test dfwr.p == dfw.p

        # gzipped CSV round-trip
        fcsvgz = tempname() * ".csv.gz"
        write_dataframe(fcsvgz, dfw, overwrite=true)
        dfgz = read_dataframe(fcsvgz)
        @test names(dfgz) == names(dfw)
        @test dfgz.p == dfw.p

        # overwrite behavior
        fow = tempname() * ".csv"
        write_dataframe(fow, dfw)
        @test_throws ArgumentError write_dataframe(fow, dfw, overwrite=false)
        write_dataframe(fow, dfw, overwrite=true)

        # IO write/read with explicit format
        fio = tempname() * ".csv"
        open(fio, "w+") do io
            write_dataframe(io, dfw, format = :csv)
        end
        dfio = read_dataframe(fio)
        @test names(dfio) == names(dfw)

        # atomic write replaces file atomically (default)
        f_atomic = tempname() * ".csv"
        dforig = DataFrame(p = [1], q = [2])
        write_dataframe(f_atomic, dforig)
        dfnew = DataFrame(p = [42], q = [100])
        # default is atomic=true so we omit the keyword here
        write_dataframe(f_atomic, dfnew, overwrite=true)
        df_after = read_dataframe(f_atomic)
        @test df_after.p == dfnew.p

        # atomic write without overwrite should error and original file remain (default atomic)
        f_atomic2 = tempname() * ".csv"
        write_dataframe(f_atomic2, dforig)
        @test_throws ArgumentError write_dataframe(f_atomic2, dfnew)
        df_check = read_dataframe(f_atomic2)
        @test df_check.p == dforig.p

        # explicit atomic=false disables atomic behavior (non-atomic direct overwrite)
        f_atomic3 = tempname() * ".csv"
        write_dataframe(f_atomic3, dforig)
        write_dataframe(f_atomic3, dfnew, overwrite=true, atomic=false)
        df_after3 = read_dataframe(f_atomic3)
        @test df_after3.p == dfnew.p

        # atomic gzipped CSV round-trip (default atomic)
        fcsvgz_atomic = tempname() * ".csv.gz"
        write_dataframe(fcsvgz_atomic, dfw, overwrite=true)
        dfgz_atomic = read_dataframe(fcsvgz_atomic)
        @test names(dfgz_atomic) == names(dfw)
        @test dfgz_atomic.p == dfw.p

        # explicit atomic=false for gzipped CSV (non-atomic)
        fcsvgz_nonatomic = tempname() * ".csv.gz"
        write_dataframe(fcsvgz_nonatomic, dfw)
        write_dataframe(fcsvgz_nonatomic, dfnew, overwrite=true, atomic=false)
        dfgz_nonatomic = read_dataframe(fcsvgz_nonatomic)
        @test dfgz_nonatomic.p == dfnew.p
    end
end