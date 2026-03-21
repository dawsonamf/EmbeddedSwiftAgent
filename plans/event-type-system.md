# Two-Layer Event Type System

Define a typed, two-layer event system modeled after pi-mono's architecture. All internal and external consumers should switch on these enums rather than ad-hoc string matching or inline printing.

## Layer 1: LLM streaming events (`StreamEvent`)

These are emitted during a **single LLM API call** as the model streams its response. `OpenRouterClient` emits these — it knows nothing about tool execution or the agent loop.

```
enum StreamEvent {
    // Lifecycle
    case start                                          // Connection opened, chunks incoming
    case done(reason: StopReason)                       // Stream finished (stop | toolUse | length)
    case error(message: String)                         // API error, HTTP error, parse error

    // Text content
    case textStart                                      // Text content block beginning
    case textDelta(text: String)                        // Streaming text token
    case textEnd(fullText: String)                      // Text content block finished

    // Reasoning / thinking
    case thinkingStart                                  // Reasoning content block beginning
    case thinkingDelta(text: String)                    // Streaming reasoning token
    case thinkingEnd(fullText: String)                  // Reasoning content block finished

    // Tool call requests (model ASKING to call a tool, not execution)
    case toolCallStart(id: String, toolName: String)    // Model began requesting a tool call
    case toolCallDelta(id: String, argsDelta: String)   // Streaming tool call arguments JSON
    case toolCallEnd(id: String, toolName: String,      // Tool call request fully received
                     fullArgs: String)
}

enum StopReason {
    case stop       // Model chose to stop
    case toolUse    // Model wants tool results before continuing
    case length     // Hit max tokens
}
```

**Key distinction:** `toolCallEnd` means the model finished *requesting* a tool call. It does NOT mean the tool has been executed. That's Layer 2's job.

## Layer 2: Agent loop events (`AgentEvent`)

These are emitted by the **agent orchestration loop** — the thing that takes user input, calls the LLM, executes tools, feeds results back, and repeats. It wraps Layer 1.

```
enum AgentEvent {
    // Agent lifecycle (one per user message)
    case agentStart                                     // Agent loop began processing user input
    case agentEnd(messages: [ChatMessage])              // Agent loop finished, back to user

    // Turn lifecycle (one LLM call + its tool executions)
    case turnStart                                      // Starting an LLM API call
    case turnEnd(message: ChatMessage,                  // Turn complete (response + tool results)
                 toolResults: [ToolResultMessage])

    // Message streaming (wraps Layer 1)
    case messageStart(message: ChatMessage)             // New assistant message being built
    case messageUpdate(message: ChatMessage,            // Layer 1 event bubbled up
                       streamEvent: StreamEvent)
    case messageEnd(message: ChatMessage)               // LLM response fully received

    // Tool execution (agent actually RUNNING the tool)
    case toolExecStart(id: String, toolName: String,    // Tool execution beginning
                       args: Any)
    case toolExecEnd(id: String, toolName: String,      // Tool execution finished
                     result: String, isError: Bool)

    // Steering
    case steeringReceived                               // User injected a message mid-turn
    case toolCallSkipped(id: String, toolName: String,  // Tool call skipped due to steering
                         reason: String)
}
```

## Event flow example

A single user message like "create hello.py and run it" produces this event sequence:

```
agentStart
  turnStart
    messageStart
      messageUpdate(streamEvent: .thinkingDelta("Let me..."))
      messageUpdate(streamEvent: .toolCallStart(id: "1", toolName: "sh"))
      messageUpdate(streamEvent: .toolCallDelta(id: "1", args: "{\"c\":\"echo..."))
      messageUpdate(streamEvent: .toolCallEnd(id: "1", toolName: "sh", fullArgs: "..."))
      messageUpdate(streamEvent: .done(reason: .toolUse))
    messageEnd
    toolExecStart(id: "1", toolName: "sh", args: "echo 'print(...)' > hello.py")
    toolExecEnd(id: "1", toolName: "sh", result: "", isError: false)
  turnEnd
  turnStart                                             // Agent feeds tool result back to LLM
    messageStart
      messageUpdate(streamEvent: .toolCallStart(id: "2", toolName: "sh"))
      ...
      messageUpdate(streamEvent: .done(reason: .toolUse))
    messageEnd
    toolExecStart(id: "2", toolName: "sh", args: "python hello.py")
    toolExecEnd(id: "2", toolName: "sh", result: "hello", isError: false)
  turnEnd
  turnStart                                             // Agent feeds second result back
    messageStart
      messageUpdate(streamEvent: .textDelta("Done! I created..."))
      messageUpdate(streamEvent: .done(reason: .stop))
    messageEnd
  turnEnd
agentEnd
```

## Steering event flow

When the user steers mid-turn (e.g. model requested 3 tool calls, user interrupts after the first):

```
agentStart
  turnStart
    messageEnd                                          // LLM requested 3 tool calls
    toolExecStart(id: "1", ...)                         // First tool executes
    toolExecEnd(id: "1", ...)
    steeringReceived                                    // User typed something
    toolCallSkipped(id: "2", reason: "Skipped: user message queued")
    toolCallSkipped(id: "3", reason: "Skipped: user message queued")
  turnEnd
  turnStart                                             // New turn with steering message
    ...
```

## Implementation notes

- `OpenRouterClient.sendStreaming` should accept a callback `(StreamEvent) -> Void` instead of printing directly. It emits Layer 1 events only.
- The agent loop in `main.swift` (or a new `AgentLoop` struct) subscribes to Layer 1 events, wraps them in `messageUpdate`, and emits Layer 2 events.
- The CLI renderer subscribes to Layer 2 events and handles all printing (text to stdout, reasoning dimmed, tool status, etc.).
- The server API (future) subscribes to the same Layer 2 events and serializes them as JSON over WebSocket/SSE.
