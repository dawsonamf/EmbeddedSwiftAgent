#if os(WASI)
import Cstdio

// MARK: - Browser HTTP backend (wasm build)
//
// Same two entry points as the native curl implementation, bridged over the
// "agent" JS imports (web/agent.js). The JS side wraps the async imports in
// WebAssembly.Suspending, so the wasm stack suspends via JSPI while the
// browser awaits fetch — these functions stay synchronous from the agent
// loop's point of view.

private let chunkBufferSize = 16384

/// Propagates a browser-side abort request (xterm Ctrl+C sets a C global via
/// the agent_abort export) into the Swift abort flag.
private func pollBrowserAbort(_ abortFlag: AbortFlag?) {
    if sc_wasm_abort_pending() != 0 {
        abortFlag?.set()
    }
}

/// Serializes headers as "Key: Value\n" lines for the JS side to split.
private func headerBlob(_ headers: [(String, String)]) -> [UInt8] {
    var out: [UInt8] = []
    for (key, value) in headers {
        out.append(contentsOf: Array(key.utf8))
        out.append(0x3A) // ':'
        out.append(0x20) // ' '
        out.append(contentsOf: Array(value.utf8))
        out.append(0x0A)
    }
    return out
}

private func httpBegin(url: String, headers: [(String, String)], body: String) -> Int32 {
    let urlBytes = Array(url.utf8)
    let headerBytes = headerBlob(headers)
    let bodyBytes = Array(body.utf8)
    return urlBytes.withUnsafeBufferPointer { u in
        headerBytes.withUnsafeBufferPointer { h in
            bodyBytes.withUnsafeBufferPointer { b in
                agent_http_begin(
                    u.baseAddress, Int32(u.count),
                    h.baseAddress, Int32(h.count),
                    b.baseAddress, Int32(b.count)
                )
            }
        }
    }
}

private func httpErrorMessage(_ handle: Int32) -> String {
    var buf = [UInt8](repeating: 0, count: 1024)
    let len = buf.withUnsafeMutableBufferPointer { ptr in
        agent_http_error_msg(handle, ptr.baseAddress, Int32(ptr.count))
    }
    guard len > 0 else { return "unknown network error" }
    var bytes = Array(buf[0..<Int(len)])
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

/// Performs a non-streaming HTTP POST and returns the full response body.
func httpPost(
    url: String,
    headers: [(String, String)],
    body: String
) -> HTTPResponse {
    let handle = httpBegin(url: url, headers: headers, body: body)
    defer { agent_http_close(handle) }

    let status = agent_http_status(handle)
    if status < 0 {
        return HTTPResponse(statusCode: -1, body: "", curlError: httpErrorMessage(handle))
    }

    var bodyBytes: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: chunkBufferSize)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            agent_http_next_chunk(handle, ptr.baseAddress, Int32(ptr.count))
        }
        if n == 0 { break }
        if n < 0 {
            return HTTPResponse(statusCode: -1, body: "", curlError: httpErrorMessage(handle))
        }
        bodyBytes.append(contentsOf: buf[0..<Int(n)])
    }

    bodyBytes.append(0)
    let bodyStr = bodyBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return HTTPResponse(statusCode: status, body: bodyStr, curlError: nil)
}

/// Performs a streaming HTTP POST. Calls `onLine` for each newline-delimited
/// chunk received from the server (designed for SSE consumption).
@discardableResult
func httpPostStreaming(
    url: String,
    headers: [(String, String)],
    body: String,
    abortFlag: AbortFlag? = nil,
    onLine: @escaping (String) -> Void
) -> HTTPResult {
    pollBrowserAbort(abortFlag)
    if let abortFlag = abortFlag, abortFlag.isSet() {
        return HTTPResult(statusCode: -1, curlError: nil)
    }

    let handle = httpBegin(url: url, headers: headers, body: body)
    defer { agent_http_close(handle) }

    pollBrowserAbort(abortFlag)
    if let abortFlag = abortFlag, abortFlag.isSet() {
        return HTTPResult(statusCode: -1, curlError: nil)
    }

    let status = agent_http_status(handle)
    if status < 0 {
        return HTTPResult(statusCode: -1, curlError: httpErrorMessage(handle))
    }

    // Same buffer/split behavior as the native curl write callback: accumulate
    // bytes, emit each non-empty line at a newline, flush the remainder at
    // end of stream.
    var lineBuffer: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: chunkBufferSize)

    func emitLine() {
        guard !lineBuffer.isEmpty else { return }
        lineBuffer.append(0)
        let line = lineBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        onLine(line)
        lineBuffer.removeAll(keepingCapacity: true)
    }

    while true {
        pollBrowserAbort(abortFlag)
        if let abortFlag = abortFlag, abortFlag.isSet() {
            return HTTPResult(statusCode: -1, curlError: nil)
        }

        let n = buf.withUnsafeMutableBufferPointer { ptr in
            agent_http_next_chunk(handle, ptr.baseAddress, Int32(ptr.count))
        }
        if n == 0 { break }
        if n == -2 {
            // Fetch aborted from the JS side (user hit Ctrl+C).
            abortFlag?.set()
            return HTTPResult(statusCode: -1, curlError: nil)
        }
        if n < 0 {
            return HTTPResult(statusCode: -1, curlError: httpErrorMessage(handle))
        }

        for i in 0..<Int(n) {
            let byte = buf[i]
            if byte == 0x0A {
                emitLine()
            } else {
                lineBuffer.append(byte)
            }
        }
    }

    emitLine()
    return HTTPResult(statusCode: status, curlError: nil)
}

#endif // os(WASI)
