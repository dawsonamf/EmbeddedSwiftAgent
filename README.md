# SwiftCodeEmbedded

Minimal coding agent CLI in Embedded Swift. No Foundation — just POSIX, cJSON, and libcurl. Streams LLM responses via OpenRouter and executes shell commands in an agentic loop.

## What It Does

An interactive REPL that takes natural-language prompts, sends them to an LLM, and autonomously executes tool calls in a loop until the task is done. The agent can run shell commands, read/write/edit files, search the web, spawn subagents, and more — all from a ~184 KB binary with zero Swift runtime overhead.

Key features:
- **Streaming responses** — token-by-token output as the LLM generates
- **Parallel tool execution** — multiple tool calls run concurrently via pthreads
- **Subagents** — spawn child agents with their own conversation context
- **Steering** — type while the agent is running to redirect it between tool calls
- **Ctrl+C abort** — cleanly cancels the current agent run

## Tools

The agent has access to the following tools:

| Tool | Description |
|---|---|
| `sh` | Execute a shell command and return its output |
| `read_file` | Read file contents, optionally limited to a line range |
| `write_file` | Create or overwrite a file (creates intermediate directories) |
| `str_replace` | Replace an exact unique string in a file |
| `glob` | Find files matching a glob pattern |
| `grep` | Search for a pattern in files |
| `web_search` | Search the web via Exa |
| `web_fetch` | Fetch the text content of a URL via Exa |
| `subagent` | Spawn a subagent to handle a self-contained task |
| `mcp` | Execute an MCP tool on a named server |

## Configuration

All configuration is via CLI flags or environment variables. Flags take precedence over env vars.

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--openrouter-key` | `OPENROUTER_API_KEY` | *(required)* | OpenRouter API key |
| `--exa-key` | `EXA_API_KEY` | *(none)* | Exa API key for `web_search` / `web_fetch` |
| `--model` | `MODEL` | `anthropic/claude-haiku-4.5` | Model to use via OpenRouter |

## Requirements

- Swift 6.3-dev snapshot (for embedded Swift support `brew install swiftly && swiftly install main-snapshot`)
- libcurl (system or Homebrew)
- `OPENROUTER_API_KEY` — set via `--openrouter-key` flag or as an environment variable
- `EXA_API_KEY` — required for `web_search` and `web_fetch` tools (`--exa-key` flag or env var)
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

| Target | Stripped Size |
|---|---|
| macOS arm64 | 183.7 KB (188176 bytes) |
| Linux aarch64 | 195.0 KB (199680 bytes) |

Startup time to interactive prompt: **~120ms** (mean of 30 runs, σ=1.9ms, 95% CI ±0.7ms). Measured on Apple Silicon by piping empty input and timing process lifetime.
