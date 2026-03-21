import Cstdio

// MARK: - Tool Definitions

let shellTool = ToolDefinition(
    name: "sh",
    description: "Execute a shell command and return its output",
    parametersJSON: """
    {"type":"object","properties":{"c":{"type":"string","description":"The shell command to execute"}},"required":["c"]}
    """
)

let subagentTool = ToolDefinition(
    name: "subagent",
    description: "Spawn a subagent to handle a self-contained task. The subagent gets its own conversation context, can use all the same tools (including spawning further subagents), and runs to completion. Returns the subagent's final text response.",
    parametersJSON: """
    {"type":"object","properties":{"task":{"type":"string","description":"The task/prompt for the subagent"},"model":{"type":"string","description":"Optional model override (e.g. 'anthropic/claude-sonnet-4'). Defaults to the parent agent's model."}},"required":["task"]}
    """
)

let allTools = [shellTool, subagentTool]

// MARK: - Tool Execution

extension AgentLoop {

    func executeTool(_ toolCall: ToolCall) -> ToolResultMessage {
        if utf8Equal(toolCall.functionName, "sh") {
            let command = extractShellCommand(from: toolCall.arguments)
            let result = runShell(command)
            let content = result.exitCode == 0
                ? result.output
                : "\(result.output)\n[exit code: \(result.exitCode)]"
            return ToolResultMessage(toolCallId: toolCall.id, content: content, isError: result.exitCode != 0)
        }
        if utf8Equal(toolCall.functionName, "subagent") {
            return executeSubagent(toolCall)
        }
        return ToolResultMessage(
            toolCallId: toolCall.id,
            content: "Unknown tool: \(toolCall.functionName)",
            isError: true
        )
    }

    func executeSubagent(_ toolCall: ToolCall) -> ToolResultMessage {
        let (task, model) = extractSubagentArgs(from: toolCall.arguments)

        guard !utf8IsEmpty(task) else {
            return ToolResultMessage(
                toolCallId: toolCall.id,
                content: "subagent error: missing 'task' parameter",
                isError: true
            )
        }

        let subClient: OpenRouterClient
        if let model = model, !utf8IsEmpty(model) {
            subClient = OpenRouterClient(apiKey: apiKey, model: model)
        } else {
            subClient = client
        }

        var subMessages: [ChatMessage] = [
            ChatMessage(role: ChatRole.user, content: task)
        ]
        let subSteeringQueue = ThreadSafeQueue()
        let subFollowUpQueue = ThreadSafeQueue()

        let responseBox = ResponseBox()

        let subLoop = AgentLoop(
            client: subClient,
            apiKey: apiKey,
            tools: tools,
            abortFlag: abortFlag,
            onEvent: { event in
                self.onEvent(.subagentEvent(innerEvent: event))
                if case .messageEnd(let msg) = event {
                    if utf8Equal(msg.role, ChatRole.assistant), let content = msg.content {
                        responseBox.value = content
                    }
                }
            }
        )

        onEvent(.subagentStart(task: task))

        subLoop.run(
            messages: &subMessages,
            steeringQueue: subSteeringQueue,
            followUpQueue: subFollowUpQueue
        )

        onEvent(.subagentEnd)

        let output = responseBox.value ?? "(subagent produced no text response)"
        return ToolResultMessage(toolCallId: toolCall.id, content: output, isError: false)
    }

    func executeToolsInParallel(_ toolCalls: [ToolCall]) -> [ToolResultMessage] {
        let count = toolCalls.count

        let resultsBox = ParallelResultsBox(count: count)

        for toolCall in toolCalls {
            onEvent(.toolExecStart(
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
            onEvent(.toolExecEnd(
                id: toolCalls[i].id,
                toolName: toolCalls[i].functionName,
                result: result.content,
                isError: result.isError
            ))
            results.append(result)
        }

        return results
    }

    func appendSyntheticResults(
        from startIndex: Int,
        in toolCalls: [ToolCall],
        content: String,
        to toolResults: inout [ToolResultMessage],
        context: inout [ChatMessage]
    ) {
        for skipped in toolCalls[startIndex...] {
            let synthetic = ToolResultMessage(
                toolCallId: skipped.id,
                content: content,
                isError: false
            )
            toolResults.append(synthetic)
            context.append(synthetic.toChatMessage())
        }
    }
}

// MARK: - Argument Extraction

/// Extracts the "c" field from the tool call arguments JSON string.
func extractShellCommand(from arguments: String) -> String {
    guard let json = jsonParse(arguments) else { return arguments }
    return json["c"]?.string ?? arguments
}

/// Extracts "task" and optional "model" from subagent tool call arguments.
func extractSubagentArgs(from arguments: String) -> (task: String, model: String?) {
    guard let json = jsonParse(arguments) else { return (arguments, nil) }
    let task = json["task"]?.string ?? ""
    let model = json["model"]?.string
    return (task, model)
}

// MARK: - Parallel Execution Support

/// Mutable box for capturing a subagent's final response.
private final class ResponseBox: @unchecked Sendable {
    private var _value: String?
    private let mutex: OpaquePointer

    init() {
        mutex = OpaquePointer(sc_mutex_create())
    }

    var value: String? {
        get {
            sc_mutex_lock(UnsafeMutableRawPointer(mutex))
            let v = _value
            sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
            return v
        }
        set {
            sc_mutex_lock(UnsafeMutableRawPointer(mutex))
            _value = newValue
            sc_mutex_unlock(UnsafeMutableRawPointer(mutex))
        }
    }

    deinit {
        sc_mutex_destroy(UnsafeMutableRawPointer(mutex))
    }
}

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
