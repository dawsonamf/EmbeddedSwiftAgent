import Cstdio

// MARK: - ANSI Colors

let ansiReset      = "\u{001B}[0m"
let ansiDim        = "\u{001B}[2m"
let ansiBold       = "\u{001B}[1m"
let ansiRed        = "\u{001B}[31m"
let ansiBlue       = "\u{001B}[34m"
let ansiDimBlue    = "\u{001B}[2;34m"
let ansiMagenta    = "\u{001B}[35m"
let ansiYellow     = "\u{001B}[33m"

// MARK: - Tool Result Previews

// Display-only limits — the model always receives the full tool output in context.
let toolResultPreviewMaxLines = 5
let toolResultPreviewMaxBytes = 500

/// Truncates a tool result for terminal display: at most `toolResultPreviewMaxLines`
/// lines and `toolResultPreviewMaxBytes` bytes. Returns the preview and how many
/// bytes were omitted (0 if the full result fit).
func truncateToolResultForDisplay(_ s: String) -> (text: String, omittedBytes: Int) {
    let bytes = Array(s.utf8)
    var end = 0
    var lines = 0
    while end < bytes.count && end < toolResultPreviewMaxBytes && lines < toolResultPreviewMaxLines {
        if bytes[end] == 0x0A { lines += 1 }
        end += 1
    }
    if end >= bytes.count { return (s, 0) }
    // Back off to a UTF-8 boundary so we never split a multi-byte character
    while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
    var slice = Array(bytes[..<end])
    slice.append(0)
    let text = slice.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return (text, bytes.count - end)
}

// MARK: - Event Rendering

func renderEventCore(_ event: AgentEvent, prefix: String) {
    switch event {
    case .messageUpdate(_, let streamEvent):
        switch streamEvent {
        case .thinkingStart:
            print("\(prefix)\(ansiDim)", terminator: "")
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
            writeStderr("\(prefix)\(ansiRed)error: \(message)\(ansiReset)\n")
        default:
            break
        }

    case .toolExecStart(_, let toolName, let args):
        let json = jsonParse(args)
        if utf8Equal(toolName, "sh") {
            let command = json?["c"]?.string ?? args
            print("\(prefix)\(ansiBlue)[running: \(command)]\(ansiReset)")
        } else if utf8Equal(toolName, "read_file") {
            let path = json?["path"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[reading: \(path)]\(ansiReset)")
        } else if utf8Equal(toolName, "write_file") {
            let path = json?["path"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[writing: \(path)]\(ansiReset)")
        } else if utf8Equal(toolName, "str_replace") {
            let path = json?["path"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[editing: \(path)]\(ansiReset)")
        } else if utf8Equal(toolName, "glob") {
            let pattern = json?["pattern"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[glob: \(pattern)]\(ansiReset)")
        } else if utf8Equal(toolName, "grep") {
            let pattern = json?["pattern"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[grep: \(pattern)]\(ansiReset)")
        } else if utf8Equal(toolName, "web_search") {
            let query = json?["query"]?.string ?? ""
            let preview = utf8Truncate(query, maxBytes: 60)
            print("\(prefix)\(ansiBlue)[searching: \(preview)]\(ansiReset)")
        } else if utf8Equal(toolName, "web_fetch") {
            let url = json?["url"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[fetching: \(url)]\(ansiReset)")
        } else if utf8Equal(toolName, "mcp") {
            let server = json?["server"]?.string ?? ""
            let tool = json?["tool"]?.string ?? ""
            print("\(prefix)\(ansiBlue)[mcp: \(server)/\(tool)]\(ansiReset)")
        } else if utf8Equal(toolName, "subagent") {
            let task = json?["task"]?.string ?? ""
            let preview = utf8Truncate(task, maxBytes: 80)
            print("\(prefix)\(ansiMagenta)┌─ subagent: \(preview)\(ansiReset)")
        }

    // toolExecUpdate is deliberately not rendered: it's emitted from tool threads,
    // so parallel subagents streaming into one terminal interleave into gibberish.
    // The event still exists for structured consumers (e.g. the planned server API).

    case .toolExecEnd(_, let toolName, let result, let isError):
        if utf8Equal(toolName, "subagent") {
            print("\(prefix)\(ansiMagenta)└─ subagent done\(ansiReset)")
            break
        }
        let (preview, omittedBytes) = truncateToolResultForDisplay(result)
        if utf8IsEmpty(preview) && omittedBytes == 0 { break }
        let color = isError ? ansiRed : ansiDimBlue
        print("\(prefix)\(color)\(preview)\(ansiReset)", terminator: utf8HasSuffix(preview, "\n") ? "" : "\n")
        if omittedBytes > 0 {
            print("\(prefix)\(ansiDim)[+\(omittedBytes) bytes truncated]\(ansiReset)")
        }

    case .toolCallSkipped(_, let toolName, let reason):
        print("\(prefix)\(ansiDimBlue)[skipped \(toolName): \(reason)]\(ansiReset)")

    case .steeringReceived:
        print("\(prefix)\(ansiYellow)[steering received]\(ansiReset)")

    case .followUpConsumed(let text):
        let preview = utf8Truncate(text, maxBytes: 60)
        print("\(prefix)\(ansiYellow)[follow-up: \(preview)]\(ansiReset)")

    case .aborted:
        print("\(prefix)\n\(ansiRed)[aborted]\(ansiReset)")

    default:
        break
    }
}

/// Top-level event renderer passed to AgentLoop as the emitEvent callback.
func renderEvent(_ event: AgentEvent) {
    renderEventCore(event, prefix: "")
}

func showPrompt() {
    print("\(ansiBold)> \(ansiReset)", terminator: "")
    flushStdout()
}
