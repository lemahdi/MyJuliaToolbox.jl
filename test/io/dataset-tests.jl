using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using DataFrames
using JSON

@testset "Dataset IO tests" begin
    struct OptimizerConfig <: iParameters
        learning_rate::Float64
    end

    struct ModelConfig <: iParameters
        model_name::String
        optimizer::OptimizerConfig
    end

    struct SampleDataSet <: iDataSet
        users::DataFrame
        orders::DataFrame
        name::String
        metadata::Dict{String,Any}
    end

    struct DataSetWithOptionalParams <: iDataSet
        users::DataFrame
        maybe_params::Union{Nothing,iParameters}
    end

    struct DataSetWithParams <: iDataSet
        users::DataFrame
        parameters::Union{Nothing,iParameters}
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
            @test isfile(joinpath(temp_dir, "data_info.json"))

            meta = JSON.parsefile(joinpath(temp_dir, "data.json"))
            @test meta["name"] == "demo-dataset"
            @test meta["metadata"]["owner"] == "qa"

            info = JSON.parsefile(joinpath(temp_dir, "data_info.json"))
            @test info["__kind__"] == "mjt_dataset_info"
            @test occursin("SampleDataSet", String(info["dataset_type"]))

            loaded = read_dataset(source)
            @test loaded isa SampleDataSet
            @test loaded.users isa DataFrame
            @test loaded.orders isa DataFrame
            @test nrow(loaded.users) == 2
            @test loaded.name == "demo-dataset"
            @test loaded.metadata["version"] == 1

            typed_loaded = read_dataset(SampleDataSet, source)
            @test typed_loaded isa SampleDataSet
            @test typed_loaded.users isa DataFrame
            @test typed_loaded.orders isa DataFrame
            @test typed_loaded.name == "demo-dataset"
            @test typed_loaded.metadata["owner"] == "qa"

            loaded_from_path = read_dataset(temp_dir)
            @test loaded_from_path isa SampleDataSet
            @test loaded_from_path.name == "demo-dataset"

            typed_loaded_from_path = read_dataset(SampleDataSet, temp_dir)
            @test typed_loaded_from_path isa SampleDataSet
            @test typed_loaded_from_path.metadata["version"] == 1
        end

        @testset "Union{Nothing, iParameters} roundtrip when nothing" begin
            optional_dir = joinpath(temp_dir, "optional-params")
            source = FileSystemMedia(optional_dir)
            optional_ds = DataSetWithOptionalParams(users_df, nothing)

            write_dataset(source, optional_ds; overwrite=true)

            meta = JSON.parsefile(joinpath(optional_dir, "data.json"))
            @test haskey(meta, "maybe_params")
            @test meta["maybe_params"] === nothing

            typed_loaded = read_dataset(DataSetWithOptionalParams, source)
            @test typed_loaded.maybe_params === nothing
        end

        @testset "iParameters fields use write/read_parameters" begin
            params_dir = joinpath(temp_dir, "with-params")
            source = FileSystemMedia(params_dir)

            model_params = ModelConfig("xgboost", OptimizerConfig(0.05))
            ds_with_params = DataSetWithParams(
                users_df,
                model_params,
                Dict(
                    "primary" => model_params,
                    "collection" => Any[OptimizerConfig(0.1), nothing, model_params],
                ),
            )

            write_dataset(source, ds_with_params; overwrite=true)

            data_json = JSON.parsefile(joinpath(params_dir, "data.json"))
            params_ref = data_json["parameters"]
            @test params_ref["__kind__"] == "mjt_iParameters_ref"
            @test params_ref["relative_path"] == "parameters"
            @test params_ref["file"] == "parameters.json"
            @test isfile(joinpath(params_dir, "parameters", "parameters.json"))

            loaded_untyped = read_dataset(source)
            @test loaded_untyped isa DataSetWithParams
            @test loaded_untyped.parameters isa ModelConfig

            loaded_typed = read_dataset(DataSetWithParams, source)
            @test loaded_typed.parameters isa ModelConfig
            @test loaded_typed.parameters.model_name == "xgboost"
            @test loaded_typed.parameters.optimizer.learning_rate == 0.05
            @test loaded_typed.metadata["primary"] isa ModelConfig
            @test loaded_typed.metadata["collection"][1] isa OptimizerConfig
            @test loaded_typed.metadata["collection"][2] === nothing
            @test loaded_typed.metadata["collection"][3] isa ModelConfig
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

        @testset "read_dataset fallback without data_info" begin
            legacy_dir = joinpath(temp_dir, "legacy-format")
            mkpath(legacy_dir)
            source = FileSystemMedia(legacy_dir)

            write_dataframe(joinpath(legacy_dir, "users.arrow"), users_df; format=:arrow, overwrite=true)
            open(joinpath(legacy_dir, "data.json"), "w") do io
                JSON.print(io, Dict("name" => "legacy"))
            end

            loaded = read_dataset(source)
            @test loaded isa LoadedDataSet
            @test loaded.attributes[:users] isa DataFrame
            @test loaded.attributes[:name] == "legacy"
        end

        @testset "Unsupported media handling" begin
            buffer = IOBuffer()
            console = ConsoleMedia(stream=buffer)
            @test_throws ArgumentError read_dataset(console)
        end

        @testset "ArchiveMedia write/read roundtrip (.zip)" begin
            zip_path = joinpath(temp_dir, "dataset.zip")
            source = ArchiveMedia(zip_path)
            write_dataset(source, ds)

            @test isfile(zip_path)

            loaded = read_dataset(source)
            @test loaded isa SampleDataSet
            @test nrow(loaded.users) == 2
            @test loaded.name == "demo-dataset"
            @test loaded.metadata["version"] == 1

            typed_loaded = read_dataset(SampleDataSet, source)
            @test typed_loaded isa SampleDataSet
            @test typed_loaded.metadata["owner"] == "qa"

            loaded_from_path = read_dataset(zip_path)
            @test loaded_from_path isa SampleDataSet
            @test loaded_from_path.name == "demo-dataset"
        end

        @testset "ArchiveMedia write/read roundtrip (.tar.gz)" begin
            tar_gz_path = joinpath(temp_dir, "dataset.tar.gz")
            source = ArchiveMedia(tar_gz_path)
            write_dataset(source, ds)

            @test isfile(tar_gz_path)

            loaded = read_dataset(source)
            @test loaded isa SampleDataSet
            @test nrow(loaded.orders) == 2
            @test loaded.name == "demo-dataset"

            typed_loaded = read_dataset(SampleDataSet, source)
            @test typed_loaded isa SampleDataSet
            @test typed_loaded.metadata["tags"] == ["sample", "io"]

            loaded_from_path = read_dataset(tar_gz_path)
            @test loaded_from_path isa SampleDataSet
        end

        @testset "ArchiveMedia overwrite protection" begin
            zip_path = joinpath(temp_dir, "protected.zip")
            source = ArchiveMedia(zip_path)
            write_dataset(source, ds)
            @test_throws ArgumentError write_dataset(source, ds)
            write_dataset(source, ds; overwrite=true)   # must not throw
            @test isfile(zip_path)
        end

        @testset "ArchiveMedia csv type roundtrip" begin
            zip_path = joinpath(temp_dir, "dataset-csv.zip")
            source = ArchiveMedia(zip_path)
            write_dataset(source, ds; type=:csv)

            loaded = read_dataset(source; type=:csv)
            @test loaded isa SampleDataSet
            @test nrow(loaded.users) == 2
        end

        @testset "ArchiveMedia format auto-detection" begin
            @test ArchiveMedia("foo.zip").format    == :zip
            @test ArchiveMedia("foo.tar.gz").format == :tar_gz
            @test ArchiveMedia("foo.tgz").format    == :tar_gz
            @test ArchiveMedia("foo.ZIP").format    == :zip
            @test_throws ArgumentError ArchiveMedia("foo.rar")
        end

        @testset "ArchiveMedia read missing file" begin
            @test_throws ArgumentError read_dataset(ArchiveMedia("nonexistent.zip"))
        end

        @testset "nonpersisted_fields — absent field defaults on FileSystemMedia" begin
            struct DataSetWithNP <: iDataSet
                users::DataFrame
                cache::DataFrame        # non-persisted
                name::String
                opt::Union{Nothing,String}  # non-persisted
            end
            MyJuliaToolbox.nonpersisted_fields(::Type{DataSetWithNP}) = (:cache, :opt)

            np_dir = joinpath(temp_dir, "nonpersisted")
            source = FileSystemMedia(np_dir)
            ds_np = DataSetWithNP(users_df, DataFrame(x=[1,2]), "np-test", "hello")

            write_dataset(source, ds_np; overwrite=true)

            # non-persisted fields must be absent from disk
            @test !isfile(joinpath(np_dir, "cache.arrow"))
            @test !haskey(JSON.parsefile(joinpath(np_dir, "data.json")), "opt")

            # read back: non-persisted fields get automatic defaults
            loaded = read_dataset(DataSetWithNP, source)
            @test loaded isa DataSetWithNP
            @test nrow(loaded.cache) == 0        # DataFrame()
            @test loaded.opt === nothing          # Union{Nothing,...}
            @test loaded.name == "np-test"
            @test nrow(loaded.users) == 2
        end

        @testset "nonpersisted_fields — absent field defaults on ArchiveMedia (.zip)" begin
            struct DataSetWithNPZip <: iDataSet
                orders::DataFrame
                scratch::DataFrame   # non-persisted
                label::String
            end
            MyJuliaToolbox.nonpersisted_fields(::Type{DataSetWithNPZip}) = (:scratch,)

            zip_np_path = joinpath(temp_dir, "np-dataset.zip")
            source = ArchiveMedia(zip_np_path)
            ds_npz = DataSetWithNPZip(orders_df, DataFrame(tmp=[99]), "zipped")

            write_dataset(source, ds_npz)
            loaded = read_dataset(DataSetWithNPZip, source)
            @test loaded isa DataSetWithNPZip
            @test nrow(loaded.scratch) == 0
            @test loaded.label == "zipped"
        end
    finally
        try
            rm(temp_dir, recursive=true, force=true)
        catch
            # Ignore cleanup errors on Windows file locks
        end
    end
end
