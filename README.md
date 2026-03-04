# SwiftCodeEmbedded

A minimal coding agent CLI written in Embedded Swift. No Foundation, no SwiftUI — just POSIX, cJSON, and libcurl.

Accepts natural-language prompts, streams responses from an LLM (via OpenRouter), and executes shell commands in an agent loop.

## Requirements

- **Swift 6.3-dev snapshot** (or later) — Embedded Swift is an experimental feature not yet in release toolchains
- **Swiftly** (recommended) for toolchain management: `brew install swiftly`
- **libcurl** (system or Homebrew)

## Binary Size

| Target | Stripped |
|---|---|
| macOS arm64 (Embedded) | 108 KB |
| Linux aarch64 (Embedded) | 131 KB |

*Previous non-embedded sizes: macOS 92 KB (dynamic), Linux 5.3 MB (static).*

## Build & Run (macOS)

```bash
# Install a nightly snapshot (if you haven't already)
swiftly install main-snapshot

# Make sure it's active
swiftly use main-snapshot
swift --version  # should show 6.3-dev or similar

# Build
export OPENROUTER_API_KEY=your-key
swift build -c release

# Strip and run
strip .build/release/SwiftCodeEmbedded
.build/release/SwiftCodeEmbedded
```

## Build & Run (Linux via Docker)

```bash
docker run --rm -v $(pwd):/workspace -w /workspace \
  swiftlang/swift:nightly-jammy \
  bash -c 'apt-get update -qq && apt-get install -y -qq libcurl4-openssl-dev > /dev/null 2>&1 && swift build -c release'

# Strip
docker run --rm -v $(pwd):/workspace -w /workspace \
  swiftlang/swift:nightly-jammy \
  strip .build/release/SwiftCodeEmbedded
```
