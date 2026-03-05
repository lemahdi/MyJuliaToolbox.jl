using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using DataFrames
using JSON

@testset "Dataset IO tests" begin
    struct SampleDataSet <: iDataSet
        users::DataFrame
        orders::DataFrame
        name::String
        metadata::Dict{String,Any}
    end

    temp_dir = mktempdir()

    try
        users_df = DataFrame(id=[1, 2], name=["Alice", "Bob"])
        orders_df = DataFrame(order_id=[10, 20], amount=[100.0, 150.5])
        ds = SampleDataSet(
            users_df,
            orders_df,
            "demo-dataset",
            Dict("owner" => "qa", "version" => 1, "tags" => ["sample", "io"]),
        )

        @testset "FileSystemMedia write/read roundtrip (arrow default)" begin
            source = FileSystemMedia(temp_dir)
            write_dataset(source, ds)

            @test isfile(joinpath(temp_dir, "users.arrow"))
            @test isfile(joinpath(temp_dir, "orders.arrow"))
            @test isfile(joinpath(temp_dir, "data.json"))

            meta = JSON.parsefile(joinpath(temp_dir, "data.json"))
            @test meta["name"] == "demo-dataset"
            @test meta["metadata"]["owner"] == "qa"

            loaded = read_dataset(source)
            @test loaded isa LoadedDataSet
            @test loaded.attributes[:users] isa DataFrame
            @test loaded.attributes[:orders] isa DataFrame
            @test nrow(loaded.attributes[:users]) == 2
            @test loaded.attributes[:name] == "demo-dataset"
            @test loaded.attributes[:metadata]["version"] == 1

            typed_loaded = read_dataset(SampleDataSet, source)
            @test typed_loaded isa SampleDataSet
            @test typed_loaded.users isa DataFrame
            @test typed_loaded.orders isa DataFrame
            @test typed_loaded.name == "demo-dataset"
            @test typed_loaded.metadata["owner"] == "qa"
        end

        @testset "ConsoleMedia write_dataset" begin
            buffer = IOBuffer()
            console = ConsoleMedia(stream=buffer)
            write_dataset(console, ds)
            output = String(take!(buffer))

            @test occursin("### users", output)
            @test occursin("Alice", output)
            @test occursin("### data.json", output)
            @test occursin("demo-dataset", output)
        end

        @testset "Unsupported media handling" begin
            buffer = IOBuffer()
            console = ConsoleMedia(stream=buffer)
            @test_throws ArgumentError read_dataset(console)
        end
    finally
        try
            rm(temp_dir, recursive=true, force=true)
        catch
            # Ignore cleanup errors on Windows file locks
        end
    end
end
