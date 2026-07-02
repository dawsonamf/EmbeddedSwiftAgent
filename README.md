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
| `--system-prompt-file` | `SYSTEM_PROMPT`  | *(none)*                     | System prompt: the flag takes a path to a file (e.g. a markdown doc), the env var takes the prompt text itself. Seeds every conversation. In the browser, the host page passes it as a WASI env var. |


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

# seed every conversation with a system prompt from a markdown file
make run ARGS="--system-prompt-file context.md"

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

## Browser (WebAssembly)

The agent also compiles to a `wasm32-unknown-wasip1` module and runs entirely in the browser: xterm.js front end, in-memory filesystem, bring-your-own OpenRouter key. The synchronous agent loop is kept as-is; the JS host suspends the wasm stack with JSPI (`WebAssembly.Suspending`) while awaiting `fetch` and keystrokes, so it needs a JSPI-capable browser (Chrome/Edge 137+; Firefox behind a flag; Safari Technology Preview). The `sh`, `glob`, and `grep` tools are compiled out (no processes on WASI); everything else works, including subagents and streaming. See `plans/wasm-port.md` for the design.

Build it:

```bash
# one-time: install the wasm Swift SDK matching the +main-snapshot toolchain
swift sdk install <swift-DEVELOPMENT-SNAPSHOT-...-a_wasm.artifactbundle.tar.gz URL or local file>

make wasm    # compiles and copies the module into web/
```

This repo ships the module and the host glue, not a demo page. To embed the agent in a site, copy `web/agent.js` and `web/EmbeddedSwiftAgent.wasm` to any static host (no special headers needed — the build is single-threaded, so no SharedArrayBuffer/COOP/COEP), create an xterm.js terminal, and call `bootAgent({ term, wasmUrl, env })` with `OPENROUTER_API_KEY`, `MODEL`, etc. in `env`. To give the agent a system prompt, include `SYSTEM_PROMPT` in `env` — for example, fetch a markdown context file from your site and pass its text through.

## Test

```bash
make test
```

Runs four phases:

1. **Build** — compiles release binaries for macOS, Linux (via Docker), and WebAssembly in parallel, reports binary sizes
2. **Agent tests** — sends real prompts through the built binary to verify:
  - Plain response (agent replies and returns to prompt)
  - Tool call success (agent runs `uuidgen` and returns a UUID)
  - Tool call failure (agent survives a bad command without crashing)
  - Subagent (spawns two subagents, each runs a command, main agent combines output)
3. **Wasm smoke tests** — runs the real `.wasm` module through the real `web/agent.js` glue headlessly in Node (which ships JSPI), with canned SSE responses instead of the network: streaming/prompt cycle, SSE parsing across chunk boundaries, and a tool-call round trip against the in-memory WASI filesystem (`web/test/wasm-smoke.mjs`)
4. **Teardown** — cleans up build artifacts

Agent tests require `OPENROUTER_API_KEY`. Set `MODEL` to override the default model. Linux build requires Docker (skipped if unavailable). Wasm build requires the wasm Swift SDK (skipped if not installed); the wasm smoke tests additionally need a recent `node` (for JSPI) and don't use an API key. `node` is optional: without it the wasm smoke tests are skipped, so it's never required to run the suite.

## Performance


| Target        | Size                    |
| ------------- | ----------------------- |
| macOS arm64   | 200.8 KB (205688 bytes) |
| Linux aarch64 | 195.0 KB (199704 bytes) |
| wasm32-wasip1 | 207.8 KB (212826 bytes) |

_macOS and Linux are stripped release binaries; wasm is the shipped `.wasm` module._


Startup time to interactive prompt: **~120ms** (mean of 30 runs, σ=1.9ms, 95% CI ±0.7ms). Measured on Apple Silicon (M4 Pro) by piping empty input and timing process lifetime.