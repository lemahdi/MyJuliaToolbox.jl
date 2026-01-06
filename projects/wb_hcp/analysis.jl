# Sandbox for ad-hoc analysis
# Run with `julia src/sandbox/analysis.jl` or include from the REPL

using Dates
using DataFrames
using DataFramesMeta
using Statistics
using MyJuliaToolbox
using Pipe
using Plots
using StatsPlots

# Set up paths relative to this script
const SCRIPT_DIR = @__DIR__
const PLOTS_DIR = joinpath(SCRIPT_DIR, "plots")

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

"""
    plot_indicator_by_region_time(df::DataFrame, indicator, output_dir::String="plots")

Plot a single indicator's value over time with different regions as separate lines.
Saves the plot to the output directory.
"""
function plot_indicator_by_region_time(df::DataFrame, indicator, output_dir::String="plots")
    # Filter data for this indicator
    ind_data = filter(row -> row.INDICATOR == indicator, df)
    
    if nrow(ind_data) == 0
        @warn "No data found for indicator: $indicator"
        return nothing
    end
    
    # Create output directory if it doesn't exist
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    try
        # Determine grouping column (CONTINENT or REF_AREA)
        group_col = :REF_AREA
        if hasproperty(ind_data, :CONTINENT) && "CONTINENT" in names(ind_data)
            group_col = :CONTINENT
        end
        
        # Get unique sex values
        sex_values = unique(skipmissing(ind_data.SEX))
        
        # Create plot
        p = plot(title=string(indicator), xlabel="Time Period", ylabel="Value", 
                 legend=:outerbottom, legendcolumns=4, size=(1400, 800), 
                 bottom_margin=10Plots.mm)
        
        # Plot each region/continent with a different color
        for sex in sex_values
            sex_data = filter(row -> row.SEX == sex, ind_data)
            
            # Group by region and plot
            for region in unique(skipmissing(getproperty(sex_data, group_col)))
                region_data = filter(row -> getproperty(row, group_col) == region, sex_data)
                
                # Sort by time period for proper line plotting
                sort!(region_data, :TIME_PERIOD)
                
                # Remove missing values
                valid_idx = .!ismissing.(region_data.VALUE)
                if any(valid_idx)
                    times = region_data.TIME_PERIOD[valid_idx]
                    values = region_data.VALUE[valid_idx]
                    label = "$(region) - $(sex)"
                    plot!(p, collect(times), collect(values), label=label, alpha=0.7, linewidth=2)
                end
            end
        end
        
        # Save plot
        filename = "$(output_dir)/$(replace(string(indicator), "/" => "_")).png"
        savefig(p, filename)
        return filename
    catch e
        @error "Error plotting indicator: $indicator" exception=(e,)
        return nothing
    end
end

"""
    plot_all_indicators(df::DataFrame, output_dir::String="plots"; max_plots::Int=0)

Plot all indicators in the dataframe. 
If max_plots > 0, only plot that many indicators (useful for large datasets).
Returns count of successfully created plots.
"""
function plot_all_indicators(df::DataFrame, output_dir::String="plots"; max_plots::Int=0)
    indicators = unique(df.INDICATOR)
    n_indicators = length(indicators)
    
    if max_plots > 0
        indicators = first(indicators, min(max_plots, n_indicators))
        n_indicators = length(indicators)
    end
    
    println("Plotting $n_indicators indicators...")
    
    successful = 0
    for (i, indicator) in enumerate(indicators)
        print("\r[$i/$n_indicators] Plotting: $indicator")
        flush(stdout)
        filename = plot_indicator_by_region_time(df, indicator, output_dir)
        if !isnothing(filename)
            successful += 1
        end
    end
    
    println("\n\nSuccessfully created $successful plot(s) in '$output_dir'")
    return successful
end

"""
    get_continent_mapping()

Returns a dictionary mapping country/region codes to continents.
"""
function get_continent_mapping()
    return Dict(
        # Africa
        "DZA" => "Africa", "AGO" => "Africa", "BEN" => "Africa", "BWA" => "Africa", "BFA" => "Africa",
        "BDI" => "Africa", "CMR" => "Africa", "CPV" => "Africa", "CAF" => "Africa", "TCD" => "Africa",
        "COM" => "Africa", "COG" => "Africa", "COD" => "Africa", "CIV" => "Africa", "DJI" => "Africa",
        "EGY" => "Africa", "GNQ" => "Africa", "ERI" => "Africa", "ETH" => "Africa", "GAB" => "Africa",
        "GMB" => "Africa", "GHA" => "Africa", "GIN" => "Africa", "GNB" => "Africa", "KEN" => "Africa",
        "LSO" => "Africa", "LBR" => "Africa", "LBY" => "Africa", "MDG" => "Africa", "MWI" => "Africa",
        "MLI" => "Africa", "MRT" => "Africa", "MUS" => "Africa", "MAR" => "Africa", "MOZ" => "Africa",
        "NAM" => "Africa", "NER" => "Africa", "NGA" => "Africa", "RWA" => "Africa", "STP" => "Africa",
        "SEN" => "Africa", "SYC" => "Africa", "SLE" => "Africa", "SOM" => "Africa", "ZAF" => "Africa",
        "SSD" => "Africa", "SDN" => "Africa", "SWZ" => "Africa", "TZA" => "Africa", "TGO" => "Africa",
        "TUN" => "Africa", "UGA" => "Africa", "ZMB" => "Africa", "ZWE" => "Africa",
        # Asia
        "AFG" => "Asia", "ARM" => "Asia", "AZE" => "Asia", "BHR" => "Asia", "BGD" => "Asia",
        "BTN" => "Asia", "BRN" => "Asia", "KHM" => "Asia", "CHN" => "Asia", "GEO" => "Asia",
        "HKG" => "Asia", "IND" => "Asia", "IDN" => "Asia", "IRN" => "Asia", "IRQ" => "Asia",
        "ISR" => "Asia", "JPN" => "Asia", "JOR" => "Asia", "KAZ" => "Asia", "KWT" => "Asia",
        "KGZ" => "Asia", "LAO" => "Asia", "LBN" => "Asia", "MAC" => "Asia", "MYS" => "Asia",
        "MDV" => "Asia", "MNG" => "Asia", "MMR" => "Asia", "NPL" => "Asia", "PRK" => "Asia",
        "OMN" => "Asia", "PAK" => "Asia", "PHL" => "Asia", "QAT" => "Asia", "SAU" => "Asia",
        "SGP" => "Asia", "KOR" => "Asia", "LKA" => "Asia", "SYR" => "Asia", "TWN" => "Asia",
        "TJK" => "Asia", "THA" => "Asia", "TLS" => "Asia", "TUR" => "Asia", "TKM" => "Asia",
        "ARE" => "Asia", "UZB" => "Asia", "VNM" => "Asia", "YEM" => "Asia",
        # Europe
        "ALB" => "Europe", "AND" => "Europe", "AUT" => "Europe", "BLR" => "Europe", "BEL" => "Europe",
        "BIH" => "Europe", "BGR" => "Europe", "HRV" => "Europe", "CYP" => "Europe", "CZE" => "Europe",
        "DNK" => "Europe", "EST" => "Europe", "FIN" => "Europe", "FRA" => "Europe", "DEU" => "Europe",
        "GRC" => "Europe", "HUN" => "Europe", "ISL" => "Europe", "IRL" => "Europe", "ITA" => "Europe",
        "XKX" => "Europe", "LVA" => "Europe", "LIE" => "Europe", "LTU" => "Europe", "LUX" => "Europe",
        "MKD" => "Europe", "MLT" => "Europe", "MDA" => "Europe", "MCO" => "Europe", "MNE" => "Europe",
        "NLD" => "Europe", "NOR" => "Europe", "POL" => "Europe", "PRT" => "Europe", "ROU" => "Europe",
        "RUS" => "Europe", "SMR" => "Europe", "SRB" => "Europe", "SVK" => "Europe", "SVN" => "Europe",
        "ESP" => "Europe", "SWE" => "Europe", "CHE" => "Europe", "UKR" => "Europe", "GBR" => "Europe",
        # North America
        "ATG" => "North America", "BHS" => "North America", "BRB" => "North America", "BLZ" => "North America",
        "CAN" => "North America", "CRI" => "North America", "CUB" => "North America", "DMA" => "North America",
        "DOM" => "North America", "SLV" => "North America", "GRD" => "North America", "GTM" => "North America",
        "HTI" => "North America", "HND" => "North America", "JAM" => "North America", "MEX" => "North America",
        "NIC" => "North America", "PAN" => "North America", "KNA" => "North America", "LCA" => "North America",
        "VCT" => "North America", "TTO" => "North America", "USA" => "North America",
        # South America
        "ARG" => "South America", "BOL" => "South America", "BRA" => "South America", "CHL" => "South America",
        "COL" => "South America", "ECU" => "South America", "GUY" => "South America", "PRY" => "South America",
        "PER" => "South America", "SUR" => "South America", "URY" => "South America", "VEN" => "South America",
        # Oceania
        "AUS" => "Oceania", "FJI" => "Oceania", "KIR" => "Oceania", "MHL" => "Oceania",
        "FSM" => "Oceania", "NRU" => "Oceania", "NZL" => "Oceania", "PLW" => "Oceania",
        "PNG" => "Oceania", "WSM" => "Oceania", "SLB" => "Oceania", "TON" => "Oceania", "TUV" => "Oceania", "VUT" => "Oceania"
    )
end

if (abspath(PROGRAM_FILE) == @__FILE__) || isinteractive()
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
        # Save the full dataframe with INDICATOR before removing columns (needed for plotting)
        wb_hcp_df_full = @pipe wb_hcp_df |>
            @select(_, :REF_AREA, :INDICATOR, :SEX, :UNIT_MEASURE, :TIME_PERIOD, :OBS_VALUE, :DECIMALS, :UNIT_MULT, :UNIT_TYPE) |>
            @transform(_, :VALUE = :OBS_VALUE .* (10.0 .^ :UNIT_MULT))
        
        # Create the cleaned dataframe without label columns
        wb_hcp_df = @pipe wb_hcp_df |>
            @select(_, :REF_AREA, :INDICATOR, :SEX, :UNIT_MEASURE, :TIME_PERIOD, :OBS_VALUE, :DECIMALS, :UNIT_MULT, :UNIT_TYPE) |>
            @transform(_, :VALUE = :OBS_VALUE .* (10.0 .^ :UNIT_MULT))
        println("\nRemoved label columns and created VALUE column: OBS_VALUE * 10^UNIT_MULT")
        
        describe_df(wb_hcp_df)
        
        # Create pivoted dataframe with INDICATOR as columns
        println("\n\nCreating pivoted dataframe with indicators as columns...")
        wb_hcp_wide = @pipe wb_hcp_df |>
            @select(_, :REF_AREA, :INDICATOR, :SEX, :TIME_PERIOD, :VALUE) |>
            unstack(_, :INDICATOR, :VALUE)
        println("Pivoted dataframe: $(nrow(wb_hcp_wide)) rows × $(ncol(wb_hcp_wide)) columns")
        println("\nFirst 5 rows of pivoted data:")
        show(first(wb_hcp_wide, 5))
        
        # Create visualizations
        println("\n\n=== Creating Indicator Visualizations ===")
        # Plot all indicators
        plot_all_indicators(wb_hcp_df_full, PLOTS_DIR; max_plots=0)
        println("\nTip: To plot all indicators, run: plot_all_indicators(wb_hcp_df_full, \"$(PLOTS_DIR)\")")
        println("Tip: To plot a specific indicator, run: plot_indicator_by_region_time(wb_hcp_df_full, \"WB_HCP_INDICATOR_NAME\", \"$(PLOTS_DIR)\")")
    else
        println("No data loaded from $WB_CSV_PATH")
    end
end
