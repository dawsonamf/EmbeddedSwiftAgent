// MARK: - Chat Message

/// String constants for OpenRouter role values.
/// Not a RawRepresentable enum because embedded Swift lacks the runtime support
/// for String-backed enums. ChatMessage.role is typed as String for direct JSON serialization.
enum ChatRole {
    static let system = "system"
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
    var parameters: JSONValue?

    func toJSON() -> JSONValue? {
        .object(
            ("type", .string("function")),
            ("function", .object(
                ("name", .string(name)),
                ("description", .string(description)),
                ("parameters", parameters?.duplicate())
            ))
        )
    }
}

// MARK: - Tool

/// Everything needed to execute a tool — passed into each tool's execute closure
/// so tools stay decoupled from AgentLoop.
struct ToolContext {
    var toolCallId: String
    var client: OpenRouterClient
    var exaApiKey: String?
    var tools: [Tool]
    var abortFlag: AbortFlag
    var emitEvent: @Sendable (AgentEvent) -> Void
}

/// A single tool: its API definition + its execution logic.
/// Uses a closure instead of a protocol to avoid existential types (unsupported in embedded Swift).
struct Tool: @unchecked Sendable {
    var definition: ToolDefinition

    /// Executes the tool given raw JSON arguments and a context.
    /// Returns the content string and whether it's an error.
    var execute: (String, ToolContext) -> (content: String, isError: Bool)

    var name: String { definition.name }
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

    func toAssistantMessage() -> ChatMessage {
        ChatMessage(
            role: ChatRole.assistant,
            content: contentText,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }
}
