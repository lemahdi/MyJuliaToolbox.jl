using DataFrames
using ..IO: AsyncLogger, log_info!, log_warn!

export compare_dataframes

struct DataFrameComparisonResult
    title::String
    equal::Bool
    compared_rows::Int
    target_columns::Vector{Symbol}
    total_checks::Int
    passed_checks::Int
    failed_checks::Int
    left_only_rows::Int
    right_only_rows::Int
    missing_mismatches::Int
    type_mismatches::Int
    numeric_mismatches::Int
    value_mismatches::Int
    differences::DataFrame
end

function _normalize_columns(columns, arg_name::String)
    if columns isa Symbol
        return Symbol[columns]
    elseif columns isa AbstractString
        return Symbol[Symbol(columns)]
    elseif columns isa AbstractVector
        normalized = Symbol[]
        for column in columns
            if column isa Symbol
                push!(normalized, column)
            elseif column isa AbstractString
                push!(normalized, Symbol(column))
            else
                throw(ArgumentError("$arg_name must contain only Symbol or String values. Found $(typeof(column))."))
            end
        end
        isempty(normalized) && throw(ArgumentError("$arg_name cannot be empty."))
        return normalized
    else
        throw(ArgumentError("$arg_name must be a Symbol, String, or a vector of Symbol/String values."))
    end
end

function _ensure_columns_exist(df::DataFrame, columns::Vector{Symbol}, label::String)
    available = Set(Symbol.(names(df)))
    missing_columns = [column for column in columns if !(column in available)]
    if !isempty(missing_columns)
        throw(ArgumentError("$label columns not found: $(join(string.(missing_columns), ", "))."))
    end
    return nothing
end

function _resolve_target_columns(
    left::DataFrame,
    right::DataFrame,
    left_keys::Vector{Symbol},
    right_keys::Vector{Symbol},
    target_columns,
)
    if isnothing(target_columns)
        right_names = Set(Symbol.(names(right)))
        excluded = Set(vcat(left_keys, right_keys))
        inferred = Symbol[]
        for name in Symbol.(names(left))
            if name in right_names && !(name in excluded)
                push!(inferred, name)
            end
        end
        isempty(inferred) && throw(ArgumentError("Could not infer target columns. Provide target_columns explicitly."))
        return inferred
    end

    normalized = _normalize_columns(target_columns, "target_columns")
    _ensure_columns_exist(left, normalized, "Left target")
    _ensure_columns_exist(right, normalized, "Right target")
    return normalized
end

function _occurrence_index(df::DataFrame, keys::Vector{Symbol})
    row_count = nrow(df)
    row_count == 0 && return Int[]

    occurrence = zeros(Int, row_count)
    key_df = select(df, keys, copycols=false)
    key_df[!, :__row_id__] = 1:row_count

    for group in groupby(key_df, keys; sort=false)
        row_ids = group[!, :__row_id__]
        for (position, row_id) in enumerate(row_ids)
            occurrence[row_id] = position
        end
    end

    return occurrence
end

function _prepare_left(df::DataFrame, keys::Vector{Symbol}, targets::Vector{Symbol})
    prepared = DataFrame()
    for key in keys
        prepared[!, key] = df[!, key]
    end
    for target in targets
        prepared[!, Symbol(target, "__left")] = df[!, target]
    end
    prepared[!, :__occurrence__] = _occurrence_index(df, keys)
    return prepared
end

function _prepare_right(df::DataFrame, right_keys::Vector{Symbol}, left_keys::Vector{Symbol}, targets::Vector{Symbol})
    prepared = DataFrame()
    for (right_key, left_key) in zip(right_keys, left_keys)
        prepared[!, left_key] = df[!, right_key]
    end
    for target in targets
        prepared[!, Symbol(target, "__right")] = df[!, target]
    end
    prepared[!, :__occurrence__] = _occurrence_index(df, right_keys)
    return prepared
end

function _precision_for_column(precision, column::Symbol)
    if precision isa Real
        precision < 0 && throw(ArgumentError("precision must be >= 0."))
        return Float64(precision)
    elseif precision isa AbstractDict
        if haskey(precision, column)
            value = precision[column]
        elseif haskey(precision, String(column))
            value = precision[String(column)]
        else
            value = 0.0
        end
        value isa Real || throw(ArgumentError("precision for column '$column' must be numeric."))
        value < 0 && throw(ArgumentError("precision for column '$column' must be >= 0."))
        return Float64(value)
    else
        throw(ArgumentError("precision must be a numeric value or dictionary keyed by column."))
    end
end

function _numbers_equal(left_value::Number, right_value::Number, tolerance::Float64)
    if (left_value isa AbstractFloat && isnan(left_value)) || (right_value isa AbstractFloat && isnan(right_value))
        return (left_value isa AbstractFloat && isnan(left_value)) && (right_value isa AbstractFloat && isnan(right_value))
    end
    if !isfinite(float(left_value)) || !isfinite(float(right_value))
        return isequal(left_value, right_value)
    end
    return abs(float(left_value) - float(right_value)) <= tolerance
end

_value_text(value) = ismissing(value) ? "missing" : repr(value)
_title_prefix(title::String) = isempty(strip(title)) ? "" : "[$(strip(title))] "

function _key_text(row, key_columns::Vector{Symbol})
    parts = String[]
    for key in key_columns
        push!(parts, string(key, "=", _value_text(row[key])))
    end
    occurrence = row[:__occurrence__]
    if occurrence > 1
        push!(parts, "occurrence=$occurrence")
    end
    return join(parts, ", ")
end

function _emit_line(io::Base.IO, text::String; color::Bool=true, level::Symbol=:info)
    if color
        color_name = if level == :ok
            :green
        elseif level == :warn
            :red
        else
            :yellow
        end
        printstyled(io, text * "\n"; color=color_name)
    else
        println(io, text)
    end
    return nothing
end

function _emit_check_counts(io::Base.IO, passed::Int, failed::Int; color::Bool=true)
    if color
        print(io, "checks: ")
        printstyled(io, "passed=$passed"; color=:green)
        print(io, " | ")
        printstyled(io, "failed=$failed\n"; color=:red)
    else
        println(io, "checks: passed=$passed | failed=$failed")
    end
    return nothing
end

function _emit_logger(logger::Union{Nothing,AsyncLogger}, text::String; warn::Bool=false)
    if isnothing(logger)
        return nothing
    end
    if warn
        log_warn!(logger, text)
    else
        log_info!(logger, text)
    end
    return nothing
end

function _render_comparison_report(
    result::DataFrameComparisonResult;
    logger::Union{Nothing,AsyncLogger}=nothing,
    io::Base.IO=stdout,
    color::Bool=true,
    emit_console::Bool=true,
    max_differences::Int=25,
)
    title_prefix = _title_prefix(result.title)
    summary = if result.equal
        "$(title_prefix)✓ DataFrame comparison passed (rows=$(result.compared_rows), targets=$(length(result.target_columns)), no differences)."
    else
        "$(title_prefix)✗ DataFrame comparison found $(nrow(result.differences)) differences (left_only=$(result.left_only_rows), right_only=$(result.right_only_rows), missing=$(result.missing_mismatches), type=$(result.type_mismatches), numeric=$(result.numeric_mismatches), value=$(result.value_mismatches))."
    end

    if emit_console
        _emit_line(io, summary; color=color, level=(result.equal ? :ok : :warn))
        _emit_check_counts(io, result.passed_checks, result.failed_checks; color=color)
    end
    _emit_logger(logger, summary; warn=!result.equal)
    _emit_logger(
        logger,
        "$(title_prefix)checks: passed=$(result.passed_checks) | failed=$(result.failed_checks)";
        warn=result.failed_checks > 0,
    )

    if result.equal || max_differences <= 0
        return nothing
    end

    print_count = min(max_differences, nrow(result.differences))
    for row in eachrow(result.differences[1:print_count, :])
        detail = "$(title_prefix)- [$(row.issue)] key($(row.key))"
        if !ismissing(row.column)
            detail *= " col=$(row.column)"
        end
        detail *= " | left=$(row.left_value) | right=$(row.right_value)"
        if !isempty(row.detail)
            detail *= " | $(row.detail)"
        end

        if emit_console
            _emit_line(io, detail; color=color, level=:detail)
        end
        _emit_logger(logger, detail; warn=true)
    end

    if nrow(result.differences) > print_count
        remaining = nrow(result.differences) - print_count
        more_line = "$(title_prefix)... $(remaining) additional differences not shown"
        if emit_console
            _emit_line(io, more_line; color=color, level=:detail)
        end
        _emit_logger(logger, more_line; warn=true)
    end

    return nothing
end

"""
    compare_dataframes(left, right, keys, target_columns; kwargs...)
    compare_dataframes(left, right, left_keys, right_keys, target_columns; kwargs...)

Compare two `DataFrame`s using key columns and report only differences.

# Positional arguments
- `left`, `right`: DataFrames to compare.
- `keys`: Key column(s) used on both DataFrames (`Symbol`, `String`, or vector).
- `left_keys`, `right_keys`: Key columns per DataFrame when key names differ.
- `target_columns`: Column(s) to compare. If omitted (`nothing`), all common non-key columns are used.

# Keyword arguments
- `precision`: Numeric tolerance (`Real`) applied to all numeric targets, or a dictionary per target column.
- `check_type::Bool=false`: When `true`, report type mismatches even when values match.
- `title::AbstractString=""`: Optional label included in report/log lines to distinguish multiple comparisons.
- `logger::Union{Nothing,AsyncLogger}=nothing`: Optional async logger sink.
- `io::IO=stdout`: Output stream used for console report.
- `color::Bool=true`: Enable/disable colored console output.
- `emit_console::Bool=true`: Print report to console.
- `max_differences::Int=25`: Maximum differences printed in the report.

Returns a `DataFrameComparisonResult` including counters and a detailed `differences` DataFrame.
"""
function compare_dataframes(
    left::DataFrame,
    right::DataFrame,
    left_keys,
    right_keys,
    target_columns;
    precision=0.0,
    check_type::Bool=false,
    title::AbstractString="",
    logger::Union{Nothing,AsyncLogger}=nothing,
    io::Base.IO=stdout,
    color::Bool=true,
    emit_console::Bool=true,
    max_differences::Int=25,
)
    normalized_left_keys = _normalize_columns(left_keys, "left_keys")
    normalized_right_keys = _normalize_columns(right_keys, "right_keys")
    length(normalized_left_keys) == length(normalized_right_keys) ||
        throw(ArgumentError("left_keys and right_keys must have the same length."))

    _ensure_columns_exist(left, normalized_left_keys, "Left key")
    _ensure_columns_exist(right, normalized_right_keys, "Right key")

    normalized_targets = _resolve_target_columns(left, right, normalized_left_keys, normalized_right_keys, target_columns)
    _ensure_columns_exist(left, normalized_targets, "Left target")
    _ensure_columns_exist(right, normalized_targets, "Right target")

    left_prepared = _prepare_left(left, normalized_left_keys, normalized_targets)
    right_prepared = _prepare_right(right, normalized_right_keys, normalized_left_keys, normalized_targets)

    joined = outerjoin(
        left_prepared,
        right_prepared;
        on=vcat(normalized_left_keys, Symbol[:__occurrence__]),
        source=:__source__,
    )

    issues = String[]
    columns = Union{Missing,String}[]
    keys = String[]
    left_values = String[]
    right_values = String[]
    details = String[]

    left_only_rows = 0
    right_only_rows = 0
    missing_mismatches = 0
    type_mismatches = 0
    numeric_mismatches = 0
    value_mismatches = 0
    compared_rows = 0
    total_checks = 0
    passed_checks = 0
    failed_checks = 0

    for row in eachrow(joined)
        key_text = _key_text(row, normalized_left_keys)
        source_tag = String(row[:__source__])

        if source_tag == "left_only"
            left_only_rows += 1
            total_checks += 1
            failed_checks += 1
            push!(issues, "left_only_row")
            push!(columns, missing)
            push!(keys, key_text)
            push!(left_values, "present")
            push!(right_values, "missing")
            push!(details, "row exists only in left DataFrame")
            continue
        elseif source_tag == "right_only"
            right_only_rows += 1
            total_checks += 1
            failed_checks += 1
            push!(issues, "right_only_row")
            push!(columns, missing)
            push!(keys, key_text)
            push!(left_values, "missing")
            push!(right_values, "present")
            push!(details, "row exists only in right DataFrame")
            continue
        end

        compared_rows += 1
        for target in normalized_targets
            left_column = Symbol(target, "__left")
            right_column = Symbol(target, "__right")
            left_value = row[left_column]
            right_value = row[right_column]
            total_checks += 1

            if ismissing(left_value) && ismissing(right_value)
                passed_checks += 1
                continue
            elseif ismissing(left_value) ⊻ ismissing(right_value)
                missing_mismatches += 1
                failed_checks += 1
                push!(issues, "missing_mismatch")
                push!(columns, String(target))
                push!(keys, key_text)
                push!(left_values, _value_text(left_value))
                push!(right_values, _value_text(right_value))
                push!(details, "one side is missing")
                continue
            end

            cell_has_failure = false

            if check_type && typeof(left_value) != typeof(right_value)
                type_mismatches += 1
                cell_has_failure = true
                push!(issues, "type_mismatch")
                push!(columns, String(target))
                push!(keys, key_text)
                push!(left_values, _value_text(left_value))
                push!(right_values, _value_text(right_value))
                push!(details, "left_type=$(typeof(left_value)), right_type=$(typeof(right_value))")
            end

            if left_value isa Number && right_value isa Number
                tolerance = _precision_for_column(precision, target)
                if !_numbers_equal(left_value, right_value, tolerance)
                    numeric_mismatches += 1
                    cell_has_failure = true
                    push!(issues, "numeric_mismatch")
                    push!(columns, String(target))
                    push!(keys, key_text)
                    push!(left_values, _value_text(left_value))
                    push!(right_values, _value_text(right_value))
                    push!(details, "abs_diff=$(abs(float(left_value) - float(right_value))), tolerance=$tolerance")
                end
            elseif !isequal(left_value, right_value)
                value_mismatches += 1
                cell_has_failure = true
                push!(issues, "value_mismatch")
                push!(columns, String(target))
                push!(keys, key_text)
                push!(left_values, _value_text(left_value))
                push!(right_values, _value_text(right_value))
                push!(details, "non-numeric values differ")
            end

            if cell_has_failure
                failed_checks += 1
            else
                passed_checks += 1
            end
        end
    end

    differences = DataFrame(
        issue=issues,
        column=columns,
        key=keys,
        left_value=left_values,
        right_value=right_values,
        detail=details,
    )

    result = DataFrameComparisonResult(
        String(title),
        nrow(differences) == 0,
        compared_rows,
        normalized_targets,
        total_checks,
        passed_checks,
        failed_checks,
        left_only_rows,
        right_only_rows,
        missing_mismatches,
        type_mismatches,
        numeric_mismatches,
        value_mismatches,
        differences,
    )

    _render_comparison_report(
        result;
        logger=logger,
        io=io,
        color=color,
        emit_console=emit_console,
        max_differences=max_differences,
    )

    return result
end

function compare_dataframes(
    left::DataFrame,
    right::DataFrame,
    keys,
    target_columns=nothing;
    kwargs...,
)
    return compare_dataframes(left, right, keys, keys, target_columns; kwargs...)
end
