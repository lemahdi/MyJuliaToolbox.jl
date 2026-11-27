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

# MinIO / S3-compatible media backend (AWSS3.jl and AWS.jl, MyJuliaToolbox's own dependencies)
include("io/media_minio.jl")

# Streaming to and from the MinIO backend: multipart writer, ranged reader, formats by object name
include("io/minio_streaming.jl")

end # module IO