using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using DataFrames
using Dates
using Arrow

# ──────────────────────────────────────────────────────────────────────────────
# Availability check
#
# MinIO tests require:
#   1. AWSS3.jl + AWS.jl installed in the active project
#   2. A reachable MinIO server (configured via env vars or defaults below)
#
# If either condition is not met the entire @testset is skipped with a notice.
#
# Override defaults with environment variables:
#   MINIO_TEST_ENDPOINT   (default: http://localhost:9000)
#   MINIO_TEST_ACCESS_KEY (default: minioadmin)
#   MINIO_TEST_SECRET_KEY (default: minioadmin)
#   MINIO_TEST_BUCKET     (default: minio-test-toolbox)
# ──────────────────────────────────────────────────────────────────────────────

const _MINIO_ENDPOINT   = get(ENV, "MINIO_TEST_ENDPOINT",   "http://localhost:9000")
const _MINIO_ACCESS_KEY = get(ENV, "MINIO_TEST_ACCESS_KEY", "minioadmin")
const _MINIO_SECRET_KEY = get(ENV, "MINIO_TEST_SECRET_KEY", "minioadmin")
const _MINIO_BUCKET     = get(ENV, "MINIO_TEST_BUCKET",     "minio-test-toolbox")

# Try to load AWSS3 / AWS; mark unavailable if not installed
const _AWSS3_LOADABLE = try
    Base.require(Main, :AWSS3)
    Base.require(Main, :AWS)
    true
catch
    false
end

# Try an actual connection to the server
const _MINIO_SERVER_UP = _AWSS3_LOADABLE && begin
    try
        probe = MinIOMedia(_MINIO_BUCKET;
                    endpoint   = _MINIO_ENDPOINT,
                    access_key = _MINIO_ACCESS_KEY,
                    secret_key = _MINIO_SECRET_KEY)
        minio_create_bucket!(probe)
        true
    catch
        false
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Shared test fixtures
# ──────────────────────────────────────────────────────────────────────────────

struct MinIOTestParams <: iParameters
    alpha::Float64
    iterations::Int
    label::String
end

struct MinIOTestDataSet <: iDataSet
    prices::DataFrame
    volumes::DataFrame
    tag::String
    config::MinIOTestParams
end

# Helper — build a fresh MinIOMedia pointed at a unique test prefix
function _test_media(prefix::String; format::Symbol = :auto)
    return MinIOMedia(_MINIO_BUCKET;
                endpoint   = _MINIO_ENDPOINT,
                access_key = _MINIO_ACCESS_KEY,
                secret_key = _MINIO_SECRET_KEY,
                prefix     = prefix,
                format     = format)
end

# Helper — delete every object under prefix (best-effort cleanup)
function _cleanup(prefix::String)
    try
        m = _test_media(prefix)
        for key in minio_list_objects(m)
            try MyJuliaToolbox.IO._s3_delete(m, key) catch; end
        end
    catch
    end
end

# Unique prefix per test run to avoid inter-run collisions
const _RUN_ID = string(round(Int, datetime2unix(now())), base=16)

# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

"""The bytes `write_dataframe(path, df)` writes into a local file named `filename`."""
function _file_bytes(filename::String, df::DataFrame; kwargs...)
    return mktempdir() do folder
        path = joinpath(folder, filename)
        write_dataframe(path, df; kwargs...)
        read(path)
    end
end

"""Whether `bytes` are an Arrow file (the magic `ARROW1` at both ends), not an Arrow stream."""
_is_arrow_file(bytes::Vector{UInt8}) =
    length(bytes) > 12 && String(bytes[1:6]) == "ARROW1" && String(bytes[end-5:end]) == "ARROW1"

# No server needed: an object holds what a local file of its name holds.
@testset "MinIO objects hold what a file holds (offline)" begin
    table = DataFrame(date=[20250101, 20250102], close=[100.1, 101.5], name=["a", "b"])

    @testset "an Arrow object is an Arrow file, byte for byte" begin
        written = MyJuliaToolbox.IO._dataframe_bytes("prices.arrow", table; format=:auto)
        @test _is_arrow_file(written)
        @test written == _file_bytes("prices.arrow", table)
        @test MyJuliaToolbox.IO._dataframe_from_bytes("prices.arrow", written; format=:auto) == table
    end

    @testset "the format keyword gives the format of a name without a known extension, as for a file" begin
        written = MyJuliaToolbox.IO._dataframe_bytes("prices.bin", table; format=:arrow)
        @test _is_arrow_file(written)
        @test MyJuliaToolbox.IO._dataframe_from_bytes("prices.bin", written; format=:arrow) == table
        # a `.csv` name is written as CSV whatever the format says, by the file functions as by MinIO
        @test MyJuliaToolbox.IO._dataframe_bytes("prices.csv", table; format=:arrow) ==
              _file_bytes("prices.csv", table; format=:arrow)
    end

    @testset "gzipped CSV and Excel, as a file has them; TSV as the file functions write it" begin
        for name in ("prices.csv.gz", "prices.xlsx")
            written = MyJuliaToolbox.IO._dataframe_bytes(name, table; format=:auto)
            @test written == _file_bytes(name, table) || name == "prices.xlsx"  # an xlsx archive holds its time
            read_back = MyJuliaToolbox.IO._dataframe_from_bytes(name, written; format=:auto)
            @test nrow(read_back) == 2
            @test string.(read_back.name) == ["a", "b"]
        end
        @test MyJuliaToolbox.IO._dataframe_bytes("prices.csv.gz", table; format=:auto)[1:2] == UInt8[0x1f, 0x8b]
        @test MyJuliaToolbox.IO._dataframe_bytes("prices.tsv", table; format=:auto) == _file_bytes("prices.tsv", table)
    end

    @testset "an Arrow stream written before is still read" begin
        stream = IOBuffer()
        Arrow.write(stream, table)
        @test MyJuliaToolbox.IO._dataframe_from_bytes("prices.arrow", take!(stream); format=:auto) == table
    end

    @testset "an unknown extension is refused as for a file" begin
        @test_throws ArgumentError MyJuliaToolbox.IO._dataframe_bytes("prices.parquet", table; format=:auto)
    end

    @testset "content types and object names" begin
        @test MyJuliaToolbox.IO._minio_content_type("dataset/prices.arrow") == "application/vnd.apache.arrow.file"
        @test MyJuliaToolbox.IO._minio_content_type("x.csv.gz") == "application/gzip"
        @test MyJuliaToolbox.IO._minio_content_type("data.json") == "application/json"
        @test MyJuliaToolbox.IO._minio_content_type("x.tsv") == "text/tab-separated-values"
        @test MyJuliaToolbox.IO._minio_object_name("a/b/prices.arrow") == "prices.arrow"
        @test MyJuliaToolbox.IO._minio_object_name("prices.arrow") == "prices.arrow"
    end

    if _AWSS3_LOADABLE
        @testset "the object a call names" begin
            named = MinIOMedia("bucket"; endpoint="http://localhost:9000", access_key="x", secret_key="y",
                               prefix="runs/one")
            @test MyJuliaToolbox.IO._minio_object_key(named, "prices.arrow") == "runs/one/prices.arrow"
            @test MyJuliaToolbox.IO._minio_object_key(named, nothing) == "runs/one"
            bare = MinIOMedia("bucket"; endpoint="http://localhost:9000", access_key="x", secret_key="y")
            @test_throws ArgumentError MyJuliaToolbox.IO._minio_object_key(bare, nothing)
        end
    end
end

if !_MINIO_SERVER_UP
    @warn "MinIO tests skipped: server not reachable at $_MINIO_ENDPOINT " *
          "(start with: docker compose -f docker-compose.minio.yml up -d)"
else

@testset "MinIO tests" begin

    prices_df  = DataFrame(date=[20250101,20250102,20250103], close=[100.1,101.5,99.8])
    volumes_df = DataFrame(date=[20250101,20250102,20250103], vol=[1000,1200,900])
    test_params = MinIOTestParams(0.01, 100, "baseline")
    test_ds = MinIOTestDataSet(prices_df, volumes_df, "run-1", test_params)

    # ── DataFrame I/O ──────────────────────────────────────────────────────────

    @testset "read_dataframe / write_dataframe — Arrow" begin
        prefix = "tests/$_RUN_ID/df_arrow"
        media  = _test_media(prefix; format=:arrow)
        try
            write_dataframe(media, "prices.arrow", prices_df)

            result = read_dataframe(media, "prices.arrow")
            @test result isa DataFrame
            @test nrow(result) == 3
            @test result.close ≈ prices_df.close
        finally
            _cleanup(prefix)
        end
    end

    @testset "read_dataframe / write_dataframe — CSV" begin
        prefix = "tests/$_RUN_ID/df_csv"
        media  = _test_media(prefix; format=:csv)
        try
            write_dataframe(media, "volumes.csv", volumes_df)

            result = read_dataframe(media, "volumes.csv")
            @test result isa DataFrame
            @test nrow(result) == 3
            @test result.vol == volumes_df.vol
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_dataframe overwrite guard" begin
        prefix = "tests/$_RUN_ID/df_overwrite"
        media  = _test_media(prefix)
        try
            write_dataframe(media, "prices.arrow", prices_df)
            @test_throws ArgumentError write_dataframe(media, "prices.arrow", prices_df)
            write_dataframe(media, "prices.arrow", prices_df; overwrite=true)  # must not throw
        finally
            _cleanup(prefix)
        end
    end

    @testset "format inferred from extension" begin
        prefix = "tests/$_RUN_ID/df_format"
        media  = _test_media(prefix)  # :auto
        try
            write_dataframe(media, "data.arrow", prices_df)
            write_dataframe(media, "data.csv",   prices_df)

            arrow_result = read_dataframe(media, "data.arrow")
            csv_result   = read_dataframe(media, "data.csv")
            @test nrow(arrow_result) == 3
            @test nrow(csv_result)   == 3
        finally
            _cleanup(prefix)
        end
    end

    @testset "an Arrow object is an Arrow file, as a FileSystemMedia writes it" begin
        prefix = "tests/$_RUN_ID/df_arrow_file"
        media  = _test_media(prefix)
        try
            write_dataframe(media, "prices.arrow", prices_df)
            written = MyJuliaToolbox.IO._s3_get_bytes(media, "$prefix/prices.arrow")
            @test _is_arrow_file(written)
            @test written == _file_bytes("prices.arrow", prices_df)
        finally
            _cleanup(prefix)
        end
    end

    @testset "gzipped CSV and Excel objects" begin
        prefix = "tests/$_RUN_ID/df_formats"
        media  = _test_media(prefix)
        try
            for name in ("volumes.csv.gz", "volumes.xlsx")
                write_dataframe(media, name, volumes_df)
                result = read_dataframe(media, name)
                @test nrow(result) == 3
                @test result.vol == volumes_df.vol
            end
        finally
            _cleanup(prefix)
        end
    end

    @testset "filename as a keyword, and the prefix as the object" begin
        prefix = "tests/$_RUN_ID/df_keyword"
        media  = _test_media(prefix)
        single = _test_media("$prefix/single.csv")
        try
            write_dataframe(media, prices_df; filename="prices.arrow", atomic=true)
            @test read_dataframe(media; filename="prices.arrow").close ≈ prices_df.close
            write_dataframe(single, volumes_df)
            @test read_dataframe(single).vol == volumes_df.vol
            @test_throws ArgumentError write_dataframe(single, volumes_df)
        finally
            _cleanup(prefix)
        end
    end

    @testset "the format keyword wins over the media's format" begin
        prefix = "tests/$_RUN_ID/df_format_keyword"
        media  = _test_media(prefix; format=:csv)
        try
            write_dataframe(media, "prices.arrow", prices_df; format=:arrow)
            @test _is_arrow_file(MyJuliaToolbox.IO._s3_get_bytes(media, "$prefix/prices.arrow"))
            @test read_dataframe(media, "prices.arrow"; format=:arrow).close ≈ prices_df.close
        finally
            _cleanup(prefix)
        end
    end

    @testset "_s3_delete removes an object" begin
        prefix = "tests/$_RUN_ID/df_delete"
        media  = _test_media(prefix)
        try
            write_dataframe(media, "prices.arrow", prices_df)
            MyJuliaToolbox.IO._s3_delete(media, "$prefix/prices.arrow")
            @test isempty(minio_list_objects(media))
        finally
            _cleanup(prefix)
        end
    end

    # ── Dataset I/O ────────────────────────────────────────────────────────────

    @testset "write_dataset — its tables are Arrow files" begin
        prefix = "tests/$_RUN_ID/ds_arrow_files"
        media  = _test_media(prefix)
        try
            write_dataset(media, test_ds)
            @test _is_arrow_file(MyJuliaToolbox.IO._s3_get_bytes(media, "$prefix/prices.arrow"))
            @test _is_arrow_file(MyJuliaToolbox.IO._s3_get_bytes(media, "$prefix/volumes.arrow"))
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_dataset / read_dataset — typed" begin
        prefix = "tests/$_RUN_ID/ds_typed"
        media  = _test_media(prefix)
        try
            write_dataset(media, test_ds)

            result = read_dataset(MinIOTestDataSet, media)
            @test result isa MinIOTestDataSet
            @test nrow(result.prices)  == 3
            @test nrow(result.volumes) == 3
            @test result.tag == "run-1"
            @test result.config isa MinIOTestParams
            @test result.config.alpha      == 0.01
            @test result.config.iterations == 100
            @test result.config.label      == "baseline"
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_dataset / read_dataset — untyped (auto-resolve from data_info.json)" begin
        prefix = "tests/$_RUN_ID/ds_untyped"
        media  = _test_media(prefix)
        try
            write_dataset(media, test_ds)

            result = read_dataset(media)
            @test result isa MinIOTestDataSet   # auto-resolved from data_info.json
            @test result.tag == "run-1"
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_dataset overwrite guard" begin
        prefix = "tests/$_RUN_ID/ds_overwrite"
        media  = _test_media(prefix)
        try
            write_dataset(media, test_ds)
            @test_throws ArgumentError write_dataset(media, test_ds)
            write_dataset(media, test_ds; overwrite=true)   # must not throw
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_dataset / read_dataset — CSV format" begin
        prefix = "tests/$_RUN_ID/ds_csv"
        media  = _test_media(prefix)
        try
            write_dataset(media, test_ds; type=:csv)

            result = read_dataset(MinIOTestDataSet, media; type=:csv)
            @test nrow(result.prices)  == 3
            @test nrow(result.volumes) == 3
            @test result.tag == "run-1"
        finally
            _cleanup(prefix)
        end
    end

    # ── Parameters I/O ─────────────────────────────────────────────────────────

    @testset "write_parameters / read_parameters — round-trip" begin
        prefix = "tests/$_RUN_ID/params"
        media  = _test_media(prefix)
        try
            write_parameters(media, "config.json", test_params)

            result = read_parameters(MinIOTestParams, media, "config.json")
            @test result isa MinIOTestParams
            @test result.alpha      == test_params.alpha
            @test result.iterations == test_params.iterations
            @test result.label      == test_params.label
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_parameters / read_parameters — relative_path" begin
        prefix = "tests/$_RUN_ID/params_sub"
        media  = _test_media(prefix)
        try
            write_parameters(media, "config.json", test_params, "subdir")

            result = read_parameters(MinIOTestParams, media, "config.json", "subdir")
            @test result.label == "baseline"
        finally
            _cleanup(prefix)
        end
    end

    @testset "write_parameters overwrite guard" begin
        prefix = "tests/$_RUN_ID/params_overwrite"
        media  = _test_media(prefix)
        try
            write_parameters(media, "cfg.json", test_params)
            @test_throws ArgumentError write_parameters(media, "cfg.json", test_params)
            write_parameters(media, "cfg.json", test_params; overwrite=true)
        finally
            _cleanup(prefix)
        end
    end

    # ── Logger sink ────────────────────────────────────────────────────────────

    @testset "AsyncLogger — batched upload on flush" begin
        prefix = "tests/$_RUN_ID/logs_batch"
        media  = _test_media(prefix)
        try
            logger = AsyncLogger(media; min_level=:debug)
            @test log_debug!(logger, "debug msg")
            @test log_info!(logger,  "info msg";  metadata=(step="a",))
            @test log_warn!(logger,  "warn msg")
            @test log_error!(logger, "error msg")
            stop_logger!(logger)

            # nothing uploaded yet — records are buffered in memory
            @test isempty(minio_list_objects(media))

            # flush uploads one JSONL object
            minio_flush_log_buffer!(media)
            keys = minio_list_objects(media)
            @test length(keys) == 1
            @test endswith(keys[1], ".jsonl")

            # check content
            raw = String(MyJuliaToolbox.IO._s3_get_bytes(media, keys[1]))
            @test occursin("debug msg",  raw)
            @test occursin("info msg",   raw)
            @test occursin("warn msg",   raw)
            @test occursin("error msg",  raw)
        finally
            _cleanup(prefix)
        end
    end

    @testset "AsyncLogger — per-record upload (batch_logs=false)" begin
        prefix = "tests/$_RUN_ID/logs_per_record"
        media  = _test_media(prefix)
        try
            logger = AsyncLogger(media; min_level=:info, batch_logs=false)
            @test log_info!(logger, "record 1")
            @test log_info!(logger, "record 2")
            stop_logger!(logger)

            # each record is a separate object
            keys = minio_list_objects(media)
            @test length(keys) == 2
        finally
            _cleanup(prefix)
        end
    end

    # ── Bucket / object management ─────────────────────────────────────────────

    @testset "minio_create_bucket! — idempotent" begin
        media = _test_media("tests/$_RUN_ID/bucket_check")
        # Should not throw even if the bucket already exists
        @test (minio_create_bucket!(media); true)
    end

    @testset "minio_list_objects — prefix scoping" begin
        prefix = "tests/$_RUN_ID/list"
        media  = _test_media(prefix)
        try
            write_dataframe(media, "a.arrow", prices_df)
            write_dataframe(media, "b.arrow", prices_df)
            write_dataframe(media, "c.csv",   prices_df)

            keys = minio_list_objects(media)
            @test length(keys) == 3
            @test any(k -> endswith(k, "a.arrow"), keys)
            @test any(k -> endswith(k, "b.arrow"), keys)
            @test any(k -> endswith(k, "c.csv"),   keys)
        finally
            _cleanup(prefix)
        end
    end

    # ── Constructor guards ─────────────────────────────────────────────────────

    @testset "MinIOMedia constructor — credential validation" begin
        @test_throws ArgumentError MinIOMedia("bucket"; endpoint=_MINIO_ENDPOINT,
                                               access_key="", secret_key="x")
        @test_throws ArgumentError MinIOMedia("bucket"; endpoint=_MINIO_ENDPOINT,
                                               access_key="x", secret_key="")
        @test_throws ArgumentError MinIOMedia("bucket"; endpoint=_MINIO_ENDPOINT,
                                               access_key="x", secret_key="y",
                                               format=:parquet)
    end

    @testset "MinIOMedia constructor — prefix normalisation" begin
        m = MinIOMedia(_MINIO_BUCKET; endpoint=_MINIO_ENDPOINT,
                       access_key=_MINIO_ACCESS_KEY, secret_key=_MINIO_SECRET_KEY,
                       prefix="/foo/bar/")
        @test m.prefix == "foo/bar"   # leading and trailing slashes stripped
    end

end # @testset "MinIO tests"

end # if _MINIO_SERVER_UP
