import Cstdio

// C stdio streams are thread-safe (internally locked), but Swift 6 can't prove it
// from the type system alone. These thin C wrappers avoid the concurrency diagnostic.
func flushStdout() {
    flush_stdout()
}

func writeStderr(_ msg: String) {
    write_stderr(msg)
}

/// Trims leading and trailing whitespace characters (space, tab, CR, LF)
/// without depending on Foundation's CharacterSet.
func trimWhitespace(_ s: String) -> String {
    let whitespace: [Character] = [" ", "\t", "\r", "\n"]
    var start = s.startIndex
    var end = s.endIndex

    while start < end && whitespace.contains(s[start]) {
        start = s.index(after: start)
    }
    while end > start && whitespace.contains(s[s.index(before: end)]) {
        end = s.index(before: end)
    }

    return String(s[start..<end])
}
