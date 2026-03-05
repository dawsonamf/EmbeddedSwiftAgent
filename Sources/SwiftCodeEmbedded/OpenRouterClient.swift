import Cstdio

struct OpenRouterClient {
    let apiKey: String
    let model: String

    private let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    /// Sends messages to OpenRouter with streaming enabled.
    /// Emits stream events for rendering and returns a structured stream result.
    func sendStreaming(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        abortFlag: AbortFlag? = nil,
        onEvent: @escaping (StreamEvent) -> Void
    ) -> StreamResult {
        let bodyJSON = buildRequestJSON(messages: messages, tools: tools)
        guard let bodyString = jsonPrintUnformatted(bodyJSON) else {
            let msg = "json-build-error: failed to serialize request"
            onEvent(.error(message: msg))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: msg)
        }

        let headers: [(String, String)] = [
            ("Authorization", "Bearer \(apiKey)"),
            ("Content-Type", "application/json"),
        ]

        var contentAccumulator = ""
        var thinkingAccumulator = ""
        // Phase: 0=idle, 1=thinking, 2=text, 3=toolCall
        var phase = 0
        var toolCallAccumulators: [ToolCallAccumulator] = []
        var errorMessage: String?

        func closePhase() {
            switch phase {
            case 1: onEvent(.thinkingEnd(fullText: thinkingAccumulator))
            case 2: onEvent(.textEnd(fullText: contentAccumulator))
            default: break
            }
            phase = 0
        }

        onEvent(.start)

        let status = httpPostStreaming(url: endpoint, headers: headers, body: bodyString, abortFlag: abortFlag) { line in
            let trimmed = trimWhitespace(line)
            guard utf8HasPrefix(trimmed, "data: ") else { return }
            let payload = utf8DropFirst(trimmed, 6)
            if utf8Equal(payload, "[DONE]") { return }

            guard let chunk = jsonParse(payload) else { return }

            if let errorObj = jsonGet(chunk, key: "error") {
                if let msg = jsonGetString(jsonGet(errorObj, key: "message")) {
                    errorMessage = msg
                    onEvent(.error(message: msg))
                }
                return
            }

            let choices = jsonGet(chunk, key: "choices")
            guard let firstChoice = jsonGetArrayElements(choices).first else { return }

            let delta = jsonGet(firstChoice, key: "delta")

            let reasoningText = jsonGetString(jsonGet(delta, key: "reasoning"))
                ?? jsonGetString(jsonGet(delta, key: "reasoning_content"))
            if let reasoning = reasoningText, !utf8IsEmpty(reasoning) {
                if phase != 1 {
                    closePhase()
                    phase = 1
                    onEvent(.thinkingStart)
                }
                thinkingAccumulator += reasoning
                onEvent(.thinkingDelta(text: reasoning))
            }

            if let text = jsonGetString(jsonGet(delta, key: "content")), !utf8IsEmpty(text) {
                if phase != 2 {
                    closePhase()
                    phase = 2
                    onEvent(.textStart)
                }
                contentAccumulator += text
                onEvent(.textDelta(text: text))
            }

            let toolCallsArray = jsonGet(delta, key: "tool_calls")
            let toolCallElements = jsonGetArrayElements(toolCallsArray)
            if !toolCallElements.isEmpty && phase != 3 {
                closePhase()
                phase = 3
            }
            for tc in toolCallElements {
                let rawIndex = jsonGetInt(jsonGet(tc, key: "index")) ?? 0
                let idx = rawIndex < 0 ? 0 : rawIndex
                while toolCallAccumulators.count <= idx {
                    toolCallAccumulators.append(ToolCallAccumulator())
                }
                var acc = toolCallAccumulators[idx]
                let priorName = acc.functionName

                if let id = jsonGetString(jsonGet(tc, key: "id")), !utf8IsEmpty(id) {
                    acc.id = id
                }

                let fn = jsonGet(tc, key: "function")
                if let name = jsonGetString(jsonGet(fn, key: "name")) {
                    acc.functionName += name
                }
                if let args = jsonGetString(jsonGet(fn, key: "arguments")) {
                    acc.arguments += args
                    let eventId = acc.id ?? "call_\(idx)"
                    onEvent(.toolCallDelta(id: eventId, argsDelta: args))
                }
                toolCallAccumulators[idx] = acc

                let eventId = acc.id ?? "call_\(idx)"
                if utf8IsEmpty(priorName) && !utf8IsEmpty(acc.functionName) {
                    onEvent(.toolCallStart(id: eventId, toolName: acc.functionName))
                }
            }
        }

        closePhase()

        var resultToolCalls: [ToolCall] = []
        for acc in toolCallAccumulators {
            let id = acc.id ?? "call_\(c_rand())"
            onEvent(.toolCallEnd(id: id, toolName: acc.functionName, fullArgs: acc.arguments))
            resultToolCalls.append(ToolCall(id: id, functionName: acc.functionName, arguments: acc.arguments))
        }

        if let errorMessage = errorMessage {
            onEvent(.done(reason: .stop))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: errorMessage)
        }
        if status < 0 {
            let msg = "http-error: curl request failed"
            onEvent(.error(message: msg))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: msg)
        }
        if status != 200 {
            let msg = "http-error: status \(status)"
            onEvent(.error(message: msg))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: msg)
        }

        let reason: StopReason = resultToolCalls.isEmpty ? .stop : .toolUse
        onEvent(.done(reason: reason))

        return StreamResult(
            contentText: utf8IsEmpty(contentAccumulator) ? nil : contentAccumulator,
            thinkingText: utf8IsEmpty(thinkingAccumulator) ? nil : thinkingAccumulator,
            toolCalls: resultToolCalls,
            stopReason: reason,
            errorMessage: nil
        )
    }

    private struct ToolCallAccumulator {
        var id: String?
        var functionName: String = ""
        var arguments: String = ""
    }

    // MARK: - Request JSON Builder

    private func buildRequestJSON(
        messages: [ChatMessage],
        tools: [ToolDefinition]
    ) -> JSONValue? {
        let root = jsonCreateObject()

        jsonAddItemToObject(root, key: "model", item: jsonCreateString(model))
        jsonAddItemToObject(root, key: "stream", item: jsonCreateBool(true))

        // Reasoning
        let reasoning = jsonCreateObject()
        jsonAddItemToObject(reasoning, key: "effort", item: jsonCreateString("high"))
        jsonAddItemToObject(root, key: "reasoning", item: reasoning)

        let messagesArray = jsonCreateArray()
        for msg in messages {
            jsonAddItemToArray(messagesArray, item: msg.toJSON())
        }
        jsonAddItemToObject(root, key: "messages", item: messagesArray)

        if !tools.isEmpty {
            let toolsArray = jsonCreateArray()
            for tool in tools {
                jsonAddItemToArray(toolsArray, item: tool.toJSON())
            }
            jsonAddItemToObject(root, key: "tools", item: toolsArray)
        }

        return root
    }
}
