// MARK: - Chat Message

/// String constants for OpenRouter role values.
/// Not a RawRepresentable enum because embedded Swift lacks the runtime support
/// for String-backed enums. ChatMessage.role is typed as String for direct JSON serialization.
enum ChatRole {
    static let user = "user"
    static let assistant = "assistant"
    static let tool = "tool"
}

struct ChatMessage {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?

    func toJSON() -> JSONValue? {
        let obj = JSONValue.object(
            ("role", .string(role)),
            ("content", content.flatMap { .string($0) } ?? .null()),
            ("tool_call_id", toolCallId.flatMap { .string($0) })
        )
        if let toolCalls = toolCalls, !toolCalls.isEmpty {
            obj?["tool_calls"] = JSONValue.array(toolCalls.map { $0.toJSON() })
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
        .object(
            ("id", .string(id)),
            ("type", .string("function")),
            ("function", .object(
                ("name", .string(functionName)),
                ("arguments", .string(arguments))
            ))
        )
    }
}

// MARK: - Tool Definition

struct ToolDefinition {
    var name: String
    var description: String
    /// Pre-serialized JSON string for the parameters schema
    var parametersJSON: String

    func toJSON() -> JSONValue? {
        .object(
            ("type", .string("function")),
            ("function", .object(
                ("name", .string(name)),
                ("description", .string(description)),
                ("parameters", jsonParse(parametersJSON))
            ))
        )
    }
}

// MARK: - Tool Result Message

struct ToolResultMessage {
    var toolCallId: String
    var content: String
    var isError: Bool

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            role: ChatRole.tool,
            content: content,
            toolCallId: toolCallId
        )
    }
}

// MARK: - Turn Result

enum TurnResult {
    case done
    case `continue`
    case exit
}

// MARK: - Stream Result

struct StreamResult {
    var contentText: String?
    var thinkingText: String?
    var toolCalls: [ToolCall]
    var stopReason: StopReason
    var errorMessage: String?

    var isError: Bool {
        errorMessage != nil
    }
}
