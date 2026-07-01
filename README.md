# EmbeddedSwiftAgent

A fully-featured coding agent in 200 KB — written in Embedded Swift with no Foundation, no runtime, and no dependencies beyond POSIX, cJSON, and libcurl.

**This agent was built with itself.** Once the core loop was functional (a plain Swift prototype with a shell command execution tool), I used the agent to port itself to Embedded Swift, strip out Foundation, and build every subsequent feature: file operations, parallel tool execution, subagents, streaming, web search, and more. Most of the code you see here was written with the agent running inside its own binary.

## What It Does

An interactive REPL that takes natural-language prompts, sends them to an LLM via OpenRouter, and autonomously executes tool calls in a loop until the task is done. The agent can run shell commands, read/write/edit files, search the web, spawn subagents, and more. All from a ~200 KB binary with zero Swift runtime overhead.

Key features:

- **Streaming responses** — token-by-token output as the LLM generates
- **Parallel tool execution** — multiple tool calls run concurrently via pthreads
- **Subagents** — spawn child agents with their own conversation context
- **Ctrl+C abort** — cleanly cancels the current agent run
- **Steering (in progress)** — raw-mode input plumbing for redirecting the agent mid-run exists in `InputReader`, but isn't wired into the agent loop yet

## Tools

The agent has access to the following tools:


| Tool          | Description                                                   |
| ------------- | ------------------------------------------------------------- |
| `sh`          | Execute a shell command and return its output                 |
| `read_file`   | Read file contents, optionally limited to a line range        |
| `write_file`  | Create or overwrite a file (creates intermediate directories) |
| `str_replace` | Replace an exact unique string in a file                      |
| `glob`        | Find files matching a glob pattern                            |
| `grep`        | Search for a pattern in files                                 |
| `web_search`  | Search the web via Exa                                        |
| `web_fetch`   | Fetch the text content of a URL via Exa                       |
| `subagent`    | Spawn a subagent to handle a self-contained task              |
| `mcp`         | Execute an MCP tool on a named server *(stub — not yet implemented)* |


## Configuration

All configuration is via CLI flags or environment variables. Flags take precedence over env vars.


| Flag               | Env var              | Default                      | Description                                |
| ------------------ | -------------------- | ---------------------------- | ------------------------------------------ |
| `--openrouter-key` | `OPENROUTER_API_KEY` | *(required)*                 | OpenRouter API key                         |
| `--exa-key`        | `EXA_API_KEY`        | *(none)*                     | Exa API key for `web_search` / `web_fetch` |
| `--model`          | `MODEL`              | `anthropic/claude-haiku-4.5` | Model to use via OpenRouter                |
| `--reasoning-effort` | `REASONING_EFFORT` | `high`                       | Reasoning effort (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`) |


## Requirements

- Swift 6.3-dev snapshot (for embedded Swift support `brew install swiftly && swiftly install main-snapshot`)
- libcurl (system or Homebrew)
- `OPENROUTER_API_KEY` (set via `--openrouter-key` flag or as an environment variable)
- `EXA_API_KEY` — required for `web_search` and `web_fetch` tools (set via `--exa-key` flag or as an environment variable)
- Docker (optional, for Linux cross-compilation)

## Build & Run

```bash
# via env vars
export OPENROUTER_API_KEY=your-key
export EXA_API_KEY=your-key
make run

# via flags (any order)
make run ARGS="--openrouter-key your-key --exa-key your-key"

# override model
make run ARGS="--model openai/gpt-4o"

# override reasoning effort
make run ARGS="--reasoning-effort medium"

# combine as needed
make run ARGS="--openrouter-key your-key --model openai/gpt-5.4-nano"
```

Other commands:

```bash
make build   # compile release binary
make test    # run build + agent integration tests
make size    # print stripped binary size
make clean   # remove build artifacts
```

## Test

```bash
make test
```

Runs three phases:

1. **Build** — compiles release binaries for macOS and Linux (via Docker) in parallel, reports stripped binary sizes
2. **Agent tests** — sends real prompts through the built binary to verify:
  - Plain response (agent replies and returns to prompt)
  - Tool call success (agent runs `uuidgen` and returns a UUID)
  - Tool call failure (agent survives a bad command without crashing)
  - Subagent (spawns two subagents, each runs a command, main agent combines output)
3. **Teardown** — cleans up build artifacts

Agent tests require `OPENROUTER_API_KEY`. Set `MODEL` to override the default model. Linux build requires Docker (skipped if unavailable).

## Performance


| Target        | Stripped Size           |
| ------------- | ----------------------- |
| macOS arm64   | 201.8 KB (206736 bytes) |
| Linux aarch64 | 195.0 KB (199688 bytes) |


Startup time to interactive prompt: **~120ms** (mean of 30 runs, σ=1.9ms, 95% CI ±0.7ms). Measured on Apple Silicon (M4 Pro) by piping empty input and timing process lifetime.