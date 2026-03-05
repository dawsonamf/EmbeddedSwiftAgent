import Cstdio

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

// MARK: - CLI Renderer

/// Subscribes to AgentEvents and handles all terminal output.
func renderEvent(_ event: AgentEvent) {
    switch event {
    case .messageUpdate(_, let streamEvent):
        switch streamEvent {
        case .thinkingStart:
            print("\u{001B}[2m", terminator: "")
        case .thinkingDelta(let text):
            print(text, terminator: "")
            flushStdout()
        case .thinkingEnd:
            print("\n\u{001B}[0m", terminator: "")
        case .textDelta(let text):
            print(text, terminator: "")
            flushStdout()
        case .textEnd:
            print("")
        case .error(let message):
            writeStderr("error: \(message)\n")
        default:
            break
        }

    case .toolExecStart(_, let toolName, let args):
        if utf8Equal(toolName, "sh") {
            let command = extractShellCommand(from: args)
            print("[running: \(command)]")
        }

    case .toolExecEnd(_, _, let result, _):
        print(result, terminator: utf8HasSuffix(result, "\n") ? "" : "\n")

    case .toolCallSkipped(_, let toolName, let reason):
        print("[skipped \(toolName): \(reason)]")

    case .aborted:
        print("\n[aborted]")

    default:
        break
    }
}

func showPrompt() {
    print("> ", terminator: "")
    flushStdout()
}

// MARK: - Agent Runtime

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
    tools: tools,
    abortFlag: abortFlag,
    onEvent: renderEvent
)

inputReader.start()
showPrompt()

// InputReader owns stdin. Main thread consumes direct input from queue.
while true {
    var input: String? = nil
    while input == nil {
        if abortFlag.isSet() || inputReader.eofFlag.isSet() { break }
        input = directInputQueue.waitAndPop(timeoutMs: 100)
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
