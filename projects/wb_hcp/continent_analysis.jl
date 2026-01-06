# Continent-level analysis for World Bank HCP data
using DataFrames, DataFramesMeta, Pipe, Plots, Statistics, MyJuliaToolbox

# Set up paths relative to this script
const SCRIPT_DIR = @__DIR__
const PLOTS_DIR = joinpath(SCRIPT_DIR, "plots", "continent")

println("Loading data...")
wb_hcp_df = read_dataframe(raw"C:\Users\mahdi\Downloads\WB_HCP.csv")
println("Loaded $(nrow(wb_hcp_df)) rows × $(ncol(wb_hcp_df)) columns")

# Remove constant columns
println("\nRemoving constant columns...")
constant_cols = [:COMP_BREAKDOWN_2_LABEL, :DATABASE_ID_LABEL, :STRUCTURE_ID, :OBS_STATUS, :STRUCTURE, :AGE_LABEL, :URBANISATION_LABEL, :TIME_FORMAT, :COMP_BREAKDOWN_3_LABEL, :URBANISATION, :TIME_FORMAT_LABEL, :COMP_BREAKDOWN_1_LABEL, :AGE, :OBS_STATUS_LABEL, :DATABASE_ID, :COMP_BREAKDOWN_3, :COMP_BREAKDOWN_2, :FREQ_LABEL, :FREQ, :COMP_BREAKDOWN_1, :ACTION]
wb_hcp_df = @select(wb_hcp_df, Not(constant_cols))

# Keep only necessary columns and add VALUE
println("Processing data...")
wb_hcp_df = @pipe wb_hcp_df |>
    @select(_, :REF_AREA, :INDICATOR, :SEX, :TIME_PERIOD, :OBS_VALUE, :UNIT_MULT) |>
    @transform(_, :VALUE = :OBS_VALUE .* (10.0 .^ :UNIT_MULT))

println("Processed: $(nrow(wb_hcp_df)) rows × $(ncol(wb_hcp_df)) columns")

# Continent mapping
println("\nMapping countries to continents...")
continent_map = Dict(
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

wb_hcp_df[!, :CONTINENT] = map(ref_area -> get(continent_map, string(ref_area), "Other"), wb_hcp_df.REF_AREA)

# Aggregate by continent
println("Aggregating by continent...")
continent_agg = @pipe wb_hcp_df |>
    @select(_, :CONTINENT, :INDICATOR, :SEX, :TIME_PERIOD, :VALUE) |>
    groupby(_, [:CONTINENT, :INDICATOR, :SEX, :TIME_PERIOD]) |>
    combine(_, :VALUE => mean => :VALUE)

println("Continent aggregation complete: $(nrow(continent_agg)) rows")
println("Continents: ", unique(continent_agg.CONTINENT))

# Plot function
function plot_continent_indicator(df, indicator, output_dir=PLOTS_DIR)
    ind_data = filter(row -> row.INDICATOR == indicator, df)
    
    if nrow(ind_data) == 0
        @warn "No data for $indicator"
        return nothing
    end
    
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    
    try
        sex_values = unique(skipmissing(ind_data.SEX))
        p = plot(title=string(indicator), xlabel="Time Period", ylabel="Average Value", 
                 legend=:outerbottom, legendcolumns=4, size=(1400, 800), 
                 bottom_margin=10Plots.mm)
        
        for sex in sex_values
            sex_data = filter(row -> row.SEX == sex, ind_data)
            
            for continent in unique(skipmissing(sex_data.CONTINENT))
                cont_data = filter(row -> row.CONTINENT == continent, sex_data)
                sort!(cont_data, :TIME_PERIOD)
                
                valid_idx = .!ismissing.(cont_data.VALUE)
                if any(valid_idx)
                    times = cont_data.TIME_PERIOD[valid_idx]
                    values = cont_data.VALUE[valid_idx]
                    label = "$(continent) - $(sex)"
                    plot!(p, collect(times), collect(values), label=label, alpha=0.7, linewidth=3, marker=:circle)
                end
            end
        end
        
        filename = "$(output_dir)/$(replace(string(indicator), "/" => "_")).png"
        savefig(p, filename)
        println("✓ Saved: $filename")
        return filename
    catch e
        @error "Error plotting $indicator" exception=(e,)
        return nothing
    end
end

# Plot first 10 indicators
println("\nPlotting first 10 indicators by continent...")
indicators = unique(continent_agg.INDICATOR)
for (i, indicator) in enumerate(first(indicators, 10))
    print("[$i/10] $indicator... ")
    plot_continent_indicator(continent_agg, indicator)
end

println("\n\n✅ Complete! Continent plots saved to plots/continent/")
