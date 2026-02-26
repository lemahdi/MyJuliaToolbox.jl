using Test
using MyJuliaToolbox.IO
using DataFrames
using SQLite

@testset "Async logger tests" begin
    @testset "ConsoleSource sink" begin
        buffer = IOBuffer()
        source = ConsoleSource(stream=buffer)
        logger = AsyncLogger(source; min_level=:debug, capacity=32)

        @test log_info!(logger, "console message")
        flush_logger!(logger)
        stop_logger!(logger)

        output = String(take!(buffer))
        @test occursin("console message", output)
        @test occursin("[INFO]", output)
    end

    @testset "FileSystemSource sink" begin
        temp_dir = mktempdir()
        try
            log_path = joinpath(temp_dir, "app.log")
            source = FileSystemSource(log_path)
            logger = AsyncLogger(source; min_level=:info, capacity=64)

            for i in 1:10
                @test log_info!(logger, "file message $i")
            end

            stop_logger!(logger)
            lines = readlines(log_path)
            @test length(lines) == 10
            @test any(line -> occursin("file message", line), lines)
        finally
            try
                rm(temp_dir, recursive=true, force=true)
            catch
                # Ignore cleanup errors on Windows (file locks)
            end
        end
    end

    @testset "DatabaseSource sink (SQLite)" begin
        db = SQLite.DB()
        source = DatabaseSource(db)
        logger = AsyncLogger(source; min_level=:debug, capacity=64, table="test_logs")

        @test log_warn!(logger, "db message", metadata=(request_id=42,))
        stop_logger!(logger)

        df = SQLite.DBInterface.execute(db, "SELECT level, message, metadata FROM test_logs") |> DataFrame
        @test nrow(df) == 1
        @test df.level[1] == "warn"
        @test df.message[1] == "db message"
        @test occursin("request_id", df.metadata[1])
        SQLite.close(db)
    end

    @testset "Queue overflow drops messages" begin
        buffer = IOBuffer()
        source = ConsoleSource(stream=buffer)
        logger = AsyncLogger(source; min_level=:debug, capacity=2)

        accepted = 0
        for i in 1:100
            accepted += log_debug!(logger, "burst-$i") ? 1 : 0
        end

        stop_logger!(logger)
        dropped = dropped_logs(logger)

        @test accepted + dropped == 100
        @test dropped >= 1
    end
end
