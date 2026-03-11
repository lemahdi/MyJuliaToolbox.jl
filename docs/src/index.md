# MyJuliaToolbox

MyJuliaToolbox provides small helpers for reading and writing `DataFrame`s to common
file formats (`CSV` and `Arrow`), as well as database sources. The library aims to provide reliable defaults and
convenient factories such as `read_dataframe` and `write_dataframe`.

## Quick examples

### Reading from files

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

The Media interface provides an abstraction layer for reading and writing across different media backends (files, databases, streams) using a unified API:

```julia
using MyJuliaToolbox.IO

# Read from CSV file in a folder
csv_source = FileSystemMedia("data")
df = read_dataframe(csv_source, "data.csv")

# Read from Arrow file in a folder
arrow_source = FileSystemMedia("data", format=:arrow)
df = read_dataframe(arrow_source, "data.arrow")

# Read from database table
using SQLite
db = SQLite.DB("mydata.db")
db_source = DatabaseMedia(db)
df = read_dataframe(db_source, table="users")

# Read with custom SQL query
query_source = DatabaseMedia(db)
df = read_dataframe(query_source, query="SELECT * FROM users WHERE age > 30")
```

The Media interface supports:
- **FileSystemMedia**: File-system backend for read and write workflows
- **DatabaseMedia**: Database backend for read/query workflows and sink-style writes
- **ConsoleMedia**: Stream backend for write-oriented workflows (e.g. logging)
- **SQLDumpMedia**: Read-only SQL dump backend for table/query extraction

### Comparing DataFrames

Use `compare_dataframes` to match rows by key(s) and report only differences.

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
  println(result.differences)
end
```

Use `title="..."` to tag each compare run in logs/output, and `logger=AsyncLogger(...)` to emit the same concise comparison report to your configured sink.
With `color=true`, `passed` checks are shown in green and `failed` checks in red.

### Writing files

Write CSV or Arrow files (writes are atomic by default):

```julia
write_dataframe("out.csv", df)            # atomic write (default)
write_dataframe("out.csv", df, overwrite=true, atomic=false)  # non-atomic
```

### Year fractions and 30/360 conventions

The package provides small date utilities useful in financial calculations:

- `date2int(d::Date) -> Int` converts a `Date` to `yyyymmdd` integer form.
- `int2date(i::Integer) -> Date` converts back.
- `days_between(i1::Integer, i2::Integer) -> Int` returns the signed number of days between two integer dates.
- `yearfrac(i1::Integer, i2::Integer; basis=:actual365) -> Float64` computes the year fraction between two integer dates using several bases:
  - `:actual365` (default), `:actual365_25`, `:actual360`, `:actual` (avg. Gregorian), and `:thirty360`.

30/360 support: the default `:thirty360` implements the US/NASD convention. Additionally, the following variants are supported:

- `:thirty360_eu`, `Symbol("30E/360")` (European 30E/360): any day=31 is treated as 30 for both start and end dates.
- `:thirty360_isda`, `:30_360_isda` (ISDA): currently implemented as an alias to the US/NASD rules; ISDA has subtle end-of-February rules and may be refined in future versions.

Examples:

```julia
# US/NASD (default 30/360 symbols)
yearfrac(20250115, 20250215, basis=:thirty360)

# European 30E/360
yearfrac(20250131, 20250331, basis=:thirty360_eu)
```

### Business-day adjustments and calendars

`add_days_convention(d::Date, delta::Integer; convention::Symbol=:following, weekends=[6,7], holidays=Date[])` adds `delta` calendar days and adjusts the result according to the chosen business-day convention. Supported conventions: `:following`, `:modified_following`, `:previous`, `:modified_previous`.

- `weekends` expects an array of weekday numbers (1=Mon .. 7=Sun), default `[6,7]` (Sat/Sun).
- `holidays` may be provided in multiple forms:
  - a `Vector` or `Set` of `Date` values or integer `yyyymmdd` values (membership => non-business holidays), or
  - a `DataFrame` with a `:ref_dt` column that **lists business days** (membership => business days). The `:ref_dt` column may contain `Date` values or integers in `yyyymmdd` form.

Examples:

```julia
using MyJuliaToolbox, DataFrames, Dates

# move 0 days and apply following convention (roll forward to next business day)
d = Date(2025,12,24)  # Wed
add_days_convention(d, 0, convention=:following)

# provide holidays as integers
add_days_convention(d, 0, convention=:following, holidays=[20251224, 20251225])

# pass a calendar DataFrame that lists business days (ref_dt column)
cal = DataFrame(ref_dt = [20251226])  # integers or Dates accepted
add_days_convention(d, 0, convention=:following, holidays=cal)
```

For API details see the API page.