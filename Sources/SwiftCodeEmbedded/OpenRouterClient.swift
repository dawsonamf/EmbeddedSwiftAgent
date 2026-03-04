import Cstdio

struct OpenRouterClient {
    let apiKey: String
    let model: String

    private let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    /// Sends messages to OpenRouter with streaming enabled.
    /// Prints assistant text to stdout in real time.
    /// Returns the fully assembled assistant message (text or tool calls).
    func sendStreaming(messages: [ChatMessage], tools: [ToolDefinition]) -> ChatMessage {
        let bodyJSON = buildRequestJSON(messages: messages, tools: tools)
        guard let bodyString = jsonPrintUnformatted(bodyJSON) else {
            return ChatMessage(role: "assistant", content: "json-build-error: failed to serialize request")
        }
        // bodyJSON is freed automatically when it goes out of scope

        let headers: [(String, String)] = [
            ("Authorization", "Bearer \(apiKey)"),
            ("Content-Type", "application/json"),
        ]

        var contentAccumulator = ""
        var inReasoning = false
        var toolCallId: String?
        var toolCallFunctionName = ""
        var toolCallArguments = ""
        var hasToolCall = false
        var errorMessage: String?

        let status = httpPostStreaming(url: endpoint, headers: headers, body: bodyString) { line in
            let trimmed = trimWhitespace(line)

            guard utf8HasPrefix(trimmed, "data: ") else { return }
            let payload = utf8DropFirst(trimmed, 6)

            if utf8Equal(payload, "[DONE]") { return }

            // chunk is owned — freed automatically at end of this closure invocation
            guard let chunk = jsonParse(payload) else { return }

            // Check for error responses
            if let errorObj = jsonGet(chunk, key: "error") {
                if let msg = jsonGetString(jsonGet(errorObj, key: "message")) {
                    errorMessage = msg
                }
                return
            }

            let choices = jsonGet(chunk, key: "choices")
            guard let firstChoice = jsonGetArrayElements(choices).first else { return }

            let delta = jsonGet(firstChoice, key: "delta")

            // Stream reasoning content (extended thinking) dimmed
            let reasoningText = jsonGetString(jsonGet(delta, key: "reasoning"))
                ?? jsonGetString(jsonGet(delta, key: "reasoning_content"))
            if let reasoning = reasoningText, !utf8IsEmpty(reasoning) {
                if !inReasoning {
                    inReasoning = true
                    print("\u{001B}[2m", terminator: "")
                }
                print(reasoning, terminator: "")
                flushStdout()
            }

            // Stream text content
            if let text = jsonGetString(jsonGet(delta, key: "content")), !utf8IsEmpty(text) {
                if inReasoning {
                    inReasoning = false
                    print("\n\u{001B}[0m", terminator: "")
                }
                print(text, terminator: "")
                flushStdout()
                contentAccumulator += text
            }

            // Accumulate tool call deltas
            let toolCallsArray = jsonGet(delta, key: "tool_calls")
            for tc in jsonGetArrayElements(toolCallsArray) {
                hasToolCall = true
                if let id = jsonGetString(jsonGet(tc, key: "id")) {
                    toolCallId = id
                }
                let fn = jsonGet(tc, key: "function")
                if let name = jsonGetString(jsonGet(fn, key: "name")) {
                    toolCallFunctionName += name
                }
                if let args = jsonGetString(jsonGet(fn, key: "arguments")) {
                    toolCallArguments += args
                }
            }
        }

        if inReasoning {
            print("\n\u{001B}[0m")
        }

        if !utf8IsEmpty(contentAccumulator) {
            print("")
        }

        if let errorMessage = errorMessage {
            return ChatMessage(role: "assistant", content: "api-error: \(errorMessage)")
        }

        if status < 0 {
            return ChatMessage(role: "assistant", content: "http-error: curl request failed")
        }

        if status != 200 {
            return ChatMessage(role: "assistant", content: "http-error: status \(status)")
        }

        if hasToolCall {
            let id = toolCallId ?? "call_\(c_rand())"
            let tc = ToolCall(
                id: id,
                functionName: toolCallFunctionName,
                arguments: toolCallArguments
            )
            return ChatMessage(role: "assistant", content: nil, toolCalls: [tc])
        }

        return ChatMessage(role: "assistant", content: contentAccumulator)
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
