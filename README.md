# MyJuliaToolbox

[![Build Status](https://github.com/lemahdi/MyJuliaToolbox.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/lemahdi/MyJuliaToolbox.jl/actions/workflows/CI.yml?query=branch%3Amaster)

## Quick examples ✅

### Reading from files

Read a CSV or Arrow file (auto-detected by extension):

```julia
using MyJuliaToolbox

# CSV
df = read_dataframe("data.csv")

# Arrow
df2 = read_dataframe("data.arrow")
```

Read from a gzipped CSV:

```julia
df = read_dataframe("data.csv.gz")
```

### Media Interface

Use the Media interface for a unified read/write abstraction across different media backends:

```julia
using MyJuliaToolbox.IO
using MyJuliaToolbox

# Read from file in a folder
csv_source = FileSystemMedia("data")
df = read_dataframe(csv_source, "data.csv")

# Read from database
using SQLite
db = SQLite.DB("mydata.db")
db_source = DatabaseMedia(db)
df = read_dataframe(db_source, table="users")

# Custom SQL query
query_source = DatabaseMedia(db)
df = read_dataframe(query_source, query="SELECT * FROM users WHERE age > 30")

# Use a dedicated parameters location for read_parameters
params_db = DatabaseMedia(db; parameters_locator="configs")
params = read_parameters(MyParams, params_db, "model.json")
```

### Async logging

Use the non-blocking logger with any `iSourceMedia` sink.

```julia
using MyJuliaToolbox

# Console sink
console_logger = AsyncLogger(ConsoleMedia(); min_level=:info, capacity=1024)
log_info!(console_logger, "job started", metadata=(job_id=42,))
log_warn!(console_logger, "slow step detected")
stop_logger!(console_logger)

# File sink
file_logger = AsyncLogger(FileSystemMedia("logs/app.log"); min_level=:debug)
log_debug!(file_logger, "debug details")
log_error!(file_logger, "step failed", metadata=(step="load",))
stop_logger!(file_logger)
```

For SQLite logging, pass a `DatabaseMedia(db)` and optional `table="logs"` to `AsyncLogger`.
Table names must match `[A-Za-z_][A-Za-z0-9_]*` (letters/digits/underscore, not starting with a digit).
Console logs are colorized by level (`debug/info/warn/error`) by default; disable with `AsyncLogger(ConsoleMedia(); color=false)`.

### Comparing DataFrames

Compare two DataFrames by key(s), report only differences, and control numeric tolerance:

```julia
using MyJuliaToolbox
using DataFrames

left = DataFrame(id=[1, 2, 3], amount=[10.0, missing, 30.0], code=["A", "B", "C"])
right = DataFrame(user_id=[1, 2, 4], amount=[10.05, 20.0, 40.0], code=["A", "X", "D"])

result = compare_dataframes(
    left,
    right,
    :id,
    :user_id,
    [:amount, :code];
    precision=Dict(:amount => 0.1),
    check_type=true,
    title="daily-reconciliation",
    max_differences=20,
)

if !result.equal
    # Structured access to all differences
    println(result.differences)
end
```

Use `title="..."` to tag each compare run in logs/output, and `logger=AsyncLogger(...)` to emit the same concise report to your logging sink.
When `color=true` (default), report summaries show `passed` checks in green and `failed` checks in red.

### Writing files

Write CSV or Arrow based on extension (supports overwrite flag and compressed CSVs):

```julia
# By default writes are atomic: data is written to a temp file in the same directory
# and then renamed into place to avoid partial writes.
write_dataframe("out.csv", df)            # atomic write (default)
write_dataframe("out.arrow", df)          # atomic write (default)
write_dataframe("out.csv.gz", df, overwrite=true)  # atomic gzipped CSV

# Opt out of atomic behavior (non-atomic direct write):
write_dataframe("out.csv", df, overwrite=true, atomic=false)
```

Read/write from/to IO streams (specify `format` when needed):

```julia
open("data.csv", "r") do io
    df = read_dataframe(io, format=:csv)
end

open("out.csv", "w+") do io
    write_dataframe(io, df, format=:csv)
end
```

For other inputs, `read_dataframe` accepts `DataFrame`s (returns the same object) and any `Tables.jl`-compatible table.

---

## MinIO / S3-compatible object store

`MinIOMedia` extends the media interface to any S3-compatible object store — local [MinIO](https://min.io), AWS S3, Cloudflare R2, etc.

### Prerequisites

```julia
pkg> add AWSS3 AWS
```

Start a local MinIO server (dev only):

```bash
docker compose -f docker-compose.minio.yml up -d
# API: http://localhost:9000   Console: http://localhost:9001
```

### Connection

```julia
using AWSS3, AWS, MyJuliaToolbox

media = MinIOMedia(
    "my-bucket";
    endpoint   = "http://localhost:9000",   # or your remote server
    access_key = ENV["MINIO_ACCESS_KEY"],
    secret_key = ENV["MINIO_SECRET_KEY"],
    prefix     = "datasets/2025/q1",        # logical directory inside the bucket
    format     = :arrow,                    # default format for DataFrame I/O
    part_size  = 64 * 1024^2,               # bytes per multipart part and per ranged GET (default; at least 5 MiB)
)

minio_create_bucket!(media)   # no-op if the bucket already exists
```

Credentials are resolved in this order: constructor arguments → `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` env vars → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars.

### DataFrame I/O

```julia
write_dataframe(media, "prices.arrow", df)
write_dataframe(media, "prices.csv",   df; format=:csv, overwrite=true)
write_dataframe(media, df; filename="prices.xlsx")

df = read_dataframe(media, "prices.arrow")
df = read_dataframe(media; filename="prices.xlsx")
```

An object holds what a local file of the same name holds: the formats (CSV, TSV, gzipped CSV, Arrow, Feather, Excel), their inference from the extension and the bytes are those of a `FileSystemMedia`. An Arrow object is in the Arrow file format (one record batch, the same bytes as the file), so a reader such as pyarrow's datasets reads it from its footer. The `format` keyword wins over the media's `format`, as for a `FileSystemMedia`; `atomic` is accepted (an object is complete or absent: a failed upload is aborted). Without `filename`, the object is the one whose key is the media's prefix.

Objects are streamed, with no temporary file:

- **Writes** go through a buffer of `part_size` bytes. An object that fits in one buffer is put in one request; a larger one is a multipart upload, one part per full buffer, and one part uploads while the next fills, so at most `2 * part_size` bytes are buffered. Above 1,000 parts the part size doubles every 1,000 parts, to stay under S3's 10,000.
- **Reads** take the object's size from a HEAD, then fetch it in ranged GETs of `part_size` bytes into one buffer of that size; Arrow is read straight from that buffer.
- Each part and each ranged GET is logged (`@info` with `key, part, bytes, total_bytes, seconds, mib_s`), then one line per object with `parts, bytes, seconds`.

### Dataset I/O

```julia
# Write
write_dataset(media, dataset)                        # Arrow (default)
write_dataset(media, dataset; type=:csv, overwrite=true)

# Read — typed
dataset = read_dataset(MyDataSet, media)

# Read — untyped (resolves concrete type from data_info.json automatically)
dataset = read_dataset(media)
```

The full dataset structure — Arrow/CSV DataFrames, `data.json`, `data_info.json`, and nested `parameters/` files — is mirrored as S3 objects under `prefix/`, with the bytes a `FileSystemMedia` folder holds. Objects are written in this order: the tables (each streamed), then `parameters/`, then `data.json`, then `data_info.json` last, as the mark of a complete dataset. One LIST up front refuses existing keys unless `overwrite=true`, before anything is written.

When `atomic=true` (default), a failed write aborts the upload under way and deletes the objects it wrote; when it was overwriting, it also deletes the rest of the old dataset (root tables, `parameters/`, `data.json`, `data_info.json`), so the prefix holds no dataset rather than a mix of old and new objects. Nested prefixes (runs, logs) are never touched.

`read_dataset` fetches only the root tables, `data.json`, `data_info.json` and `parameters/*.json`, one object at a time into memory: nested prefixes (other runs, logs) are not downloaded.

### Parameter I/O

```julia
write_parameters(media, "config.json", params)
write_parameters(media, "config.json", params, "subdir"; overwrite=true)

params = read_parameters(MyParams, media, "config.json")
params = read_parameters(MyParams, media, "config.json", "subdir")
```

### Async logging

MinIO has no native append — records are buffered in memory and flushed as a single JSONL object per batch.

```julia
logger = AsyncLogger(media; min_level=:info)
log_info!(logger, "pipeline started"; metadata=(step="ingest",))
log_warn!(logger, "slow query")
minio_flush_log_buffer!(media)   # optional periodic flush: uploads one .jsonl object to {prefix}/logs/{date}/{ts}.jsonl
stop_logger!(logger)             # uploads the records still buffered
```

Pass `batch_logs=false` (`AsyncLogger(media; batch_logs=false)`, one of the sink options `AsyncLogger` hands to the sink) to write one object per record instead.

### Object management

```julia
minio_create_bucket!(media)          # create bucket if absent
minio_list_objects(media)            # list all keys under media.prefix
minio_flush_log_buffer!(media)       # flush buffered log records
```

### Security notes

- **Never hardcode credentials** — use environment variables or a secrets manager.
- In production, run MinIO behind a reverse proxy (nginx / Traefik) with a **valid TLS certificate** and keep `tls_verify=true` (the default). Only set `tls_verify=false` against self-signed dev certs.
- Create per-application **service accounts** in the MinIO console with least-privilege bucket policies rather than using the root credentials.

### Running MinIO tests

```bash
# Start the server, then:
julia --project=. -e 'using Pkg; Pkg.test()'

# Override defaults with env vars:
MINIO_TEST_ENDPOINT=http://localhost:9000 \
MINIO_TEST_ACCESS_KEY=minioadmin \
MINIO_TEST_SECRET_KEY=minioadmin \
julia --project=. -e 'using Pkg; Pkg.test()'
```

Tests are skipped automatically if the server is not reachable, so the standard test suite always passes without MinIO.

---

For more details, see the docstrings in `src/MyJuliaToolbox.jl` or build the documentation locally:

```bash
julia --project=docs docs/make.jl
```
