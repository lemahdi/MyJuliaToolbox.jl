using Test
using MyJuliaToolbox

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
end
