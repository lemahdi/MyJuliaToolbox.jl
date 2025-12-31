module MyJuliaToolbox

"""MyJuliaToolbox — small utilities and IO helpers.

Submodules:
- `MyJuliaToolbox.IO` — I/O helpers for `DataFrame`s (CSV, Arrow, gzipped CSVs).

Main exported helpers (re-exported from `MyJuliaToolbox.IO`):
- `read_dataframe`, `write_dataframe` — factory-style read/write functions for various sources and sinks.
- `read_csv_to_df`, `read_arrow_to_df` — convenience helpers.
"""

# Include submodules
include("io.jl")
include("utils.jl")

# Re-export commonly-used IO helpers at top level for convenience
using .IO: read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df
using .Utils: date_to_yyyymmdd
export read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df, date_to_yyyymmdd

end
