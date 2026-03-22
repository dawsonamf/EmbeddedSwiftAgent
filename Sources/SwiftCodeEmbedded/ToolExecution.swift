import Cstdio

// MARK: - Tool Dispatch

extension AgentLoop {

    func executeTool(_ toolCall: ToolCall) -> ToolResultMessage {
        if utf8Equal(toolCall.functionName, "sh") {
            let command = extractShellCommand(from: toolCall.arguments)
            let result = runShell(command)
            let content = result.exitCode == 0
                ? result.output
                : "\(result.output)\n[exit code: \(result.exitCode)]"
            return ToolResultMessage(toolCallId: toolCall.id, content: content, isError: result.exitCode != 0)
        }
        if utf8Equal(toolCall.functionName, "subagent") {
            return executeSubagent(toolCall)
        }
        if utf8Equal(toolCall.functionName, "read_file") {
            return executeReadFile(toolCall)
        }
        if utf8Equal(toolCall.functionName, "write_file") {
            return executeWriteFile(toolCall)
        }
        if utf8Equal(toolCall.functionName, "str_replace") {
            return executeStrReplace(toolCall)
        }
        if utf8Equal(toolCall.functionName, "glob") {
            return executeGlob(toolCall)
        }
        if utf8Equal(toolCall.functionName, "grep") {
            return executeGrep(toolCall)
        }
        if utf8Equal(toolCall.functionName, "web_search") {
            return executeWebSearch(toolCall)
        }
        if utf8Equal(toolCall.functionName, "web_fetch") {
            return executeWebFetch(toolCall)
        }
        if utf8Equal(toolCall.functionName, "mcp") {
            return executeMcp(toolCall)
        }
        return ToolResultMessage(
            toolCallId: toolCall.id,
            content: "Unknown tool: \(toolCall.functionName)",
            isError: true
        )
    }

    func executeSubagent(_ toolCall: ToolCall) -> ToolResultMessage {
        let (task, model) = extractSubagentArgs(from: toolCall.arguments)

        guard !utf8IsEmpty(task) else {
            return ToolResultMessage(
                toolCallId: toolCall.id,
                content: "subagent error: missing 'task' parameter",
                isError: true
            )
        }

        let subClient: OpenRouterClient
        if let model = model, !utf8IsEmpty(model) {
            subClient = OpenRouterClient(apiKey: apiKey, model: model)
        } else {
            subClient = client
        }

        var subMessages: [ChatMessage] = [
            ChatMessage(role: ChatRole.user, content: task)
        ]
        let subSteeringQueue = ThreadSafeQueue()
        let subFollowUpQueue = ThreadSafeQueue()

        let responseBox = ResponseBox()

        let subLoop = AgentLoop(
            client: subClient,
            apiKey: apiKey,
            exaApiKey: exaApiKey,
            tools: tools,
            abortFlag: abortFlag,
            onEvent: { event in
                self.onEvent(.subagentEvent(innerEvent: event))
                if case .messageEnd(let msg) = event {
                    if utf8Equal(msg.role, ChatRole.assistant), let content = msg.content {
                        responseBox.value = content
                    }
                }
            }
        )

        onEvent(.subagentStart(task: task))

        subLoop.run(
            messages: &subMessages,
            steeringQueue: subSteeringQueue,
            followUpQueue: subFollowUpQueue
        )

        onEvent(.subagentEnd)

        let output = responseBox.value ?? "(subagent produced no text response)"
        return ToolResultMessage(toolCallId: toolCall.id, content: output, isError: false)
    }

    func appendSyntheticResults(
        from startIndex: Int,
        in toolCalls: [ToolCall],
        content: String,
        to toolResults: inout [ToolResultMessage],
        context: inout [ChatMessage]
    ) {
        for skipped in toolCalls[startIndex...] {
            let synthetic = ToolResultMessage(
                toolCallId: skipped.id,
                content: content,
                isError: false
            )
            toolResults.append(synthetic)
            context.append(synthetic.toChatMessage())
        }
    }
}

// MARK: - Argument Extraction

/// Extracts the "c" field from the tool call arguments JSON string.
func extractShellCommand(from arguments: String) -> String {
    guard let json = jsonParse(arguments) else { return arguments }
    return json["c"]?.string ?? arguments
}

/// Extracts "task" and optional "model" from subagent tool call arguments.
func extractSubagentArgs(from arguments: String) -> (task: String, model: String?) {
    guard let json = jsonParse(arguments) else { return (arguments, nil) }
    let task = json["task"]?.string ?? ""
    let model = json["model"]?.string
    return (task, model)
}

func extractReadFileArgs(from arguments: String) -> (path: String, offset: Int?, limit: Int?) {
    guard let json = jsonParse(arguments) else { return (arguments, nil, nil) }
    let path = json["path"]?.string ?? ""
    let offset = json["offset"]?.int
    let limit = json["limit"]?.int
    return (path, offset, limit)
}

func extractWriteFileArgs(from arguments: String) -> (path: String, content: String) {
    guard let json = jsonParse(arguments) else { return (arguments, "") }
    let path = json["path"]?.string ?? ""
    let content = json["content"]?.string ?? ""
    return (path, content)
}

func extractStrReplaceArgs(from arguments: String) -> (path: String, oldStr: String, newStr: String) {
    guard let json = jsonParse(arguments) else { return (arguments, "", "") }
    let path = json["path"]?.string ?? ""
    let oldStr = json["old_str"]?.string ?? ""
    let newStr = json["new_str"]?.string ?? ""
    return (path, oldStr, newStr)
}

func extractGlobArgs(from arguments: String) -> (pattern: String, path: String) {
    guard let json = jsonParse(arguments) else { return (arguments, ".") }
    let pattern = json["pattern"]?.string ?? ""
    let path = json["path"]?.string ?? "."
    return (pattern, path)
}

func extractGrepArgs(from arguments: String) -> (pattern: String, path: String, include: String?) {
    guard let json = jsonParse(arguments) else { return (arguments, ".", nil) }
    let pattern = json["pattern"]?.string ?? ""
    let path = json["path"]?.string ?? "."
    let include = json["include"]?.string
    return (pattern, path, include)
}

func extractWebSearchArgs(from arguments: String) -> (query: String, numResults: Int) {
    guard let json = jsonParse(arguments) else { return (arguments, 5) }
    let query = json["query"]?.string ?? ""
    let numResults = json["num_results"]?.int ?? 5
    return (query, numResults)
}

func extractWebFetchArgs(from arguments: String) -> (url: String, maxChars: Int) {
    guard let json = jsonParse(arguments) else { return (arguments, 20000) }
    let url = json["url"]?.string ?? ""
    let maxChars = json["max_chars"]?.int ?? 20000
    return (url, maxChars)
}

func extractMcpArgs(from arguments: String) -> (server: String, tool: String, args: String?) {
    guard let json = jsonParse(arguments) else { return (arguments, "", nil) }
    let server = json["server"]?.string ?? ""
    let tool = json["tool"]?.string ?? ""
    let args = json["args"]?.string
    return (server, tool, args)
}

// MARK: - Tool Implementation: File Operations

/// Returns the index of the first occurrence of `needle` in `haystack` at or after `from`, or nil.
private func byteSearch(_ haystack: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty else { return from }
    let limit = haystack.count - needle.count
    guard from <= limit else { return nil }
    for i in from...limit {
        if haystack[i] == needle[0] {
            var match = true
            for j in 1..<needle.count {
                if haystack[i + j] != needle[j] { match = false; break }
            }
            if match { return i }
        }
    }
    return nil
}

extension AgentLoop {
    /// Reads a file, optionally sliced by 1-indexed line offset and limit.
    /// Returns content with "N|" line number prefixes.
    func executeReadFile(_ toolCall: ToolCall) -> ToolResultMessage {
        let (path, offset, limit) = extractReadFileArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(path) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "read_file error: missing 'path'", isError: true)
        }

        guard let fp = path.withCString({ fopen($0, "r") }) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "read_file error: cannot open '\(path)'", isError: true)
        }
        defer { fclose(fp) }

        fseek(fp, 0, SEEK_END)
        let fileSize = ftell(fp)
        fseek(fp, 0, SEEK_SET)

        guard fileSize > 0 else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "(empty file)", isError: false)
        }

        var rawBytes = [UInt8](repeating: 0, count: fileSize)
        let bytesRead = fread(&rawBytes, 1, fileSize, fp)

        var lines: [ArraySlice<UInt8>] = []
        var lineStart = 0
        for i in 0..<bytesRead {
            if rawBytes[i] == 0x0A {
                lines.append(rawBytes[lineStart..<i])
                lineStart = i + 1
            }
        }
        lines.append(rawBytes[lineStart..<bytesRead])

        let startIdx = max(0, (offset ?? 1) - 1)
        let endIdx = limit.map { min(lines.count, startIdx + $0) } ?? lines.count

        var numbered = ""
        for i in startIdx..<endIdx {
            var lineBytes = Array(lines[i])
            lineBytes.append(0)
            let lineStr = lineBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            numbered += "\(i + 1)|\(lineStr)\n"
        }
        return ToolResultMessage(toolCallId: toolCall.id, content: numbered, isError: false)
    }

    func executeWriteFile(_ toolCall: ToolCall) -> ToolResultMessage {
        let (path, content) = extractWriteFileArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(path) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "write_file error: missing 'path'", isError: true)
        }

        // Create intermediate directories
        let dir: String = {
            let bytes = Array(path.utf8)
            var lastSlash = -1
            for i in 0..<bytes.count {
                if bytes[i] == 0x2F { lastSlash = i }
            }
            if lastSlash > 0 {
                var slice = Array(bytes[0..<lastSlash])
                slice.append(0)
                return slice.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            return "."
        }()
        if !utf8Equal(dir, ".") {
            let mkdirResult = runShell("mkdir -p \(shellEscape(dir))")
            if mkdirResult.exitCode != 0 {
                return ToolResultMessage(toolCallId: toolCall.id,
                    content: "write_file error: mkdir -p failed: \(mkdirResult.output)", isError: true)
            }
        }

        guard let fp = path.withCString({ fopen($0, "w") }) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "write_file error: cannot open '\(path)' for writing", isError: true)
        }
        defer { fclose(fp) }

        var bytes = Array(content.utf8)
        let written = bytes.withUnsafeMutableBufferPointer { ptr in
            fwrite(ptr.baseAddress, 1, ptr.count, fp)
        }

        return ToolResultMessage(toolCallId: toolCall.id, content: "wrote \(written) bytes to \(path)", isError: false)
    }

    func executeStrReplace(_ toolCall: ToolCall) -> ToolResultMessage {
        let (path, oldStr, newStr) = extractStrReplaceArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(path) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "str_replace error: missing 'path'", isError: true)
        }
        guard !utf8IsEmpty(oldStr) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "str_replace error: missing 'old_str'", isError: true)
        }

        guard let fp = path.withCString({ fopen($0, "r") }) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "str_replace error: cannot open '\(path)'", isError: true)
        }

        fseek(fp, 0, SEEK_END)
        let fileSize = ftell(fp)
        fseek(fp, 0, SEEK_SET)

        var fileBytes = [UInt8](repeating: 0, count: fileSize)
        let bytesRead = fread(&fileBytes, 1, fileSize, fp)
        fclose(fp)
        if bytesRead < fileBytes.count { fileBytes.removeSubrange(bytesRead..<fileBytes.count) }

        let oldBytes = Array(oldStr.utf8)
        let newBytes = Array(newStr.utf8)

        // Count occurrences using byte-level search — avoids Foundation's range(of:) / replacingOccurrences
        var count = 0
        var searchFrom = 0
        var matchIdx = -1
        while let idx = byteSearch(fileBytes, oldBytes, from: searchFrom) {
            count += 1
            if count == 1 { matchIdx = idx }
            if count > 1 { break }
            searchFrom = idx + 1
        }

        if count == 0 {
            return ToolResultMessage(toolCallId: toolCall.id,
                content: "str_replace error: 'old_str' not found in '\(path)'", isError: true)
        }
        if count > 1 {
            return ToolResultMessage(toolCallId: toolCall.id,
                content: "str_replace error: 'old_str' matches multiple times in '\(path)' — provide more context to make it unique", isError: true)
        }

        var outBytes = Array(fileBytes[0..<matchIdx])
        outBytes.append(contentsOf: newBytes)
        outBytes.append(contentsOf: fileBytes[(matchIdx + oldBytes.count)...])

        guard let wfp = path.withCString({ fopen($0, "w") }) else {
            return ToolResultMessage(toolCallId: toolCall.id,
                content: "str_replace error: cannot open '\(path)' for writing", isError: true)
        }
        defer { fclose(wfp) }

        _ = outBytes.withUnsafeMutableBufferPointer { ptr in
            fwrite(ptr.baseAddress, 1, ptr.count, wfp)
        }

        return ToolResultMessage(toolCallId: toolCall.id, content: "str_replace applied successfully to \(path)", isError: false)
    }

    func executeGlob(_ toolCall: ToolCall) -> ToolResultMessage {
        let (pattern, path) = extractGlobArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(pattern) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "glob error: missing 'pattern'", isError: true)
        }
        let result = runShell("find \(shellEscape(path)) -name \(shellEscape(pattern)) -type f 2>/dev/null | head -200 | sort")
        let content = utf8IsEmpty(result.output) ? "(no matches)" : result.output
        return ToolResultMessage(toolCallId: toolCall.id, content: content, isError: false)
    }

    func executeGrep(_ toolCall: ToolCall) -> ToolResultMessage {
        let (pattern, path, include) = extractGrepArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(pattern) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "grep error: missing 'pattern'", isError: true)
        }
        var cmd = "grep -rn \(shellEscape(pattern)) \(shellEscape(path))"
        if let include = include, !utf8IsEmpty(include) {
            cmd += " --include=\(shellEscape(include))"
        }
        cmd += " 2>/dev/null | head -200"
        let result = runShell(cmd)
        let content = utf8IsEmpty(result.output) ? "(no matches)" : result.output
        return ToolResultMessage(toolCallId: toolCall.id, content: content, isError: false)
    }
}

// MARK: - Tool Implementation: Web

/// Escapes a string for safe inclusion in a JSON string literal (byte-level, no Unicode tables).
/// Handles all control characters (0x00-0x1F) per the JSON spec.
private func jsonEscapeString(_ s: String) -> String {
    let hexDigits: [UInt8] = [
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, // 0-7
        0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66  // 8-f
    ]
    var out: [UInt8] = []
    for byte in s.utf8 {
        switch byte {
        case 0x22: out.append(0x5C); out.append(0x22) // \"
        case 0x5C: out.append(0x5C); out.append(0x5C) // \\
        case 0x0A: out.append(0x5C); out.append(0x6E) // \n
        case 0x0D: out.append(0x5C); out.append(0x72) // \r
        case 0x09: out.append(0x5C); out.append(0x74) // \t
        case 0x08: out.append(0x5C); out.append(0x62) // \b
        case 0x0C: out.append(0x5C); out.append(0x66) // \f
        case 0x00...0x1F:
            // \u00XX for remaining control chars
            out.append(0x5C) // backslash
            out.append(0x75) // u
            out.append(0x30) // 0
            out.append(0x30) // 0
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        default: out.append(byte)
        }
    }
    out.append(0)
    return out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

extension AgentLoop {
    func executeWebSearch(_ toolCall: ToolCall) -> ToolResultMessage {
        let (query, numResults) = extractWebSearchArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(query) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_search error: missing 'query'", isError: true)
        }
        guard let key = exaApiKey, !utf8IsEmpty(key) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_search error: EXA_API_KEY not set", isError: true)
        }

        let bodyJSON = """
        {"query":"\(jsonEscapeString(query))","type":"auto","numResults":\(numResults),"contents":{"highlights":{"maxCharacters":4000}}}
        """
        let response = httpPost(
            url: "https://api.exa.ai/search",
            headers: [("Content-Type", "application/json"), ("x-api-key", key)],
            body: bodyJSON
        )

        if let curlError = response.curlError {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_search error: \(curlError)", isError: true)
        }
        if response.statusCode != 200 {
            return ToolResultMessage(toolCallId: toolCall.id,
                content: "web_search error: HTTP \(response.statusCode): \(response.body)", isError: true)
        }

        guard let json = jsonParse(response.body), let results = json["results"]?.arrayElements else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_search error: failed to parse response", isError: true)
        }

        var output = ""
        for (i, result) in results.enumerated() {
            let title = result["title"]?.string ?? "(no title)"
            let url = result["url"]?.string ?? ""
            var highlights = ""
            if let hlArray = result["highlights"]?.arrayElements {
                for (hi, hl) in hlArray.enumerated() {
                    if let s = hl.string {
                        if hi > 0 { highlights += " ... " }
                        highlights += s
                    }
                }
            }
            output += "[\(i + 1)] \(title)\n\(url)\n\(highlights)\n\n"
        }
        return ToolResultMessage(toolCallId: toolCall.id, content: utf8IsEmpty(output) ? "(no results)" : output, isError: false)
    }

    func executeWebFetch(_ toolCall: ToolCall) -> ToolResultMessage {
        let (url, maxChars) = extractWebFetchArgs(from: toolCall.arguments)
        guard !utf8IsEmpty(url) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_fetch error: missing 'url'", isError: true)
        }
        guard let key = exaApiKey, !utf8IsEmpty(key) else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_fetch error: EXA_API_KEY not set", isError: true)
        }

        let bodyJSON = """
        {"urls":["\(jsonEscapeString(url))"],"text":{"maxCharacters":\(maxChars)}}
        """
        let response = httpPost(
            url: "https://api.exa.ai/contents",
            headers: [("Content-Type", "application/json"), ("x-api-key", key)],
            body: bodyJSON
        )

        if let curlError = response.curlError {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_fetch error: \(curlError)", isError: true)
        }
        if response.statusCode != 200 {
            return ToolResultMessage(toolCallId: toolCall.id,
                content: "web_fetch error: HTTP \(response.statusCode): \(response.body)", isError: true)
        }

        guard let json = jsonParse(response.body),
              let firstResult = json["results"]?.arrayElements.first,
              let text = firstResult["text"]?.string else {
            return ToolResultMessage(toolCallId: toolCall.id, content: "web_fetch error: failed to parse response", isError: true)
        }

        return ToolResultMessage(toolCallId: toolCall.id, content: text, isError: false)
    }

    func executeMcp(_ toolCall: ToolCall) -> ToolResultMessage {
        let (server, tool, _) = extractMcpArgs(from: toolCall.arguments)
        return ToolResultMessage(
            toolCallId: toolCall.id,
            content: "MCP tool execution is not yet implemented. Server: \(server), Tool: \(tool)",
            isError: true
        )
    }
}
