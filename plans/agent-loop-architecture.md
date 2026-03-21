# Agent Loop Architecture (Outer/Inner Loop)

Restructure the current flat `while !done` loop into a proper two-loop architecture.

## Inner loop (turns)

Handles one turn: stream an LLM response, execute any tool calls, check for steering between each tool execution.

```
func runTurn(context, steeringQueue, signal) -> TurnResult {
    emit(.turnStart)

    // Stream LLM response
    let response = streamAssistantResponse(context)

    // If error or aborted, exit
    if response.stopReason == .error || response.stopReason == .aborted {
        emit(.turnEnd)
        return .exit
    }

    // Execute tool calls (if any)
    for toolCall in response.toolCalls {
        // Check steering queue BEFORE each tool execution
        if let steering = steeringQueue.dequeue() {
            emit(.steeringReceived)
            // Skip remaining tool calls with synthetic results
            skipRemainingToolCalls(from: toolCall, reason: "user message queued")
            context.append(steering)
            emit(.turnEnd)
            return .continue  // Re-enter inner loop with steering message
        }

        emit(.toolExecStart(toolCall))
        let result = executeTool(toolCall)
        emit(.toolExecEnd(toolCall, result))
        context.appendToolResult(result)
    }

    emit(.turnEnd)

    if response.toolCalls.isEmpty {
        return .done  // No tool calls = model is finished
    }
    return .continue  // Had tool calls = need another turn to feed results back
}
```

## Outer loop (follow-ups)

Handles the full agent run. Runs the inner loop until the model is done, then checks for queued follow-up messages.

```
func runAgent(initialMessages, followUpQueue, steeringQueue, signal) {
    emit(.agentStart)
    var context = initialMessages

    while true {
        // Inner loop: run turns until model is done
        while true {
            let result = runTurn(context, steeringQueue, signal)
            switch result {
            case .done: break     // Model finished, exit inner loop
            case .continue: continue  // More turns needed
            case .exit: 
                emit(.agentEnd)
                return  // Error/abort
            }
        }

        // Check follow-up queue
        if let followUp = followUpQueue.dequeue() {
            context.append(followUp)
            continue  // Re-enter outer loop
        }

        break  // No follow-ups, we're done
    }

    emit(.agentEnd)
}
```

## Synthetic tool results for skipped calls

When steering causes tool calls to be skipped, insert synthetic `ToolResultMessage` entries so the conversation history stays valid. Every tool call the model made must have a corresponding tool result — otherwise the model gets confused on the next turn.

```
func skipRemainingToolCalls(from index: Int, toolCalls: [ToolCall], reason: String) {
    for i in index..<toolCalls.count {
        let synthetic = ToolResultMessage(
            toolCallId: toolCalls[i].id,
            content: "Skipped: \(reason)",
            isError: false
        )
        context.append(synthetic)
        emit(.toolCallSkipped(id: toolCalls[i].id, toolName: toolCalls[i].name, reason: reason))
    }
}
```
