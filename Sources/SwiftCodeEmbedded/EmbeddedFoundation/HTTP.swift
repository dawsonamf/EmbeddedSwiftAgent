import Ccurl
import Cstdio

// MARK: - Streaming HTTP POST

/// Context passed through CURLOPT_WRITEDATA to the C write callback.
/// Buffers incoming bytes and invokes `onLine` for each complete line.
final class StreamContext {
    var buffer: [UInt8] = []
    var onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }
}

/// C-compatible write callback for libcurl.
/// Buffers data and calls the Swift closure for each newline-delimited line.
private let curlWriteCallback: curl_write_callback = { (ptr: UnsafeMutablePointer<Int8>?, size: Int, nmemb: Int, userdata: UnsafeMutableRawPointer?) -> Int in
    let totalBytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return 0 }

    let ctx = Unmanaged<StreamContext>.fromOpaque(userdata).takeUnretainedValue()

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

/// Performs a streaming HTTP POST. Calls `onLine` for each newline-delimited
/// chunk received from the server (designed for SSE consumption).
/// Returns the HTTP status code, or -1 on curl failure.
@discardableResult
func httpPostStreaming(
    url: String,
    headers: [(String, String)],
    body: String,
    onLine: @escaping (String) -> Void
) -> Int32 {
    guard let curl = curl_easy_init() else { return -1 }
    defer { curl_easy_cleanup(curl) }

    _ = url.withCString { curl_easy_setopt_string(curl, CURLOPT_URL, $0) }
    curl_easy_setopt_long(curl, CURLOPT_POST, 1)
    curl_easy_setopt_string(curl, CURLOPT_COPYPOSTFIELDS, body)

    var headerList: UnsafeMutablePointer<curl_slist>? = nil
    for (key, value) in headers {
        headerList = curl_slist_append(headerList, "\(key): \(value)")
    }
    curl_easy_setopt_slist(curl, CURLOPT_HTTPHEADER, headerList)

    let ctx = StreamContext(onLine: onLine)
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
        return -1
    }

    var statusCode: CLong = 0
    curl_easy_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &statusCode)
    return Int32(statusCode)
}
