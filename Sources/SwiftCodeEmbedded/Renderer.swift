import Cstdio

// MARK: - ANSI Colors

let ansiReset      = "\u{001B}[0m"
let ansiDim        = "\u{001B}[2m"
let ansiBold       = "\u{001B}[1m"
let ansiRed        = "\u{001B}[31m"
let ansiBlue       = "\u{001B}[34m"
let ansiDimBlue    = "\u{001B}[2;34m"
let ansiMagenta    = "\u{001B}[35m"
let ansiDimMagenta = "\u{001B}[2;35m"

nonisolated(unsafe) var quietSubagents = true

// MARK: - Event Rendering

/// Shared rendering logic. `prefix` is empty for top-level events,
/// or a gutter string (e.g. "│ ") for nested subagent output.
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
        if utf8Equal(toolName, "sh") {
            let command = extractShellCommand(from: args)
            print("\(prefix)\(ansiBlue)[running: \(command)]\(ansiReset)")
        }

    case .toolExecEnd(_, let toolName, let result, let isError):
        if utf8Equal(toolName, "subagent") { break }
        if isError {
            print("\(prefix)\(ansiRed)\(result)\(ansiReset)", terminator: utf8HasSuffix(result, "\n") ? "" : "\n")
        } else {
            print("\(prefix)\(ansiDimBlue)\(result)\(ansiReset)", terminator: utf8HasSuffix(result, "\n") ? "" : "\n")
        }

    case .toolCallSkipped(_, let toolName, let reason):
        print("\(prefix)\(ansiDimBlue)[skipped \(toolName): \(reason)]\(ansiReset)")

    case .subagentStart(let task):
        let preview = utf8Truncate(task, maxBytes: 80)
        print("\(prefix)\(ansiMagenta)┌─ subagent: \(preview)\(ansiReset)")

    case .subagentEnd:
        print("\(prefix)\(ansiMagenta)└─ subagent done\(ansiReset)")

    case .subagentEvent(let innerEvent):
        if !quietSubagents {
            let subPrefix = "\(prefix)\(ansiDimMagenta)│\(ansiReset) "
            renderEventCore(innerEvent, prefix: subPrefix)
        }

    case .aborted:
        print("\(prefix)\n\(ansiRed)[aborted]\(ansiReset)")

    default:
        break
    }
}

/// Top-level event renderer passed to AgentLoop as the onEvent callback.
func renderEvent(_ event: AgentEvent) {
    renderEventCore(event, prefix: "")
}

func showPrompt() {
    print("\(ansiBold)> \(ansiReset)", terminator: "")
    flushStdout()
}
