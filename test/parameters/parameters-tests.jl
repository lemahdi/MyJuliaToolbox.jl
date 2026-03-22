using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using SQLite
using JSON

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

# ── Nested plain-struct serialization ─────────────────────────────────────────
#
# Regression tests for structs that contain nested types which are NOT iParameters
# subtypes (plain @kwdef structs, vectors of plain structs, Any fields).
#
# Motivation: RSUParameters (RSU202503) has a scoring_formula field whose nested
# types (ScoringFormulaParam, ZoneScoringParam, ZoneConstantParam, etc.) are plain
# mutable structs — they do not inherit from iParameters.  The read path
# (_construct_from_dict / _convert_value) handles them via the `isstructtype`
# branch and works correctly.  The write path (_parameter_to_json_value) only
# recurses into iParameters subtypes; plain nested structs fall through to the
# bare `return value` branch, which causes JSON.jl to receive a raw Julia struct
# it cannot serialize (MethodError / incorrect output).
#
# These tests expose both failure modes so the fix can be targeted precisely:
#   1. write_parameters serializes plain nested structs correctly.
#   2. write_parameters → read_parameters round-trip preserves all values.
#   3. _meta::Any field holding a non-null Dict is preserved through round-trip.
#   4. Vector{plain struct} fields survive round-trip.
#   5. Union{Nothing, T} fields in plain structs survive round-trip.
@testset "Nested plain-struct serialization (non-iParameters)" begin

    # ── Struct hierarchy mirroring RSUParameters (no iParameters inheritance) ─

    Base.@kwdef mutable struct LeafParam
        name::String = ""
        value::Float64 = 0.0
        optional_id::Union{Nothing, Int} = nothing
    end

    Base.@kwdef mutable struct NestedContainerParam
        label::String = ""
        items::Vector{LeafParam} = LeafParam[]
        count::Int = 0
    end

    Base.@kwdef mutable struct RootWithPlainNested <: iParameters
        _meta::Any = nothing
        threshold::Float64 = 0.0
        container::NestedContainerParam = NestedContainerParam()
        extra_items::Vector{LeafParam} = LeafParam[]
    end

    # ── Test 1: read from dict (isstructtype branch) already works ────────────
    @testset "read plain nested structs from dict" begin
        data = Dict(
            "_meta" => Dict("version" => "1.0", "note" => "test"),
            "threshold" => 9.5,
            "container" => Dict(
                "label" => "my-container",
                "count" => 3,
                "items" => [
                    Dict("name" => "alpha", "value" => 1.1, "optional_id" => 10),
                    Dict("name" => "beta",  "value" => 2.2, "optional_id" => nothing),
                ],
            ),
            "extra_items" => [
                Dict("name" => "gamma", "value" => 3.3, "optional_id" => 99),
            ],
        )

        params = parameters_from_dict(RootWithPlainNested, data)

        @test params.threshold == 9.5
        @test params._meta isa Dict
        @test params._meta["version"] == "1.0"
        @test params.container isa NestedContainerParam
        @test params.container.label == "my-container"
        @test params.container.count == 3
        @test length(params.container.items) == 2
        @test params.container.items[1] isa LeafParam
        @test params.container.items[1].name == "alpha"
        @test params.container.items[1].value == 1.1
        @test params.container.items[1].optional_id == 10
        @test isnothing(params.container.items[2].optional_id)
        @test length(params.extra_items) == 1
        @test params.extra_items[1].name == "gamma"
    end

    # ── Test 2: write_parameters serializes plain nested structs ──────────────
    # This test currently FAILS: _parameter_to_json_value only handles iParameters
    # subtypes; plain structs fall through to `return value` and JSON.jl cannot
    # serialize raw Julia structs.
    @testset "write_parameters serializes plain nested structs" begin
        params = RootWithPlainNested(
            _meta      = Dict("version" => "2.0"),
            threshold  = 7.25,
            container  = NestedContainerParam(
                label  = "c1",
                count  = 2,
                items  = [
                    LeafParam(name="x", value=0.5, optional_id=1),
                    LeafParam(name="y", value=1.5, optional_id=nothing),
                ],
            ),
            extra_items = [LeafParam(name="z", value=9.9, optional_id=42)],
        )

        tmp_path, io = mktemp()
        close(io)
        try
            # Must not throw; previously threw MethodError from JSON.jl.
            @test_nowarn write_parameters(tmp_path * ".json", params; overwrite=true)

            # The output must be valid JSON.
            raw = read(tmp_path * ".json", String)
            parsed = JSON.parse(raw)
            @test parsed isa AbstractDict

            # Top-level scalar field must round-trip.
            @test parsed["threshold"] == 7.25

            # _meta dict must be serialized as a JSON object, not a raw struct repr.
            @test parsed["_meta"] isa AbstractDict
            @test parsed["_meta"]["version"] == "2.0"

            # Nested plain struct must be serialized as a JSON object.
            @test parsed["container"] isa AbstractDict
            @test parsed["container"]["label"] == "c1"
            @test parsed["container"]["count"] == 2
            @test parsed["container"]["items"] isa Vector
            @test length(parsed["container"]["items"]) == 2
            @test parsed["container"]["items"][1]["name"] == "x"
            @test parsed["container"]["items"][2]["optional_id"] === nothing

            # Vector of plain structs at top level.
            @test parsed["extra_items"] isa Vector
            @test parsed["extra_items"][1]["name"] == "z"
            @test parsed["extra_items"][1]["optional_id"] == 42
        finally
            rm(tmp_path; force=true)
            rm(tmp_path * ".json"; force=true)
        end
    end

    # ── Test 3: full round-trip write_parameters → read_parameters ────────────
    @testset "write → read round-trip for plain nested structs" begin
        original = RootWithPlainNested(
            _meta      = Dict("version" => "rt"),
            threshold  = 3.14,
            container  = NestedContainerParam(
                label  = "rt-container",
                count  = 1,
                items  = [LeafParam(name="rt-leaf", value=2.71, optional_id=7)],
            ),
            extra_items = LeafParam[],
        )

        tmp_dir = mktempdir()
        try
            path = joinpath(tmp_dir, "rt.json")
            write_parameters(path, original)

            loaded = parameters_from_json(RootWithPlainNested, path)

            @test loaded.threshold == original.threshold
            @test loaded._meta isa AbstractDict
            @test loaded._meta["version"] == "rt"
            @test loaded.container.label == original.container.label
            @test loaded.container.count == original.container.count
            @test length(loaded.container.items) == 1
            @test loaded.container.items[1].name == "rt-leaf"
            @test loaded.container.items[1].value == 2.71
            @test loaded.container.items[1].optional_id == 7
            @test isempty(loaded.extra_items)
        finally
            rm(tmp_dir; recursive=true, force=true)
        end
    end

    # ── Test 4: write via FileSystemMedia → read_parameters round-trip ────────
    @testset "FileSystemMedia write → read_parameters round-trip" begin
        params = RootWithPlainNested(
            _meta     = nothing,
            threshold = 5.0,
            container = NestedContainerParam(
                label = "fs-container",
                count = 0,
                items = LeafParam[],
            ),
            extra_items = [LeafParam(name="fs-leaf", value=4.0, optional_id=nothing)],
        )

        tmp_dir = mktempdir()
        try
            source = FileSystemMedia(tmp_dir)
            write_parameters(source, "nested.json", params, "cfg")
            loaded = read_parameters(RootWithPlainNested, source, "nested.json", "cfg")

            @test loaded.threshold == 5.0
            @test isnothing(loaded._meta)
            @test loaded.container.label == "fs-container"
            @test isempty(loaded.container.items)
            @test length(loaded.extra_items) == 1
            @test loaded.extra_items[1].name == "fs-leaf"
            @test isnothing(loaded.extra_items[1].optional_id)
        finally
            rm(tmp_dir; recursive=true, force=true)
        end
    end
end
