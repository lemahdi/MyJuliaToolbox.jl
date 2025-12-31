# Sandbox for ad-hoc analysis
# Run with `julia src/sandbox/analysis.jl` or include from the REPL

using Dates
using DataFrames
using MyJuliaToolbox

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

# Describe a DataFrame succinctly for quick inspection
function describe_df(df::DataFrame; n::Integer=5)
    println("Rows: $(nrow(df)), Columns: $(ncol(df))")
    println("Column types and missing counts:")
    for (nm, tp) in zip(names(df), eltypes(df))
        miss = count(ismissing, df[!, nm])
        println(" - $(nm) :: $(tp) | missing=$(miss)")
    end

    println("\nSummary (describe):")
    show(describe(df); allrows=false, allcols=false)

    println("\nFirst $(min(n, nrow(df))) rows:")
    show(first(df, min(n, nrow(df))))
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Example shift (following +1): ", example_shift())

    # Attempt to load the WB CSV
    df = load_wb_hcp()
    if nrow(df) > 0
        describe_df(df)
    else
        println("No data loaded from $WB_CSV_PATH")
    end
end
