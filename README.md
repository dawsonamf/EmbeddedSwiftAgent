# SwiftCodeEmbedded

Minimal coding agent CLI in Embedded Swift. No Foundation — just POSIX, cJSON, and libcurl. Streams LLM responses via OpenRouter and executes shell commands in an agent loop.

## Requirements

- Swift 6.3-dev snapshot (`brew install swiftly && swiftly install main-snapshot`)
- libcurl (system or Homebrew)
- `OPENROUTER_API_KEY` environment variable (or in a `.env` file)
- Docker (optional, for Linux cross-compilation)

## Build & Run

```bash
export OPENROUTER_API_KEY=your-key
swiftly run swift build -c release +main-snapshot; .build/release/SwiftCodeEmbedded
```

## Test

```bash
./test.sh
```

Runs three phases:

1. **Build** — compiles release binaries for macOS and Linux (via Docker) in parallel, reports stripped binary sizes
2. **Agent tests** — sends real prompts through the built binary in parallel to verify:
   - Plain response (agent replies and returns to prompt)
   - Tool call success (agent runs `uuidgen` and returns a UUID)
   - Tool call failure (agent survives a bad command without crashing)
   - Subagent (spawns two subagents, each runs a command, main agent combines output)
3. **Teardown** — cleans up build artifacts

Agent tests require `OPENROUTER_API_KEY`. Linux build requires Docker (skipped if unavailable).

## Binary Size

| Target | Stripped |
|---|---|
| macOS arm64 | ~148 KB |
| Linux aarch64 | ~131 KB |
