import Ccurl
import Cstdio

// MARK: - Streaming HTTP POST

/// Context passed through CURLOPT_WRITEDATA to the C write callback.
/// Buffers incoming bytes and invokes `onLine` for each complete line.
///
/// Thread-safety: this is only safe because `curl_easy_perform` calls the write
/// callback synchronously on the calling thread. A switch to `curl_multi` would
/// require synchronization around `buffer` and `onLine`.
final class StreamContext {
    var buffer: [UInt8] = []
    var onLine: (String) -> Void
    var abortFlag: AbortFlag?

    init(onLine: @escaping (String) -> Void, abortFlag: AbortFlag? = nil) {
        self.onLine = onLine
        self.abortFlag = abortFlag
    }
}

/// C-compatible write callback for libcurl.
/// Buffers data and calls the Swift closure for each newline-delimited line.
private let curlWriteCallback: curl_write_callback = { (ptr: UnsafeMutablePointer<Int8>?, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
    let totalBytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }

    let ctx = Unmanaged<StreamContext>.fromOpaque(userdata).takeUnretainedValue()
    if let abortFlag = ctx.abortFlag, abortFlag.isSet() {
        // Returning 0 tells curl to abort the transfer.
        return 0
    }

    for i in 0..<totalBytes {
        let byte = UInt8(bitPattern: ptr[i])
        if byte == UInt8(0x0A) {
            if !ctx.buffer.isEmpty {
                ctx.buffer.append(0)
                let line = ctx.buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                ctx.onLine(line)
                ctx.buffer.removeAll(keepingCapacity: true)
            }
        } else {
            ctx.buffer.append(byte)
        }
    }

    return totalBytes
}

struct HTTPResult {
    let statusCode: Int32
    /// Non-nil when curl itself failed (network error, DNS failure, etc.)
    let curlError: String?
}

struct HTTPResponse {
    let statusCode: Int32
    let body: String
    let curlError: String?
}

/// Accumulates all incoming bytes into a flat buffer for non-streaming HTTP POST.
private final class BufferContext {
    var buffer: [UInt8] = []
}

private let curlBufferCallback: curl_write_callback = { (ptr: UnsafeMutablePointer<Int8>?, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
    let totalBytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let ctx = Unmanaged<BufferContext>.fromOpaque(userdata).takeUnretainedValue()
    for i in 0..<totalBytes {
        ctx.buffer.append(UInt8(bitPattern: ptr[i]))
    }
    return totalBytes
}

/// Performs a non-streaming HTTP POST and returns the full response body.
/// Thread-safe: each call creates its own curl handle.
func httpPost(
    url: String,
    headers: [(String, String)],
    body: String
) -> HTTPResponse {
    guard let curl = curl_easy_init() else {
        return HTTPResponse(statusCode: -1, body: "", curlError: "curl_easy_init failed")
    }
    defer { curl_easy_cleanup(curl) }

    _ = url.withCString { curl_easy_setopt_string(curl, CURLOPT_URL, $0) }
    curl_easy_setopt_long(curl, CURLOPT_POST, 1)
    curl_easy_setopt_string(curl, CURLOPT_COPYPOSTFIELDS, body)

    var headerList: UnsafeMutablePointer<curl_slist>? = nil
    for (key, value) in headers {
        headerList = curl_slist_append(headerList, "\(key): \(value)")
    }
    curl_easy_setopt_slist(curl, CURLOPT_HTTPHEADER, headerList)
    defer { curl_slist_free_all(headerList) }

    let ctx = BufferContext()
    let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
    defer { Unmanaged<BufferContext>.fromOpaque(ctxPtr).release() }

    curl_easy_setopt_writefunc(curl, curlBufferCallback)
    curl_easy_setopt_writedata(curl, ctxPtr)

    let result = curl_easy_perform(curl)

    if result != CURLE_OK {
        let errStr = String(cString: curl_easy_strerror_wrapper(result))
        return HTTPResponse(statusCode: -1, body: "", curlError: errStr)
    }

    var statusCode: CLong = 0
    curl_easy_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &statusCode)

    ctx.buffer.append(0)
    let bodyStr = ctx.buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return HTTPResponse(statusCode: Int32(statusCode), body: bodyStr, curlError: nil)
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
    guard let curl = curl_easy_init() else {
        return HTTPResult(statusCode: -1, curlError: "curl_easy_init failed")
    }
    defer { curl_easy_cleanup(curl) }

    _ = url.withCString { curl_easy_setopt_string(curl, CURLOPT_URL, $0) }
    curl_easy_setopt_long(curl, CURLOPT_POST, 1)
    curl_easy_setopt_string(curl, CURLOPT_COPYPOSTFIELDS, body)

    var headerList: UnsafeMutablePointer<curl_slist>? = nil
    for (key, value) in headers {
        headerList = curl_slist_append(headerList, "\(key): \(value)")
    }
    curl_easy_setopt_slist(curl, CURLOPT_HTTPHEADER, headerList)

    let ctx = StreamContext(onLine: onLine, abortFlag: abortFlag)
    let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
    defer { Unmanaged<StreamContext>.fromOpaque(ctxPtr).release() }

    curl_easy_setopt_writefunc(curl, curlWriteCallback)
    curl_easy_setopt_writedata(curl, ctxPtr)

    let result = curl_easy_perform(curl)

    // Flush any remaining buffered data
    if !ctx.buffer.isEmpty {
        ctx.buffer.append(0)
        let line = ctx.buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        ctx.onLine(line)
    }

    curl_slist_free_all(headerList)

    if result != CURLE_OK {
        let errStr = String(cString: curl_easy_strerror_wrapper(result))
        return HTTPResult(statusCode: -1, curlError: errStr)
    }

    var statusCode: CLong = 0
    curl_easy_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &statusCode)
    return HTTPResult(statusCode: Int32(statusCode), curlError: nil)
}
