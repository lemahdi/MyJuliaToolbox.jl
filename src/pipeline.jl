# Pipeline runs for Mykonos: a pipeline's steps, the tables they set, and the run's log.
#
# A pipeline reads its landing tables, runs its steps through `run_step`, sets each output table through
# `set_output!` inside a step, and ends with `write_run`. The run's log is a `Dict{String, Any}` in the Dataset
# Tower's standard, `mykonos.steps.v1`; it is written as `steps.json` in the run's prefix of the pipeline zone at each
# step's start and end, and the dataset is written beside it, in `dataset/`.

using DataFrames
using Dates
using JSON

export open_zones, read_landing, run_step, set_output!, write_run

const _STEPS_CONTRACT = "mykonos.steps.v1"
const _STEPS_FILE = "steps.json"
const _LANDING_FILE = "landing.json"
const _DATASET_FOLDER = "dataset"
const _LOG_FIELDS = ("contract", "state", "started_at", "ended_at", "error", "steps", "sets", "tables", "files")
# In memory only, never written: each field's table as its last set left it (a reference, not a copy).
const _OUTPUTS = "_outputs"
# The tower's step, field and table names; 128 is C10's limit for a table's name.
const _NAME_PATTERN = r"^[A-Za-z0-9_-]{1,128}$"
# The UID tower's form, `<kind>-<UUIDv7>`, as the Dataset Tower checks it.
const _UID_PATTERN = r"^[a-z][a-z0-9]{1,31}-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
const _DATASET_UID_PATTERN = r"^dataset-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
const _ZONE_VARIABLES = (
    endpoint = "MYKONOS_OBJECT_ENDPOINT",
    landing_store = "MYKONOS_LANDING_STORE",
    pipeline_store = "MYKONOS_PIPELINE_STORE",
    dataset_uid = "MYKONOS_DATASET_UID",
    run_uid = "MYKONOS_RUN_UID",
    access_key = "MINIO_ACCESS_KEY",
    secret_key = "MINIO_SECRET_KEY",
)

# ──────────────────────────────────────────────────────────────────────────────
# The zones
# ──────────────────────────────────────────────────────────────────────────────

"""
    open_zones(environment::AbstractDict = ENV) -> NamedTuple{(:landing, :pipeline)}

The landing zone and this run's prefix of the pipeline zone, as `MinIOMedia`, from the variables S6 sets:

| Variable | Holds |
|---|---|
| `MYKONOS_OBJECT_ENDPOINT` | MinIO's address, e.g. `https://kb-objects:9000` |
| `MYKONOS_LANDING_STORE` | The landing zone, `s3://<bucket>/<prefix>` |
| `MYKONOS_PIPELINE_STORE` | The pipeline zone, `s3://<bucket>/<prefix>` |
| `MYKONOS_DATASET_UID`, `MYKONOS_RUN_UID` | The dataset and the run: the run's prefix is `<prefix>/<dataset UID>/<run UID>` |
| `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | The key the process reaches MinIO with |

Throws `ArgumentError` when a variable is missing or empty, a store is not `s3://<bucket>/<prefix>`, or a UID is
not in the UID tower's form (`<kind>-<UUIDv7>`; the dataset's kind is `dataset`).
"""
function open_zones(environment::AbstractDict = ENV)
    settings = _zone_settings(environment)
    landing_bucket, landing_prefix = _store_location(settings.landing_store, _ZONE_VARIABLES.landing_store)
    pipeline_bucket, pipeline_prefix = _store_location(settings.pipeline_store, _ZONE_VARIABLES.pipeline_store)
    run_prefix = join(filter(!isempty, [pipeline_prefix, settings.dataset_uid, settings.run_uid]), "/")
    return (landing = _zone_media(settings, landing_bucket, landing_prefix),
            pipeline = _zone_media(settings, pipeline_bucket, run_prefix))
end

"""The variables `open_zones` reads, each required and non-empty, with the two UIDs in the UID tower's form."""
function _zone_settings(environment::AbstractDict)
    settings = map(_ZONE_VARIABLES) do variable
        value = string(get(environment, variable, ""))
        isempty(value) && throw(ArgumentError("open_zones: $variable is not set"))
        value
    end
    occursin(_DATASET_UID_PATTERN, settings.dataset_uid) || throw(ArgumentError(
        "open_zones: $(_ZONE_VARIABLES.dataset_uid) is not a dataset UID: $(repr(settings.dataset_uid))"))
    occursin(_UID_PATTERN, settings.run_uid) || throw(ArgumentError(
        "open_zones: $(_ZONE_VARIABLES.run_uid) is not a UID: $(repr(settings.run_uid))"))
    return settings
end

"""The bucket and the prefix of a store written `s3://<bucket>/<prefix>`, the form of `MYKONOS_LANDING_STORE`."""
function _store_location(uri::AbstractString, variable::AbstractString)
    location = match(r"^s3://([^/]+)(?:/(.*))?$", uri)
    location === nothing && throw(ArgumentError(
        "open_zones: $variable must be s3://<bucket>/<prefix>, not $(repr(uri))"))
    return String(location[1]), String(strip(something(location[2], ""), '/'))
end

"""A zone as a `MinIOMedia`: a bucket and a prefix on the endpoint, with the process's key."""
function _zone_media(settings::NamedTuple, bucket::AbstractString, prefix::AbstractString)
    return IO.MinIOMedia(String(bucket); endpoint = settings.endpoint, access_key = settings.access_key,
                         secret_key = settings.secret_key, prefix = String(prefix))
end

"""A zone's subfolder, as a media of the zone's kind."""
_zone_folder(zone::IO.FileSystemMedia, folder::AbstractString) = IO.FileSystemMedia(joinpath(zone.path, folder))

"""A zone's subfolder, as a media of the zone's kind: the same bucket, endpoint and key, one prefix further."""
function _zone_folder(zone::IO.MinIOMedia, folder::AbstractString)
    config = zone._config
    return IO.MinIOMedia(zone.bucket; endpoint = config.endpoint, region = config.region,
                         access_key = config.credentials.access_key_id, secret_key = config.credentials.secret_key,
                         prefix = IO._minio_key(zone, String(folder)))
end

"""Write a file at a path relative to a zone that is a folder."""
function _write_zone_file(zone::IO.FileSystemMedia, relative_path::AbstractString, bytes::Vector{UInt8})
    path = joinpath(zone.path, relative_path)
    mkpath(dirname(path))
    write(path, bytes)
    return nothing
end

"""Write a JSON file at a path relative to a zone that is a MinIO prefix."""
function _write_zone_file(zone::IO.MinIOMedia, relative_path::AbstractString, bytes::Vector{UInt8})
    IO._s3_put_bytes(zone, IO._minio_key(zone, String(relative_path)), bytes; content_type = "application/json")
    return nothing
end

"""Read a file at a path relative to a zone that is a folder."""
_read_zone_file(zone::IO.FileSystemMedia, relative_path::AbstractString) = read(joinpath(zone.path, relative_path))

"""Read a file at a path relative to a zone that is a MinIO prefix."""
function _read_zone_file(zone::IO.MinIOMedia, relative_path::AbstractString)
    return IO._s3_get_bytes(zone, IO._minio_key(zone, String(relative_path)))
end

"""A file's key in a zone that is a folder: its path."""
_zone_key(zone::IO.FileSystemMedia, relative_path::AbstractString) = replace(joinpath(zone.path, relative_path), '\\' => '/')

"""A file's key in a zone that is a MinIO prefix: its object's key in the bucket."""
_zone_key(zone::IO.MinIOMedia, relative_path::AbstractString) = IO._minio_key(zone, String(relative_path))

"""Every file under a zone that is a folder, by key, in order."""
function _zone_keys(zone::IO.FileSystemMedia)
    paths = [joinpath(root, name) for (root, _, names) in walkdir(zone.path) for name in names]
    return sort([replace(path, '\\' => '/') for path in paths])
end

"""Every object under a zone that is a MinIO prefix, by key, in order."""
_zone_keys(zone::IO.MinIOMedia) = sort(IO._s3_list_keys(zone, isempty(zone.prefix) ? "" : zone.prefix * "/"))

# ──────────────────────────────────────────────────────────────────────────────
# The landing tables
# ──────────────────────────────────────────────────────────────────────────────

"""
    read_landing(zones) -> Dict{String, DataFrame}

The dataset's landing tables by name, each table's parts read from the landing zone in their order and stacked.
The names and the parts' keys come from `landing.json`, which S6 writes in the run's prefix before the run: C10's
answer for the dataset's landing zone, unchanged (its `manifest.tables`, each with its `parts` and their `key`).
The parts are not checked again: C10 checked them when they were loaded.

Throws `ArgumentError` when `landing.json` holds no `manifest.tables`, or a table has no part.
"""
function read_landing(zones)
    tables = Dict{String, DataFrame}()
    for (name, entry) in _landing_tables(zones.pipeline)
        part_keys = [String(part["key"]) for part in get(entry, "parts", Any[])]
        isempty(part_keys) && throw(ArgumentError("read_landing: the landing table $name has no part"))
        tables[String(name)] = reduce(vcat, [IO.read_dataframe(zones.landing, key) for key in part_keys])
    end
    return tables
end

"""The landing tables `landing.json` lists: C10's landing zone answer, its `manifest.tables`, by name."""
function _landing_tables(pipeline_zone)
    landing = JSON.parse(String(_read_zone_file(pipeline_zone, _LANDING_FILE)))
    manifest = landing isa AbstractDict ? get(landing, "manifest", nothing) : nothing
    tables = manifest isa AbstractDict ? get(manifest, "tables", nothing) : nothing
    tables isa AbstractDict || throw(ArgumentError("read_landing: $(_LANDING_FILE) holds no manifest.tables"))
    return tables
end

# ──────────────────────────────────────────────────────────────────────────────
# The steps
# ──────────────────────────────────────────────────────────────────────────────

"""
    run_step(run_log, zones, f, dataset, args...; kwargs...)

Run one step of the pipeline: `f(dataset, run_log, args...; kwargs...)`, and return what it returns. The step is
named after its function, without the trailing `!` (`compute!` gives `compute`); a table set in a helper that `f`
calls belongs to this step. The step is recorded as `running`, then `done`, and `steps.json` is written in the run's
prefix of the pipeline zone at its start and at its end. If `f` throws, the step and the run are recorded as
`failed`, with the error's text on one line (no backtrace), `steps.json` is written, and the error is thrown again.

`run_log` starts as an empty `Dict{String, Any}()`. Throws `ArgumentError` for an anonymous function, a name
outside `^[A-Za-z0-9_-]{1,128}\$`, a name used twice (`clean` and `clean!` give one name), a step while another
runs, and a step after a failed one or after `write_run`.
"""
function run_step(run_log::Dict{String, Any}, zones, step_function::Function, dataset::iDataSet, arguments...;
                  keywords...)
    name = _step_name(step_function)
    _start_step!(run_log, name, step_function)
    _write_steps(zones, run_log)
    result = try
        step_function(dataset, run_log, arguments...; keywords...)
    catch failure
        _end_step!(run_log, "failed", _error_text(failure))
        _write_steps_after_failure(zones, run_log)
        rethrow()
    end
    _end_step!(run_log, "done", nothing)
    _write_steps(zones, run_log)
    return result
end

"""A step's name: its function's name without the trailing `!`. Refuses an anonymous function and a name outside
the tower's pattern."""
function _step_name(step_function::Function)
    function_name = string(nameof(step_function))
    occursin('#', function_name) && throw(ArgumentError(
        "run_step: an anonymous function is not a step; give the step a named function"))
    name = String(rstrip(function_name, '!'))
    _check_name(name, "run_step: the step name")
    return name
end

"""Refuse a name outside the tower's pattern for step, field and table names."""
function _check_name(name::AbstractString, what::AbstractString)
    occursin(_NAME_PATTERN, name) || throw(ArgumentError("$what $(repr(name)) is outside ^[A-Za-z0-9_-]{1,128}\$"))
    return nothing
end

"""Record a new step as `running`, after the others; the first step starts the run's log."""
function _start_step!(run_log::Dict{String, Any}, name::AbstractString, step_function::Function)
    isempty(run_log) && _start_run!(run_log)
    _check_open(run_log, "run_step")
    any(step -> step["name"] == name, run_log["steps"]) && throw(ArgumentError(
        "run_step: the step name $name is used twice"))
    push!(run_log["steps"], Dict{String, Any}(
        "position" => length(run_log["steps"]) + 1, "name" => name,
        "function" => string(parentmodule(step_function), ".", nameof(step_function)),
        "state" => "running", "started_at" => _now(), "ended_at" => nothing, "error" => nothing))
    return run_log
end

"""A new run's log: the standard's fields, `running`, with no step yet."""
function _start_run!(run_log::Dict{String, Any})
    merge!(run_log, Dict{String, Any}(
        "contract" => _STEPS_CONTRACT, "state" => "running", "started_at" => _now(), "ended_at" => nothing,
        "error" => nothing, "steps" => Any[], "sets" => Any[], "tables" => Any[], "files" => Any[],
        _OUTPUTS => Dict{String, DataFrame}()))
    return run_log
end

"""Refuse a log that takes nothing more: not a run's log, a failed or written run, a step still running."""
function _check_open(run_log::Dict{String, Any}, caller::AbstractString)
    get(run_log, "contract", nothing) == _STEPS_CONTRACT || throw(ArgumentError(
        "$caller: not a run's log; a run's log starts as Dict{String, Any}()"))
    run_log["state"] == "failed" && throw(ArgumentError("$caller: the run failed; nothing more runs or is written"))
    run_log["state"] == "done" && throw(ArgumentError("$caller: the run is written already"))
    running = _running_step(run_log)
    running === nothing || throw(ArgumentError("$caller: the step $(running["name"]) is still running"))
    return nothing
end

"""The step running now, or `nothing`."""
function _running_step(run_log::Dict{String, Any})
    steps = get(run_log, "steps", Any[])
    return !isempty(steps) && steps[end]["state"] == "running" ? steps[end] : nothing
end

"""End the running step as `done` or `failed`; a failed step ends the run as `failed` too."""
function _end_step!(run_log::Dict{String, Any}, state::AbstractString, failure_text)
    step = run_log["steps"][end]
    step["state"], step["ended_at"], step["error"] = state, _now(), failure_text
    state == "failed" && _end_run!(run_log, "failed", nothing)
    return run_log
end

"""End the run as `done` or `failed`, with the run's own error (a failure outside any step) or `nothing`."""
function _end_run!(run_log::Dict{String, Any}, state::AbstractString, failure_text)
    run_log["state"], run_log["ended_at"], run_log["error"] = state, _now(), failure_text
    if state == "failed"
        run_log["tables"], run_log["files"] = Any[], Any[]
    end
    return run_log
end

"""The time now, in UTC with milliseconds, as the run's log keeps it: `2026-11-18T12:38:09.921Z`."""
_now() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

"""An error's text for the log: as `showerror` prints it, without a backtrace, each control character a space."""
function _error_text(failure)
    text = strip(map(character -> character < ' ' ? ' ' : character, sprint(showerror, failure)))
    return isempty(text) ? string(nameof(typeof(failure))) : String(text)
end

"""The run's log as `steps.json` holds it: the standard's fields only."""
_log_document(run_log::Dict{String, Any}) = Dict{String, Any}(field => run_log[field] for field in _LOG_FIELDS)

"""Write the run's log as `steps.json` in the run's prefix of the pipeline zone."""
function _write_steps(zones, run_log::Dict{String, Any})
    text = sprint(io -> JSON.print(io, _log_document(run_log), 2))
    _write_zone_file(zones.pipeline, _STEPS_FILE, Vector{UInt8}(text))
    return nothing
end

"""Write `steps.json` after a failure; if that write fails too, it is reported and the first failure is kept."""
function _write_steps_after_failure(zones, run_log::Dict{String, Any})
    try
        _write_steps(zones, run_log)
    catch write_failure
        @error "steps.json was not written after a failure" exception = (write_failure, catch_backtrace())
    end
    return nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# The outputs
# ──────────────────────────────────────────────────────────────────────────────

"""
    set_output!(dataset, run_log, field::Symbol, table::DataFrame) -> dataset

Set the dataset's `field` to `table` inside the running step, and record the set in the log: the time, the step,
the field, the table's name (the field's without a trailing `_df`), its rows, and its columns with their Julia types.
The log keeps a reference to the table, not a copy: `write_run` refuses a table changed since its last set.

Throws `ArgumentError` when no step is running, the dataset has no such field, `table` is not a `DataFrame`, the
field's or the table's name is outside `^[A-Za-z0-9_-]{1,128}\$`, or a column's name is empty or holds a control
character (the tower refuses both).
"""
function set_output!(dataset::iDataSet, run_log::Dict{String, Any}, field::Symbol, table)
    step = _running_step(run_log)
    step === nothing && throw(ArgumentError("set_output!: no step is running; a table is set inside a step (run_step)"))
    hasfield(typeof(dataset), field) || throw(ArgumentError("set_output!: $(typeof(dataset)) has no field $field"))
    table isa DataFrame || throw(ArgumentError("set_output!: $field takes a DataFrame, not a $(typeof(table))"))
    field_name = string(field)
    table_name = _table_name(field_name)
    _check_name(field_name, "set_output!: the field")
    _check_name(table_name, "set_output!: the table name")
    columns = _checked_columns(table, field_name)
    setproperty!(dataset, field, table)
    push!(run_log["sets"], Dict{String, Any}("at" => _now(), "step" => step["name"], "field" => field_name,
                                             "table" => table_name, "rows" => nrow(table), "columns" => columns))
    run_log[_OUTPUTS][field_name] = table
    return dataset
end

"""A table's name: its field's without a trailing `_df`."""
_table_name(field_name::AbstractString) = replace(field_name, r"_df$" => "")

"""A table's columns, each its name and its Julia type."""
function _columns(table::DataFrame)
    return Any[Dict{String, Any}("name" => name, "type" => string(eltype(table[!, name]))) for name in names(table)]
end

"""A table's columns, refusing a name that is empty or holds a control character."""
function _checked_columns(table::DataFrame, field_name::AbstractString)
    columns = _columns(table)
    for column in columns
        name = column["name"]
        (isempty(name) || any(character -> character < ' ', name)) && throw(ArgumentError(
            "set_output!: $field_name has a column named $(repr(name)); a column's name is a text with no control character"))
    end
    return columns
end

# ──────────────────────────────────────────────────────────────────────────────
# The end of the run
# ──────────────────────────────────────────────────────────────────────────────

"""
    write_run(run_log, zones, dataset)

End the run: write the dataset with `write_dataset` into `dataset/` in the run's prefix of the pipeline zone
(`<field>.arrow` for each table with rows, `parameters/`, `data.json`, `data_info.json`), record each table with its
file's key and the step that set it last, and each other file's key, then write `steps.json` as `done`.

Throws `ArgumentError` when no step ran, a step is running, or the run failed or is written already. These are also
refused, and end the run as `failed` with the run's own error: a table field with rows that no `set_output!` set, a
table changed since its last set (replaced, or with other rows or columns: a change needs a step), two fields giving
one table name. A failure while writing ends the run as `failed` the same way; the error is thrown again.
"""
function write_run(run_log::Dict{String, Any}, zones, dataset::iDataSet)
    isempty(get(run_log, "steps", Any[])) && throw(ArgumentError("write_run: no step ran; a run has at least one step"))
    _check_open(run_log, "write_run")
    try
        tables = _tables_to_write(run_log, dataset)
        dataset_zone = _zone_folder(zones.pipeline, _DATASET_FOLDER)
        write_dataset(dataset_zone, dataset; type = :arrow)
        _record_files!(run_log, dataset_zone, tables)
    catch failure
        _end_run!(run_log, "failed", _error_text(failure))
        _write_steps_after_failure(zones, run_log)
        rethrow()
    end
    _end_run!(run_log, "done", nothing)
    _write_steps(zones, run_log)
    return nothing
end

"""The last sets of the tables `write_dataset` writes, in the order of the dataset's fields. Refuses a table field
with rows that no `set_output!` set, a table changed since its last set, and two fields giving one table name."""
function _tables_to_write(run_log::Dict{String, Any}, dataset::iDataSet)
    last_sets = Dict{String, Any}(set["field"] => set for set in run_log["sets"])
    skipped = Set(nonpersisted_fields(typeof(dataset)))
    tables = Dict{String, Any}[]
    for field in fieldnames(typeof(dataset))
        field in skipped && continue
        field_name, value = string(field), getfield(dataset, field)
        if haskey(last_sets, field_name)
            _unchanged(value, run_log[_OUTPUTS][field_name], last_sets[field_name]) || throw(ArgumentError(
                "write_run: $field_name changed since its last set_output!; a change needs a step"))
        elseif value isa DataFrame && nrow(value) > 0
            throw(ArgumentError("write_run: $field_name has rows that no set_output! set; a table is set inside a step"))
        end
        value isa DataFrame && nrow(value) > 0 && push!(tables, last_sets[field_name])
    end
    _check_distinct_tables(tables)
    return tables
end

"""Whether a field still holds the table its last set gave it, with the same rows and columns."""
function _unchanged(value, table::DataFrame, last_set::AbstractDict)
    return value === table && nrow(table) == last_set["rows"] && _columns(table) == last_set["columns"]
end

"""Refuse two fields giving one table name (`score` and `score_df`)."""
function _check_distinct_tables(tables::Vector{Dict{String, Any}})
    fields_by_table = Dict{String, String}()
    for set in tables
        other = get(fields_by_table, set["table"], nothing)
        other === nothing || throw(ArgumentError(
            "write_run: $other and $(set["field"]) give one table name, $(set["table"])"))
        fields_by_table[set["table"]] = set["field"]
    end
    return nothing
end

"""Record what `write_dataset` wrote: each table with its file's key, then the other files' keys."""
function _record_files!(run_log::Dict{String, Any}, dataset_zone, tables::Vector{Dict{String, Any}})
    written = _zone_keys(dataset_zone)
    table_entries = Any[]
    for set in tables
        key = _zone_key(dataset_zone, set["field"] * ".arrow")
        key in written || error("write_run: $key was not written")
        push!(table_entries, Dict{String, Any}("name" => set["table"], "field" => set["field"], "step" => set["step"],
                                               "rows" => set["rows"], "columns" => set["columns"], "key" => key))
    end
    table_keys = Set(entry["key"] for entry in table_entries)
    run_log["tables"] = table_entries
    run_log["files"] = Any[Dict{String, Any}("key" => key) for key in written if !(key in table_keys)]
    return run_log
end
