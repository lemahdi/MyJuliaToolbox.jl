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

Use the Media interface for a unified API across different data sources:

```julia
using MyJuliaToolbox.IO

# Read from file
csv_source = FileSystemSource("data.csv")
df = read_dataframe(csv_source)

# Read from database
using SQLite
db = SQLite.DB("mydata.db")
db_source = DatabaseSource(db, table="users")
df = read_dataframe(db_source)

# Custom SQL query
query_source = DatabaseSource(db, query="SELECT * FROM users WHERE age > 30")
df = read_dataframe(query_source)
```

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
