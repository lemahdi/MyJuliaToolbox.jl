# Date utilities for MyJuliaToolbox

using Dates

export date2int, int2date, days_between, yearfrac

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
    if basis in (:thirty360, Symbol("30/360"), Symbol("30_360"), :thirty360_us, :thirty360_nasd, :thirty360_us_nasd)
        d1 = int2date(i1)
        d2 = int2date(i2)
        days = _days_30_360_us(d1, d2)
        return days / 360.0
    elseif basis in (:thirty360_eu, Symbol("30E/360"), Symbol("30_E_360"), Symbol("30_360_eu"))
        d1 = int2date(i1)
        d2 = int2date(i2)
        days = _days_30_360_eu(d1, d2)
        return days / 360.0
    elseif basis == :thirty360_isda || basis == Symbol("30_360_isda")
        d1 = int2date(i1)
        d2 = int2date(i2)
        days = _days_30_360_isda(d1, d2)
        return days / 360.0
    end

    days = days_between(i1, i2)
    if basis == :actual365
        return days / 365.0
    elseif basis == :actual365_25
        return days / 365.25
    elseif basis == :actual360
        return days / 360.0
    elseif basis == :actual
        return days / 365.2425
    else
        error("Unsupported basis: $basis. Supported: :actual365, :actual365_25, :actual360, :actual, :thirty360 (or :30_360 / :'30/360')")
    end
end
