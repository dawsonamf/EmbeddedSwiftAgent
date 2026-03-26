// MARK: - Comparison with pi-agent-core (badlogic/pi-mono)
//
// Core lifecycle events (1:1 match):
//   agent_start / agent_end          → agentStart / agentEnd              ✓
//   turn_start / turn_end            → turnStart / turnEnd                ✓
//   message_start / message_update / message_end
//                                    → messageStart / messageUpdate / messageEnd  ✓
//   tool_execution_start             → toolExecStart                      ✓
//   tool_execution_update            → toolExecUpdate                     ✓
//   tool_execution_end               → toolExecEnd                        ✓
//
// Events we have that pi-agent-core does NOT:
//   steeringReceived      — they handle steering via getSteeringMessages() callback,
//                            no dedicated event. We emit it for TUI rendering.
//   toolCallSkipped       — they use beforeToolCall hook returning { block: true },
//                            then emit tool_execution_end with isError: true instead
//                            of a separate skip event. We keep it to distinguish
//                            "intentionally skipped" from "failed".
//   aborted               — they use AbortSignal + stopReason "aborted" on the
//                            assistant message, not a separate event. We keep it
//                            for immediate TUI feedback.
//
// Subagents are modeled as regular tools — their internal agent loop is opaque
// to the event protocol. Use toolExecUpdate to stream inner progress if needed.
// The renderer can check toolName to display subagent tools specially.
//
// Layer 1 (StreamEvent):
//   No direct counterpart in pi-agent-core. Their streaming granularity lives in
//   AssistantMessageEvent from the pi-ai package (LLM layer), passed through via
//   message_update. Our explicit StreamEvent layer is a clean separation that
//   pi-agent-core achieves differently.

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
enum AgentEvent {
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
    case toolExecUpdate(id: String, toolName: String, partialResult: String)
    case toolExecEnd(id: String, toolName: String, result: String, isError: Bool)

    // Steering & follow-up
    case steeringReceived
    case followUpConsumed(text: String)
    case toolCallSkipped(id: String, toolName: String, reason: String)

    // Abort
    case aborted
}

// MARK: - Helpers

/// Extracts the StreamEvent from a messageUpdate, returns nil for all other AgentEvents.
func extractStreamDelta(_ event: AgentEvent) -> StreamEvent? {
    if case .messageUpdate(_, let streamEvent) = event {
        return streamEvent
    }
    return nil
}
