# SwiftCode

Lightweight embedded coding agent CLI, written in Swift.

## Goal

Build a minimal CLI tool that acts as a coding agent — it executes shell commands on behalf of the user. Think of it as a stripped-down, coding assistant.

## Architecture

- **Language:** Embedded Swift (no Foundation, no SwiftUI, no AppKit — raw C interop)
- **Entry point:** `Sources/SwiftCodeEmbedded/main.swift`
- **Build system:** Swift Package Manager (`Package.swift`)
- **Target:** macOS command-line tool
- **Concurrency:** pthreads via C shims (embedded Swift lacks the async/await runtime)

## Core Capabilities (in priority order)

1. Accept a natural-language prompt via stdin or argument
2. Execute shell commands and capture output
3. Send prompts to an LLM API (OpenRouter specifically) and stream responses
5. Apply code edits suggested by the LLM back to files

## Constraints

- Keep dependencies minimal — prefer C shims over third-party Swift packages
- Vendored C libraries: cJSON (JSON), libcurl (HTTP), custom Cstdio (stdio/threads/signals)
- All output goes to stdout/stderr; no GUI

## Code Style

- Use pthreads via the Cstdio shim for concurrency (no async/await in embedded Swift)
- Prefer value types (`struct`, `enum`) over classes — use classes only when deinit or reference semantics are required (e.g. `AbortFlag`, `ThreadSafeQueue`, `JSONValue`)
- Keep files small and focused — one responsibility per file
- Errors should be descriptive and include context for debugging
