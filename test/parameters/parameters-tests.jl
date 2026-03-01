using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using SQLite

@testset "Parameters from JSON" begin
    struct OptimizerParameters <: iParameters
        learning_rate::Float64
        beta1::Float64
    end

    struct ModelParameters <: iParameters
        name::String
        epochs::Int
        enabled::Bool
        optimizer::OptimizerParameters
        tags::Vector{String}
    end

    struct LayerParameters <: iParameters
        units::Int
        activation::String
    end

    struct NetworkParameters <: iParameters
        model_name::String
        layers::Vector{LayerParameters}
    end

    @testset "construct from dictionary" begin
        data = Dict(
            "name" => "baseline",
            "epochs" => 25,
            "enabled" => true,
            "optimizer" => Dict(
                "learning_rate" => 0.01,
                "beta1" => 0.9,
            ),
            "tags" => ["fast", "safe"],
        )

        params = parameters_from_dict(ModelParameters, data)
        @test params.name == "baseline"
        @test params.epochs == 25
        @test params.enabled == true
        @test params.optimizer.learning_rate == 0.01
        @test params.optimizer.beta1 == 0.9
        @test params.tags == ["fast", "safe"]
    end

    @testset "construct from json file" begin
        tmp, io = mktemp()
        try
            write(io, """
            {
              \"name\": \"prod\",
              \"epochs\": 50,
              \"enabled\": false,
              \"optimizer\": {
                \"learning_rate\": 0.001,
                \"beta1\": 0.95
              },
              \"tags\": [\"stable\", \"release\"]
            }
            """)
            close(io)

            params = parameters_from_json(ModelParameters, tmp)
            @test params.name == "prod"
            @test params.epochs == 50
            @test params.enabled == false
            @test params.optimizer.learning_rate == 0.001
            @test params.optimizer.beta1 == 0.95
            @test params.tags == ["stable", "release"]
        finally
            isopen(io) && close(io)
            rm(tmp; force=true)
        end
    end

    @testset "invalid shape throws" begin
        missing_key = Dict(
            "name" => "x",
            "epochs" => 1,
            "enabled" => true,
            "optimizer" => Dict("learning_rate" => 0.1, "beta1" => 0.9),
        )
        @test_throws ArgumentError parameters_from_dict(ModelParameters, missing_key)

        extra_key = Dict(
            "name" => "x",
            "epochs" => 1,
            "enabled" => true,
            "optimizer" => Dict("learning_rate" => 0.1, "beta1" => 0.9),
            "tags" => ["a"],
            "unexpected" => 123,
        )
        @test_throws ArgumentError parameters_from_dict(ModelParameters, extra_key)
    end

    @testset "vector of nested iParameters" begin
        data = Dict(
            "model_name" => "mlp",
            "layers" => [
                Dict("units" => 64, "activation" => "relu"),
                Dict("units" => 32, "activation" => "tanh"),
            ],
        )

        params = parameters_from_dict(NetworkParameters, data)
        @test params.model_name == "mlp"
        @test length(params.layers) == 2
        @test params.layers[1] isa LayerParameters
        @test params.layers[1].units == 64
        @test params.layers[1].activation == "relu"
        @test params.layers[2].units == 32
        @test params.layers[2].activation == "tanh"

        tmp, io = mktemp()
        try
            write(io, """
            {
              \"model_name\": \"deep-net\",
              \"layers\": [
                {\"units\": 128, \"activation\": \"relu\"},
                {\"units\": 64, \"activation\": \"relu\"},
                {\"units\": 10, \"activation\": \"softmax\"}
              ]
            }
            """)
            close(io)

            json_params = parameters_from_json(NetworkParameters, tmp)
            @test json_params.model_name == "deep-net"
            @test length(json_params.layers) == 3
            @test json_params.layers[3].activation == "softmax"
        finally
            isopen(io) && close(io)
            rm(tmp; force=true)
        end

        invalid_layers = Dict(
            "model_name" => "broken",
            "layers" => [
                Dict("units" => 16, "activation" => "relu"),
                "not-an-object",
            ],
        )
        @test_throws ArgumentError parameters_from_dict(NetworkParameters, invalid_layers)
    end

    @testset "read_parameters from media source" begin
        temp_dir = mktempdir()
        params_root = nothing
        try
            conf_dir = joinpath(temp_dir, "configs")
            mkpath(conf_dir)

            json_path = joinpath(conf_dir, "model.json")
            open(json_path, "w") do io
                write(io, """
                {
                  \"name\": \"fs-model\",
                  \"epochs\": 12,
                  \"enabled\": true,
                  \"optimizer\": {
                    \"learning_rate\": 0.02,
                    \"beta1\": 0.91
                  },
                  \"tags\": [\"cfg\", \"filesystem\"]
                }
                """)
            end

            source = FileSystemMedia(temp_dir)
            params = read_parameters(ModelParameters, source, "model.json", "configs")

            @test params.name == "fs-model"
            @test params.epochs == 12
            @test params.optimizer.learning_rate == 0.02
            @test params.tags == ["cfg", "filesystem"]

            non_json_error = try
                read_parameters(ModelParameters, source, "model.txt", "configs")
                nothing
            catch err
                err
            end
            @test non_json_error isa ArgumentError
            @test occursin("expected a .json file", string(non_json_error))

            params_root = mktempdir()
            json_in_root = joinpath(params_root, "model.json")
            open(json_in_root, "w") do io
                write(io, read(json_path, String))
            end

            db_source = DatabaseMedia(":memory:", parameters_locator=params_root)
            try
                params_from_db_locator = read_parameters(ModelParameters, db_source, "model.json")
                @test params_from_db_locator.optimizer.beta1 == 0.91
            finally
                SQLite.close(db_source.connection)
            end

            db_without_locator = DatabaseMedia(":memory:")
            try
                missing_locator_error = try
                    read_parameters(ModelParameters, db_without_locator, "model.json")
                    nothing
                catch err
                    err
                end
                @test missing_locator_error isa ArgumentError
                @test occursin("requires `parameters_locator`", string(missing_locator_error))
            finally
                SQLite.close(db_without_locator.connection)
            end
        finally
            rm(temp_dir; recursive=true, force=true)
            if params_root !== nothing
                rm(params_root; recursive=true, force=true)
            end
        end
    end

    @testset "write_parameters to path and media" begin
        temp_dir = mktempdir()
        params_root = nothing
        try
            params = ModelParameters(
                "writer",
                21,
                true,
                OptimizerParameters(0.015, 0.88),
                ["save", "json"],
            )

            # plain path write + roundtrip read
            path_out = joinpath(temp_dir, "plain.json")
            write_parameters(path_out, params)
            loaded = parameters_from_json(ModelParameters, path_out)
            @test loaded.name == "writer"
            @test loaded.optimizer.beta1 == 0.88
            @test loaded.tags == ["save", "json"]

            # overwrite protection
            @test_throws ArgumentError write_parameters(path_out, params)
            write_parameters(path_out, params; overwrite=true, pretty=false)

            # FileSystemMedia write + read_parameters roundtrip
            source_fs = FileSystemMedia(temp_dir)
            write_parameters(source_fs, "fs.json", params, "cfg")
            loaded_fs = read_parameters(ModelParameters, source_fs, "fs.json", "cfg")
            @test loaded_fs.epochs == 21

            # DatabaseMedia with parameters_locator write + read_parameters roundtrip
            params_root = mktempdir()
            source_db = DatabaseMedia(":memory:", parameters_locator=params_root)
            try
                write_parameters(source_db, "db.json", params, "nested")
                loaded_db = read_parameters(ModelParameters, source_db, "db.json", "nested")
                @test loaded_db.optimizer.learning_rate == 0.015
            finally
                SQLite.close(source_db.connection)
            end

            # media-specific validation
            source_db_no_locator = DatabaseMedia(":memory:")
            try
                @test_throws ArgumentError write_parameters(source_db_no_locator, "db.json", params)
            finally
                SQLite.close(source_db_no_locator.connection)
            end
        finally
            rm(temp_dir; recursive=true, force=true)
            if params_root !== nothing
                rm(params_root; recursive=true, force=true)
            end
        end
    end
end
