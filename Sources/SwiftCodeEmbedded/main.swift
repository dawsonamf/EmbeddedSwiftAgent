#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Configuration

guard let apiKeyCStr = getenv("OPENROUTER_API_KEY") else {
    writeStderr("Set OPENROUTER_API_KEY environment variable\n")
    exit(1)
}
let apiKey = String(cString: apiKeyCStr)

let client = OpenRouterClient(apiKey: apiKey, model: "anthropic/claude-haiku-4.5")

let shellTool = ToolDefinition(
    name: "sh",
    description: "Execute a shell command and return its output",
    parametersJSON: """
    {"type":"object","properties":{"c":{"type":"string","description":"The shell command to execute"}},"required":["c"]}
    """
)
let tools = [shellTool]

// MARK: - Agent Loop

var messages: [ChatMessage] = []

print("> ", terminator: "")
flushStdout()

while let line = readLine() {
    let input = trimWhitespace(line)
    guard !input.isEmpty else {
        print("> ", terminator: "")
        flushStdout()
        continue
    }

    messages.append(ChatMessage(role: "user", content: input))

    var done = false
    while !done {
        let reply = client.sendStreaming(messages: messages, tools: tools)
        messages.append(reply)

        if let toolCalls = reply.toolCalls, let toolCall = toolCalls.first {
            // Parse the tool call arguments to extract the command
            let command = extractShellCommand(from: toolCall.arguments)
            print("[running: \(command)]")
            let output = runShell(command)
            print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
            messages.append(ChatMessage(
                role: "tool",
                content: output,
                toolCallId: toolCall.id
            ))
        } else {
            done = true
        }
    }

    print("> ", terminator: "")
    flushStdout()
}

// MARK: - Helpers

/// Extracts the "c" field from the tool call arguments JSON string.
func extractShellCommand(from arguments: String) -> String {
    guard let json = jsonParse(arguments) else { return arguments }
    return jsonGetString(jsonGet(json, key: "c")) ?? arguments
}
