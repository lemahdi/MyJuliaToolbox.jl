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

    # yearfrac tests (default basis = :actual365)
    @test isapprox(yearfrac(20250101, 20250103), 2/365; atol=1e-12)
    @test yearfrac(20250101, 20260101) == 1.0
    @test isapprox(yearfrac(20250101, 20260101, basis=:actual365_25), 365/365.25; atol=1e-12)
    @test isapprox(yearfrac(20250101, 20260101, basis=:actual), 365/365.2425; atol=1e-12)
    @test isapprox(yearfrac(20250101, 20250701, basis=:actual360), days_between(20250101,20250701)/360; atol=1e-12)
    @test_throws ErrorException yearfrac(20250101, 20250103, basis=:unknown)

    # thirty/360 tests (US/NASD)
    @test isapprox(yearfrac(20250115, 20250215, basis=:thirty360), 30/360; atol=1e-12)
    @test isapprox(yearfrac(20250130, 20250228, basis=:thirty360), 28/360; atol=1e-12)
    @test isapprox(yearfrac(20250130, 20250330, basis=:thirty360), 60/360; atol=1e-12)
    # accept different symbol forms
    @test isapprox(yearfrac(20250115, 20250215, basis=Symbol("30/360")), 30/360; atol=1e-12)
    @test isapprox(yearfrac(20250115, 20250215, basis=Symbol("30_360")), 30/360; atol=1e-12)
end
