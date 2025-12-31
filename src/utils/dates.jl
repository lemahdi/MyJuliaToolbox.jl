# Date utilities for MyJuliaToolbox

using Dates

export date2int, int2date, days_between

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
