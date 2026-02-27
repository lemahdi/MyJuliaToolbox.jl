using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO

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
        finally
            rm(temp_dir; recursive=true, force=true)
        end
    end
end
