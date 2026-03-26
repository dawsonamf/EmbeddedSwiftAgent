import Cstdio

enum StreamPhase {
    case idle, thinking, text, toolCall
}

struct OpenRouterClient {
    let apiKey: String
    let model: String
    let reasoningEffort: String

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
        var phase: StreamPhase = .idle
        var toolCallAccumulators: [ToolCallAccumulator] = []
        var errorMessage: String?

        func closePhase() {
            switch phase {
            case .thinking: onEvent(.thinkingEnd(fullText: thinkingAccumulator))
            case .text: onEvent(.textEnd(fullText: contentAccumulator))
            case .idle, .toolCall: break
            }
            phase = .idle
        }

        onEvent(.start)

        let httpResult = httpPostStreaming(url: endpoint, headers: headers, body: bodyString, abortFlag: abortFlag) { line in
            let trimmed = trimWhitespace(line)
            guard utf8HasPrefix(trimmed, "data: ") else { return }
            let payload = utf8DropFirst(trimmed, 6)
            if utf8Equal(payload, "[DONE]") { return }

            guard let chunk = jsonParse(payload) else { return }

            if let errorObj = chunk["error"] {
                if let msg = errorObj["message"]?.string {
                    errorMessage = msg
                    onEvent(.error(message: msg))
                }
                return
            }

            guard let firstChoice = chunk["choices"]?.arrayElements.first else { return }

            let delta = firstChoice["delta"]

            let reasoningText = delta?["reasoning"]?.string
                ?? delta?["reasoning_content"]?.string
            if let reasoning = reasoningText, !utf8IsEmpty(reasoning) {
                if phase != .thinking {
                    closePhase()
                    phase = .thinking
                    onEvent(.thinkingStart)
                }
                thinkingAccumulator += reasoning
                onEvent(.thinkingDelta(text: reasoning))
            }

            if let text = delta?["content"]?.string, !utf8IsEmpty(text) {
                if phase != .text {
                    closePhase()
                    phase = .text
                    onEvent(.textStart)
                }
                contentAccumulator += text
                onEvent(.textDelta(text: text))
            }

            let toolCallElements = delta?["tool_calls"]?.arrayElements ?? []
            if !toolCallElements.isEmpty && phase != .toolCall {
                closePhase()
                phase = .toolCall
            }
            for tc in toolCallElements {
                let rawIndex = tc["index"]?.int ?? 0
                let idx = rawIndex < 0 ? 0 : rawIndex
                while toolCallAccumulators.count <= idx {
                    toolCallAccumulators.append(ToolCallAccumulator())
                }
                var acc = toolCallAccumulators[idx]
                let priorName = acc.functionName

                if let id = tc["id"]?.string, !utf8IsEmpty(id) {
                    acc.id = id
                }

                let fn = tc["function"]
                if let name = fn?["name"]?.string {
                    acc.functionName += name
                }
                if let args = fn?["arguments"]?.string {
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

        // User hit Ctrl+C — return whatever we've accumulated so far, no error.
        if abortFlag?.isSet() == true {
            onEvent(.done(reason: .stop))
            return StreamResult(
                contentText: utf8IsEmpty(contentAccumulator) ? nil : contentAccumulator,
                thinkingText: utf8IsEmpty(thinkingAccumulator) ? nil : thinkingAccumulator,
                toolCalls: resultToolCalls,
                stopReason: .stop,
                errorMessage: nil
            )
        }

        if let errorMessage = errorMessage {
            onEvent(.done(reason: .stop))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: errorMessage)
        }
        if let curlError = httpResult.curlError {
            let msg = "http-error: \(curlError)"
            onEvent(.error(message: msg))
            return StreamResult(contentText: nil, thinkingText: nil, toolCalls: [], stopReason: .stop, errorMessage: msg)
        }
        if httpResult.statusCode != 200 {
            let msg = "http-error: status \(httpResult.statusCode)"
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
        let root = JSONValue.object()
        root?["model"] = .string(model)
        root?["stream"] = .bool(true)
        root?["reasoning"] = .object(("effort", .string(reasoningEffort)))
        root?["messages"] = .array(messages.map { $0.toJSON() })
        if !tools.isEmpty {
            root?["tools"] = .array(tools.map { $0.toJSON() })
        }
        return root
    }
}
