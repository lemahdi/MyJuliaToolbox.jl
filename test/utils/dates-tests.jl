using MyJuliaToolbox
using Test
using Dates

@testset "Dates utils" begin
    @test date_to_yyyymmdd(Date(2025,12,31)) == 20251231
    @test date_to_yyyymmdd(Date(2020,2,29)) == 20200229
    @test_throws MethodError date_to_yyyymmdd("2025-12-31")
end
