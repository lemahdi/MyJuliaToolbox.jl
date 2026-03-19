# MinIO sandbox — end-to-end usage examples
#
# Prerequisites:
#   1. Start MinIO:
#        docker compose -f docker-compose.minio.yml up -d
#   2. Add AWSS3 + AWS to your project:
#        pkg> add AWSS3 AWS
#   3. Set credentials (or pass them directly — never hardcode in production):
#        ENV["MINIO_ACCESS_KEY"] = "minioadmin"
#        ENV["MINIO_SECRET_KEY"] = "minioadmin"

using AWSS3, AWS
using DataFrames
using MyJuliaToolbox

# ──────────────────────────────────────────────────────────────────────────────
# 1.  Connection
# ──────────────────────────────────────────────────────────────────────────────

media = MinIOMedia(
    "analytics";                          # bucket name
    endpoint   = "http://localhost:9000",
    access_key = ENV["MINIO_ACCESS_KEY"],
    secret_key = ENV["MINIO_SECRET_KEY"],
    prefix     = "sandbox",              # logical directory inside the bucket
    format     = :arrow,
)

# Create the bucket if it doesn't already exist
minio_create_bucket!(media)

# ──────────────────────────────────────────────────────────────────────────────
# 2.  DataFrame I/O
# ──────────────────────────────────────────────────────────────────────────────

prices = DataFrame(
    date  = [20250101, 20250102, 20250103],
    open  = [100.0, 101.5, 99.8],
    close = [101.0, 100.2, 102.3],
)

write_dataframe(media, "prices.arrow", prices; overwrite=true)

prices2 = read_dataframe(media, "prices.arrow")
@assert prices2 == prices

# CSV also works
write_dataframe(media, "prices.csv", prices; format=:csv, overwrite=true)
prices3 = read_dataframe(media, "prices.csv"; format=:csv)

println("DataFrame round-trip OK: $(nrow(prices3)) rows")

# ──────────────────────────────────────────────────────────────────────────────
# 3.  Dataset I/O
# ──────────────────────────────────────────────────────────────────────────────

# Define a simple dataset type for this example
struct SandboxDataSet <: iDataSet
    prices::DataFrame
    metadata::String
end

ds = SandboxDataSet(prices, "sandbox run 2025-01-01")

# Point at a dataset-specific prefix to keep files organised
ds_media = MinIOMedia(
    "analytics";
    endpoint   = "http://localhost:9000",
    access_key = ENV["MINIO_ACCESS_KEY"],
    secret_key = ENV["MINIO_SECRET_KEY"],
    prefix     = "sandbox/datasets/sandbox_ds",
)

write_dataset(ds_media, ds; overwrite=true)

# Untyped read (auto-resolves type from data_info.json)
ds2 = read_dataset(ds_media)
println("Untyped dataset read: $(typeof(ds2))")

# Typed read
ds3 = read_dataset(SandboxDataSet, ds_media)
@assert ds3.metadata == ds.metadata
println("Typed dataset round-trip OK")

# ──────────────────────────────────────────────────────────────────────────────
# 4.  Parameters I/O
# ──────────────────────────────────────────────────────────────────────────────

struct SandboxParameters <: iParameters
    alpha::Float64
    iterations::Int
    label::String
end

params = SandboxParameters(0.01, 500, "baseline")

write_parameters(media, "params.json", params; overwrite=true)

params2 = read_parameters(SandboxParameters, media, "params.json")
@assert params2 == params
println("Parameters round-trip OK")

# ──────────────────────────────────────────────────────────────────────────────
# 5.  Async logger → MinIO
# ──────────────────────────────────────────────────────────────────────────────

log_media = MinIOMedia(
    "analytics";
    endpoint   = "http://localhost:9000",
    access_key = ENV["MINIO_ACCESS_KEY"],
    secret_key = ENV["MINIO_SECRET_KEY"],
    prefix     = "sandbox/logs",
)

logger = AsyncLogger(log_media; min_level=:info)
log_info!(logger, "pipeline started"; metadata=(step="ingest", rows=nrow(prices)))
log_warn!(logger, "missing values detected"; metadata=(column="open", count=0))
stop_logger!(logger)

# Flush buffered log records to MinIO
minio_flush_log_buffer!(log_media)

keys = minio_list_objects(log_media)
println("Log objects uploaded: $(length(keys))")

# ──────────────────────────────────────────────────────────────────────────────
# 6.  List objects
# ──────────────────────────────────────────────────────────────────────────────

all_keys = minio_list_objects(MinIOMedia(
    "analytics";
    endpoint   = "http://localhost:9000",
    access_key = ENV["MINIO_ACCESS_KEY"],
    secret_key = ENV["MINIO_SECRET_KEY"],
))
println("\nAll objects in bucket 'analytics':")
foreach(k -> println("  $k"), all_keys)
