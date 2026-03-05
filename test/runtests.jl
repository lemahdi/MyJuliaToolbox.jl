using MyJuliaToolbox
using Test

include("io/csv-tests.jl")
include("io/arrow-tests.jl")
include("io/factory-tests.jl")
include("io/media-tests.jl")
include("io/sqldump-tests.jl")
include("io/logger-tests.jl")
include("io/dataset-tests.jl")

# utils tests
include("utils/dates-tests.jl")

# parameters tests
include("parameters/parameters-tests.jl")

