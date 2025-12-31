using MyJuliaToolbox
using Test
using Dates
using DataFrames

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

    # thirty/360 European (30E/360)
    @test isapprox(yearfrac(20250131, 20250331, basis=:thirty360_eu), 60/360; atol=1e-12)
    @test isapprox(yearfrac(20250131, 20250331, basis=Symbol("30E/360")), 60/360; atol=1e-12)

    # ISDA variant (alias to US implementation for now)
    @test isapprox(yearfrac(20250115, 20250215, basis=:thirty360_isda), 30/360; atol=1e-12)

    # business day adjustment: following / previous / modified variants
    d = Date(2021,1,31) # Sunday
    @test add_days_convention(d, 0, convention=:following) == Date(2021,2,1)    # following -> Mon Feb 1
    @test add_days_convention(d, 0, convention=:modified_following) == Date(2021,1,29) # modified following -> previous business day (Jan 29)
    @test add_days_convention(d, 0, convention=:previous) == Date(2021,1,29)
    @test add_days_convention(d, 0, convention=:modified_previous) == Date(2021,1,29) # modified previous -> previous business day (Jan 29)

    # adding across month boundary with non-zero delta
    d2 = Date(2021,1,30) # Saturday
    @test add_days_convention(d2, 1, convention=:following) == Date(2021,2,1) # unadjusted = Feb 1 (Mon)
    @test add_days_convention(d2, 1, convention=:modified_following) == Date(2021,1,29) # modified following moves back

    # holidays support: treat a date as holiday and skip (vector form)
    d3 = Date(2025,12,24) # assume Wed
    holidays = [Date(2025,12,24), Date(2025,12,25)]
    @test add_days_convention(d3, 0, convention=:following, holidays=holidays) == Date(2025,12,26)

    # holidays as integer yyyymmdd values
    holidays_int = [20251224, 20251225]
    @test add_days_convention(d3, 0, convention=:following, holidays=holidays_int) == Date(2025,12,26)

    # calendar DataFrame form: a calendar listing *business* days via :ref_dt (integers)
    cal_df = DataFrame(ref_dt = [20251226])
    @test add_days_convention(d3, 0, convention=:following, holidays=cal_df) == Date(2025,12,26)
end
