struct AgentLoop: Sendable {
    let client: OpenRouterClient
    let tools: [ToolDefinition]
    let abortFlag: AbortFlag
    let onEvent: @Sendable (AgentEvent) -> Void

    /// Outer loop: runs turns until the model is done, then checks for follow-ups.
    func run(
        messages: inout [ChatMessage],
        steeringQueue: ThreadSafeQueue,
        followUpQueue: ThreadSafeQueue
    ) {
        onEvent(.agentStart)

        outer: while true {
            if abortFlag.isSet() {
                onEvent(.aborted)
                onEvent(.agentEnd(messages: messages))
                return
            }

            // Inner loop: run turns until model is done
            while true {
                let result = runTurn(context: &messages, steeringQueue: steeringQueue)
                switch result {
                case .done:
                    break // Exit inner loop
                case .continue:
                    continue
                case .exit:
                    if abortFlag.isSet() {
                        onEvent(.aborted)
                    }
                    onEvent(.agentEnd(messages: messages))
                    return
                }
                break // .done breaks out of inner loop
            }

            // Check follow-up queue
            if !followUpQueue.isEmpty() {
                if let text = followUpQueue.popFirst() {
                    let followUp = ChatMessage(role: ChatRole.user, content: text)
                    messages.append(followUp)
                    continue outer
                }
            }

            break // No follow-ups, we're done
        }

        onEvent(.agentEnd(messages: messages))
    }

    /// Inner loop: one turn = stream an LLM response + execute any tool calls.
    private func runTurn(
        context: inout [ChatMessage],
        steeringQueue: ThreadSafeQueue
    ) -> TurnResult {
        onEvent(.turnStart)

        if abortFlag.isSet() { return .exit }

        // Build the in-progress assistant message as events arrive
        var assistantMessage = ChatMessage(role: ChatRole.assistant, content: nil)
        onEvent(.messageStart(message: assistantMessage))

        let streamResult = client.sendStreaming(
            messages: context,
            tools: tools,
            abortFlag: abortFlag
        ) { streamEvent in
            // Update assistant message from stream events
            switch streamEvent {
            case .textEnd(let fullText):
                assistantMessage.content = fullText
            case .toolCallEnd(let id, let toolName, let fullArgs):
                let tc = ToolCall(id: id, functionName: toolName, arguments: fullArgs)
                if assistantMessage.toolCalls == nil {
                    assistantMessage.toolCalls = [tc]
                } else {
                    assistantMessage.toolCalls!.append(tc)
                }
            default:
                break
            }

            // Bubble up as Layer 2 messageUpdate
            onEvent(.messageUpdate(message: assistantMessage, streamEvent: streamEvent))
        }

        // Finalize the assistant message
        if assistantMessage.content == nil && streamResult.contentText != nil {
            assistantMessage.content = streamResult.contentText
        }
        if assistantMessage.toolCalls == nil && !streamResult.toolCalls.isEmpty {
            assistantMessage.toolCalls = streamResult.toolCalls
        }

        onEvent(.messageEnd(message: assistantMessage))
        context.append(assistantMessage)

        // Handle error
        if streamResult.isError {
            onEvent(.turnEnd(message: assistantMessage, toolResults: []))
            return .exit
        }

        // Execute tool calls
        let toolCalls = streamResult.toolCalls
        var toolResults: [ToolResultMessage] = []

        for (i, toolCall) in toolCalls.enumerated() {
            // Check abort before each tool execution
            if abortFlag.isSet() {
                appendSyntheticResults(
                    from: i,
                    in: toolCalls,
                    content: "Aborted by user",
                    to: &toolResults,
                    context: &context
                )
                onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
                return .exit
            }

            // Check steering queue BEFORE each tool execution
            if !steeringQueue.isEmpty() {
                if let steeringText = steeringQueue.popFirst() {
                    let steering = ChatMessage(role: ChatRole.user, content: steeringText)
                    onEvent(.steeringReceived)

                    for skipped in toolCalls[i...] {
                        onEvent(.toolCallSkipped(
                            id: skipped.id,
                            toolName: skipped.functionName,
                            reason: "user message queued"
                        ))
                    }
                    appendSyntheticResults(
                        from: i,
                        in: toolCalls,
                        content: "Skipped: user message queued",
                        to: &toolResults,
                        context: &context
                    )

                    context.append(steering)
                    onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
                    return .continue
                }
            }

            onEvent(.toolExecStart(
                id: toolCall.id,
                toolName: toolCall.functionName,
                args: toolCall.arguments
            ))

            let result = executeTool(toolCall)

            onEvent(.toolExecEnd(
                id: toolCall.id,
                toolName: toolCall.functionName,
                result: result.content,
                isError: result.isError
            ))

            toolResults.append(result)
            context.append(result.toChatMessage())
        }

        onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))

        if toolCalls.isEmpty {
            return .done
        }
        return .continue
    }

    // MARK: - Tool Execution

    private func executeTool(_ toolCall: ToolCall) -> ToolResultMessage {
        if utf8Equal(toolCall.functionName, "sh") {
            let command = extractShellCommand(from: toolCall.arguments)
            let output = runShell(command)
            return ToolResultMessage(toolCallId: toolCall.id, content: output, isError: false)
        }
        return ToolResultMessage(
            toolCallId: toolCall.id,
            content: "Unknown tool: \(toolCall.functionName)",
            isError: true
        )
    }

    private func appendSyntheticResults(
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

/// Extracts the "c" field from the tool call arguments JSON string.
func extractShellCommand(from arguments: String) -> String {
    guard let json = jsonParse(arguments) else { return arguments }
    return jsonGetString(jsonGet(json, key: "c")) ?? arguments
}
