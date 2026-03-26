import Cstdio

// MARK: - Configuration

let args = parseArgs()

let apiKey: String = args.openrouterKey
    ?? getenv("OPENROUTER_API_KEY").map({ String(cString: $0) })
    ?? {
        writeStderr("Set OPENROUTER_API_KEY via --openrouter-key flag or as an environment variable\n")
        exit(1)
    }()

let exaApiKey: String? = args.exaKey
    ?? getenv("EXA_API_KEY").map({ String(cString: $0) })

let model = args.model ?? getenv("MODEL").map({ String(cString: $0) }) ?? defaultModel
let reasoningEffort = args.reasoningEffort ?? getenv("REASONING_EFFORT").map({ String(cString: $0) }) ?? defaultReasoningEffort
let client = OpenRouterClient(apiKey: apiKey, model: model, reasoningEffort: reasoningEffort)
let tools = allTools

// MARK: - Agent Loop
//
// The core algorithm: send messages to the LLM, execute any tool calls it
// requests, append results, and loop until the model stops calling tools.
//
// NOTE: Steering (Ctrl+S) and follow-up (Enter while running) support is
// implemented in InputReader but not wired into the agent loop yet.
// See InputReader.swift for the raw-mode input handling and queue plumbing.

struct AgentLoop: Sendable {
    let client: OpenRouterClient
    let exaApiKey: String?
    let tools: [Tool]
    let abortFlag: AbortFlag
    let emitEvent: @Sendable (AgentEvent) -> Void

    /// Runs a single agent turn: streams LLM responses, executes tool calls, and
    /// loops until the model stops calling tools or the user aborts.
    func run(messages: inout [ChatMessage]) {
        emitEvent(.agentStart)

        while true {
            if abortFlag.isSet() { emitEvent(.aborted); break }

            // Stream LLM response
            let toolDefinitions = tools.map { $0.definition }
            let streamResult = client.sendStreaming(
                messages: messages,
                tools: toolDefinitions,
                abortFlag: abortFlag
            ) { streamEvent in
                emitEvent(.messageUpdate(message: ChatMessage(role: ChatRole.assistant), streamEvent: streamEvent))
            }
            if streamResult.isError { break }

            // Append assistant message
            let assistantMessage = streamResult.toAssistantMessage()
            emitEvent(.messageEnd(message: assistantMessage))
            messages.append(assistantMessage)

            // No tool calls — model is done
            guard !streamResult.toolCalls.isEmpty else { break }

            // Abort check before running tools
            if abortFlag.isSet() {
                appendSyntheticResults(from: 0, in: streamResult.toolCalls, content: "Aborted by user", to: &messages)
                break
            }

            // Execute tool calls
            let toolResults = executeToolsInParallel(streamResult.toolCalls)

            for result in toolResults {
                messages.append(result.toChatMessage())
            }

            emitEvent(.turnEnd(message: assistantMessage, toolResults: toolResults))
        }

        emitEvent(.agentEnd(messages: messages))
    }

    /// Starts the interactive REPL: installs signal handlers, reads input, and
    /// dispatches each user message through `run()`.
    func start() {
        sc_install_sigint_handler(abortFlag.rawPointer)

        let inputReader = InputReader(abortFlag: abortFlag)
        inputReader.start()

        var messages: [ChatMessage] = []

        showPrompt()

        while let input = inputReader.waitForInput() {
            messages.append(ChatMessage(role: ChatRole.user, content: input))

            run(messages: &messages)

            abortFlag.reset()
            showPrompt()
        }
    }
}

// MARK: - REPL

let abortFlag = AbortFlag()

AgentLoop(
    client: client,
    exaApiKey: exaApiKey,
    tools: tools,
    abortFlag: abortFlag,
    emitEvent: renderEvent
).start()
