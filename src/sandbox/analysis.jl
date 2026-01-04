# Sandbox for ad-hoc analysis
# Run with `julia src/sandbox/analysis.jl` or include from the REPL

using Dates
using DataFrames
using DataFramesMeta
using Statistics
using MyJuliaToolbox
using Pipe

# Example helper that uses MyJuliaToolbox if available
function example_shift(d::Date = Date(2025,12,31))
    try
        return add_days_convention(d, 1)
    catch e
        @warn "add_days_convention not available, returning unadjusted date+1" exception=(e,)
        return d + Day(1)
    end
end

const WB_CSV_PATH = raw"C:\Users\mahdi\Downloads\WB_HCP.csv"

"""Load the World Bank HCP CSV at `path` using `read_dataframe`.
If the file is missing, warn and return an empty DataFrame.
"""
function load_wb_hcp(path::AbstractString = WB_CSV_PATH)
    if isfile(path)
        try
            df = read_dataframe(path)
            println("Loaded $(nrow(df)) rows and $(ncol(df)) columns from: $path")
            return df
        catch e
            @error "Failed to read with read_dataframe" exception=(e,)
            rethrow(e)
        end
    else
        @warn "CSV file not found" path=path
        return DataFrame()
    end
end

# Detect and remove constant columns
"""remove_constant_columns(df; inplace=false)
Detect columns whose non-missing values are constant (1 unique value) or entirely missing.
Prints the columns and their representative value and returns a tuple `(df_pruned, removed_dict)`.
If `inplace=true`, modifies `df` in-place and returns it.
"""
function remove_constant_columns(df::DataFrame; inplace::Bool=false)
    removed = Dict{Symbol, Any}()
    for nm in names(df)
        col = df[!, nm]
        nm_sym = nm isa Symbol ? nm : Symbol(nm)
        uniq = collect(unique(skipmissing(col)))
        if length(uniq) == 1
            removed[nm_sym] = uniq[1]
        elseif length(uniq) == 0
            # column entirely missing
            removed[nm_sym] = missing
        end
    end

    if isempty(removed)
        println("No constant columns found.")
        return df, removed
    end

    println("Removing $(length(removed)) constant columns:")
    for (k, v) in removed
        println(" - $(k) = $(v)")
    end

    if inplace
        select!(df, Not(collect(keys(removed))))
        return df, removed
    else
        keep_sym = setdiff(Symbol.(names(df)), collect(keys(removed)))
        # preserve original column order
        keep = [s for s in names(df) if Symbol(s) in keep_sym]
        return df[:, keep], removed
    end
end

# Describe a DataFrame succinctly for quick inspection
function _col_stats(col)
    T = eltype(col)
    nmiss = count(ismissing, col)
    nn = length(col) - nmiss
    if T <: Number && nn > 0
        vals = skipmissing(col)
        return Dict(
            :type=>T,
            :nmissing=>nmiss,
            :count=>nn,
            :mean=>mean(vals),
            :min=>minimum(vals),
            :median=>median(collect(vals)),
            :max=>maximum(vals)
        )
    else
        # categorical or all-missing
        uniq = length(unique(skipmissing(col)))
        top = try
            first(sort(collect(freqtable(skipmissing(col))), by=x->-x[2])[1])[1]
        catch
            missing
        end
        return Dict(:type=>T, :nmissing=>nmiss, :count=>nn, :unique=>uniq, :top=>top)
    end
end

function describe_df(df::DataFrame; n::Integer=5)
    println("Rows: $(nrow(df)), Columns: $(ncol(df))")

    println("\nColumn summary:")
    names_ = names(df)
    types = map(eltype, eachcol(df))
    for (nm, tp) in zip(names_, types)
        col = df[!, nm]
        nmiss = count(ismissing, col)
        print(" - $(nm) :: $(tp) | missing=$(nmiss)")
        if tp <: Number
            nnonmissing = count(x->!ismissing(x), col)
            if nnonmissing > 0
                vals = skipmissing(col)
                print(" | mean=$(mean(vals)), min=$(minimum(vals)), median=$(median(collect(vals))), max=$(maximum(vals))")
            end
        else
            # show top and unique counts
            uniq = length(unique(skipmissing(col)))
            # compute modal value without external deps
            counts = Dict{Any, Int}()
            for v in skipmissing(col)
                counts[v] = get(counts, v, 0) + 1
            end
            top = isempty(counts) ? missing : begin
                bestk = first(keys(counts))
                bestv = counts[bestk]
                for (k,v) in counts
                    if v > bestv
                        bestk = k
                        bestv = v
                    end
                end
                bestk
            end
            print(" | unique=$(uniq), top=$(top)")
        end
        println()
    end

    println("\nSummary (describe):")
    show(describe(df); allrows=false, allcols=false)

    println("\nFirst $(min(n, nrow(df))) rows:")
    show(first(df, min(n, nrow(df))))
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Example shift (following +1): ", example_shift())

    # Attempt to load the WB CSV
    wb_hcp_df = load_wb_hcp()
    if nrow(wb_hcp_df) > 0
        wb_hcp_df, removed = remove_constant_columns(wb_hcp_df)
        if !isempty(removed)
            println("Removed columns: ", join(string.(keys(removed)), ", "))
        end
        
        # Create indicator_df with unique INDICATOR and INDICATOR_LABEL combinations before removing column
        println("\n\nCreating unique indicators dataframe...")
        indicator_df = @pipe wb_hcp_df |> @select(_, :INDICATOR, :INDICATOR_LABEL) |> unique(_)
        println("Unique indicators: $(nrow(indicator_df))")
        println("\nFirst 10 unique indicators:")
        show(first(indicator_df, 10))
        
        # Create ref_area_df with unique REF_AREA and REF_AREA_LABEL combinations before removing column
        println("\n\nCreating unique reference areas dataframe...")
        ref_area_df = @pipe wb_hcp_df |> @select(_, :REF_AREA, :REF_AREA_LABEL) |> unique(_)
        println("Unique reference areas: $(nrow(ref_area_df))")
        println("\nFirst 10 unique reference areas:")
        show(first(ref_area_df, 10))
        
        # Create sex_df with unique SEX and SEX_LABEL combinations before removing column
        println("\n\nCreating unique sex categories dataframe...")
        sex_df = @pipe wb_hcp_df |> @select(_, :SEX, :SEX_LABEL) |> unique(_)
        println("Unique sex categories: $(nrow(sex_df))")
        println("\nSex categories:")
        show(sex_df)
        
        # Create unit_measure_df with unique UNIT_MEASURE and UNIT_MEASURE_LABEL combinations before removing column
        println("\n\nCreating unique unit measures dataframe...")
        unit_measure_df = @pipe wb_hcp_df |> @select(_, :UNIT_MEASURE, :UNIT_MEASURE_LABEL) |> unique(_)
        println("Unique unit measures: $(nrow(unit_measure_df))")
        println("\nUnit measures:")
        show(unit_measure_df)
        
        # Create unit_type_df with unique UNIT_TYPE and UNIT_TYPE_LABEL combinations before removing column
        println("\n\nCreating unique unit types dataframe...")
        unit_type_df = @pipe wb_hcp_df |> @select(_, :UNIT_TYPE, :UNIT_TYPE_LABEL) |> unique(_)
        println("Unique unit types: $(nrow(unit_type_df))")
        println("\nUnit types:")
        show(unit_type_df)
        
        # Create unit_mult_df with unique UNIT_MULT and UNIT_MULT_LABEL combinations before removing column
        println("\n\nCreating unique unit multipliers dataframe...")
        unit_mult_df = @pipe wb_hcp_df |> @select(_, :UNIT_MULT, :UNIT_MULT_LABEL) |> unique(_)
        println("Unique unit multipliers: $(nrow(unit_mult_df))")
        println("\nUnit multipliers:")
        show(unit_mult_df)
        
        # Remove label columns from main dataframe and create VALUE column
        wb_hcp_df = @pipe wb_hcp_df |>
            @select(_, Not([:INDICATOR_LABEL, :REF_AREA_LABEL, :SEX_LABEL, :UNIT_MEASURE_LABEL, :DECIMALS_LABEL, :UNIT_TYPE_LABEL, :UNIT_MULT_LABEL])) |>
            @transform(_, :VALUE = :OBS_VALUE .* (10.0 .^ :UNIT_MULT))
        println("\nRemoved label columns and created VALUE column: OBS_VALUE * 10^UNIT_MULT")
        
        describe_df(wb_hcp_df)
    else
        println("No data loaded from $WB_CSV_PATH")
    end
end
