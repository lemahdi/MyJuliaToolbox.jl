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
function _days_30_360(d1::Date, d2::Date)::Int
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

function yearfrac(i1::Integer, i2::Integer; basis::Symbol = :actual365)::Float64
    if basis in (:thirty360, Symbol("30/360"), Symbol("30_360"))
        d1 = int2date(i1)
        d2 = int2date(i2)
        days = _days_30_360(d1, d2)
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
