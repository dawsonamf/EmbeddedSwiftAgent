import Cstdio

// MARK: - Parallel Tool Execution

extension AgentLoop {
    func executeToolsInParallel(_ toolCalls: [ToolCall]) -> [ToolResultMessage] {
        let count = toolCalls.count

        let resultsBox = ParallelResultsBox(count: count)

        for toolCall in toolCalls {
            emitEvent(.toolExecStart(
                id: toolCall.id,
                toolName: toolCall.functionName,
                args: toolCall.arguments
            ))
        }

        var threadHandles: [UnsafeMutableRawPointer] = []
        for i in 0..<count {
            let ctx = ParallelToolContext(
                index: i,
                toolCall: toolCalls[i],
                agentLoop: self,
                resultsBox: resultsBox
            )
            let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
            if let handle = sc_thread_create(parallelToolCallback, ctxPtr) {
                threadHandles.append(handle)
            } else {
                Unmanaged<ParallelToolContext>.fromOpaque(ctxPtr).release()
                let result = executeTool(toolCalls[i])
                resultsBox.set(index: i, result: result)
            }
        }

        for handle in threadHandles {
            sc_thread_join(handle)
        }

        var results: [ToolResultMessage] = []
        for i in 0..<count {
            let result = resultsBox.get(index: i)
            emitEvent(.toolExecEnd(
                id: toolCalls[i].id,
                toolName: toolCalls[i].functionName,
                result: result.content,
                isError: result.isError
            ))
            results.append(result)
        }

        return results
    }
}

// MARK: - Thread-Safe Result Box

/// Thread-safe storage for parallel tool results. Each slot is written by exactly one thread.
private final class ParallelResultsBox: @unchecked Sendable {
    private var results: [ToolResultMessage?]
    private let mutex: OpaquePointer

    init(count: Int) {
        results = [ToolResultMessage?](repeating: nil, count: count)
        mutex = OpaquePointer(sc_mutex_create())
    }

    func set(index: Int, result: ToolResultMessage) {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        results[index] = result
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
    }

    func get(index: Int) -> ToolResultMessage {
        sc_mutex_lock(UnsafeMutableRawPointer(mutex))
        let r = results[index] ?? ToolResultMessage(
            toolCallId: "",
            content: "parallel-exec-error: no result captured",
            isError: true
        )
        sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        return r
    }

    deinit {
        sc_mutex_destroy(UnsafeMutableRawPointer(mutex))
    }
}

// MARK: - Pthread Callback

/// Context passed to each parallel tool execution pthread.
private final class ParallelToolContext: @unchecked Sendable {
    let index: Int
    let toolCall: ToolCall
    let agentLoop: AgentLoop
    let resultsBox: ParallelResultsBox

    init(index: Int, toolCall: ToolCall, agentLoop: AgentLoop, resultsBox: ParallelResultsBox) {
        self.index = index
        self.toolCall = toolCall
        self.agentLoop = agentLoop
        self.resultsBox = resultsBox
    }
}

/// The @convention(c) callback invoked on each pthread for parallel tool execution.
private let parallelToolCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { rawCtx in
    guard let rawCtx = rawCtx else { return nil }
    let ctx = Unmanaged<ParallelToolContext>.fromOpaque(rawCtx).takeRetainedValue()

    let result = ctx.agentLoop.executeTool(ctx.toolCall)
    ctx.resultsBox.set(index: ctx.index, result: result)

    return nil
}
