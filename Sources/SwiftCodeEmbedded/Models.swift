// MARK: - Chat Message

struct ChatMessage {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    func toJSON() -> JSONValue? {
        let obj = jsonCreateObject()
        jsonAddItemToObject(obj, key: "role", item: jsonCreateString(role))

        if let content = content {
            jsonAddItemToObject(obj, key: "content", item: jsonCreateString(content))
        } else {
            jsonAddItemToObject(obj, key: "content", item: jsonCreateNull())
        }

        if let toolCalls = toolCalls, !toolCalls.isEmpty {
            let arr = jsonCreateArray()
            for tc in toolCalls {
                jsonAddItemToArray(arr, item: tc.toJSON())
            }
            jsonAddItemToObject(obj, key: "tool_calls", item: arr)
        }

        if let toolCallId = toolCallId {
            jsonAddItemToObject(obj, key: "tool_call_id", item: jsonCreateString(toolCallId))
        }

        return obj
    }
}

// MARK: - Tool Call

struct ToolCall {
    var id: String
    var functionName: String
    var arguments: String

    func toJSON() -> JSONValue? {
        let obj = jsonCreateObject()
        jsonAddItemToObject(obj, key: "id", item: jsonCreateString(id))
        jsonAddItemToObject(obj, key: "type", item: jsonCreateString("function"))

        let fn = jsonCreateObject()
        jsonAddItemToObject(fn, key: "name", item: jsonCreateString(functionName))
        jsonAddItemToObject(fn, key: "arguments", item: jsonCreateString(arguments))
        jsonAddItemToObject(obj, key: "function", item: fn)

        return obj
    }
}

// MARK: - Tool Definition

struct ToolDefinition {
    var name: String
    var description: String
    /// Pre-serialized JSON string for the parameters schema
    var parametersJSON: String

    func toJSON() -> JSONValue? {
        let obj = jsonCreateObject()
        jsonAddItemToObject(obj, key: "type", item: jsonCreateString("function"))

        let fn = jsonCreateObject()
        jsonAddItemToObject(fn, key: "name", item: jsonCreateString(name))
        jsonAddItemToObject(fn, key: "description", item: jsonCreateString(description))

        // Parse the pre-serialized parameters JSON and attach as a real object
        if let params = jsonParse(parametersJSON) {
            jsonAddItemToObject(fn, key: "parameters", item: params)
        }

        jsonAddItemToObject(obj, key: "function", item: fn)
        return obj
    }
}
