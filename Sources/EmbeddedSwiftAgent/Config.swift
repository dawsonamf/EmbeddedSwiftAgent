import Cstdio

// MARK: - Config

struct ParsedArgs {
    var model: String?
    var openrouterKey: String?
    var exaKey: String?
}

let defaultModel = "anthropic/claude-haiku-4.5"

/// Parses CLI arguments for `--model`, `--openrouter-key`, and `--exa-key`.
/// Each flag expects the next argument as its value.
func parseArgs() -> ParsedArgs {
    var result = ParsedArgs()
    let argc = Int(sc_get_argc())
    var i = 1
    while i < argc {
        guard let raw = sc_get_argv(Int32(i)) else { i += 1; continue }
        let arg = String(cString: raw)
        if utf8Equal(arg, "--model") {
            i += 1
            if i < argc, let val = sc_get_argv(Int32(i)) {
                result.model = String(cString: val)
            }
        } else if utf8Equal(arg, "--openrouter-key") {
            i += 1
            if i < argc, let val = sc_get_argv(Int32(i)) {
                result.openrouterKey = String(cString: val)
            }
        } else if utf8Equal(arg, "--exa-key") {
            i += 1
            if i < argc, let val = sc_get_argv(Int32(i)) {
                result.exaKey = String(cString: val)
            }
        }
        i += 1
    }
    return result
}
