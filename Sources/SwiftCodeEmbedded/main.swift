import Cstdio

// MARK: - Configuration

guard let apiKeyCStr = getenv("OPENROUTER_API_KEY") else {
    writeStderr("Set OPENROUTER_API_KEY environment variable\n")
    exit(1)
}
let apiKey = String(cString: apiKeyCStr)
let exaApiKey: String? = getenv("EXA_API_KEY").map { String(cString: $0) }
let client = OpenRouterClient(apiKey: apiKey, model: "anthropic/claude-haiku-4.5")
let tools = allTools

// MARK: - Agent Loop
//
// The core algorithm: send messages to the LLM, execute any tool calls it
// requests, append results, and loop until the model stops calling tools.
// Subagents and follow-up messages can extend the loop across multiple turns.

struct AgentLoop: Sendable {
    let client: OpenRouterClient
    let apiKey: String
    let exaApiKey: String?
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

            // Run turns until the model stops requesting tools
            while true {
                let result = runTurn(context: &messages, steeringQueue: steeringQueue)
                switch result {
                case .done:     break   // model finished, check for follow-ups
                case .continue: continue // model wants another turn
                case .exit:
                    if abortFlag.isSet() { onEvent(.aborted) }
                    onEvent(.agentEnd(messages: messages))
                    return
                }
                break
            }

            // If there's a queued follow-up, inject it and loop again
            if let text = followUpQueue.popFirst() {
                messages.append(ChatMessage(role: ChatRole.user, content: text))
                continue outer
            }

            break
        }

        onEvent(.agentEnd(messages: messages))
    }

    /// One turn = stream an LLM response + execute any tool calls it requests.
    private func runTurn(
        context: inout [ChatMessage],
        steeringQueue: ThreadSafeQueue
    ) -> TurnResult {
        onEvent(.turnStart)
        if abortFlag.isSet() { return .exit }

        // Stream the LLM response, building the assistant message as chunks arrive
        var assistantMessage = ChatMessage(role: ChatRole.assistant, content: nil)
        onEvent(.messageStart(message: assistantMessage))

        let streamResult = client.sendStreaming(
            messages: context,
            tools: tools,
            abortFlag: abortFlag
        ) { streamEvent in
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

        if streamResult.isError {
            onEvent(.turnEnd(message: assistantMessage, toolResults: []))
            return .exit
        }

        // Execute tool calls
        let toolCalls = streamResult.toolCalls
        var toolResults: [ToolResultMessage] = []

        // Abort check before running tools
        if !toolCalls.isEmpty && abortFlag.isSet() {
            appendSyntheticResults(from: 0, in: toolCalls, content: "Aborted by user",
                                   to: &toolResults, context: &context)
            onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
            return .exit
        }

        // Steering: if the user typed something while tools were queued, skip them
        if !toolCalls.isEmpty, let steeringText = steeringQueue.popFirst() {
            let steering = ChatMessage(role: ChatRole.user, content: steeringText)
            onEvent(.steeringReceived)
            for skipped in toolCalls {
                onEvent(.toolCallSkipped(id: skipped.id, toolName: skipped.functionName,
                                         reason: "user message queued"))
            }
            appendSyntheticResults(from: 0, in: toolCalls, content: "Skipped: user message queued",
                                   to: &toolResults, context: &context)
            context.append(steering)
            onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
            return .continue
        }

        // Single tool call — run directly
        if toolCalls.count == 1 {
            let toolCall = toolCalls[0]
            onEvent(.toolExecStart(id: toolCall.id, toolName: toolCall.functionName, args: toolCall.arguments))
            let result = executeTool(toolCall)
            onEvent(.toolExecEnd(id: toolCall.id, toolName: toolCall.functionName,
                                 result: result.content, isError: result.isError))
            toolResults.append(result)
            context.append(result.toChatMessage())
        }
        // Multiple tool calls — run in parallel via pthreads
        else if toolCalls.count > 1 {
            toolResults = executeToolsInParallel(toolCalls)
            for result in toolResults {
                context.append(result.toChatMessage())
            }
        }

        onEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
        return toolCalls.isEmpty ? .done : .continue
    }
}

// MARK: - REPL

nonisolated(unsafe) var messages: [ChatMessage] = []

let abortFlag = AbortFlag()
let steeringQueue = ThreadSafeQueue()
let followUpQueue = ThreadSafeQueue()
let directInputQueue = ThreadSafeQueue()

sc_install_sigint_handler(abortFlag.rawPointer)

let inputReader = InputReader(
    steeringQueue: steeringQueue,
    directInputQueue: directInputQueue,
    abortFlag: abortFlag
)

let agentLoop = AgentLoop(
    client: client,
    apiKey: apiKey,
    exaApiKey: exaApiKey,
    tools: tools,
    abortFlag: abortFlag,
    onEvent: renderEvent
)

inputReader.start()
showPrompt()

while true {
    var input: String? = nil
    while input == nil {
        if abortFlag.isSet() { break }
        input = directInputQueue.waitAndPop(timeoutMs: 100)
        if input == nil && inputReader.eofFlag.isSet() {
            input = directInputQueue.popFirst()
            break
        }
    }

    if abortFlag.isSet() {
        print("")
        break
    }

    guard let input else {
        print("")
        break
    }

    messages.append(ChatMessage(role: ChatRole.user, content: input))
    inputReader.setAgentRunning(true)

    agentLoop.run(
        messages: &messages,
        steeringQueue: steeringQueue,
        followUpQueue: followUpQueue
    )

    abortFlag.reset()
    inputReader.setAgentRunning(false)

    showPrompt()
}
