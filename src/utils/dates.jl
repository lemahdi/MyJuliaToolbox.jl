# Date utilities for MyJuliaToolbox

using Dates

export date2int, int2date

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
