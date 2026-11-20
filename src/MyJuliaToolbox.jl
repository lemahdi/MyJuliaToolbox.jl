module MyJuliaToolbox

"""MyJuliaToolbox — small utilities and IO helpers.

Submodules:
- `MyJuliaToolbox.IO` — I/O helpers for `DataFrame`s (CSV, Arrow, gzipped CSVs).

Primary exported helpers (re-exported from `MyJuliaToolbox.IO`):
- `read_dataframe`, `write_dataframe` — factory-style read/write functions for various sources and sinks.
- `read_csv_to_df`, `read_arrow_to_df` — convenience helpers.

Pipeline runs (`pipeline.jl`): `open_zones`, `read_landing`, `run_step`, `set_output!`, `write_run`.
"""

# Include submodules
include("io.jl")
include("utils.jl")
include("parameters.jl")
include("dataset.jl")
include("pipeline.jl")

# Re-export commonly-used IO helpers at top level for convenience
using .IO: read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df
using .IO: iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia, ArchiveMedia
using .IO: MinIOMedia, minio_create_bucket!, minio_list_objects, minio_flush_log_buffer!
using .IO: LogRecord, AsyncLogger, log!, log_debug!, log_info!, log_warn!, log_error!, flush_logger!, stop_logger!, dropped_logs
using .Utils: date2int, int2date, days_between, yearfrac, add_days_convention, compare_dataframes
export read_dataframe, write_dataframe, read_csv_to_df, read_arrow_to_df, date2int, int2date, days_between, yearfrac, add_days_convention, compare_dataframes
export iSourceMedia, FileSystemMedia, DatabaseMedia, SQLDumpMedia, ConsoleMedia, ArchiveMedia
export MinIOMedia, minio_create_bucket!, minio_list_objects, minio_flush_log_buffer!
export LogRecord, AsyncLogger, log!, log_debug!, log_info!, log_warn!, log_error!, flush_logger!, stop_logger!, dropped_logs
export iDataSet, iParameters, nonpersisted_fields
export open_zones, read_landing, run_step, set_output!, write_run

end
