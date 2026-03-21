// MARK: - Stop Reason

enum StopReason {
    case stop       // Model chose to stop
    case toolUse    // Model wants tool results before continuing
    case length     // Hit max tokens
}

// MARK: - Layer 1: LLM Streaming Events

/// Emitted by `OpenRouterClient` during a single LLM API call.
/// Knows nothing about tool execution or the agent loop.
enum StreamEvent {
    // Lifecycle
    case start
    case done(reason: StopReason)
    case error(message: String)

    // Text content
    case textStart
    case textDelta(text: String)
    case textEnd(fullText: String)

    // Reasoning / thinking
    case thinkingStart
    case thinkingDelta(text: String)
    case thinkingEnd(fullText: String)

    // Tool call requests (model ASKING to call a tool, not execution)
    case toolCallStart(id: String, toolName: String)
    case toolCallDelta(id: String, argsDelta: String)
    case toolCallEnd(id: String, toolName: String, fullArgs: String)
}

// MARK: - Layer 2: Agent Loop Events

/// Emitted by `AgentLoop` during agent orchestration.
/// Wraps Layer 1 events and adds tool execution, turn, and agent lifecycle events.
indirect enum AgentEvent {
    // Agent lifecycle (one per user message)
    case agentStart
    case agentEnd(messages: [ChatMessage])

    // Turn lifecycle (one LLM call + its tool executions)
    case turnStart
    case turnEnd(message: ChatMessage, toolResults: [ToolResultMessage])

    // Message streaming (wraps Layer 1)
    case messageStart(message: ChatMessage)
    case messageUpdate(message: ChatMessage, streamEvent: StreamEvent)
    case messageEnd(message: ChatMessage)

    // Tool execution (agent actually RUNNING the tool)
    case toolExecStart(id: String, toolName: String, args: String)
    case toolExecEnd(id: String, toolName: String, result: String, isError: Bool)

    // Steering
    case steeringReceived
    case toolCallSkipped(id: String, toolName: String, reason: String)

    // Subagent
    case subagentStart(task: String)
    case subagentEnd
    case subagentEvent(innerEvent: AgentEvent)

    // Abort
    case aborted
}
