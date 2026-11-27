using MyJuliaToolbox
using Test

include("io/csv-tests.jl")
include("io/arrow-tests.jl")
include("io/factory-tests.jl")
include("io/media-tests.jl")
include("io/sqldump-tests.jl")
include("io/logger-tests.jl")
include("io/dataset-tests.jl")
include("io/minio-tests.jl")
include("io/minio-streaming-tests.jl")

# utils tests
include("utils/dates-tests.jl")
include("utils/dataframe-compare-tests.jl")

# parameters tests
include("parameters/parameters-tests.jl")

