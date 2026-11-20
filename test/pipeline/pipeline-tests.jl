using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using DataFrames
using DataFramesMeta
using JSON

# Pipeline runs (src/pipeline.jl): offline on folders, then on a MinIO when one answers, reached with the variables
# minio-tests.jl reads (MINIO_TEST_ENDPOINT, MINIO_TEST_ACCESS_KEY, MINIO_TEST_SECRET_KEY, MINIO_TEST_BUCKET).

# ──────────────────────────────────────────────────────────────────────────────
# Fixtures
# ──────────────────────────────────────────────────────────────────────────────

const PIPELINE_DATASET_UID = "dataset-0190f5a2-7c3e-7d4a-8b1c-2e3f4a5b6c7d"
const PIPELINE_RUN_UID = "run-0190f5a2-7c3e-7d4a-9b1c-2e3f4a5b6c7e"
const PIPELINE_TABLE_UID = "table-0190f5a2-7c3e-7d4a-ab1c-2e3f4a5b6c7f"
const PIPELINE_TIME = r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"

"""A dataset for the pipeline tests: three tables, and a label set outside any step."""
mutable struct PipelineTestDataSet <: iDataSet
    raw_amoa_df::DataFrame
    clean_df::DataFrame
    score_df::DataFrame
    label::String
end

"""An empty test dataset."""
PipelineTestDataSet() = PipelineTestDataSet(DataFrame(), DataFrame(), DataFrame(), "")

"""A dataset whose fields break the rules: a name outside the pattern, two fields giving one table name."""
mutable struct PipelineOddDataSet <: iDataSet
    données_df::DataFrame
    score::DataFrame
    score_df::DataFrame
end

"""An empty odd dataset."""
PipelineOddDataSet() = PipelineOddDataSet(DataFrame(), DataFrame(), DataFrame())

"""Parameters for the pipeline tests."""
struct PipelineTestParameters <: iParameters
    threshold::Int
end

"""A dataset of rsu's shape: a table, and parameters set outside any step."""
mutable struct PipelineParametersDataSet <: iDataSet
    score_df::DataFrame
    parameters::PipelineTestParameters
end

"""A step that sets the score table from the parameters."""
function score_with_parameters!(dataset::PipelineParametersDataSet, run_log::Dict{String, Any})
    set_output!(dataset, run_log, :score_df, DataFrame(score = [dataset.parameters.threshold]))
    return dataset
end

"""Take the landing table `raw_amoa` into the dataset."""
function ingest!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}, landing::Dict{String, DataFrame})
    set_output!(dataset, run_log, :raw_amoa_df, landing["raw_amoa"])
    return dataset
end

"""Keep the households with at least one person."""
function clean!(dataset::PipelineTestDataSet, run_log::Dict{String, Any})
    set_output!(dataset, run_log, :clean_df, @rsubset(dataset.raw_amoa_df, :persons > 0))
    return dataset
end

"""Score each household, through a helper that sets the table."""
function score!(dataset::PipelineTestDataSet, run_log::Dict{String, Any})
    set_score!(dataset, run_log)
    return dataset
end

"""Set the score table: a helper that `score!` calls, so its set belongs to the step `score`."""
function set_score!(dataset::PipelineTestDataSet, run_log::Dict{String, Any})
    set_output!(dataset, run_log, :score_df, @transform(dataset.clean_df, :score = :persons .* 1.5))
    return dataset
end

"""Score again: the score table set by a second step."""
function rescore!(dataset::PipelineTestDataSet, run_log::Dict{String, Any})
    set_output!(dataset, run_log, :score_df, @transform(dataset.clean_df, :score = :persons .* 2.0))
    return dataset
end

"""A step named like `clean!` without the `!`."""
clean(dataset::PipelineTestDataSet, run_log::Dict{String, Any}) = dataset

"""A step whose name is outside the pattern."""
étape!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}) = dataset

"""A step that fails with a two-line message."""
fail!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}, message::AbstractString) = error(message)

"""A step that reads `steps.json` while it runs."""
function peek!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}, zones, seen::Vector{Any})
    push!(seen, read_steps(zones))
    return dataset
end

"""A step that starts another step while it runs."""
nested!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}, zones) = run_step(run_log, zones, clean!, dataset)

"""A step that sets the given fields of an odd dataset to one small table each."""
function set_odd!(dataset::PipelineOddDataSet, run_log::Dict{String, Any}, fields::Vector{Symbol})
    for field in fields
        set_output!(dataset, run_log, field, DataFrame(value = [1, 2]))
    end
    return dataset
end

"""A step that sets the given table as the clean table."""
function set_clean!(dataset::PipelineTestDataSet, run_log::Dict{String, Any}, table::DataFrame)
    set_output!(dataset, run_log, :clean_df, table)
    return dataset
end

"""A step that sets the given field to the given value."""
function set_field!(dataset::iDataSet, run_log::Dict{String, Any}, field::Symbol, value)
    set_output!(dataset, run_log, field, value)
    return dataset
end

# 201 steps (the tower once took 200, a limit with no meaning, now gone); names of 128 and 129 characters.
for index in 1:201
    @eval begin
        "One of many steps; it does nothing."
        $(Symbol("many_step_$(index)!"))(dataset::PipelineTestDataSet, run_log::Dict{String, Any}) = dataset
    end
end
@eval begin
    "A step whose name has 128 characters."
    $(Symbol("s" * "x"^127 * "!"))(dataset::PipelineTestDataSet, run_log::Dict{String, Any}) = dataset
    "A step whose name has 129 characters."
    $(Symbol("s" * "x"^128 * "!"))(dataset::PipelineTestDataSet, run_log::Dict{String, Any}) = dataset
end

"""Zones in folders: a landing folder, and the run's folder in a pipeline folder."""
function folder_zones()
    run_folder = joinpath(mktempdir(), PIPELINE_DATASET_UID, PIPELINE_RUN_UID)
    mkpath(run_folder)
    return (landing = FileSystemMedia(mktempdir()), pipeline = FileSystemMedia(run_folder))
end

"""A landing part's key: `<dataset UID>/<table UID>/<SHA-256>.arrow` (the SHA-256 is not checked again)."""
landing_key(fill_character::Char) = "$(PIPELINE_DATASET_UID)/$(PIPELINE_TABLE_UID)/$(fill_character^64).arrow"

"""Write one landing part into the landing zone (again if the tests already wrote it: a part's key is its content's)."""
function write_landing_part(zone, key::AbstractString, table::DataFrame)
    zone isa FileSystemMedia && mkpath(dirname(joinpath(zone.path, key)))
    write_dataframe(zone, key, table; overwrite = true)
    return nothing
end

"""Write `landing.json` in the run's prefix: C10's answer for a landing zone, with the given tables."""
function write_landing_list(zones, tables::AbstractDict)
    answer = Dict("dataset_id" => PIPELINE_DATASET_UID, "sha256" => "0"^64, "updated_at" => "2026-11-18T09:00:00Z",
                  "manifest" => Dict("tables" => tables))
    MyJuliaToolbox._write_zone_file(zones.pipeline, "landing.json", Vector{UInt8}(JSON.json(answer)))
    return nothing
end

"""A landing zone: `raw_amoa` in two parts and `raw_menage` in one, with `landing.json`."""
function write_test_landing(zones)
    parts = [landing_key('a') => DataFrame(menage_ano = ["m1", "m2", "m3"], persons = [2, 0, 3]),
             landing_key('b') => DataFrame(menage_ano = ["m4", "m5"], persons = [1, 4]),
             landing_key('c') => DataFrame(menage_ano = ["m1"], region = ["north"])]
    for (key, table) in parts
        write_landing_part(zones.landing, key, table)
    end
    write_landing_list(zones, Dict("raw_amoa" => landing_entry("raw_amoa", [first(parts[1]), first(parts[2])]),
                                   "raw_menage" => landing_entry("raw_menage", [first(parts[3])])))
    return nothing
end

"""A table as C10's landing answer lists it, with its parts' keys in order."""
function landing_entry(name::AbstractString, part_keys::Vector{String})
    return Dict("name" => name, "table_uid" => PIPELINE_TABLE_UID,
                "parts" => [Dict("key" => key, "sha256" => "0"^64, "rows" => 1) for key in part_keys])
end

"""`steps.json` as the zone holds it now."""
read_steps(zones) = JSON.parse(String(MyJuliaToolbox._read_zone_file(zones.pipeline, "steps.json")))

"""The test pipeline's steps on a new log and dataset, without `write_run`."""
function run_test_steps(zones)
    run_log, dataset = Dict{String, Any}(), PipelineTestDataSet()
    dataset.label = "amoa test"
    run_step(run_log, zones, ingest!, dataset, read_landing(zones))
    run_step(run_log, zones, clean!, dataset)
    run_step(run_log, zones, score!, dataset)
    return run_log, dataset
end

"""The test pipeline from its landing zone to `write_run`."""
function run_test_pipeline(zones)
    write_test_landing(zones)
    run_log, dataset = run_test_steps(zones)
    write_run(run_log, zones, dataset)
    return run_log, dataset
end

"""The keys of a log's tables, then of its other files."""
log_keys(steps) = vcat([table["key"] for table in steps["tables"]], [file["key"] for file in steps["files"]])

"""Check a `done` run of the test pipeline whose dataset was written under `dataset_prefix`."""
function check_done_run(steps, dataset_prefix::AbstractString)
    @test steps["contract"] == "mykonos.steps.v1"
    @test steps["state"] == "done" && steps["error"] === nothing
    @test [step["name"] for step in steps["steps"]] == ["ingest", "clean", "score"]
    @test [step["function"] for step in steps["steps"]] == ["Main.ingest!", "Main.clean!", "Main.score!"]
    @test [step["position"] for step in steps["steps"]] == [1, 2, 3]
    @test all(step["state"] == "done" && step["error"] === nothing for step in steps["steps"])
    @test [(set["step"], set["field"], set["table"], set["rows"]) for set in steps["sets"]] ==
          [("ingest", "raw_amoa_df", "raw_amoa", 5), ("clean", "clean_df", "clean", 4), ("score", "score_df", "score", 4)]
    @test steps["sets"][3]["columns"] == [Dict("name" => "menage_ano", "type" => "String"),
                                          Dict("name" => "persons", "type" => "Int64"),
                                          Dict("name" => "score", "type" => "Float64")]
    @test [(table["name"], table["step"], table["rows"], table["key"]) for table in steps["tables"]] ==
          [(name, step, rows, "$(dataset_prefix)/$(field).arrow") for (name, step, rows, field) in
           (("raw_amoa", "ingest", 5, "raw_amoa_df"), ("clean", "clean", 4, "clean_df"), ("score", "score", 4, "score_df"))]
    @test [file["key"] for file in steps["files"]] == ["$(dataset_prefix)/data.json", "$(dataset_prefix)/data_info.json"]
    times = vcat(steps["started_at"], steps["ended_at"], [set["at"] for set in steps["sets"]],
                 [step[moment] for step in steps["steps"] for moment in ("started_at", "ended_at")])
    @test all(occursin(PIPELINE_TIME, time) for time in times)
    @test sort(collect(keys(steps))) == sort(["contract", "state", "started_at", "ended_at", "error", "steps", "sets",
                                              "tables", "files"])
    return nothing
end

"""Check a dataset read back from a written run against the one the pipeline built."""
function check_read_back(read_back::PipelineTestDataSet, dataset::PipelineTestDataSet)
    @test read_back.raw_amoa_df == dataset.raw_amoa_df
    @test read_back.clean_df == dataset.clean_df
    @test read_back.score_df == dataset.score_df
    @test read_back.label == "amoa test"
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# Offline, on folders
# ──────────────────────────────────────────────────────────────────────────────

@testset "Pipeline runs" begin

    @testset "three steps, then write_run" begin
        zones = folder_zones()
        run_log, dataset = run_test_pipeline(zones)
        steps = read_steps(zones)
        dataset_folder = joinpath(zones.pipeline.path, "dataset")
        check_done_run(steps, dataset_folder)
        @test steps == JSON.parse(JSON.json(MyJuliaToolbox._log_document(run_log)))
        @test log_keys(steps) == [joinpath(dataset_folder, name) for name in
                                  ("raw_amoa_df.arrow", "clean_df.arrow", "score_df.arrow", "data.json", "data_info.json")]
        @test sort(log_keys(steps)) == MyJuliaToolbox._zone_keys(FileSystemMedia(dataset_folder))
        check_read_back(read_dataset(PipelineTestDataSet, FileSystemMedia(dataset_folder)), dataset)
        @test JSON.parsefile(joinpath(dataset_folder, "data.json"))["label"] == "amoa test"
    end

    @testset "read_landing stacks each table's parts in order" begin
        zones = folder_zones()
        write_test_landing(zones)
        tables = read_landing(zones)
        @test sort(collect(keys(tables))) == ["raw_amoa", "raw_menage"]
        @test tables["raw_amoa"] == DataFrame(menage_ano = ["m1", "m2", "m3", "m4", "m5"], persons = [2, 0, 3, 1, 4])
        @test tables["raw_menage"] == DataFrame(menage_ano = ["m1"], region = ["north"])
        write_landing_list(zones, Dict("raw_empty" => Dict("name" => "raw_empty", "parts" => [])))
        @test_throws ArgumentError read_landing(zones)
        MyJuliaToolbox._write_zone_file(zones.pipeline, "landing.json", Vector{UInt8}("{\"dataset_id\": \"x\"}"))
        @test_throws ArgumentError read_landing(zones)
    end

    @testset "steps.json during a step: running" begin
        zones = folder_zones()
        run_log, dataset, seen = Dict{String, Any}(), PipelineTestDataSet(), Any[]
        run_step(run_log, zones, peek!, dataset, zones, seen)
        during = only(seen)
        @test during["state"] == "running" && during["ended_at"] === nothing
        @test only(during["steps"])["state"] == "running" && only(during["steps"])["ended_at"] === nothing
        @test isempty(during["tables"]) && isempty(during["files"])
        @test read_steps(zones)["steps"][1]["state"] == "done"
        @test read_steps(zones)["state"] == "running"
    end

    @testset "set_output! with no step running: refused" begin
        zones = folder_zones()
        write_test_landing(zones)
        dataset = PipelineTestDataSet()
        @test_throws ArgumentError set_output!(dataset, Dict{String, Any}(), :clean_df, DataFrame(a = [1]))
        run_log, dataset = run_test_steps(zones)
        @test_throws ArgumentError set_output!(dataset, run_log, :clean_df, DataFrame(a = [1]))
    end

    @testset "a table field with rows that no step set: refused by write_run" begin
        zones = folder_zones()
        write_test_landing(zones)
        run_log, dataset = Dict{String, Any}(), PipelineTestDataSet()
        run_step(run_log, zones, ingest!, dataset, read_landing(zones))
        dataset.score_df = DataFrame(menage_ano = ["m1"], score = [1.0])
        refusal = try write_run(run_log, zones, dataset); nothing catch failure; failure end
        @test refusal isa ArgumentError && occursin("score_df", refusal.msg)
        steps = read_steps(zones)
        @test steps["state"] == "failed" && occursin("score_df", steps["error"]) && steps["ended_at"] !== nothing
        @test only(steps["steps"])["state"] == "done"
        @test isempty(steps["tables"]) && isempty(steps["files"])
        @test !isdir(joinpath(zones.pipeline.path, "dataset"))
    end

    @testset "a table changed since its last set: refused by write_run" begin
        for change! in (dataset -> push!(dataset.clean_df, ("m9", 9)), dataset -> (dataset.clean_df = copy(dataset.clean_df)))
            zones = folder_zones()
            write_test_landing(zones)
            run_log, dataset = run_test_steps(zones)
            change!(dataset)
            refusal = try write_run(run_log, zones, dataset); nothing catch failure; failure end
            @test refusal isa ArgumentError && occursin("clean_df", refusal.msg)
            @test read_steps(zones)["state"] == "failed"
        end
    end

    @testset "a table set by two steps: two sets, its step the second" begin
        zones = folder_zones()
        write_test_landing(zones)
        run_log, dataset = run_test_steps(zones)
        run_step(run_log, zones, rescore!, dataset)
        write_run(run_log, zones, dataset)
        steps = read_steps(zones)
        @test [set["step"] for set in steps["sets"] if set["field"] == "score_df"] == ["score", "rescore"]
        @test only(table["step"] for table in steps["tables"] if table["field"] == "score_df") == "rescore"
    end

    @testset "a failing step: failed, its error on one line, thrown again" begin
        zones = folder_zones()
        write_test_landing(zones)
        run_log, dataset = run_test_steps(zones)
        @test_throws ErrorException run_step(run_log, zones, fail!, dataset, "line one\nline\ttwo")
        steps = read_steps(zones)
        @test steps["state"] == "failed" && steps["error"] === nothing && steps["ended_at"] !== nothing
        @test steps["steps"][end]["name"] == "fail" && steps["steps"][end]["state"] == "failed"
        @test steps["steps"][end]["error"] == "line one line two"
        @test isempty(steps["tables"]) && isempty(steps["files"])
        @test_throws ArgumentError run_step(run_log, zones, rescore!, dataset)
        @test_throws ArgumentError write_run(run_log, zones, dataset)
        @test length(read_steps(zones)["steps"]) == 4
    end

    @testset "refused steps" begin
        zones = folder_zones()
        run_log, dataset = Dict{String, Any}(), PipelineTestDataSet()
        @test_throws ArgumentError run_step(run_log, zones, (dataset, run_log) -> dataset, dataset)
        @test_throws ArgumentError run_step(run_log, zones, étape!, dataset)
        @test_throws ArgumentError run_step(run_log, zones, getfield(Main, Symbol("s" * "x"^128 * "!")), dataset)
        run_step(run_log, zones, getfield(Main, Symbol("s" * "x"^127 * "!")), dataset)
        @test run_log["steps"][end]["name"] == "s" * "x"^127
        run_step(run_log, zones, many_step_1!, dataset)
        @test_throws ArgumentError run_step(run_log, zones, many_step_1!, dataset)
        run_step(run_log, zones, clean, dataset)
        @test_throws ArgumentError run_step(run_log, zones, clean!, dataset)
        @test_throws ArgumentError write_run(Dict{String, Any}(), zones, dataset)
        @test_throws ArgumentError run_step(run_log, zones, nested!, dataset, zones)
        steps = read_steps(zones)
        @test steps["steps"][end]["name"] == "nested" && occursin("still running", steps["steps"][end]["error"])
    end

    @testset "a step after write_run: refused" begin
        zones = folder_zones()
        run_log, dataset = run_test_pipeline(zones)
        @test_throws ArgumentError run_step(run_log, zones, rescore!, dataset)
        @test_throws ArgumentError write_run(run_log, zones, dataset)
    end

    @testset "refused sets" begin
        zones = folder_zones()
        run_log = Dict{String, Any}()
        refused(dataset, field, value) =
            try run_step(run_log, zones, set_field!, dataset, field, value); nothing catch failure; failure end
        @test refused(PipelineTestDataSet(), :missing_df, DataFrame(a = [1])) isa ArgumentError
        empty!(run_log)
        @test refused(PipelineTestDataSet(), :score_df, [1, 2]) isa ArgumentError
        empty!(run_log)
        @test refused(PipelineOddDataSet(), :données_df, DataFrame(a = [1])) isa ArgumentError
        empty!(run_log)
        @test refused(PipelineTestDataSet(), :score_df, DataFrame(Symbol("a\nb") => [1])) isa ArgumentError
        empty!(run_log)
        @test refused(PipelineTestDataSet(), :score_df, DataFrame(Symbol("") => [1])) isa ArgumentError
    end

    @testset "two fields giving one table name: refused by write_run" begin
        zones = folder_zones()
        run_log, dataset = Dict{String, Any}(), PipelineOddDataSet()
        run_step(run_log, zones, set_odd!, dataset, [:score, :score_df])
        refusal = try write_run(run_log, zones, dataset); nothing catch failure; failure end
        @test refusal isa ArgumentError && occursin("score", refusal.msg)
        @test read_steps(zones)["state"] == "failed"
    end

    @testset "an empty table: in sets, not in tables" begin
        zones = folder_zones()
        write_test_landing(zones)
        run_log, dataset = Dict{String, Any}(), PipelineTestDataSet()
        run_step(run_log, zones, ingest!, dataset, read_landing(zones))
        run_step(run_log, zones, set_clean!, dataset, DataFrame(menage_ano = String[], persons = Int[]))
        write_run(run_log, zones, dataset)
        steps = read_steps(zones)
        @test steps["sets"][end]["field"] == "clean_df" && steps["sets"][end]["rows"] == 0
        @test [table["field"] for table in steps["tables"]] == ["raw_amoa_df"]
    end

    @testset "parameters set outside any step: written, listed in files" begin
        zones = folder_zones()
        run_log = Dict{String, Any}()
        dataset = PipelineParametersDataSet(DataFrame(), PipelineTestParameters(3))
        run_step(run_log, zones, score_with_parameters!, dataset)
        write_run(run_log, zones, dataset)
        dataset_folder = joinpath(zones.pipeline.path, "dataset")
        @test [file["key"] for file in read_steps(zones)["files"]] ==
              [joinpath(dataset_folder, name) for name in ("data.json", "data_info.json", "parameters/parameters.json")]
        read_back = read_dataset(PipelineParametersDataSet, FileSystemMedia(dataset_folder))
        @test read_back.parameters == dataset.parameters && read_back.score_df == dataset.score_df
    end

    @testset "set_output! keeps the table, not a copy" begin
        zones = folder_zones()
        run_log, dataset, table = Dict{String, Any}(), PipelineTestDataSet(), DataFrame(a = [1, 2])
        run_step(run_log, zones, set_clean!, dataset, table)
        @test dataset.clean_df === table
    end

    @testset "no limit beyond a name's 128 characters" begin
        zones = folder_zones()
        run_log, dataset = Dict{String, Any}(), PipelineTestDataSet()
        for index in 1:201
            run_step(run_log, zones, getfield(Main, Symbol("many_step_$(index)!")), dataset)
        end
        wide = DataFrame([Symbol("c$(index)") => [index] for index in 1:600])
        run_step(run_log, zones, set_clean!, dataset, wide)
        @test_throws ErrorException run_step(run_log, zones, fail!, dataset, "x"^5000)
        steps = read_steps(zones)
        @test length(steps["steps"]) == 203 && steps["steps"][end]["position"] == 203
        @test length(steps["sets"][end]["columns"]) == 600
        @test steps["steps"][end]["error"] == "x"^5000
    end

    @testset "open_zones" begin
        settings = Dict("MYKONOS_OBJECT_ENDPOINT" => "https://kb-objects:9000",
                        "MYKONOS_LANDING_STORE" => "s3://mykonos-private/landing",
                        "MYKONOS_PIPELINE_STORE" => "s3://mykonos-private/pipeline/",
                        "MYKONOS_DATASET_UID" => PIPELINE_DATASET_UID, "MYKONOS_RUN_UID" => PIPELINE_RUN_UID,
                        "MINIO_ACCESS_KEY" => "test-access", "MINIO_SECRET_KEY" => "test-secret")
        zones = open_zones(settings)
        @test zones.landing isa MinIOMedia && zones.pipeline isa MinIOMedia
        @test (zones.landing.bucket, zones.landing.prefix) == ("mykonos-private", "landing")
        @test (zones.pipeline.bucket, zones.pipeline.prefix) ==
              ("mykonos-private", "pipeline/$(PIPELINE_DATASET_UID)/$(PIPELINE_RUN_UID)")
        dataset_zone = MyJuliaToolbox._zone_folder(zones.pipeline, "dataset")
        @test dataset_zone.prefix == "pipeline/$(PIPELINE_DATASET_UID)/$(PIPELINE_RUN_UID)/dataset"
        @test dataset_zone._config.endpoint == "https://kb-objects:9000"
        for variable in keys(settings)
            @test_throws ArgumentError open_zones(delete!(copy(settings), variable))
            @test_throws ArgumentError open_zones(merge(settings, Dict(variable => "")))
        end
        for (variable, value) in ("MYKONOS_LANDING_STORE" => "file:///landing", "MYKONOS_PIPELINE_STORE" => "s3://",
                                  "MYKONOS_DATASET_UID" => PIPELINE_RUN_UID, "MYKONOS_RUN_UID" => "../escape")
            @test_throws ArgumentError open_zones(merge(settings, Dict(variable => value)))
        end
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# On a MinIO, when one answers
# ──────────────────────────────────────────────────────────────────────────────

const PIPELINE_MINIO_ENDPOINT = get(ENV, "MINIO_TEST_ENDPOINT", "http://localhost:9000")
const PIPELINE_MINIO_ACCESS_KEY = get(ENV, "MINIO_TEST_ACCESS_KEY", "minioadmin")
const PIPELINE_MINIO_SECRET_KEY = get(ENV, "MINIO_TEST_SECRET_KEY", "minioadmin")
const PIPELINE_MINIO_BUCKET = get(ENV, "MINIO_TEST_BUCKET", "minio-test-toolbox")

"""Whether a MinIO answers at the test endpoint; its bucket is created if missing, as minio-tests.jl does."""
function pipeline_minio_answers()
    try
        minio_create_bucket!(MinIOMedia(PIPELINE_MINIO_BUCKET; endpoint = PIPELINE_MINIO_ENDPOINT,
                                        access_key = PIPELINE_MINIO_ACCESS_KEY, secret_key = PIPELINE_MINIO_SECRET_KEY))
        return true
    catch
        return false
    end
end

"""A new run UID in the UID tower's form, so that each test run has its own prefix."""
function new_test_uid(kind::AbstractString)
    digits = collect(bytes2hex(rand(UInt8, 16)))
    digits[13], digits[17] = '7', '8'
    text = String(digits)
    return "$kind-$(text[1:8])-$(text[9:12])-$(text[13:16])-$(text[17:20])-$(text[21:32])"
end

"""The zones `open_zones` gives on the test MinIO, for a new run."""
function minio_zones()
    return open_zones(Dict(
        "MYKONOS_OBJECT_ENDPOINT" => PIPELINE_MINIO_ENDPOINT,
        "MYKONOS_LANDING_STORE" => "s3://$(PIPELINE_MINIO_BUCKET)/landing",
        "MYKONOS_PIPELINE_STORE" => "s3://$(PIPELINE_MINIO_BUCKET)/pipeline",
        "MYKONOS_DATASET_UID" => PIPELINE_DATASET_UID, "MYKONOS_RUN_UID" => new_test_uid("run"),
        "MINIO_ACCESS_KEY" => PIPELINE_MINIO_ACCESS_KEY, "MINIO_SECRET_KEY" => PIPELINE_MINIO_SECRET_KEY))
end

if !pipeline_minio_answers()
    @warn "Pipeline MinIO tests skipped: no MinIO answers at $(PIPELINE_MINIO_ENDPOINT)"
else

@testset "Pipeline runs on MinIO" begin

    @testset "write_run on MinIO; steps.json running during a step" begin
        zones = minio_zones()
        write_test_landing(zones)
        run_log, dataset, seen = Dict{String, Any}(), PipelineTestDataSet(), Any[]
        dataset.label = "amoa test"
        run_step(run_log, zones, ingest!, dataset, read_landing(zones))
        run_step(run_log, zones, clean!, dataset)
        run_step(run_log, zones, score!, dataset)
        run_step(run_log, zones, peek!, dataset, zones, seen)
        @test only(seen)["state"] == "running" && only(seen)["steps"][end]["state"] == "running"
        write_run(run_log, zones, dataset)
        steps = read_steps(zones)
        dataset_prefix = "$(zones.pipeline.prefix)/dataset"
        @test startswith(dataset_prefix, "pipeline/$(PIPELINE_DATASET_UID)/run-")
        @test steps["state"] == "done" && length(steps["steps"]) == 4
        @test [table["key"] for table in steps["tables"]] ==
              ["$(dataset_prefix)/$(field).arrow" for field in ("raw_amoa_df", "clean_df", "score_df")]
        @test [file["key"] for file in steps["files"]] == ["$(dataset_prefix)/data.json", "$(dataset_prefix)/data_info.json"]
        dataset_zone = MyJuliaToolbox._zone_folder(zones.pipeline, "dataset")
        @test sort(log_keys(steps)) == sort(minio_list_objects(dataset_zone))
        check_read_back(read_dataset(PipelineTestDataSet, dataset_zone), dataset)
        @test sort(minio_list_objects(zones.pipeline)) ==
              sort(vcat(log_keys(steps), ["$(zones.pipeline.prefix)/landing.json", "$(zones.pipeline.prefix)/steps.json"]))
    end

    @testset "a failing step on MinIO" begin
        zones = minio_zones()
        write_test_landing(zones)
        run_log, dataset = run_test_steps(zones)
        @test_throws ErrorException run_step(run_log, zones, fail!, dataset, "on\nMinIO")
        steps = read_steps(zones)
        @test steps["state"] == "failed" && steps["steps"][end]["error"] == "on MinIO"
    end
end

end
