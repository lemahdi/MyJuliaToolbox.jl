using Dates
using SQLite

export LogRecord, AsyncLogger, log!, log_debug!, log_info!, log_warn!, log_error!, flush_logger!, stop_logger!, dropped_logs

const _LOG_LEVEL_PRIORITY = Dict(
    :debug => 10,
    :info => 20,
    :warn => 30,
    :error => 40,
)

const _LOG_LEVEL_ANSI_COLOR = Dict(
    :debug => "\e[90m", # bright black / gray
    :info => "\e[36m",  # cyan
    :warn => "\e[33m",  # yellow
    :error => "\e[31m", # red
)

const _ANSI_RESET = "\e[0m"

"""
    LogRecord

Lightweight log payload used by `AsyncLogger` workers.
"""
struct LogRecord
    timestamp::DateTime
    level::Symbol
    message::String
    metadata::Any
end

mutable struct _LogRingBuffer
    buffer::Vector{Union{Nothing,LogRecord}}
    head::Int
    tail::Int
    count::Int
    dropped::Int
    closed::Bool
    lock::ReentrantLock
    has_data::Threads.Condition
end

function _LogRingBuffer(capacity::Int)
    capacity > 0 || throw(ArgumentError("capacity must be > 0"))
    lock = ReentrantLock()
    return _LogRingBuffer(
        fill(nothing, capacity),
        1,
        1,
        0,
        0,
        false,
        lock,
        Threads.Condition(lock),
    )
end

function _enqueue!(queue::_LogRingBuffer, record::LogRecord)
    lock(queue.lock)
    try
        if queue.closed
            return false
        end
        if queue.count == length(queue.buffer)
            queue.dropped += 1
            return false
        end

        queue.buffer[queue.tail] = record
        queue.tail = (queue.tail == length(queue.buffer)) ? 1 : (queue.tail + 1)
        queue.count += 1
        notify(queue.has_data)
        return true
    finally
        unlock(queue.lock)
    end
end

function _dequeue!(queue::_LogRingBuffer)
    lock(queue.lock)
    try
        while queue.count == 0 && !queue.closed
            wait(queue.has_data)
        end

        if queue.count == 0 && queue.closed
            return nothing
        end

        record = queue.buffer[queue.head]
        queue.buffer[queue.head] = nothing
        queue.head = (queue.head == length(queue.buffer)) ? 1 : (queue.head + 1)
        queue.count -= 1
        return record
    finally
        unlock(queue.lock)
    end
end

function _close_queue!(queue::_LogRingBuffer)
    lock(queue.lock)
    try
        queue.closed = true
        notify(queue.has_data; all=true)
    finally
        unlock(queue.lock)
    end
    return nothing
end

function _count(queue::_LogRingBuffer)
    lock(queue.lock)
    try
        return queue.count
    finally
        unlock(queue.lock)
    end
end

function _dropped(queue::_LogRingBuffer)
    lock(queue.lock)
    try
        return queue.dropped
    finally
        unlock(queue.lock)
    end
end

"""
    AsyncLogger(source::iSourceMedia; min_level::Symbol=:info, capacity::Int=1024, sink_kwargs...)

Asynchronous logger that queues records in-memory and writes them from a background task,
so main execution paths are not blocked by sink IO.

# Arguments
- `source::iSourceMedia`: Destination sink (e.g. `FileSystemMedia`, `DatabaseMedia`, `ConsoleMedia`)
- `min_level::Symbol`: Minimum accepted level (`:debug`, `:info`, `:warn`, `:error`)
- `capacity::Int`: Ring buffer size. When full, new logs are dropped.
- `sink_kwargs...`: Additional sink-specific options (e.g. `table="logs"` for `DatabaseMedia`)
"""
mutable struct AsyncLogger
    source::iSourceMedia
    min_level::Symbol
    sink_kwargs::NamedTuple
    queue::_LogRingBuffer
    worker::Task
end

function _should_log(min_level::Symbol, level::Symbol)
    min_priority = get(_LOG_LEVEL_PRIORITY, min_level, nothing)
    level_priority = get(_LOG_LEVEL_PRIORITY, level, nothing)
    if isnothing(min_priority)
        throw(ArgumentError("Unsupported min_level: $min_level. Supported: :debug, :info, :warn, :error"))
    end
    if isnothing(level_priority)
        throw(ArgumentError("Unsupported log level: $level. Supported: :debug, :info, :warn, :error"))
    end
    return level_priority >= min_priority
end

function _format_record(record::LogRecord; color::Bool=false)
    ts = Dates.format(record.timestamp, dateformat"yyyy-mm-ddTHH:MM:SS.s")
    level_text = "[" * uppercase(String(record.level)) * "]"
    level = if color
        color_code = get(_LOG_LEVEL_ANSI_COLOR, record.level, "")
        isempty(color_code) ? level_text : string(color_code, level_text, _ANSI_RESET)
    else
        level_text
    end
    meta = isnothing(record.metadata) ? "" : " | metadata=$(record.metadata)"
    return "[$ts] $level $(record.message)$(meta)"
end

function _metadata_to_string(metadata)
    return isnothing(metadata) ? "" : string(metadata)
end

function _validated_sql_identifier(identifier::String; field::String="identifier")
    if match(r"^[A-Za-z_][A-Za-z0-9_]*$", identifier) === nothing
        throw(ArgumentError("Invalid $field '$identifier'. Use only letters, digits, and underscore."))
    end
    return identifier
end

function write_log_record(source::FileSystemMedia, record::LogRecord; kwargs...)
    path = source.path
    dir = dirname(path)
    if !isempty(dir)
        mkpath(dir)
    end
    open(path, "a") do io
        println(io, _format_record(record))
    end
    return nothing
end

function write_log_record(source::ConsoleMedia, record::LogRecord; kwargs...)
    color = get(kwargs, :color, true)
    println(source.stream, _format_record(record; color=color))
    flush(source.stream)
    return nothing
end

function write_log_record(source::DatabaseMedia, record::LogRecord; table::String="logs", kwargs...)
    safe_table = _validated_sql_identifier(table; field="table name")

    _with_database_connection(source) do conn
        if !(conn isa SQLite.DB)
            throw(ArgumentError("Database logging currently supports only SQLite connections"))
        end

        create_stmt = """
            CREATE TABLE IF NOT EXISTS $safe_table (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                metadata TEXT
            )
        """
        SQLite.execute(conn, create_stmt)

        SQLite.DBInterface.execute(
            conn,
            "INSERT INTO $safe_table (timestamp, level, message, metadata) VALUES (?, ?, ?, ?)",
            (string(record.timestamp), String(record.level), record.message, _metadata_to_string(record.metadata)),
        )
    end

    return nothing
end

function write_log_record(source::SQLDumpMedia, record::LogRecord; kwargs...)
    throw(ArgumentError("SQLDumpMedia is read-only and cannot be used as a logging sink"))
end

function write_log_record(source::iSourceMedia, record::LogRecord; kwargs...)
    throw(ArgumentError("write_log_record not implemented for source type $(typeof(source))"))
end

function _log_worker_loop(source::iSourceMedia, queue::_LogRingBuffer, sink_kwargs::NamedTuple)
    while true
        record = _dequeue!(queue)
        if isnothing(record)
            break
        end
        try
            write_log_record(source, record; sink_kwargs...)
        catch err
            @warn "Failed to write log record" exception=(err, catch_backtrace()) source=typeof(source)
        end
    end
    return nothing
end

function AsyncLogger(source::iSourceMedia; min_level::Symbol=:info, capacity::Int=1024, sink_kwargs...)
    _should_log(min_level, min_level)
    queue = _LogRingBuffer(capacity)
    sink_kwargs_nt = (; sink_kwargs...)
    worker = Threads.@spawn _log_worker_loop(source, queue, sink_kwargs_nt)
    return AsyncLogger(source, min_level, sink_kwargs_nt, queue, worker)
end

"""
    log!(logger::AsyncLogger, level::Symbol, message::AbstractString; metadata=nothing) -> Bool

Queue a log record for asynchronous processing.

Returns `true` when accepted (or skipped due to level filtering), `false` when dropped
because the queue is full or logger is closed.
"""
function log!(logger::AsyncLogger, level::Symbol, message::AbstractString; metadata=nothing)
    if !_should_log(logger.min_level, level)
        return true
    end
    record = LogRecord(now(Dates.UTC), level, String(message), metadata)
    return _enqueue!(logger.queue, record)
end

log_debug!(logger::AsyncLogger, message::AbstractString; metadata=nothing) = log!(logger, :debug, message; metadata=metadata)
log_info!(logger::AsyncLogger, message::AbstractString; metadata=nothing) = log!(logger, :info, message; metadata=metadata)
log_warn!(logger::AsyncLogger, message::AbstractString; metadata=nothing) = log!(logger, :warn, message; metadata=metadata)
log_error!(logger::AsyncLogger, message::AbstractString; metadata=nothing) = log!(logger, :error, message; metadata=metadata)

"""
    flush_logger!(logger::AsyncLogger)

Wait until the pending queue is drained by the worker task.
"""
function flush_logger!(logger::AsyncLogger)
    last_count = -1
    stable_iterations = 0
    sleep_interval = 0.001
    max_sleep_interval = 0.1
    max_stable_iterations = 10_000

    while true
        current_count = _count(logger.queue)
        if current_count == 0
            break
        end

        if current_count == last_count
            stable_iterations += 1
            if stable_iterations >= max_stable_iterations
                throw(ErrorException("Logger queue did not drain; worker may have failed while flushing."))
            end
        else
            last_count = current_count
            stable_iterations = 0
        end

        sleep(sleep_interval)
        sleep_interval = min(sleep_interval * 2, max_sleep_interval)
    end
    return nothing
end

"""
    stop_logger!(logger::AsyncLogger)

Close the logger queue and wait for the background worker to finish.
"""
function stop_logger!(logger::AsyncLogger)
    _close_queue!(logger.queue)
    wait(logger.worker)
    return nothing
end

"""
    dropped_logs(logger::AsyncLogger) -> Int

Return the number of records dropped due to a full queue.
"""
function dropped_logs(logger::AsyncLogger)
    return _dropped(logger.queue)
end
