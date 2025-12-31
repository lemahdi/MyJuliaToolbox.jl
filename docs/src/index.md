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

For API details see the API page.