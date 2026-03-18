# Project Context for Claude Code

> This file is automatically read by Claude Code at the start of every session.
> It gives Claude the context needed to assist with this project without repeated explanations.

---

## Project Overview

**MyJuliaToolbox** is a personal Julia utility package (version `1.0.0-DEV`) providing:

- **Media-agnostic I/O** — read/write DataFrames from/to files, SQLite databases, SQL dumps, and console streams through a uniform interface
- **Dataset management** — serialize/deserialize typed dataset structs (collections of DataFrames + metadata) to Arrow or CSV directories, or directly into `.zip` / `.tar.gz` archives
- **Parameter management** — load and save structured configuration objects from/to JSON, including nested structs and URL-based configs
- **Asynchronous logging** — non-blocking ring-buffer logger with pluggable sinks
- **Date utilities** — integer-date conversions, year fractions, and business-day adjustment conventions

The package is the shared infrastructure layer for data pipeline projects (e.g., RSU202503).

---

## Repository Structure

```
MyJuliaToolbox.jl/
├── Project.toml                  # Package manifest (Julia 1.10.10+, version 1.0.0-DEV)
├── Manifest.toml
├── README.md
├── CHANGELOG.md
├── src/
│   ├── MyJuliaToolbox.jl         # Module entry point and re-exports
│   ├── io.jl                     # IO submodule loader
│   ├── io/
│   │   ├── media.jl              # iSourceMedia + concrete media types
│   │   ├── dataframes.jl         # read_dataframe/write_dataframe (factory functions)
│   │   ├── media_dataframes.jl   # read_dataframe/write_dataframe methods per media type
│   │   └── logger.jl             # AsyncLogger, LogRecord, ring buffer
│   ├── utils.jl                  # Utils submodule loader
│   ├── utils/
│   │   └── dates.jl              # date2int, int2date, yearfrac, add_days_convention
│   ├── dataset.jl                # iDataSet, LoadedDataSet, read_dataset, write_dataset
│   └── parameters.jl             # iParameters, read_parameters, write_parameters
├── test/
│   ├── runtests.jl
│   ├── io/                       # CSV, Arrow, factory, media, SQL dump, logger, dataset tests
│   ├── parameters/
│   └── utils/
├── src/sandbox/
│   ├── media/                    # Example scripts for FileSystemMedia and DatabaseMedia usage
│   └── sql/                      # Example scripts for SQL queries and empty-table handling
└── docs/
    └── src/
        ├── index.md
        └── api.md
```

---

## Public API

All symbols below are exported from the top-level `MyJuliaToolbox` module.

### Abstract Types (extension points)

```julia
abstract type iSourceMedia end   # Base for all media backends
abstract type iDataSet end       # Base for all dataset implementations
abstract type iParameters end    # Base for all parameter configurations
```

---

### Media Types (`MyJuliaToolbox.IO`)

| Type | Constructor | Purpose |
|------|-------------|---------|
| `FileSystemMedia` | `FileSystemMedia(path; format=:auto)` | File-system paths (CSV, Arrow, gzipped) |
| `DatabaseMedia` | `DatabaseMedia(locator; db_type=:sqlite, parameters_locator=nothing)` | SQLite databases (path, URL, or pre-opened connection) |
| `SQLDumpMedia` | `SQLDumpMedia(path; db_type=:mysql, in_memory=true, parameters_locator=nothing)` | SQL dump files auto-converted to in-memory SQLite |
| `ConsoleMedia` | `ConsoleMedia(; stream=stdout)` | Console/stream output |
| `ArchiveMedia` | `ArchiveMedia(path; format=:auto)` | `.zip` / `.tar.gz` archives for dataset read/write |

`format` on `FileSystemMedia` can be `:auto` (inferred from extension), `:csv`, or `:arrow`.
`db_type` on `DatabaseMedia`/`SQLDumpMedia` supports `:sqlite`, `:mysql`, `:postgresql`.
`format` on `ArchiveMedia` can be `:zip` or `:tar_gz`; auto-detected from `.zip`, `.tar.gz`, `.tgz` extensions. `.rar` and other formats are not supported.

---

### DataFrame I/O

Factory-style dispatch — the same function name works across all sources and formats.

#### `read_dataframe`

```julia
# From a file path (format inferred from extension by default)
read_dataframe(path::AbstractString; format=:auto, kwargs...) -> DataFrame

# From an IO object (format must be specified)
read_dataframe(io::Base.IO; format=:csv|:arrow, kwargs...) -> DataFrame

# Pass-through: already a DataFrame
read_dataframe(df::DataFrame) -> DataFrame

# From a Tables.jl-compatible source
read_dataframe(tbl) -> DataFrame

# From a FileSystemMedia directory + filename
read_dataframe(media::FileSystemMedia, filename::AbstractString; kwargs...) -> DataFrame

# From a DatabaseMedia (by table name or raw SQL query)
read_dataframe(media::DatabaseMedia; table=nothing, query=nothing) -> DataFrame

# From a SQLDumpMedia (by table name)
read_dataframe(media::SQLDumpMedia; table::AbstractString) -> DataFrame
```

**Convenience wrappers:**
```julia
read_csv_to_df(path; kwargs...)    # Thin wrapper over CSV.read
read_arrow_to_df(path; kwargs...)  # Thin wrapper over Arrow.Table + DataFrame
```

#### `write_dataframe`

```julia
# To a file path (format inferred from extension by default)
write_dataframe(path::AbstractString, df::DataFrame;
                format=:auto, overwrite=false, atomic=true, kwargs...)

# To an IO object
write_dataframe(io::Base.IO, df::DataFrame; format=:csv|:arrow, kwargs...)

# To a FileSystemMedia directory + filename
write_dataframe(media::FileSystemMedia, filename::AbstractString, df::DataFrame;
                overwrite=false, atomic=true, kwargs...)

# To a DatabaseMedia (creates/replaces a table)
write_dataframe(media::DatabaseMedia, table_name::AbstractString, df::DataFrame)
```

`atomic=true` (default) writes to a temp file then renames, preventing partial writes.

---

### Dataset I/O

Datasets are directories containing one Arrow (or CSV) file per `DataFrame` field, a `data.json` for metadata/parameter references, and a `data_info.json` that records the dataset type.

#### `read_dataset`

```julia
# Untyped read — returns LoadedDataSet; auto-resolves type from data_info.json if present
read_dataset(path::AbstractString; type=:arrow) -> iDataSet        # path can be a dir, .zip, or .tar.gz
read_dataset(media::FileSystemMedia; type=:arrow) -> iDataSet
read_dataset(media::ArchiveMedia; type=:arrow) -> iDataSet

# Typed read — reconstructs a concrete iDataSet subtype explicitly
read_dataset(::Type{T}, path::AbstractString; type=:arrow) -> T where T<:iDataSet
read_dataset(::Type{T}, media::FileSystemMedia; type=:arrow) -> T where T<:iDataSet
read_dataset(::Type{T}, media::ArchiveMedia; type=:arrow) -> T where T<:iDataSet
```

`read_dataset(path)` auto-routes to `ArchiveMedia` when `path` ends in `.zip`, `.tar.gz`, or `.tgz`; otherwise uses `FileSystemMedia`.

For the typed read to work, the concrete type `T` must be loaded in the current Julia session (i.e., `using YourModule` that defines it).

#### `write_dataset`

```julia
write_dataset(media::iSourceMedia, dataset::iDataSet;
              type=:arrow, overwrite=false, atomic=true, pretty=true)
```

Writes each `DataFrame` field as `<fieldname>.arrow` (or `.csv`), serializes all other fields into `data.json`, and saves each `iParameters` field to `parameters/params_N.json`.
Supported sinks: `FileSystemMedia`, `ConsoleMedia`, `ArchiveMedia`.

For `ArchiveMedia`: the dataset is first written to a temp directory, then packed into the archive. `atomic=true` (default) uses a `.tmp` file then renames to prevent partial archives.

---

### Parameter I/O

Parameters are plain Julia structs (`<: iParameters`) backed by JSON files. Nested structs are fully supported.

```julia
# Construct from a JSON file path
parameters_from_json(::Type{T}, path::AbstractString) -> T where T<:iParameters

# Construct from a Dict (e.g. after JSON.parsefile)
parameters_from_dict(::Type{T}, data::AbstractDict) -> T where T<:iParameters

# Write to a JSON file
write_parameters(path::AbstractString, params::iParameters;
                 overwrite=false, pretty=true)

# Write via media (resolves path relative to media root + optional subdirectory)
write_parameters(media::iSourceMedia, file_name::AbstractString,
                 params::iParameters, relative_path::AbstractString="";
                 overwrite=false, pretty=true)

# Read via media
read_parameters(::Type{T}, media::iSourceMedia,
                file_name::AbstractString,
                relative_path::AbstractString="") -> T where T<:iParameters
```

`read_parameters` and `write_parameters` also support URL-based `parameters_locator` strings (downloads via `Downloads.jl`) when set on `DatabaseMedia` or `SQLDumpMedia`.

---

### Async Logger

Non-blocking logger backed by a ring buffer; a background worker drains the queue to the configured sink.

```julia
# Construct
AsyncLogger(sink::iSourceMedia; min_level=:info, capacity=1024, sink_kwargs...)

# Logging functions (return false and drop the record if queue is full)
log!(logger, level::Symbol, message::AbstractString; metadata=nothing) -> Bool
log_debug!(logger, msg; metadata=nothing)
log_info!(logger, msg; metadata=nothing)
log_warn!(logger, msg; metadata=nothing)
log_error!(logger, msg; metadata=nothing)

# Lifecycle
flush_logger!(logger)   # Block until the queue is drained
stop_logger!(logger)    # Close the queue, drain, and join the worker task

# Diagnostics
dropped_logs(logger)::Int   # Number of records dropped due to a full buffer
```

**Level priority** (filtered by `min_level`):
`:debug` (10) < `:info` (20) < `:warn` (30) < `:error` (40)

**Sink behaviour by media type:**
| Sink | Output |
|------|--------|
| `FileSystemMedia` | Appends formatted lines to the target file |
| `ConsoleMedia` | Prints colorized lines to the stream (gray/cyan/yellow/red) |
| `DatabaseMedia` | Inserts rows into a `logs` table (`id`, `timestamp`, `level`, `message`, `metadata`) |

`metadata` can be any Julia value (commonly a `NamedTuple`); it is serialized to a string by the sink.

---

### Date Utilities

```julia
date2int(d::Date) -> Int          # Date(2025,12,31) → 20251231
int2date(i::Integer) -> Date      # 20251231 → Date(2025,12,31)

days_between(i1::Integer, i2::Integer) -> Int   # Signed day count between two yyyymmdd integers

yearfrac(i1::Integer, i2::Integer; basis::Symbol=:actual365) -> Float64
# basis options: :actual365, :actual365_25, :actual360, :actual,
#                :thirty360 / :"30/360", :thirty360_eu / :"30E/360", :thirty360_isda

add_days_convention(d::Date, delta::Integer;
                    convention=:following,
                    weekends=[6,7],
                    holidays=Date[]) -> Date
# convention options: :following, :modified_following, :previous/:preceding,
#                     :modified_previous/:modified_preceding
# holidays can also be Vector{Integer} (yyyymmdd) or a DataFrame with a :ref_dt column
```

---

## Key Design Patterns

1. **Media-agnostic I/O** — all read/write functions dispatch on `iSourceMedia` subtypes; swap backends without changing call sites.
2. **Factory dispatch** — `read_dataframe` and `write_dataframe` accept paths, IO objects, DataFrames, Tables.jl sources, or media objects through Julia multiple dispatch.
3. **Type-driven reconstruction** — `read_dataset` and `read_parameters` use `fieldnames`/`fieldtype` to reconstruct concrete structs from JSON/Arrow without hand-written parsers.
4. **Structured metadata** — `data_info.json` embeds `dataset_type`; `data.json` embeds `__kind__` markers for parameter references, enabling polymorphic round-trips.
5. **Atomic writes** — DataFrame, parameter, and archive writes use a temp-file-then-rename pattern by default.
6. **Ring-buffer async logging** — the logger never blocks the caller; records are dropped (and counted via `dropped_logs`) when the buffer is full.
7. **Archive transparency** — `ArchiveMedia` is a thin wrapper: it extracts to a temp dir, delegates to `FileSystemMedia` logic, then repacks. All dataset features (typed reads, `iParameters` refs, `data_info.json`) work identically inside archives.

---

## Important Notes for Callers

- `set_global_logger!`, `get_global_logger`, and `close_global_logger!` are **not** part of this package. They are thin wrappers defined in consuming projects (e.g., RSU202503.jl) around `AsyncLogger`, `flush_logger!`, and `stop_logger!`.
- For the typed `read_dataset(T, ...)` to work, `T` must be visible in `Main` or the calling module. Load the package that defines the type before calling `read_dataset`.
- `parameters_from_dict` is strict: it throws `ArgumentError` on unexpected keys and on missing required keys. JSON field names must exactly match Julia field names.
- `SQLDumpMedia` loads the entire dump into an in-memory SQLite database at construction time, which may be slow for large dumps.
- `ArchiveMedia` extracts to a `mktempdir()` on every read; for large archives this involves full decompression. Keep datasets reasonably sized or prefer `FileSystemMedia` for hot paths.
- On Windows, Arrow memory-maps files. `_with_archive_extracted` calls `GC.gc()` before cleanup and silently ignores `ENOTEMPTY`; the OS reclaims the temp dir once all handles close.

---

## Running Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Or from the Julia REPL:

```julia
pkg> test
```

---

## Notes on Global CLAUDE.md Rules

Two global rules do **not** apply when working on this package itself:

- **"Always add `MyJuliaToolbox.jl` to project dependencies"** — inapplicable; this *is* MyJuliaToolbox.
- **"Avoid `CSV.jl` unless explicitly requested"** — `CSV.jl` is a core dependency of this package; using it here is intentional and expected.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `Arrow` 2.8+ | Columnar serialization for DataFrames |
| `CSV` 0.10+ | CSV parsing and writing |
| `CodecZlib` | Gzip compression/decompression (`.csv.gz` and `.tar.gz` archives) |
| `DataFrames` 1.8+ | Core tabular data structure |
| `DataFramesMeta` 0.15+ | Macro helpers (`@chain`, `@transform`, etc.) |
| `JSON` 1.3+ | Parameter and metadata serialization |
| `SQLite` 1.8+ | Database backend for `DatabaseMedia` and `SQLDumpMedia` |
| `Downloads` | URL-based parameter fetching |
| `Pipe` | Pipe operator (`|>` chains) |
| `Plots` + `StatsPlots` | Visualization — hard dependencies; used in sandbox scripts. Consider moving to a package extension if install weight becomes a concern. |
| `Tables` | Tables.jl interface compatibility |
| `Tar` (stdlib) | `.tar.gz` archive creation and extraction |
| `ZipFile` 0.10+ | `.zip` archive creation and extraction |

---

## Typical Usage Patterns

### Read a typed dataset from disk

```julia
using MyModule          # defines MyDataSet <: iDataSet
using MyJuliaToolbox: read_dataset
using MyJuliaToolbox.IO: FileSystemMedia

media = FileSystemMedia("path/to/dataset"; format=:arrow)
dataset = read_dataset(MyDataSet, media)
# or equivalently:
dataset = read_dataset(MyDataSet, "path/to/dataset")
```

### Write a dataset

```julia
using MyJuliaToolbox: write_dataset
using MyJuliaToolbox.IO: FileSystemMedia

write_dataset(FileSystemMedia("path/to/output"), dataset; overwrite=true)
```

### Write and read a dataset from an archive

```julia
using MyJuliaToolbox: read_dataset, write_dataset
using MyJuliaToolbox.IO: ArchiveMedia

# Write to .zip (atomic by default — writes .zip.tmp then renames)
write_dataset(ArchiveMedia("output.zip"), dataset)

# Write to .tar.gz
write_dataset(ArchiveMedia("output.tar.gz"), dataset)

# Read back — untyped (auto-resolves type from data_info.json)
dataset = read_dataset(ArchiveMedia("output.zip"))

# Read back — typed
dataset = read_dataset(MyDataSet, ArchiveMedia("output.zip"))

# Convenience: pass the path directly (auto-detects archive from extension)
dataset = read_dataset("output.zip")
dataset = read_dataset(MyDataSet, "output.tar.gz")

# Overwrite an existing archive
write_dataset(ArchiveMedia("output.zip"), new_dataset; overwrite=true)
```

### Load parameters from JSON

```julia
using MyJuliaToolbox: read_parameters
using MyJuliaToolbox.IO: FileSystemMedia

params = read_parameters(MyParameters, FileSystemMedia("path/to/dir"), "config.json", "subdir")
```

### Log to file

```julia
using MyJuliaToolbox: AsyncLogger, log_info!, flush_logger!, stop_logger!
using MyJuliaToolbox.IO: FileSystemMedia

logger = AsyncLogger(FileSystemMedia("logs/job.log"); min_level=:info, capacity=2048)
log_info!(logger, "pipeline started"; metadata=(step="ingest", rows=50_000))
flush_logger!(logger)
stop_logger!(logger)
```

### Log to console

```julia
using MyJuliaToolbox: AsyncLogger, log_warn!, stop_logger!
using MyJuliaToolbox.IO: ConsoleMedia

logger = AsyncLogger(ConsoleMedia(); min_level=:debug)
log_warn!(logger, "unexpected null values"; metadata=(column="score", count=12))
stop_logger!(logger)
```

### Read a DataFrame from SQLite

```julia
using MyJuliaToolbox: read_dataframe
using MyJuliaToolbox.IO: DatabaseMedia

db = DatabaseMedia("data.db"; parameters_locator="configs/")
df = read_dataframe(db; table="menages")
# or with a raw query:
df = read_dataframe(db; query="SELECT * FROM menages WHERE region_id = 3")
```

---

*Last updated: 2026-03-18 (added ArchiveMedia: .zip and .tar.gz dataset read/write, ZipFile/Tar deps, Windows cleanup notes)*
