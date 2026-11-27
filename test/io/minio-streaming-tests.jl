using Test
using MyJuliaToolbox
using MyJuliaToolbox.IO
using DataFrames
using Arrow

# ──────────────────────────────────────────────────────────────────────────────
# Offline tests of MinIO streaming, against FakeS3: an in-memory S3 backend that records every call and refuses, as
# S3 does, a multipart upload whose parts other than the last are under 5 MiB.
# ──────────────────────────────────────────────────────────────────────────────

const _MJT_IO = MyJuliaToolbox.IO
const _MIB = 1024 * 1024
const _TEST_PART_SIZE = 5 * _MIB

"""
    FakeS3()

An in-memory S3 bucket. `calls` lists `(operation, key)` in call order. Set `fail_on_part` to make that part number
fail, or `fail_on_key` to make every put or part upload of that key fail.
"""
mutable struct FakeS3 <: _MJT_IO._S3Backend
    objects::Dict{String, Vector{UInt8}}
    content_types::Dict{String, String}
    uploads::Dict{String, Dict{Int, Vector{UInt8}}}
    upload_keys::Dict{String, String}
    part_sizes::Dict{String, Vector{Int}}
    calls::Vector{Tuple{Symbol, String}}
    fail_on_part::Int
    fail_on_key::String
    upload_count::Int
end

FakeS3() = FakeS3(Dict{String, Vector{UInt8}}(), Dict{String, String}(), Dict{String, Dict{Int, Vector{UInt8}}}(),
                  Dict{String, String}(), Dict{String, Vector{Int}}(), Tuple{Symbol, String}[], 0, "", 0)

"""Throw the injected failure when `key` is the one set to fail."""
function _maybe_fail(store::FakeS3, key::String)
    !isempty(store.fail_on_key) && key == store.fail_on_key && error("injected failure on $key")
    return nothing
end

function _MJT_IO._backend_put(store::FakeS3, key::String, data::Vector{UInt8}, content_type::String)
    push!(store.calls, (:put, key))
    _maybe_fail(store, key)
    store.objects[key] = copy(data)
    store.content_types[key] = content_type
    return nothing
end

function _MJT_IO._backend_begin_upload(store::FakeS3, key::String, content_type::String)
    push!(store.calls, (:begin, key))
    store.upload_count += 1
    upload_id = "upload-$(store.upload_count)"
    store.uploads[upload_id] = Dict{Int, Vector{UInt8}}()
    store.upload_keys[upload_id] = key
    store.content_types[key] = content_type
    return upload_id
end

function _MJT_IO._backend_upload_part(store::FakeS3, key::String, upload_id::String, part_number::Int,
                                      data::Vector{UInt8})
    push!(store.calls, (:part, key))
    part_number == store.fail_on_part && error("injected failure on part $part_number")
    _maybe_fail(store, key)
    store.uploads[upload_id][part_number] = copy(data)
    return "etag-$part_number"
end

function _MJT_IO._backend_complete_upload(store::FakeS3, key::String, upload_id::String, etags::Vector{String})
    push!(store.calls, (:complete, key))
    parts = store.uploads[upload_id]
    part_numbers = sort!(collect(keys(parts)))
    part_numbers == collect(1:length(etags)) || error("parts $(part_numbers) do not match $(length(etags)) ETags")
    sizes = [length(parts[number]) for number in part_numbers]
    all(size -> size >= _TEST_PART_SIZE, sizes[1:end-1]) || error("EntityTooSmall: part sizes $(sizes)")
    store.objects[key] = reduce(vcat, (parts[number] for number in part_numbers))
    store.part_sizes[key] = sizes
    delete!(store.uploads, upload_id)
    return nothing
end

function _MJT_IO._backend_abort_upload(store::FakeS3, key::String, upload_id::String)
    push!(store.calls, (:abort, key))
    delete!(store.uploads, upload_id)
    return nothing
end

function _MJT_IO._backend_get_range(store::FakeS3, key::String, first_byte::Int, last_byte::Int)
    push!(store.calls, (:get, key))
    return store.objects[key][first_byte:last_byte]
end

function _MJT_IO._backend_object_size(store::FakeS3, key::String)
    push!(store.calls, (:head, key))
    haskey(store.objects, key) || error("NoSuchKey: $key")
    return length(store.objects[key])
end

_MJT_IO._backend_exists(store::FakeS3, key::String) = haskey(store.objects, key)

function _MJT_IO._backend_list(store::FakeS3, prefix::String; recursive::Bool)
    push!(store.calls, (:list, prefix))
    matching = filter(key -> startswith(key, prefix), collect(keys(store.objects)))
    recursive || filter!(key -> !occursin('/', key[length(prefix)+1:end]), matching)
    return sort!(matching)
end

function _MJT_IO._backend_delete(store::FakeS3, key::String)
    push!(store.calls, (:delete, key))
    delete!(store.objects, key)
    return nothing
end

"""A `MinIOMedia` over `store`, with 5 MiB parts."""
_fake_media(store::FakeS3; prefix::String = "runs/one", format::Symbol = :auto) =
    MinIOMedia("bucket"; access_key = "x", secret_key = "y", prefix = prefix, format = format,
               part_size = _TEST_PART_SIZE, backend = store)

"""Keys `store` was asked `operation` for, in call order."""
_keys_called(store::FakeS3, operation::Symbol) = [key for (called, key) in store.calls if called == operation]

"""Keys whose object was finished (put whole or upload completed), in order."""
_keys_finished(store::FakeS3) = [key for (called, key) in store.calls if called in (:put, :complete)]

"""A table of about 12 MiB as an Arrow file: three parts of 5 MiB."""
_large_table() = DataFrame(id = collect(1:800_000), value = sin.(1:800_000))

"""The bytes `write_dataframe(path, df)` writes into a local file named `filename` (the reference)."""
function _local_file_bytes(filename::String, df::DataFrame; kwargs...)
    return mktempdir() do folder
        path = joinpath(folder, filename)
        write_dataframe(path, df; kwargs...)
        read(path)
    end
end

struct StreamingTestParams <: iParameters
    alpha::Float64
    label::String
end

struct StreamingTestDataSet <: iDataSet
    prices::DataFrame
    volumes::DataFrame
    empty_table::DataFrame
    tag::String
    config::StreamingTestParams
    nested::Dict{String, Any}
end

"""A dataset with two tables (one multipart), an empty table, a parameters field and a nested parameters value."""
function _streaming_dataset(; prices::DataFrame = _large_table())
    return StreamingTestDataSet(prices, DataFrame(volume = [10, 20, 30]), DataFrame(), "v1",
                                StreamingTestParams(0.5, "base"),
                                Dict{String, Any}("inner" => StreamingTestParams(0.25, "inner")))
end

"""Every file under `folder`, as `relative/path => bytes`, with `/` separators."""
function _folder_files(folder::String)
    files = Dict{String, Vector{UInt8}}()
    for (root, _, names) in walkdir(folder), name in names
        path = joinpath(root, name)
        files[replace(relpath(path, folder), '\\' => '/')] = read(path)
    end
    return files
end

"""The objects of `store` under `prefix/`, as `relative key => bytes`."""
function _objects_under(store::FakeS3, prefix::String)
    return Dict(key[length(prefix)+2:end] => bytes for (key, bytes) in store.objects if startswith(key, prefix * "/"))
end

@testset "MinIO streaming (offline, FakeS3)" begin

    @testset "a large Arrow table goes as a multipart upload, byte-identical to the local file" begin
        store = FakeS3()
        media = _fake_media(store)
        table = _large_table()
        write_dataframe(media, "prices.arrow", table)
        key = "runs/one/prices.arrow"
        expected = _local_file_bytes("prices.arrow", table)
        @test store.objects[key] == expected
        @test length(expected) > 2 * _TEST_PART_SIZE
        @test store.part_sizes[key] == [_TEST_PART_SIZE, _TEST_PART_SIZE, length(expected) - 2 * _TEST_PART_SIZE]
        @test _keys_called(store, :begin) == [key]
        @test isempty(_keys_called(store, :put))
        @test store.content_types[key] == "application/vnd.apache.arrow.file"
        @test isempty(store.uploads)

        empty!(store.calls)
        @test read_dataframe(media, "prices.arrow") == table
        @test _keys_called(store, :head) == [key]
        @test length(_keys_called(store, :get)) == cld(length(expected), _TEST_PART_SIZE)
    end

    @testset "a large CSV table streams too, byte-identical to the local file" begin
        store = FakeS3()
        table = _large_table()
        write_dataframe(_fake_media(store), "prices.csv", table)
        @test store.objects["runs/one/prices.csv"] == _local_file_bytes("prices.csv", table)
        @test length(store.part_sizes["runs/one/prices.csv"]) >= 2
    end

    @testset "small objects are put in one request" begin
        store = FakeS3()
        media = _fake_media(store)
        table = DataFrame(a = [1, 2], b = ["x", "y"])
        for name in ("small.arrow", "small.csv", "small.csv.gz", "small.tsv")
            write_dataframe(media, name, table)
            @test store.objects["runs/one/$name"] == _local_file_bytes(name, table)
        end
        @test isempty(_keys_called(store, :begin))
        @test read_dataframe(media, "small.csv.gz") == table
        write_dataframe(media, "small.xlsx", table)
        @test nrow(read_dataframe(media, "small.xlsx")) == 2
    end

    @testset "the writer: one PUT up to one buffer, parts beyond, position and peak memory" begin
        store = FakeS3()
        writer = _MJT_IO._with_multipart_writer(store, "exact"; content_type = "application/octet-stream",
                                                part_size = _TEST_PART_SIZE) do io
            write(io, zeros(UInt8, _TEST_PART_SIZE))
            @test position(io) == _TEST_PART_SIZE
        end
        @test _keys_called(store, :put) == ["exact"]
        @test isempty(_keys_called(store, :begin))
        @test writer.bytes_written == _TEST_PART_SIZE

        payload = rand(UInt8, 3 * _TEST_PART_SIZE + 17)
        writer = _MJT_IO._with_multipart_writer(store, "large"; content_type = "application/octet-stream",
                                                part_size = _TEST_PART_SIZE) do io
            for start in 1:1_000_003:length(payload)   # uneven writes that straddle part boundaries
                write(io, view(payload, start:min(start + 1_000_002, length(payload))))
            end
            write(io, UInt8(0x2a))
            @test position(io) == length(payload) + 1
        end
        @test store.objects["large"] == vcat(payload, UInt8(0x2a))
        @test store.part_sizes["large"] == [_TEST_PART_SIZE, _TEST_PART_SIZE, _TEST_PART_SIZE, 18]
        @test writer.bytes_written == length(payload) + 1
        @test writer.peak_buffered_bytes <= 2 * _TEST_PART_SIZE
        @test !isopen(writer)
    end

    @testset "the part size doubles every 1,000 parts and stays under 5 GiB" begin
        @test _MJT_IO._part_size(_TEST_PART_SIZE, 1) == _TEST_PART_SIZE
        @test _MJT_IO._part_size(_TEST_PART_SIZE, 1000) == _TEST_PART_SIZE
        @test _MJT_IO._part_size(_TEST_PART_SIZE, 1001) == 2 * _TEST_PART_SIZE
        @test _MJT_IO._part_size(64 * _MIB, 9_999) == 5 * 1024^3
        @test_throws ArgumentError MinIOMedia("bucket"; access_key = "x", secret_key = "y", part_size = _MIB)
    end

    @testset "an exception mid-write aborts the upload and is rethrown" begin
        store = FakeS3()
        @test_throws ErrorException("stop here") _MJT_IO._with_multipart_writer(
                store, "broken"; content_type = "application/octet-stream", part_size = _TEST_PART_SIZE) do io
            write(io, zeros(UInt8, 2 * _TEST_PART_SIZE + 10))
            error("stop here")
        end
        @test _keys_called(store, :abort) == ["broken"]
        @test !haskey(store.objects, "broken")
        @test isempty(store.uploads)

        store = FakeS3()
        store.fail_on_part = 2
        @test_throws ErrorException("injected failure on part 2") write_dataframe(_fake_media(store), "prices.arrow",
                                                                                  _large_table())
        @test _keys_called(store, :abort) == ["runs/one/prices.arrow"]
        @test isempty(store.objects)

        store = FakeS3()   # an exception before any part: nothing was begun, nothing to abort
        @test_throws ArgumentError write_dataframe(_fake_media(store), "prices.parquet", _large_table())
        @test isempty(_keys_called(store, :begin)) && isempty(store.objects)
    end

    @testset "each part, and each object, is logged" begin
        store = FakeS3()
        logger = Test.TestLogger(min_level = Base.CoreLogging.Info)
        Base.CoreLogging.with_logger(logger) do
            write_dataframe(_fake_media(store), "prices.arrow", _large_table())
            read_dataframe(_fake_media(store), "prices.arrow")
        end
        parts = filter(record -> record.message == "MinIO part uploaded", logger.logs)
        @test length(parts) == 3
        @test all(record -> issubset((:key, :part, :bytes, :total_bytes, :seconds, :mib_s), keys(record.kwargs)),
                  parts)
        @test [record.kwargs[:part] for record in parts] == [1, 2, 3]
        written = only(filter(record -> record.message == "MinIO object written", logger.logs))
        @test written.kwargs[:parts] == 3
        @test written.kwargs[:bytes] == length(store.objects["runs/one/prices.arrow"])
        @test length(filter(record -> record.message == "MinIO range downloaded", logger.logs)) == 3
        @test only(filter(record -> record.message == "MinIO object read", logger.logs)).kwargs[:parts] == 3
    end

    @testset "write_dataset: a folder's layout and bytes, JSON last, data_info.json the very last" begin
        store = FakeS3()
        dataset = _streaming_dataset()
        write_dataset(_fake_media(store), dataset)
        reference = mktempdir() do folder
            write_dataset(FileSystemMedia(folder), dataset)
            _folder_files(folder)
        end
        @test _objects_under(store, "runs/one") == reference
        @test sort!(collect(keys(reference))) == ["data.json", "data_info.json", "parameters/config.json",
                                                   "parameters/params_1.json", "prices.arrow", "volumes.arrow"]
        finished = _keys_finished(store)
        @test finished[1:2] == ["runs/one/prices.arrow", "runs/one/volumes.arrow"]
        @test Set(finished[3:4]) == Set(["runs/one/parameters/config.json", "runs/one/parameters/params_1.json"])
        @test finished[5:6] == ["runs/one/data.json", "runs/one/data_info.json"]
        @test length(_keys_called(store, :list)) == 1     # one LIST up front, no HEAD per object
        @test isempty(_keys_called(store, :head))
        @test isempty(_keys_called(store, :put) ∩ ["runs/one/prices.arrow"])   # the large table went in parts
    end

    @testset "write_dataset refuses existing keys before writing anything" begin
        store = FakeS3()
        media = _fake_media(store)
        dataset = _streaming_dataset(prices = DataFrame(close = [1.0, 2.0]))
        write_dataset(media, dataset)
        empty!(store.calls)
        @test_throws ArgumentError write_dataset(media, dataset)
        @test isempty(_keys_finished(store)) && isempty(_keys_called(store, :begin))
        write_dataset(media, dataset; overwrite = true)
        @test length(_keys_finished(store)) == 6
    end

    @testset "a failed atomic overwrite leaves no dataset, and nested prefixes alone" begin
        store = FakeS3()
        media = _fake_media(store)
        write_dataset(media, _streaming_dataset(prices = DataFrame(close = [1.0, 2.0])))
        store.objects["runs/one/run1/data.json"] = UInt8[0x7b, 0x7d]          # a nested run
        store.objects["runs/one/logs/2026-11-27/1.jsonl"] = UInt8[0x0a]       # its logs
        store.fail_on_key = "runs/one/volumes.arrow"                          # after prices.arrow is replaced
        @test_throws ErrorException write_dataset(media, _streaming_dataset(); overwrite = true)
        @test sort!(collect(keys(store.objects))) == ["runs/one/logs/2026-11-27/1.jsonl", "runs/one/run1/data.json"]
        @test isempty(store.uploads)

        store = FakeS3()   # a failed first write deletes what it wrote, and nothing else
        store.objects["runs/one/notes.txt"] = UInt8[0x31]
        store.fail_on_key = "runs/one/data.json"
        @test_throws ErrorException write_dataset(_fake_media(store), _streaming_dataset(prices = DataFrame(close = [1.0])))
        @test collect(keys(store.objects)) == ["runs/one/notes.txt"]

        store = FakeS3()   # atomic=false leaves what was written
        store.fail_on_key = "runs/one/data.json"
        @test_throws ErrorException write_dataset(_fake_media(store), _streaming_dataset(prices = DataFrame(close = [1.0]));
                                                  atomic = false)
        @test haskey(store.objects, "runs/one/prices.arrow")
    end

    @testset "read_dataset fetches the root tables, JSON and parameters only" begin
        store = FakeS3()
        media = _fake_media(store)
        dataset = _streaming_dataset()
        write_dataset(media, dataset)
        write_dataset(_fake_media(store; prefix = "runs/one/run1"), _streaming_dataset(prices = DataFrame(close = [9.0])))
        store.objects["runs/one/logs/2026-11-27/1.jsonl"] = UInt8[0x0a]
        empty!(store.calls)

        typed = read_dataset(StreamingTestDataSet, media)
        @test typed.prices == dataset.prices
        @test typed.volumes == dataset.volumes
        @test typed.empty_table == DataFrame()
        @test typed.tag == "v1"
        @test typed.config == dataset.config
        @test typed.nested["inner"] == StreamingTestParams(0.25, "inner")
        fetched = vcat(_keys_called(store, :head), _keys_called(store, :get))
        @test !any(key -> occursin("run1/", key) || occursin("logs/", key), fetched)

        untyped = read_dataset(media)
        @test untyped isa StreamingTestDataSet
        @test untyped.config == dataset.config
        loaded = MyJuliaToolbox._read_dataset_impl(media)
        @test loaded isa LoadedDataSet
        @test loaded.attributes[:volumes] == dataset.volumes

        @test_throws ArgumentError read_dataset(_fake_media(store; prefix = "nothing/here"))
    end

    @testset "no temporary file or folder is created" begin
        store = FakeS3()
        media = _fake_media(store)
        scratch = mktempdir()
        withenv("TMP" => scratch, "TEMP" => scratch, "TMPDIR" => scratch) do
            @test tempdir() == scratch || rstrip(tempdir(), ['\\', '/']) == rstrip(scratch, ['\\', '/'])
            write_dataframe(media, "prices.arrow", _large_table())
            read_dataframe(media, "prices.arrow")
            write_dataframe(media, "prices.csv.gz", DataFrame(a = [1, 2]))
            read_dataframe(media, "prices.csv.gz")
            write_dataset(_fake_media(store; prefix = "datasets/one"), _streaming_dataset())
            read_dataset(StreamingTestDataSet, _fake_media(store; prefix = "datasets/one"))
        end
        @test isempty(readdir(scratch))
        rm(scratch; recursive = true, force = true)
    end

    @testset "stop_logger! uploads the buffered records" begin
        store = FakeS3()
        media = _fake_media(store; prefix = "runs/logs")
        logger = AsyncLogger(media; min_level = :info)
        @test log_info!(logger, "first record")
        @test log_warn!(logger, "second record")
        stop_logger!(logger)
        log_keys = filter(key -> startswith(key, "runs/logs/logs/"), collect(keys(store.objects)))
        @test length(log_keys) == 1
        content = String(store.objects[only(log_keys)])
        @test occursin("first record", content) && occursin("second record", content)
        @test store.content_types[only(log_keys)] == "application/x-ndjson"
        minio_flush_log_buffer!(media)   # nothing left to upload
        @test length(filter(key -> startswith(key, "runs/logs/logs/"), collect(keys(store.objects)))) == 1
    end
end
