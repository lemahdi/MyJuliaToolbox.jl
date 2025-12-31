# MyJuliaToolbox

MyJuliaToolbox provides small helpers for reading and writing `DataFrame`s to common
file formats (`CSV` and `Arrow`). The library aims to provide reliable defaults and
convenient factories such as `read_dataframe` and `write_dataframe`.

## Quick examples

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

For API details see the API page.