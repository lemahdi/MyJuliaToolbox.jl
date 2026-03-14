using MyJuliaToolbox
using MyJuliaToolbox.IO
using Test
using DataFrames

@testset "DataFrame compare utility" begin
    @testset "Passes with numeric precision" begin
        left = DataFrame(id=[1, 2], score=[1.0, 2.0], tag=["A", "B"], note=["ok", missing])
        right = DataFrame(id=[1, 2], score=[1.0004, 2.0], tag=["A", "B"], note=["ok", missing])

        buffer = IOBuffer()
        result = compare_dataframes(
            left,
            right,
            :id,
            [:score, :tag, :note];
            precision=Dict(:score => 1e-3),
            check_type=true,
            title="precision-check",
            io=buffer,
            color=false,
        )

        @test result.equal
        @test result.title == "precision-check"
        @test result.failed_checks == 0
        @test result.total_checks == result.passed_checks
        @test result.numeric_mismatches == 0
        @test nrow(result.differences) == 0
        output = lowercase(String(take!(buffer)))
        @test occursin("[precision-check]", output)
        @test occursin("comparison passed", output)
        @test occursin("checks: passed=", output)
        @test occursin("failed=0", output)
    end

    @testset "Reports all difference categories" begin
        left = DataFrame(
            id=[1, 2, 3],
            amount=[10.0, missing, 30.0],
            code=["A", "B", "C"],
            qty=Int[1, 2, 3],
        )

        right = DataFrame(
            user_id=[1, 2, 4],
            amount=[10.5, 20.0, 40.0],
            code=["A", "X", "D"],
            qty=[1.0, 2.0, 4.0],
        )

        buffer = IOBuffer()
        result = compare_dataframes(
            left,
            right,
            :id,
            :user_id,
            [:amount, :code, :qty];
            precision=Dict(:amount => 0.1),
            check_type=true,
            title="categorical-and-numeric",
            io=buffer,
            color=false,
            max_differences=20,
        )

        @test !result.equal
        @test result.left_only_rows == 1
        @test result.right_only_rows == 1
        @test result.missing_mismatches == 1
        @test result.type_mismatches == 2
        @test result.numeric_mismatches == 1
        @test result.value_mismatches == 1
        @test nrow(result.differences) == 7
        @test result.failed_checks == 7

        output = String(take!(buffer))
        @test occursin("comparison found", lowercase(output))
        @test occursin("[categorical-and-numeric]", output)
        @test occursin("checks: passed=", lowercase(output))
        @test occursin("failed=7", lowercase(output))
        @test occursin("numeric_mismatch", output)
        @test occursin("missing_mismatch", output)
        @test occursin("type_mismatch", output)
    end

    @testset "Logger output support" begin
        left = DataFrame(id=[1], value=[10.0])
        right = DataFrame(id=[1], value=[12.0])

        log_buffer = IOBuffer()
        logger = AsyncLogger(ConsoleMedia(stream=log_buffer); min_level=:info, capacity=64)

        result = compare_dataframes(
            left,
            right,
            :id,
            :value;
            title="logger-case",
            logger=logger,
            emit_console=false,
            color=false,
        )

        stop_logger!(logger)

        @test !result.equal
        log_output = lowercase(String(take!(log_buffer)))
        @test occursin("[logger-case]", log_output)
        @test occursin("comparison found", log_output)
        @test occursin("checks: passed=", log_output)
        @test occursin("failed=1", log_output)
    end

    # #12 — nrow(differences) == failed_checks invariant: cells with both a
    # type mismatch and a numeric diff must produce exactly one row each.
    @testset "nrow(differences) == failed_checks invariant" begin
        left  = DataFrame(id=[1, 2], value=[Int(1),   Int(10)])
        right = DataFrame(id=[1, 2], value=[Float64(1.5), Float64(20.0)])

        result = compare_dataframes(
            left, right, :id, [:value];
            check_type=true, emit_console=false,
        )

        @test !result.equal
        @test nrow(result.differences) == result.failed_checks
        # Both cells: type mismatch (Int vs Float64) + numeric diff → 1 row each
        @test result.type_mismatches == 2
        @test result.numeric_mismatches == 0  # absorbed into type_mismatch row
        @test nrow(result.differences) == 2
        # Detail string should contain abs_diff for the mismatch
        @test all(occursin("abs_diff", row.detail) for row in eachrow(result.differences))
    end

    # #13 — duplicate key rows are disambiguated by occurrence index.
    @testset "Duplicate key rows (occurrence > 1)" begin
        left  = DataFrame(id=[1, 1, 2], value=[10, 20, 30])
        right = DataFrame(id=[1, 1, 2], value=[10, 99, 30])

        result = compare_dataframes(
            left, right, :id, [:value]; emit_console=false,
        )

        @test !result.equal
        @test result.compared_rows == 3
        @test result.value_mismatches == 1
        @test result.failed_checks == 1
        @test nrow(result.differences) == 1
        # The key text for the differing row should indicate occurrence=2
        @test occursin("occurrence=2", result.differences[1, :key])
    end

    # #14 — silent mode: emit_console=false + no logger still returns result.
    @testset "Silent mode (emit_console=false, no logger)" begin
        left  = DataFrame(id=[1], value=["A"])
        right = DataFrame(id=[1], value=["B"])

        result = compare_dataframes(
            left, right, :id, [:value];
            emit_console=false, logger=nothing,
        )

        @test !result.equal
        @test result.value_mismatches == 1
        @test nrow(result.differences) == 1
    end

    # #15 — sentinel column names raise a clear ArgumentError.
    @testset "Sentinel column collision raises ArgumentError" begin
        left  = DataFrame(id=[1], __occurrence__=[42], value=[1])
        right = DataFrame(id=[1], __occurrence__=[42], value=[2])

        @test_throws ArgumentError compare_dataframes(
            left, right, :id, [:value]; emit_console=false,
        )

        left2  = DataFrame(id=[1], __source__=["x"], value=[1])
        right2 = DataFrame(id=[1], __source__=["x"], value=[2])

        @test_throws ArgumentError compare_dataframes(
            left2, right2, :id, [:value]; emit_console=false,
        )
    end
end
