// MARK: - Tool Definitions

let shellTool = ToolDefinition(
    name: "sh",
    description: "Execute a shell command and return its output",
    parametersJSON: """
    {"type":"object","properties":{"c":{"type":"string","description":"The shell command to execute"}},"required":["c"]}
    """
)

let subagentTool = ToolDefinition(
    name: "subagent",
    description: "Spawn a subagent to handle a self-contained task. The subagent gets its own conversation context, can use all the same tools (including spawning further subagents), and runs to completion. Returns the subagent's final text response.",
    parametersJSON: """
    {"type":"object","properties":{"task":{"type":"string","description":"The task/prompt for the subagent"},"model":{"type":"string","description":"Optional model override (e.g. 'anthropic/claude-sonnet-4'). Defaults to the parent agent's model."}},"required":["task"]}
    """
)

let readFileTool = ToolDefinition(
    name: "read_file",
    description: "Read the contents of a file, optionally limited to a range of lines. Returns content with 1-indexed line numbers prefixed.",
    parametersJSON: """
    {"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file"},"offset":{"type":"integer","description":"1-indexed line number to start reading from (optional)"},"limit":{"type":"integer","description":"Maximum number of lines to return (optional)"}},"required":["path"]}
    """
)

let writeFileTool = ToolDefinition(
    name: "write_file",
    description: "Create or overwrite a file with the given content. Creates intermediate directories as needed.",
    parametersJSON: """
    {"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
    """
)

let strReplaceTool = ToolDefinition(
    name: "str_replace",
    description: "Replace an exact unique string in a file. Fails if old_str is not found or matches more than once.",
    parametersJSON: """
    {"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file"},"old_str":{"type":"string","description":"Exact string to find (must match exactly once)"},"new_str":{"type":"string","description":"String to replace it with"}},"required":["path","old_str","new_str"]}
    """
)

let globTool = ToolDefinition(
    name: "glob",
    description: "Find files matching a glob pattern. Returns up to 200 sorted file paths.",
    parametersJSON: """
    {"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. *.swift, *.ts)"},"path":{"type":"string","description":"Directory to search in (defaults to current directory)"}},"required":["pattern"]}
    """
)

let grepTool = ToolDefinition(
    name: "grep",
    description: "Search for a pattern in files. Returns up to 200 matching lines with file and line number.",
    parametersJSON: """
    {"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern"},"path":{"type":"string","description":"Directory or file to search in (defaults to current directory)"},"include":{"type":"string","description":"Glob to filter files (e.g. *.swift)"}},"required":["pattern"]}
    """
)

let webSearchTool = ToolDefinition(
    name: "web_search",
    description: "Search the web using Exa. Returns titles, URLs, and relevant highlights.",
    parametersJSON: """
    {"type":"object","properties":{"query":{"type":"string","description":"Search query"},"num_results":{"type":"integer","description":"Number of results to return (default 5)"}},"required":["query"]}
    """
)

let webFetchTool = ToolDefinition(
    name: "web_fetch",
    description: "Fetch the text content of a URL using Exa (handles JS-rendered pages, PDFs, returns clean text).",
    parametersJSON: """
    {"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"},"max_chars":{"type":"integer","description":"Maximum characters to return (default 20000)"}},"required":["url"]}
    """
)

let mcpTool = ToolDefinition(
    name: "mcp",
    description: "Execute an MCP (Model Context Protocol) tool on a named server.",
    parametersJSON: """
    {"type":"object","properties":{"server":{"type":"string","description":"MCP server name"},"tool":{"type":"string","description":"Tool name on the server"},"args":{"type":"string","description":"JSON-encoded arguments for the tool (optional)"}},"required":["server","tool"]}
    """
)

let allTools = [shellTool, subagentTool, readFileTool, writeFileTool, strReplaceTool, globTool, grepTool, webSearchTool, webFetchTool, mcpTool]
