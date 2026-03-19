# IO submodule for MyJuliaToolbox

module IO

# Include dataframes helpers (read/write DataFrame and factory functions)
include("io/dataframes.jl")

# Include media interface for reading from files or databases
include("io/media.jl")

# Include asynchronous logger with iSourceMedia sinks
include("io/logger.jl")

# Include read_dataframe extensions for iSourceMedia types
include("io/media_dataframes.jl")

# MinIO / S3-compatible media backend (optional — requires AWSS3.jl + AWS.jl)
include("io/media_minio.jl")

end # module IO