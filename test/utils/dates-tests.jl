using MyJuliaToolbox
using Test
using Dates

@testset "Dates utils" begin
    @test date2int(Date(2025,12,31)) == 20251231
    @test date2int(Date(2020,2,29)) == 20200229
    @test_throws MethodError date2int("2025-12-31")

    @test int2date(20251231) == Date(2025,12,31)
    @test int2date(20200229) == Date(2020,2,29)
    @test_throws MethodError int2date("20251231")

    # days_between tests (signed differences)
    @test days_between(20250101, 20250103) == 2
    @test days_between(20250103, 20250101) == -2
    @test days_between(20200228, 20200301) == 2  # leap day included
    @test days_between(20200228, 20200229) == 1
    @test days_between(20200229, 20200229) == 0
    @test_throws MethodError days_between("20250101", "20250103")
end
