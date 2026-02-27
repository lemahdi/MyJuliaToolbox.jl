module MyJuliaToolbox

"""MyJuliaToolbox — small utilities and IO helpers.

Submodules:
- `MyJuliaToolbox.IO` — I/O helpers for `DataFrame`s (CSV, Arrow, gzipped CSVs).

Primary exported helpers (re-exported from `MyJuliaToolbox.IO`):
- `read_dataframe`, `write_dataframe` — factory-style read/write functions for various sources and sinks.
- `read_csv_to_df`, `read_arrow_to_df` — convenience helpers.
"""

# Include submodules
include("io.jl")
include("utils.jl")
include("dataset.jl")
include("parameters.jl")

# Re-export commonly-used IO helpers at top level for convenience
using .IO: read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df
using .IO: iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia
using .IO: LogRecord, AsyncLogger, log!, log_debug!, log_info!, log_warn!, log_error!, flush_logger!, stop_logger!, dropped_logs
using .Utils: date2int, int2date, days_between, yearfrac, add_days_convention
export read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df, date2int, int2date, days_between, yearfrac, add_days_convention
export iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia
export LogRecord, AsyncLogger, log!, log_debug!, log_info!, log_warn!, log_error!, flush_logger!, stop_logger!, dropped_logs
export iDataSet, iParameters

end
