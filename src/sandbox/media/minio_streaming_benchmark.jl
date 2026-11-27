# Benchmark of one MinIO operation on a large table: wall time, peak memory and peak temporary disk.
#
# Run each operation in its own Julia process, so its peak memory is its own:
#
#   julia --project=. src/sandbox/media/minio_streaming_benchmark.jl write_dataframe bench/run1 17000000
#   julia --project=. src/sandbox/media/minio_streaming_benchmark.jl read_dataframe  bench/run1 17000000
#   julia --project=. src/sandbox/media/minio_streaming_benchmark.jl write_dataset   bench/run1 17000000
#   julia --project=. src/sandbox/media/minio_streaming_benchmark.jl read_dataset    bench/run1 17000000
#
# 17,000,000 rows of 8 eight-byte columns make a table of about 1 GiB. The writes must come before the reads. Needs
# a MinIO server (docker compose -f docker-compose.minio.yml up -d); the bucket is created if absent. Set
# MINIO_BENCH_BUCKET (default "minio-bench"), MINIO_BENCH_ENDPOINT, MINIO_BENCH_ACCESS_KEY, MINIO_BENCH_SECRET_KEY.
#
# Memory is measured two ways, after the table is built and the code compiled on a small table: the growth of the
# process's maximum resident set over the operation (it misses what fits under an earlier peak, such as building the
# table), and the peak growth of the live Julia heap, sampled every 20 ms (it misses memory-mapped files). Peak
# temporary disk is the most bytes seen under the temporary folder, which the script points at an empty folder of its
# own. An operation that throws is still measured, and its error printed in the last column.

using DataFrames
using Dates
using MyJuliaToolbox
using Random

"""The dataset `write_dataset` and `read_dataset` are measured on: the large table and a small one."""
struct BenchmarkDataSet <: iDataSet
    table::DataFrame
    small::DataFrame
    tag::String
end

"""A table of `row_count` rows: an `Int64` id and seven `Float64` columns (64 bytes a row)."""
function benchmark_table(row_count::Int)
    generator = Random.Xoshiro(20261127)
    table = DataFrame(id = collect(1:row_count))
    for column_name in ("a", "b", "c", "d", "e", "f", "g")
        table[!, column_name] = rand(generator, row_count)
    end
    return table
end

"""The media the benchmark writes to and reads from, under `prefix`."""
function benchmark_media(prefix::String)
    return MinIOMedia(get(ENV, "MINIO_BENCH_BUCKET", "minio-bench");
                      endpoint   = get(ENV, "MINIO_BENCH_ENDPOINT", "http://localhost:9000"),
                      access_key = get(ENV, "MINIO_BENCH_ACCESS_KEY", "minioadmin"),
                      secret_key = get(ENV, "MINIO_BENCH_SECRET_KEY", "minioadmin"),
                      prefix     = prefix)
end

"""Total bytes of the files under `folder` (0 when it cannot be listed, as while a file is being removed)."""
function folder_bytes(folder::String)
    total = 0
    try
        for (root, _, names) in walkdir(folder), name in names
            total += filesize(joinpath(root, name))
        end
    catch
    end
    return total
end

"""
    sample_peaks(operation, folder) -> (disk_peak, heap_peak, failure)

Run `operation()` while a task samples, every 20 ms, the bytes under `folder` and the live Julia heap; returns the
most of each seen (the heap as growth over its size at the start), and the error `operation` threw (`nothing` if
none): a failed operation still has its peaks measured.
"""
function sample_peaks(operation::Function, folder::String)
    heap_at_start = Base.gc_live_bytes()
    disk_peak = Ref(0)
    heap_peak = Ref(0)
    running = Ref(true)
    poller = Threads.@spawn while running[]
        disk_peak[] = max(disk_peak[], folder_bytes(folder))
        heap_peak[] = max(heap_peak[], Base.gc_live_bytes() - heap_at_start)
        sleep(0.02)
    end
    failure = nothing
    try
        operation()
    catch error
        failure = error
    finally
        running[] = false
        wait(poller)
    end
    return (max(disk_peak[], folder_bytes(folder)), heap_peak[], failure)
end

"""The operation `name` on `media`, given the table (for writes) or nothing (for reads); returns the rows."""
function run_operation(name::String, media::MinIOMedia, table::Union{DataFrame, Nothing})
    if name == "write_dataframe"
        write_dataframe(media, "table.arrow", table; overwrite = true)
    elseif name == "read_dataframe"
        return nrow(read_dataframe(media, "table.arrow"))
    elseif name == "write_dataset"
        write_dataset(media, BenchmarkDataSet(table, DataFrame(x = [1, 2, 3]), "bench"); overwrite = true)
    elseif name == "read_dataset"
        return nrow(read_dataset(BenchmarkDataSet, media).table)
    else
        throw(ArgumentError("unknown operation $name"))
    end
    return nrow(table)
end

"""
Compile the code paths of `name` on a small table, under a prefix of their own. A failure is reported on stderr, not
thrown, so the measured operation still runs (and has its own failure recorded).
"""
function warm_up(name::String, prefix::String)
    media = benchmark_media(prefix * "-warmup")
    small = benchmark_table(1_000)
    startswith(name, "write") || run_operation(replace(name, "read" => "write"), media, small)
    try
        run_operation(name, media, startswith(name, "write") ? small : nothing)
    catch warm_up_error
        println(stderr, "warm-up of $name failed: ", sprint(showerror, warm_up_error))
    end
    return nothing
end

"""A short label for how the operation ended: `ok`, or the error's type and the start of its message."""
function outcome_label(failure)
    isnothing(failure) && return "ok"
    message = first(replace(sprint(showerror, failure), r"\s+" => " "), 70)
    return "FAILED[$(nameof(typeof(failure))): $message]"
end

"""
Measure one operation; print one line:
`operation rows seconds maxrss_growth_mib heap_peak_mib temp_disk_peak_mib table_mib outcome`.
"""
function main(arguments::Vector{String})
    name, prefix, row_count = arguments[1], arguments[2], parse(Int, arguments[3])
    temporary_folder = mktempdir()
    Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(stderr, Base.CoreLogging.Warn)) do
        withenv("TMP" => temporary_folder, "TEMP" => temporary_folder, "TMPDIR" => temporary_folder) do
            minio_create_bucket!(benchmark_media(prefix))
            warm_up(name, prefix)
            table = startswith(name, "write") ? benchmark_table(row_count) : nothing
            GC.gc()
            memory_before = Sys.maxrss()
            started = time()
            rows = Ref(0)
            disk_peak, heap_peak, failure = sample_peaks(temporary_folder) do
                rows[] = run_operation(name, benchmark_media(prefix), table)
            end
            seconds = time() - started
            maxrss_growth = Sys.maxrss() - memory_before
            table_mib = isnothing(table) ? 0.0 : Base.summarysize(table) / 1024^2
            mib(bytes) = round(Int, bytes / 1024^2)
            println(join([name, rows[], round(seconds; digits = 1), mib(maxrss_growth), mib(heap_peak),
                          mib(disk_peak), round(Int, table_mib), outcome_label(failure)], " "))
        end
    end
    GC.gc()
    try
        rm(temporary_folder; recursive = true, force = true)
    catch
        # Windows keeps a memory-mapped file open until its mapping is collected; the OS cleans the folder later
    end
    return nothing
end

main(ARGS)
