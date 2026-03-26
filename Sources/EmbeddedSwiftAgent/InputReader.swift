import Cstdio

private let inputReaderThreadCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { rawCtx in
    guard let rawCtx = rawCtx else { return nil }
    let ctx = Unmanaged<InputReaderContext>.fromOpaque(rawCtx).takeRetainedValue()

    while true {
        if ctx.eofFlag.isSet() { break }

        if ctx.isAgentRunning.isSet() {
            // Raw mode: read byte-by-byte, route to followUp or steering
            let byte = sc_read_byte_stdin()
            if byte < 0 {
                ctx.eofFlag.set()
                break
            }

            // If agent stopped while we were blocked in read(), the byte belongs
            // to the next cooked-mode line. Seed the line buffer for getline.
            if !ctx.isAgentRunning.isSet() {
                ctx.lineBuffer.append(UInt8(byte))
                let seed = ctx.lineBuffer.finish()
                ctx.pendingSeed = seed
                continue
            }

            let b = UInt8(byte)

            switch b {
            case 0x0A, 0x0D:
                // Enter — queue as follow-up
                if !ctx.lineBuffer.isEmpty {
                    let line = ctx.lineBuffer.finish()
                    ctx.followUpQueue.push(line)
                    write_stderr("\n\u{001B}[33m[queued]\u{001B}[0m\n")
                }

            case 0x13:
                // Ctrl+S — send as steering
                if !ctx.lineBuffer.isEmpty {
                    let line = ctx.lineBuffer.finish()
                    ctx.steeringQueue.push(line)
                    write_stderr("\n\u{001B}[35m[steering]\u{001B}[0m\n")
                }

            case 0x03:
                // Ctrl+C — abort
                ctx.lineBuffer.clear()
                ctx.abortFlag.set()

            case 0x04:
                // Ctrl+D — EOF
                ctx.lineBuffer.clear()
                ctx.eofFlag.set()

            case 0x7F, 0x08:
                // Backspace / Delete
                ctx.lineBuffer.dropLast()

            default:
                if b >= 0x20 {
                    ctx.lineBuffer.append(b)
                }
            }
        } else {
            // Cooked mode: read full lines via getline.
            // If we have a pending seed from a raw→cooked transition, the byte
            // was already consumed; getline will pick up from the next keystroke.
            // The seed is prepended to whatever getline returns.
            guard let cStr = read_line_stdin() else {
                ctx.eofFlag.set()
                break
            }
            var line = String(cString: cStr)
            free(cStr)

            if let seed = ctx.pendingSeed {
                line = seed + line
                ctx.pendingSeed = nil
            }

            let trimmed = trimWhitespace(line)
            guard !utf8IsEmpty(trimmed) else { continue }

            ctx.directInputQueue.push(trimmed)
        }
    }

    return nil
}

/// Reads stdin on a background pthread.
///
/// Currently operates in cooked mode only — input goes to `directInputQueue`
/// which is consumed by the main loop via `waitForInput()`.
///
/// Raw-mode steering/follow-up support (Ctrl+S / Enter while running) is
/// implemented in the thread callback and context below but not wired up yet.
struct InputReader: @unchecked Sendable {
    let abortFlag: AbortFlag

    /// Set by the stdin thread when it hits EOF (Ctrl+D).
    let eofFlag: AbortFlag

    /// Whether the agent is currently running — set by the main thread.
    private let isAgentRunning: AbortFlag

    private let directInputQueue: ThreadSafeQueue

    /// Opaque handle to the background thread (for joining on shutdown).
    private let threadHandle: ThreadHandle

    // Queues for future steering/follow-up support (not consumed by agent loop yet)
    private let steeringQueue: ThreadSafeQueue
    private let followUpQueue: ThreadSafeQueue

    init(abortFlag: AbortFlag) {
        self.steeringQueue = ThreadSafeQueue()
        self.followUpQueue = ThreadSafeQueue()
        self.directInputQueue = ThreadSafeQueue()
        self.abortFlag = abortFlag
        self.eofFlag = AbortFlag()
        self.isAgentRunning = AbortFlag()
        self.threadHandle = ThreadHandle()
    }

    func start() {
        let ctx = InputReaderContext(
            steeringQueue: steeringQueue,
            followUpQueue: followUpQueue,
            directInputQueue: directInputQueue,
            isAgentRunning: isAgentRunning,
            abortFlag: abortFlag,
            eofFlag: eofFlag
        )

        let handle = sc_thread_create(inputReaderThreadCallback, Unmanaged.passRetained(ctx).toOpaque())

        threadHandle.handle = handle
    }

    /// Blocks until the user submits input, or returns nil on abort/EOF.
    func waitForInput() -> String? {
        while true {
            if abortFlag.isSet() { return nil }
            if let value = directInputQueue.waitAndPop(timeoutMs: 100) {
                return value
            }
            if eofFlag.isSet() {
                return directInputQueue.popFirst()
            }
        }
    }

    func stop() {
        sc_disable_raw_mode()
        if let handle = threadHandle.handle {
            sc_thread_join(handle)
        }
    }
}

/// Mutable storage for the thread handle so the InputReader struct can set it after creation.
private final class ThreadHandle {
    var handle: UnsafeMutableRawPointer?
}

/// Simple byte buffer for accumulating a line in raw mode.
/// Not thread-safe — only used from the input thread.
private final class LineBuffer {
    private var bytes: [UInt8] = []

    var isEmpty: Bool { bytes.isEmpty }

    func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    func dropLast() {
        if !bytes.isEmpty {
            bytes.removeLast()
        }
    }

    func clear() {
        bytes.removeAll()
    }

    /// Returns the accumulated string and clears the buffer.
    func finish() -> String {
        bytes.append(0)
        let s = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        bytes.removeAll()
        return s
    }
}

/// Context object passed to the background pthread via `Unmanaged`.
private final class InputReaderContext {
    let steeringQueue: ThreadSafeQueue
    let followUpQueue: ThreadSafeQueue
    let directInputQueue: ThreadSafeQueue
    let isAgentRunning: AbortFlag
    let abortFlag: AbortFlag
    let eofFlag: AbortFlag
    let lineBuffer = LineBuffer()

    /// When the agent stops while we're blocked in raw-mode read(), the byte
    /// we consumed belongs to the next cooked-mode line. We stash it here so
    /// it can be prepended to the next getline result.
    var pendingSeed: String?

    init(
        steeringQueue: ThreadSafeQueue,
        followUpQueue: ThreadSafeQueue,
        directInputQueue: ThreadSafeQueue,
        isAgentRunning: AbortFlag,
        abortFlag: AbortFlag,
        eofFlag: AbortFlag
    ) {
        self.steeringQueue = steeringQueue
        self.followUpQueue = followUpQueue
        self.directInputQueue = directInputQueue
        self.isAgentRunning = isAgentRunning
        self.abortFlag = abortFlag
        self.eofFlag = eofFlag
    }
}
