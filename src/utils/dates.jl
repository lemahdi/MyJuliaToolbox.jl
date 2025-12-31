# Date utilities for MyJuliaToolbox

using Dates

export date_to_yyyymmdd

"""
    date_to_yyyymmdd(d::Date) -> Int

Return an integer in the form `yyyymmdd` for the given `Date`.
Example: `Date(2025, 12, 31)` -> `20251231`.
"""
function date_to_yyyymmdd(d::Date)::Int
    y = year(d)
    m = month(d)
    dd = day(d)
    return y * 10000 + m * 100 + dd
end
