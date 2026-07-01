# WASM Port: Handoff Notes

Goal: run this agent in the browser as a small wasm binary served from a static site (xterm.js front end, user brings their own OpenRouter key). This doc captures exploration already done (July 2026) so the implementing agent doesn't have to redo it. Facts marked **verified** were confirmed against current docs; anything marked **verify** needs a fresh check before relying on it.

**Verdict: feasible.** The codebase is unusually well positioned because every platform dependency is isolated behind small seams (two HTTP functions, `runShell`, thread/mutex/cond shims, stdin/termios, SIGINT). The port is "reimplement the seams," not "rewrite the agent."

## Toolchain (verified)

- Swift ships official WebAssembly SDKs on swift.org (Swift 6.1 made wasm a supported target; 6.2+/snapshots distribute SDK artifact bundles). The bundles include an **experimental Embedded Swift mode for wasm**, which produces binaries in the hundreds-of-KB class instead of several MB.
  - Getting started: https://www.swift.org/documentation/articles/wasm-getting-started.html
  - Announcement: https://forums.swift.org/t/swift-sdks-for-webassembly-now-available-on-swift-org/80405
- This repo already builds with `swiftly run swift +main-snapshot`, which matches the SDK requirements.
- **Target choice: `wasm32-unknown-wasip1`** (with wasi-libc), not `wasm32-unknown-none`. wasi-libc provides `malloc`, `fopen`/`fread`/`fwrite`, `mkdir`, `getenv`, so cJSON and the file tools compile essentially unchanged. Bare-metal wasm would mean hand-rolling an allocator for cJSON. (**verify** the exact SDK id string once installed, e.g. via `swift sdk list`.)
- Size expectation: this code + cJSON plausibly 200–400 KB raw, ~100 KB gzipped. Run `wasm-opt -Oz` and strip on the output.

## The blocking problem (biggest decision)

The loop is fully synchronous: blocking curl in `sendStreaming`, blocking `waitForInput()`. Browsers cannot block, and `fetch` is async even in a Worker. Three options:

1. **JSPI (JavaScript Promise Integration)**: lets sync wasm suspend on async JS. Status (**verified July 2026**): on by default in Chrome since 137 (May 2025); Firefox behind a flag; Safari has it in Technology Preview after dropping its objection in late 2025; JSPI is an Interop 2026 focus area. Best path for a demo now, cross-browser soon. See https://caniuse.com/wf-wasm-jspi
2. **Binaryen Asyncify** (`wasm-opt --asyncify`): works in every browser today, costs roughly 2x module size and some fragility. The portable fallback.
3. **Event-driven refactor**: make the loop re-entrant (input events in, render callbacks out) so nothing ever blocks. Most work, cleanest result, and it is the same decoupling `plans/agent-loop-architecture.md` and the server-API TODO already want. Pays off natively too.

Related: wasip1 has "command" (runs `main()` to completion) vs "reactor" (`-mexec-model=reactor`, exports functions instead) execution models. The current REPL-in-`main()` shape fits command+JSPI; the event-driven refactor pairs with reactor. (**verify** reactor-model support in the Swift SDK.)

## Seam-by-seam port map

### HTTP — `Sources/EmbeddedSwiftAgent/EmbeddedFoundation/HTTP.swift`
Reimplement exactly two functions for wasm, same signatures:
- `httpPost(url:headers:body:) -> HTTPResponse`
- `httpPostStreaming(url:headers:body:abortFlag:onLine:) -> HTTPResult`

Browser backend: JS import over `fetch` + `ReadableStream`. Keep the newline-splitting in Swift (the buffer/split loop in `curlWriteCallback` is portable logic; feed it raw chunks via an exported function) so SSE handling in `OpenRouterClient` stays untouched. Abort: `AbortController` on the JS side, checked against the same `AbortFlag`. Roughly 100 lines of JS glue.

### Shell — `EmbeddedFoundation/Shell.swift` (`runShell`)
No processes in the browser, period. Current callers:
- `sh` tool: compile out for wasm.
- `glob` / `grep` tools: shell out to `find`/`grep`; compile out, or reimplement natively over the FS later.
- `write_file`'s `mkdir -p`: replace with a native `mkdir()` loop (wasi-libc has `mkdir`; ~15 lines). Worth doing on native too, it removes a shell dependency from a file primitive.

Gate the tool registry (`allTools` in `Tools.swift`) with `#if os(WASI)` or a platform-tools grouping.

### Threads — `Cstdio` + `ParallelExecution.swift`
Key existing property: `executeToolsInParallel` already falls back to inline sequential execution when `sc_thread_create` returns NULL. So for wasm, stub `sc_thread_create` to return NULL and parallel tool calls degrade gracefully with zero Swift changes. Make mutex/cond no-ops (single-threaded module).

Skipping wasm threads means no SharedArrayBuffer, which means **no COOP/COEP headers**, which means it deploys on GitHub Pages or any dumb static host.

### Input & terminal — `InputReader.swift`, termios in `Cstdio.c`
Replace entirely in the browser: xterm.js captures keys, an exported `agent_submit_input(ptr, len)` pushes into the input queue (steering later is just another exported call pushing to the steering queue). Drop termios/raw mode. SIGINT does not exist in wasm; abort is an exported `agent_abort()` that sets the `AbortFlag`.

### Cstdio compile surface
`Cstdio.c` will not compile for WASI as-is: `posix_spawn`, `termios`, pthreads, `signal` are the offenders. Either an `#ifdef __wasi__` stub section or a separate target. wasi-libc offers emulation shims for some APIs (`-D_WASI_EMULATED_SIGNAL -lwasi-emulated-signal`, `-D_WASI_EMULATED_PROCESS_CLOCKS`); **verify** which are actually needed for the subset kept. Note: the Linux argv-capture constructor trick in `Cstdio.c` won't work on WASI; prefer env vars (below) over CLI flags in the browser.

### Package.swift
- `Ccurl` systemLibrary and `.linkedLibrary("curl")` must be excluded for wasm (conditionalize like the existing macOS/Linux linker split).
- The `Embedded` experimental feature is already enabled; the wasm SDK consumes the same setting (**verify** flag interplay per the swift.org article).

### Filesystem
`read_file` / `write_file` / `str_replace` use `fopen`/`fread`/`fwrite` and work unchanged against a WASI filesystem. In the browser, use an in-memory FS shim with a preopened dir: `@bjorn3/browser_wasi_shim` (small, no deps) or `@wasmer/wasi`. Persist to IndexedDB later if wanted.

### Config & keys
- `getenv` works under WASI (env supplied by the JS shim at instantiation): pass `OPENROUTER_API_KEY`, `MODEL`, `REASONING_EFFORT` that way.
- OpenRouter from the browser works; they provide an **OAuth PKCE flow specifically for client-side apps** so visitors connect their own account, or paste a key stored in localStorage. Never embed a real key in the site; anyone can extract it. Docs: https://openrouter.ai/docs
- Exa CORS: **unverified**. If blocked, either a tiny proxy (Cloudflare Worker) or compile out `web_search`/`web_fetch` for the browser build.

### Untouched by the port
cJSON (pure C99), `JSON.swift`, `Models.swift`, `Events.swift`, `OpenRouterClient.swift` (pure logic over the HTTP seam), the agent loop, the subagent tool (HTTP only), and the renderer (ANSI escapes render fine in xterm.js).

## Suggested phasing

1. **Native prep** (no wasm yet): native `mkdir -p` for `write_file`; group shell-backed tools behind a platform gate. Everything still builds and tests on macOS/Linux.
2. **Compile for `wasm32-unknown-wasip1`** with curl/spawn/termios stubbed. Tools: read/write/str_replace/subagent only. Instantiate in a browser page with a stub HTTP import returning canned SSE; verify loop, JSON, FS behavior.
3. **Real fetch bridge + JSPI**, Chrome-only page. No Worker needed if JSPI handles suspension.
4. **xterm.js UI + BYOK key entry** → ship on the static site.
5. **Cross-browser**: Asyncify build, or do the event-driven refactor and delete the suspension hack entirely.

## Open questions for the implementer

- Exact `swift sdk install` invocation and SDK id for the current snapshot; embedded-mode flag interplay with SwiftPM.
- JavaScriptKit: it has gained Embedded Swift support (**verify** current state), but hand-rolled raw JS imports may fit this project's no-dependency ethos better than pulling in JavaScriptKit.
- Reactor exec-model support in the Swift SDK linker flags.
- Exa CORS behavior from a browser origin.
- Which wasi-libc emulation defines the retained `Cstdio` subset actually needs.

## Sources

- Swift SDKs for WebAssembly: https://www.swift.org/documentation/articles/wasm-getting-started.html
- swift.org SDK announcement: https://forums.swift.org/t/swift-sdks-for-webassembly-now-available-on-swift-org/80405
- SwiftWasm book: https://book.swiftwasm.org/
- JSPI support table: https://caniuse.com/wf-wasm-jspi
- State of WebAssembly 2025/2026 (JSPI browser status): https://platform.uno/blog/the-state-of-webassembly-2025-2026/
- browser_wasi_shim: https://github.com/bjorn3/browser_wasi_shim
- OpenRouter auth (PKCE for client-side apps): https://openrouter.ai/docs/api/reference/authentication
