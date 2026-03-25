import Cstdio

private let inputReaderThreadCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { rawCtx in
    guard let rawCtx = rawCtx else { return nil }
    let ctx = Unmanaged<InputReaderContext>.fromOpaque(rawCtx).takeRetainedValue()

    while true {
        guard let cStr = read_line_stdin() else {
            ctx.eofFlag.set()
            break
        }
        let line = String(cString: cStr)
        free(cStr)

        let trimmed = trimWhitespace(line)
        guard !utf8IsEmpty(trimmed) else { continue }

        if ctx.isAgentRunning.isSet() {
            ctx.steeringQueue.push(trimmed)
        } else {
            ctx.directInputQueue.push(trimmed)
        }
    }

    return nil
}

/// Reads stdin on a background pthread and routes input to the appropriate queue.
///
/// When the agent is idle, input goes to `directInputQueue` (consumed by the main loop).
/// When the agent is running, input goes to `steeringQueue` (consumed by AgentLoop between tool calls).
struct InputReader: @unchecked Sendable {
    let steeringQueue: ThreadSafeQueue
    let directInputQueue: ThreadSafeQueue
    let abortFlag: AbortFlag

    /// Set by the stdin thread when it hits EOF (Ctrl+D).
    let eofFlag: AbortFlag

    /// Whether the agent is currently running — set by the main thread.
    private let isAgentRunning: AbortFlag

    /// Opaque handle to the background thread (for joining on shutdown).
    private let threadHandle: ThreadHandle

    init(
        steeringQueue: ThreadSafeQueue,
        directInputQueue: ThreadSafeQueue,
        abortFlag: AbortFlag
    ) {
        self.steeringQueue = steeringQueue
        self.directInputQueue = directInputQueue
        self.abortFlag = abortFlag
        self.eofFlag = AbortFlag()
        self.isAgentRunning = AbortFlag()
        self.threadHandle = ThreadHandle()
    }

    func start() {
        let ctx = InputReaderContext(
            steeringQueue: steeringQueue,
            directInputQueue: directInputQueue,
            isAgentRunning: isAgentRunning,
            eofFlag: eofFlag
        )

        let handle = sc_thread_create(inputReaderThreadCallback, Unmanaged.passRetained(ctx).toOpaque())

        threadHandle.handle = handle
    }

    func setAgentRunning(_ running: Bool) {
        if running {
            isAgentRunning.set()
        } else {
            isAgentRunning.reset()
        }
    }

    func stop() {
        if let handle = threadHandle.handle {
            sc_thread_join(handle)
        }
    }
}

/// Mutable storage for the thread handle so the InputReader struct can set it after creation.
private final class ThreadHandle {
    var handle: UnsafeMutableRawPointer?
}

/// Context object passed to the background pthread via `Unmanaged`.
private final class InputReaderContext {
    let steeringQueue: ThreadSafeQueue
    let directInputQueue: ThreadSafeQueue
    let isAgentRunning: AbortFlag
    let eofFlag: AbortFlag

    init(
        steeringQueue: ThreadSafeQueue,
        directInputQueue: ThreadSafeQueue,
        isAgentRunning: AbortFlag,
        eofFlag: AbortFlag
    ) {
        self.steeringQueue = steeringQueue
        self.directInputQueue = directInputQueue
        self.isAgentRunning = isAgentRunning
        self.eofFlag = eofFlag
    }
}
