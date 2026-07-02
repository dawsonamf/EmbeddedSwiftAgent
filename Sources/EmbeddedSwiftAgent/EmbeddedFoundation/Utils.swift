import Cstdio

// MARK: - C Wrappers

func flushStdout() {
    flush_stdout()
}

func writeStderr(_ msg: String) {
    write_stderr(msg)
}

// MARK: - UTF8-Safe String Helpers
// Embedded Swift's stdlib doesn't include the Unicode normalization / grapheme-breaking
// tables. All string comparisons must go through the UTF8View to avoid pulling those in.

func utf8IsEmpty(_ s: String) -> Bool {
    var it = s.utf8.makeIterator()
    return it.next() == nil
}

func utf8HasPrefix(_ s: String, _ prefix: String) -> Bool {
    var si = s.utf8.makeIterator()
    var pi = prefix.utf8.makeIterator()
    while let pb = pi.next() {
        guard let sb = si.next(), sb == pb else { return false }
    }
    return true
}

func utf8HasSuffix(_ s: String, _ suffix: String) -> Bool {
    let sBytes = Array(s.utf8)
    let pBytes = Array(suffix.utf8)
    guard sBytes.count >= pBytes.count else { return false }
    let offset = sBytes.count - pBytes.count
    for i in 0..<pBytes.count {
        if sBytes[offset + i] != pBytes[i] { return false }
    }
    return true
}

func utf8Equal(_ a: String, _ b: String) -> Bool {
    var ai = a.utf8.makeIterator()
    var bi = b.utf8.makeIterator()
    while true {
        let ab = ai.next()
        let bb = bi.next()
        if ab != bb { return false }
        if ab == nil { return true }
    }
}

/// Drops the first `n` UTF-8 bytes from `s`.
/// Callers must ensure `n` lands on a UTF-8 character boundary (i.e. not in the
/// middle of a multi-byte sequence). Safe for ASCII-only offsets like SSE prefix stripping.
func utf8DropFirst(_ s: String, _ n: Int) -> String {
    let bytes = Array(s.utf8)
    guard n < bytes.count else { return "" }
    var slice = Array(bytes[n...])
    slice.append(0)
    return slice.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Truncates a string to at most `maxBytes` UTF-8 bytes, appending "..." if truncated.
/// Avoids String.count / String.prefix which pull in Unicode grapheme tables.
func utf8Truncate(_ s: String, maxBytes: Int) -> String {
    let bytes = Array(s.utf8)
    guard bytes.count > maxBytes else { return s }
    var slice = Array(bytes[..<maxBytes])
    slice.append(contentsOf: [0x2E, 0x2E, 0x2E]) // "..."
    slice.append(0)
    return slice.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Wraps a string in single quotes for safe shell interpolation.
/// Any embedded single quotes are escaped as `'\''` (end quote, escaped quote, reopen quote).
func shellEscape(_ s: String) -> String {
    var out: [UInt8] = [0x27] // opening '
    for byte in s.utf8 {
        if byte == 0x27 { // single quote
            out.append(contentsOf: [0x27, 0x5C, 0x27, 0x27]) // '\''
        } else {
            out.append(byte)
        }
    }
    out.append(0x27) // closing '
    out.append(0)
    return out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Creates `dir` and any missing parent directories (a native `mkdir -p`).
/// Returns nil on success, or an error description on failure.
/// Works on every platform including WASI — no shell involved.
func mkdirRecursive(_ dir: String) -> String? {
    let bytes = Array(dir.utf8)
    guard !bytes.isEmpty else { return nil }
    var i = 0
    while i <= bytes.count {
        // At each '/' (and at the end of the path), create the prefix so far.
        if i == bytes.count || bytes[i] == 0x2F {
            if i > 0 {
                var prefix = Array(bytes[0..<i])
                prefix.append(0)
                let partial = prefix.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                let rc = partial.withCString { sc_mkdir($0) }
                if rc != 0 {
                    return "cannot create directory '\(partial)'"
                }
            }
        }
        i += 1
    }
    return nil
}

/// Trims leading and trailing ASCII whitespace (space, tab, CR, LF)
func trimWhitespace(_ s: String) -> String {
    var bytes = Array(s.utf8)
    while let first = bytes.first,
          first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A {
        bytes.removeFirst()
    }
    while let last = bytes.last,
          last == 0x20 || last == 0x09 || last == 0x0D || last == 0x0A {
        bytes.removeLast()
    }
    guard !bytes.isEmpty else { return "" }
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
