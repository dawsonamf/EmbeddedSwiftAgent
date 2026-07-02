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

/// Reads an entire file as a UTF-8 string, or nil if it can't be opened.
func readEntireFile(_ path: String) -> String? {
    guard let fp = path.withCString({ fopen($0, "r") }) else { return nil }
    defer { fclose(fp) }

    fseek(fp, 0, SEEK_END)
    let fileSize = ftell(fp)
    fseek(fp, 0, SEEK_SET)
    guard fileSize > 0 else { return "" }

    var rawBytes = [UInt8](repeating: 0, count: fileSize)
    let bytesRead = fread(&rawBytes, 1, fileSize, fp)
    guard bytesRead > 0 else { return "" }

    var bytes = Array(rawBytes[0..<bytesRead])
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

// Optional system prompt: --system-prompt-file wins, then the SYSTEM_PROMPT
// environment variable (which is how the browser demo passes system-context.md in).
let systemPrompt: String? = {
    if let path = args.systemPromptFile {
        guard let contents = readEntireFile(path) else {
            writeStderr("Cannot read system prompt file: \(path)\n")
            exit(1)
        }
        return contents
    }
    return getenv("SYSTEM_PROMPT").map({ String(cString: $0) })
}()

// A configured system prompt becomes the first message of every conversation.
let initialMessages: [ChatMessage] = {
    guard let systemPrompt, !utf8IsEmpty(systemPrompt) else { return [] }
    return [ChatMessage(role: ChatRole.system, content: systemPrompt)]
}()

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

            emitEvent(.turnStart)

            // Stream LLM response
            let toolDefinitions = tools.map { $0.definition }
            emitEvent(.messageStart(message: ChatMessage(role: ChatRole.assistant)))
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
            guard !streamResult.toolCalls.isEmpty else {
                emitEvent(.turnEnd(message: assistantMessage, toolResults: []))
                break
            }

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
#if os(WASI)
        // Browser REPL: input arrives from xterm.js through the JS host bridge
        // (agent_input_wait suspends the wasm stack via JSPI until the user
        // submits a line). Ctrl+C arrives through the agent_abort export,
        // polled at HTTP chunk boundaries. No threads, no signals, no termios.
        var messages = initialMessages

        showPrompt()

        while true {
            let inputLen = agent_input_wait()
            if inputLen < 0 { break }

            var input = ""
            if inputLen > 0 {
                var buf = [UInt8](repeating: 0, count: Int(inputLen))
                let copied = buf.withUnsafeMutableBufferPointer { ptr in
                    agent_input_read(ptr.baseAddress, Int32(ptr.count))
                }
                if copied > 0 {
                    var bytes = Array(buf[0..<Int(copied)])
                    bytes.append(0)
                    input = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                }
            }

            let trimmed = trimWhitespace(input)
            if utf8IsEmpty(trimmed) {
                showPrompt()
                continue
            }

            messages.append(ChatMessage(role: ChatRole.user, content: trimmed))

            run(messages: &messages)

            abortFlag.reset()
            sc_wasm_abort_clear()
            showPrompt()
        }
#else
        sc_install_sigint_handler(abortFlag.rawPointer)

        let inputReader = InputReader(abortFlag: abortFlag)
        inputReader.start()

        var messages = initialMessages

        showPrompt()

        while let input = inputReader.waitForInput() {
            messages.append(ChatMessage(role: ChatRole.user, content: input))

            run(messages: &messages)

            abortFlag.reset()
            showPrompt()
        }
#endif
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
