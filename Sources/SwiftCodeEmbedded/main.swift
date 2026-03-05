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

// MARK: - ANSI Colors

let ansiReset     = "\u{001B}[0m"
let ansiDim       = "\u{001B}[2m"
let ansiBold      = "\u{001B}[1m"
let ansiRed       = "\u{001B}[31m"
let ansiBlue      = "\u{001B}[34m"
let ansiDimBlue   = "\u{001B}[2;34m"

// MARK: - CLI Renderer

/// Subscribes to AgentEvents and handles all terminal output.
func renderEvent(_ event: AgentEvent) {
    switch event {
    case .messageUpdate(_, let streamEvent):
        switch streamEvent {
        case .thinkingStart:
            print(ansiDim, terminator: "")
        case .thinkingDelta(let text):
            print(text, terminator: "")
            flushStdout()
        case .thinkingEnd:
            print("\n\(ansiReset)", terminator: "")
        case .textDelta(let text):
            print(text, terminator: "")
            flushStdout()
        case .textEnd:
            print("")
        case .error(let message):
            writeStderr("\(ansiRed)error: \(message)\(ansiReset)\n")
        default:
            break
        }

    case .toolExecStart(_, let toolName, let args):
        if utf8Equal(toolName, "sh") {
            let command = extractShellCommand(from: args)
            print("\(ansiBlue)[running: \(command)]\(ansiReset)")
        }

    case .toolExecEnd(_, _, let result, let isError):
        if isError {
            print("\(ansiRed)\(result)\(ansiReset)", terminator: utf8HasSuffix(result, "\n") ? "" : "\n")
        } else {
            print("\(ansiDimBlue)\(result)\(ansiReset)", terminator: utf8HasSuffix(result, "\n") ? "" : "\n")
        }

    case .toolCallSkipped(_, let toolName, let reason):
        print("\(ansiDimBlue)[skipped \(toolName): \(reason)]\(ansiReset)")

    case .aborted:
        print("\n\(ansiRed)[aborted]\(ansiReset)")

    default:
        break
    }
}

func showPrompt() {
    print("\(ansiBold)> \(ansiReset)", terminator: "")
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
