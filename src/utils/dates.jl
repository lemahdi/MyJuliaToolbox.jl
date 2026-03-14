# Date utilities for MyJuliaToolbox

using Dates
using DataFrames

export date2int, int2date, days_between, yearfrac, add_days_convention

"""
    date2int(d::Date) -> Int

Return an integer in the form `yyyymmdd` for the given `Date`.
Example: `Date(2025, 12, 31)` -> `20251231`.
"""
function date2int(d::Date)::Int
    y = year(d)
    m = month(d)
    dd = day(d)
    return y * 10000 + m * 100 + dd
end

"""
    int2date(i::Integer) -> Date

Convert an integer of the form `yyyymmdd` into a `Date`.
Example: `20251231` -> `Date(2025, 12, 31)`.
"""
function int2date(i::Integer)::Date
    y = i ÷ 10000
    m = (i ÷ 100) % 100
    d = i % 100
    return Date(y, m, d)
end

"""
    days_between(i1::Integer, i2::Integer) -> Int

Return the signed number of days from `i1` to `i2`, where `i1` and `i2` are integers
of the form `yyyymmdd`. Example: `days_between(20250101, 20250103) == 2` and
`days_between(20250103, 20250101) == -2`.
"""
function days_between(i1::Integer, i2::Integer)::Int
    d1 = int2date(i1)
    d2 = int2date(i2)
    return Dates.value(d2 - d1)
end

"""
    yearfrac(i1::Integer, i2::Integer; basis=:actual365) -> Float64

Compute the year fraction between two integer dates (`yyyymmdd`) according to `basis`:
- `:actual365` (default): days / 365
- `:actual365_25`: days / 365.25
- `:actual360`: days / 360
- `:actual`: days / 365.2425 (approx. Gregorian mean)

Returns a signed floating-point year fraction (positive if `i2 > i1`).
"""
function _days_30_360_us(d1::Date, d2::Date)::Int
    # 30/360 US (NASD) convention
    y1, m1, day1 = year(d1), month(d1), day(d1)
    y2, m2, day2 = year(d2), month(d2), day(d2)

    d1p = day1 == 31 ? 30 : day1
    if day2 == 31 && d1p == 30
        d2p = 30
    else
        d2p = min(day2, 30)
    end

    return 360 * (y2 - y1) + 30 * (m2 - m1) + (d2p - d1p)
end

function _days_30_360_eu(d1::Date, d2::Date)::Int
    # 30E/360 (European) convention: any 31st day becomes 30
    y1, m1, day1 = year(d1), month(d1), day(d1)
    y2, m2, day2 = year(d2), month(d2), day(d2)

    d1p = min(day1, 30)
    d2p = min(day2, 30)

    return 360 * (y2 - y1) + 30 * (m2 - m1) + (d2p - d1p)
end

function _days_30_360_isda(d1::Date, d2::Date)::Int
    # ISDA variant approximate implementation: align with US/NASD rules for simplicity
    # Note: ISDA has subtle rules around end-of-February; this uses US rules as a practical approximation.
    return _days_30_360_us(d1, d2)
end

function yearfrac(i1::Integer, i2::Integer; basis::Symbol = :actual365)::Float64
    d1 = int2date(i1)
    d2 = int2date(i2)
    days = Dates.value(d2 - d1)

    if basis == :actual365
        return days / 365
    elseif basis == :actual365_25
        return days / 365.25
    elseif basis == :actual360
        return days / 360
    elseif basis == :actual
        return days / 365.2425
    elseif basis == :thirty360 || basis == Symbol("30/360") || basis == Symbol("30_360")
        return _days_30_360_us(d1, d2) / 360
    elseif basis == :thirty360_eu || basis == Symbol("30E/360")
        return _days_30_360_eu(d1, d2) / 360
    elseif basis == :thirty360_isda
        return _days_30_360_isda(d1, d2) / 360
    else
        throw(ErrorException("Unknown basis: $basis"))
    end
end

# helper: robust conversion to Date
function _to_date(x)
    if x isa Date
        return x
    elseif x isa Integer
        return int2date(x)
    elseif x isa AbstractString
        try
            return Date(x)
        catch
            throw(ErrorException("Cannot parse string to Date: $x"))
        end
    else
        try
            return Date(x)
        catch
            throw(ErrorException("Cannot convert value of type $(typeof(x)) to Date"))
        end
    end
end
function _is_business_day(d::Date, weekends::AbstractVector{Int}, calendar::AbstractSet{Date}, calendar_is_business::Bool)::Bool
    # `calendar_is_business == true` means `calendar` lists business days (membership => business)
    # otherwise `calendar` lists holidays (membership => non-business)
    wd = dayofweek(d) # 1=Mon .. 7=Sun
    if wd in weekends
        return false
    end
    if calendar_is_business
        return d in calendar
    else
        return !(d in calendar)
    end
end

function _adjust_following(d::Date, weekends::AbstractVector{Int}, calendar::AbstractSet{Date}, calendar_is_business::Bool)::Date
    dd = d
    while !_is_business_day(dd, weekends, calendar, calendar_is_business)
        dd += Day(1)
    end
    return dd
end

function _adjust_previous(d::Date, weekends::AbstractVector{Int}, calendar::AbstractSet{Date}, calendar_is_business::Bool)::Date
    dd = d
    while !_is_business_day(dd, weekends, calendar, calendar_is_business)
        dd -= Day(1)
    end
    return dd
end

"""
    add_days_convention(d::Date, delta::Integer; convention::Symbol=:following, weekends=[6,7], holidays=Date[])

Add `delta` calendar days to `d` and adjust the resulting date according to `convention`.
Supported conventions: `:following`, `:modified_following`, `:previous`, `:modified_previous`.
- `:following`: move forward to the next business day
- `:modified_following`: following, unless it moves to the next month, then use previous business day
- `:previous`: move backward to the previous business day
- `:modified_previous`: previous, unless it moves to the previous month, then use following business day

`weekends` expects an array of integer weekday numbers (1=Mon .. 7=Sun), default `[6,7]`.
`holidays` is an array of `Date`s to treat as non-business days.
"""
function add_days_convention(d::Date, delta::Integer; convention::Symbol=:following, weekends::AbstractVector{Int} = [6,7], holidays=Date[])::Date
    # Normalize `holidays` which can be:
    # - a Vector{Date} listing holidays (membership => non-business)
    # - a Set{Date} listing holidays
    # - a DataFrame with a `:ref_dt` column that *lists business days* (membership => business)
    calendar_is_business = false
    calset = Set{Date}()

    if holidays isa DataFrame
        # try symbol column name first, then string name for robustness
        if :ref_dt in names(holidays)
            col = holidays[!, :ref_dt]
        elseif "ref_dt" in names(holidays)
            col = holidays[!, "ref_dt"]
        else
            throw(ArgumentError("calendar DataFrame must contain a :ref_dt column of Date or integer yyyymmdd values"))
        end
        for r in col
            push!(calset, _to_date(r))
        end
        calendar_is_business = true
    elseif holidays === Date[] || (isa(holidays, AbstractVector) && isempty(holidays))
        calset = Set{Date}()
        calendar_is_business = false
    else
        # holidays may be a Vector/Set/Iterable of integers or Dates
        try
            for r in holidays
                push!(calset, _to_date(r))
            end
            calendar_is_business = false
        catch
            throw(ArgumentError("Unsupported holidays type: $(typeof(holidays)). Expect Vector/Set of Date or integer yyyymmdd, or DataFrame with :ref_dt."))
        end
    end

    unadjusted = d + Day(delta)

    if convention == :following
        return _adjust_following(unadjusted, weekends, calset, calendar_is_business)
    elseif convention == :modified_following
        adj = _adjust_following(unadjusted, weekends, calset, calendar_is_business)
        if month(adj) != month(unadjusted)
            return _adjust_previous(unadjusted, weekends, calset, calendar_is_business)
        else
            return adj
        end
    elseif convention == :previous || convention == :preceding
        return _adjust_previous(unadjusted, weekends, calset, calendar_is_business)
    elseif convention == :modified_previous || convention == :modified_preceding
        adj = _adjust_previous(unadjusted, weekends, calset, calendar_is_business)
        if month(adj) != month(unadjusted)
            return _adjust_following(unadjusted, weekends, calset, calendar_is_business)
        else
            return adj
        end
    else
        throw(ArgumentError("Unsupported convention: $convention. Supported: :following, :modified_following, :previous, :modified_previous"))
    end
end

# end of file
