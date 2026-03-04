# SwiftCodeEmbedded

A minimal coding agent CLI written in Swift. No Foundation, no SwiftUI — just POSIX, cJSON, and libcurl.

Accepts natural-language prompts, streams responses from an LLM (via OpenRouter), and executes shell commands in an agent loop.

## Binary Size

| Target | Size |
|---|---|
| macOS (dynamic, stripped) | 92 KB |
| Linux (static, stripped) | 5.3 MB |

## Build & Run

```
export OPENROUTER_API_KEY=your-key
xcrun swift build -c release && strip .build/release/SwiftCodeEmbedded
.build/release/SwiftCodeEmbedded
```
