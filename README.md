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

For more details, see the docstrings in `src/MyJuliaToolbox.jl` or build the documentation locally:

```bash
julia --project=docs docs/make.jl
```
