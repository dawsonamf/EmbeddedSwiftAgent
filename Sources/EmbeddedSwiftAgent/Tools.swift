import Cstdio

// MARK: - Tool Registry

let allTools: [Tool] = [
    shellTool,
    subagentTool,
    readFileTool,
    writeFileTool,
    strReplaceTool,
    globTool,
    grepTool,
    webSearchTool,
    webFetchTool,
    mcpTool,
]

// MARK: - Tool Dispatch

extension AgentLoop {

    func executeTool(_ toolCall: ToolCall) -> ToolResultMessage {
        let context = ToolContext(
            toolCallId: toolCall.id,
            client: client,
            exaApiKey: exaApiKey,
            tools: tools,
            abortFlag: abortFlag,
            emitEvent: emitEvent
        )

        for tool in tools {
            if utf8Equal(toolCall.functionName, tool.name) {
                let (content, isError) = tool.execute(toolCall.arguments, context)
                return ToolResultMessage(toolCallId: toolCall.id, content: content, isError: isError)
            }
        }

        return ToolResultMessage(
            toolCallId: toolCall.id,
            content: "Unknown tool: \(toolCall.functionName)",
            isError: true
        )
    }

    func appendSyntheticResults(
        from startIndex: Int,
        in toolCalls: [ToolCall],
        content: String,
        to messages: inout [ChatMessage]
    ) {
        for skipped in toolCalls[startIndex...] {
            let synthetic = ToolResultMessage(
                toolCallId: skipped.id,
                content: content,
                isError: false
            )
            messages.append(synthetic.toChatMessage())
        }
    }
}

// MARK: - Shell

let shellTool = Tool(
    definition: ToolDefinition(
        name: "sh",
        description: "Execute a shell command and return its output",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("c", .object(
                    ("type", .string("string")),
                    ("description", .string("The shell command to execute"))
                ))
            )),
            ("required", .array([.string("c")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            let result = runShell(arguments)
            let content = result.exitCode == 0
                ? result.output
                : "\(result.output)\n[exit code: \(result.exitCode)]"
            return (content, result.exitCode != 0)
        }
        let command = json["c"]?.string ?? arguments
        let result = runShell(command)
        let content = result.exitCode == 0
            ? result.output
            : "\(result.output)\n[exit code: \(result.exitCode)]"
        return (content, result.exitCode != 0)
    }
)

// MARK: - Subagent

let subagentTool = Tool(
    definition: ToolDefinition(
        name: "subagent",
        description: "Spawn a subagent to handle a self-contained task. The subagent gets its own conversation context, can use all the same tools (including spawning further subagents), and runs to completion. Returns the subagent's final text response.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("task", .object(
                    ("type", .string("string")),
                    ("description", .string("The task/prompt for the subagent"))
                )),
                ("model", .object(
                    ("type", .string("string")),
                    ("description", .string("Optional model override (e.g. 'anthropic/claude-sonnet-4'). Defaults to the parent agent's model."))
                ))
            )),
            ("required", .array([.string("task")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("subagent error: invalid arguments", true)
        }
        let task = json["task"]?.string ?? ""
        let model = json["model"]?.string

        guard !utf8IsEmpty(task) else {
            return ("subagent error: missing 'task' parameter", true)
        }

        let subClient: OpenRouterClient
        if let model = model, !utf8IsEmpty(model) {
            subClient = OpenRouterClient(apiKey: ctx.client.apiKey, model: model, reasoningEffort: ctx.client.reasoningEffort)
        } else {
            subClient = ctx.client
        }

        var subMessages: [ChatMessage] = [
            ChatMessage(role: ChatRole.user, content: task)
        ]
        let responseQueue = ThreadSafeQueue()

        let subLoop = AgentLoop(
            client: subClient,
            exaApiKey: ctx.exaApiKey,
            tools: ctx.tools,
            abortFlag: ctx.abortFlag,
            emitEvent: { event in
                if case .textDelta(let text) = extractStreamDelta(event) {
                    ctx.emitEvent(.toolExecUpdate(id: ctx.toolCallId, toolName: "subagent", partialResult: text))
                }
                if case .messageEnd(let msg) = event {
                    if utf8Equal(msg.role, ChatRole.assistant), let content = msg.content {
                        responseQueue.push(content)
                    }
                }
            }
        )

        subLoop.run(messages: &subMessages)

        // The queue holds every assistant message the subagent produced;
        // its final one is the answer to return to the parent.
        let output = responseQueue.drain().last ?? "(subagent produced no text response)"
        return (output, false)
    }
)

// MARK: - Read File

let readFileTool = Tool(
    definition: ToolDefinition(
        name: "read_file",
        description: "Read the contents of a file, optionally limited to a range of lines. Returns content with 1-indexed line numbers prefixed.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("path", .object(
                    ("type", .string("string")),
                    ("description", .string("Absolute or relative path to the file"))
                )),
                ("offset", .object(
                    ("type", .string("integer")),
                    ("description", .string("1-indexed line number to start reading from (optional)"))
                )),
                ("limit", .object(
                    ("type", .string("integer")),
                    ("description", .string("Maximum number of lines to return (optional)"))
                ))
            )),
            ("required", .array([.string("path")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("read_file error: invalid arguments", true)
        }
        let path = json["path"]?.string ?? ""
        let offset = json["offset"]?.int
        let limit = json["limit"]?.int

        guard !utf8IsEmpty(path) else {
            return ("read_file error: missing 'path'", true)
        }

        guard let fp = path.withCString({ fopen($0, "r") }) else {
            return ("read_file error: cannot open '\(path)'", true)
        }
        defer { fclose(fp) }

        fseek(fp, 0, SEEK_END)
        let fileSize = ftell(fp)
        fseek(fp, 0, SEEK_SET)

        guard fileSize > 0 else {
            return ("(empty file)", false)
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
        // Only append the final line if the file doesn't end with a newline,
        // so trailing newlines don't produce a phantom empty line.
        if lineStart < bytesRead {
            lines.append(rawBytes[lineStart..<bytesRead])
        }

        // Clamp to valid bounds — an out-of-range offset or negative limit from
        // the model must not build an invalid range (which would trap).
        let startIdx = min(max(0, (offset ?? 1) - 1), lines.count)
        let endIdx = max(startIdx, limit.map { min(lines.count, startIdx + max(0, $0)) } ?? lines.count)

        var numbered = ""
        for i in startIdx..<endIdx {
            var lineBytes = Array(lines[i])
            lineBytes.append(0)
            let lineStr = lineBytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            numbered += "\(i + 1)|\(lineStr)\n"
        }
        return (utf8IsEmpty(numbered) ? "(no lines in requested range)" : numbered, false)
    }
)

// MARK: - Write File

let writeFileTool = Tool(
    definition: ToolDefinition(
        name: "write_file",
        description: "Create or overwrite a file with the given content. Creates intermediate directories as needed.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("path", .object(
                    ("type", .string("string")),
                    ("description", .string("Absolute or relative path to the file"))
                )),
                ("content", .object(
                    ("type", .string("string")),
                    ("description", .string("Content to write to the file"))
                ))
            )),
            ("required", .array([.string("path"), .string("content")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("write_file error: invalid arguments", true)
        }
        let path = json["path"]?.string ?? ""
        let content = json["content"]?.string ?? ""

        guard !utf8IsEmpty(path) else {
            return ("write_file error: missing 'path'", true)
        }

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
                return ("write_file error: mkdir -p failed: \(mkdirResult.output)", true)
            }
        }

        guard let fp = path.withCString({ fopen($0, "w") }) else {
            return ("write_file error: cannot open '\(path)' for writing", true)
        }
        defer { fclose(fp) }

        var bytes = Array(content.utf8)
        let written = bytes.withUnsafeMutableBufferPointer { ptr in
            fwrite(ptr.baseAddress, 1, ptr.count, fp)
        }

        return ("wrote \(written) bytes to \(path)", false)
    }
)

// MARK: - String Replace

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

let strReplaceTool = Tool(
    definition: ToolDefinition(
        name: "str_replace",
        description: "Replace an exact unique string in a file. Fails if old_str is not found or matches more than once.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("path", .object(
                    ("type", .string("string")),
                    ("description", .string("Absolute or relative path to the file"))
                )),
                ("old_str", .object(
                    ("type", .string("string")),
                    ("description", .string("Exact string to find (must match exactly once)"))
                )),
                ("new_str", .object(
                    ("type", .string("string")),
                    ("description", .string("String to replace it with"))
                ))
            )),
            ("required", .array([.string("path"), .string("old_str"), .string("new_str")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("str_replace error: invalid arguments", true)
        }
        let path = json["path"]?.string ?? ""
        let oldStr = json["old_str"]?.string ?? ""
        let newStr = json["new_str"]?.string ?? ""

        guard !utf8IsEmpty(path) else {
            return ("str_replace error: missing 'path'", true)
        }
        guard !utf8IsEmpty(oldStr) else {
            return ("str_replace error: missing 'old_str'", true)
        }

        guard let fp = path.withCString({ fopen($0, "r") }) else {
            return ("str_replace error: cannot open '\(path)'", true)
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
            return ("str_replace error: 'old_str' not found in '\(path)'", true)
        }
        if count > 1 {
            return ("str_replace error: 'old_str' matches multiple times in '\(path)' — provide more context to make it unique", true)
        }

        var outBytes = Array(fileBytes[0..<matchIdx])
        outBytes.append(contentsOf: newBytes)
        outBytes.append(contentsOf: fileBytes[(matchIdx + oldBytes.count)...])

        guard let wfp = path.withCString({ fopen($0, "w") }) else {
            return ("str_replace error: cannot open '\(path)' for writing", true)
        }
        defer { fclose(wfp) }

        _ = outBytes.withUnsafeMutableBufferPointer { ptr in
            fwrite(ptr.baseAddress, 1, ptr.count, wfp)
        }

        return ("str_replace applied successfully to \(path)", false)
    }
)

// MARK: - Glob

let globTool = Tool(
    definition: ToolDefinition(
        name: "glob",
        description: "Find files matching a glob pattern. Returns up to 200 sorted file paths.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("pattern", .object(
                    ("type", .string("string")),
                    ("description", .string("Glob pattern (e.g. *.swift, *.ts)"))
                )),
                ("path", .object(
                    ("type", .string("string")),
                    ("description", .string("Directory to search in (defaults to current directory)"))
                ))
            )),
            ("required", .array([.string("pattern")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("glob error: invalid arguments", true)
        }
        let pattern = json["pattern"]?.string ?? ""
        let path = json["path"]?.string ?? "."

        guard !utf8IsEmpty(pattern) else {
            return ("glob error: missing 'pattern'", true)
        }
        let result = runShell("find \(shellEscape(path)) -name \(shellEscape(pattern)) -type f 2>/dev/null | head -200 | sort")
        let content = utf8IsEmpty(result.output) ? "(no matches)" : result.output
        return (content, false)
    }
)

// MARK: - Grep

let grepTool = Tool(
    definition: ToolDefinition(
        name: "grep",
        description: "Search for a pattern in files. Returns up to 200 matching lines with file and line number.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("pattern", .object(
                    ("type", .string("string")),
                    ("description", .string("Search pattern"))
                )),
                ("path", .object(
                    ("type", .string("string")),
                    ("description", .string("Directory or file to search in (defaults to current directory)"))
                )),
                ("include", .object(
                    ("type", .string("string")),
                    ("description", .string("Glob to filter files (e.g. *.swift)"))
                ))
            )),
            ("required", .array([.string("pattern")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("grep error: invalid arguments", true)
        }
        let pattern = json["pattern"]?.string ?? ""
        let path = json["path"]?.string ?? "."
        let include = json["include"]?.string

        guard !utf8IsEmpty(pattern) else {
            return ("grep error: missing 'pattern'", true)
        }
        var cmd = "grep -rn \(shellEscape(pattern)) \(shellEscape(path))"
        if let include = include, !utf8IsEmpty(include) {
            cmd += " --include=\(shellEscape(include))"
        }
        cmd += " 2>/dev/null | head -200"
        let result = runShell(cmd)
        let content = utf8IsEmpty(result.output) ? "(no matches)" : result.output
        return (content, false)
    }
)

// MARK: - Web Search

/// Escapes a string for safe inclusion in a JSON string literal (byte-level, no Unicode tables).
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

let webSearchTool = Tool(
    definition: ToolDefinition(
        name: "web_search",
        description: "Search the web using Exa. Returns titles, URLs, and relevant highlights.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("query", .object(
                    ("type", .string("string")),
                    ("description", .string("Search query"))
                )),
                ("num_results", .object(
                    ("type", .string("integer")),
                    ("description", .string("Number of results to return (default 5)"))
                ))
            )),
            ("required", .array([.string("query")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("web_search error: invalid arguments", true)
        }
        let query = json["query"]?.string ?? ""
        let numResults = json["num_results"]?.int ?? 5

        guard !utf8IsEmpty(query) else {
            return ("web_search error: missing 'query'", true)
        }
        guard let key = ctx.exaApiKey, !utf8IsEmpty(key) else {
            return ("web_search error: EXA_API_KEY not set", true)
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
            return ("web_search error: \(curlError)", true)
        }
        if response.statusCode != 200 {
            return ("web_search error: HTTP \(response.statusCode): \(response.body)", true)
        }

        guard let respJSON = jsonParse(response.body), let results = respJSON["results"]?.arrayElements else {
            return ("web_search error: failed to parse response", true)
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
        return (utf8IsEmpty(output) ? "(no results)" : output, false)
    }
)

// MARK: - Web Fetch

let webFetchTool = Tool(
    definition: ToolDefinition(
        name: "web_fetch",
        description: "Fetch the text content of a URL using Exa (handles JS-rendered pages, PDFs, returns clean text).",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("url", .object(
                    ("type", .string("string")),
                    ("description", .string("URL to fetch"))
                )),
                ("max_chars", .object(
                    ("type", .string("integer")),
                    ("description", .string("Maximum characters to return (default 20000)"))
                ))
            )),
            ("required", .array([.string("url")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("web_fetch error: invalid arguments", true)
        }
        let url = json["url"]?.string ?? ""
        let maxChars = json["max_chars"]?.int ?? 20000

        guard !utf8IsEmpty(url) else {
            return ("web_fetch error: missing 'url'", true)
        }
        guard let key = ctx.exaApiKey, !utf8IsEmpty(key) else {
            return ("web_fetch error: EXA_API_KEY not set", true)
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
            return ("web_fetch error: \(curlError)", true)
        }
        if response.statusCode != 200 {
            return ("web_fetch error: HTTP \(response.statusCode): \(response.body)", true)
        }

        guard let respJSON = jsonParse(response.body),
              let firstResult = respJSON["results"]?.arrayElements.first,
              let text = firstResult["text"]?.string else {
            return ("web_fetch error: failed to parse response", true)
        }

        return (text, false)
    }
)

// MARK: - MCP

let mcpTool = Tool(
    definition: ToolDefinition(
        name: "mcp",
        description: "Execute an MCP (Model Context Protocol) tool on a named server.",
        parameters: .object(
            ("type", .string("object")),
            ("properties", .object(
                ("server", .object(
                    ("type", .string("string")),
                    ("description", .string("MCP server name"))
                )),
                ("tool", .object(
                    ("type", .string("string")),
                    ("description", .string("Tool name on the server"))
                )),
                ("args", .object(
                    ("type", .string("string")),
                    ("description", .string("JSON-encoded arguments for the tool (optional)"))
                ))
            )),
            ("required", .array([.string("server"), .string("tool")]))
        )
    ),
    execute: { arguments, ctx in
        guard let json = jsonParse(arguments) else {
            return ("mcp error: invalid arguments", true)
        }
        let server = json["server"]?.string ?? ""
        let tool = json["tool"]?.string ?? ""
        return ("MCP tool execution is not yet implemented. Server: \(server), Tool: \(tool)", true)
    }
)
