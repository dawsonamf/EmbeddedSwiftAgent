SWIFT      = swiftly run swift +main-snapshot
SCRATCH    = /tmp/swiftcode-build
BINARY     = $(SCRATCH)/arm64-apple-macosx/release/EmbeddedSwiftAgent

# WebAssembly build (browser demo in web/). The SDK version must exactly match
# the +main-snapshot toolchain — see plans/wasm-port.md and README.
WASM_SDK     = swift-DEVELOPMENT-SNAPSHOT-2026-03-16-a_wasm-embedded
WASM_SCRATCH = /tmp/swiftcode-build-wasm
WASM_BINARY  = $(WASM_SCRATCH)/wasm32-unknown-wasip1/release/EmbeddedSwiftAgent.wasm

# Port for the local wasm demo server (override with `make web WEB_PORT=1234`).
WEB_PORT ?= 8765

.PHONY: build run rerun test size clean help wasm web
.DEFAULT_GOAL := help

build:
	$(SWIFT) build -c release --scratch-path $(SCRATCH) --disable-sandbox

wasm:
	$(SWIFT) build -c release --swift-sdk $(WASM_SDK) --scratch-path $(WASM_SCRATCH) --disable-sandbox
	@cp $(WASM_BINARY) web/EmbeddedSwiftAgent.wasm 2>/dev/null \
		|| cp $(WASM_SCRATCH)/wasm32-unknown-wasip1/release/EmbeddedSwiftAgent web/EmbeddedSwiftAgent.wasm
	@ls -lh web/EmbeddedSwiftAgent.wasm | awk '{print $$9 "  " $$5}'

web:
	@test -f web/EmbeddedSwiftAgent.wasm || { echo "web/EmbeddedSwiftAgent.wasm not found — run 'make wasm' first."; exit 1; }
	@echo "Serving the wasm demo at http://localhost:$(WEB_PORT)/  (press Ctrl-C to stop)"
	@command -v open >/dev/null 2>&1 && ( sleep 1 && open "http://localhost:$(WEB_PORT)/" ) &
	@python3 -m http.server --directory web $(WEB_PORT)

run: build
	$(BINARY) $(ARGS)

rerun:
	@test -f $(BINARY) || { echo "No build found. Run 'make run' first."; exit 1; }
	$(BINARY) $(ARGS)

test:
	./test.sh

size: build
	@cp $(BINARY) $(BINARY).stripped && strip $(BINARY).stripped 2>/dev/null; \
	ls -lh $(BINARY).stripped | awk '{print $$5 " (stripped)"}'; \
	rm -f $(BINARY).stripped

clean:
	rm -rf $(SCRATCH)

help:
	@echo "Usage: make [target] [ARGS=...]"
	@echo ""
	@echo "Targets:"
	@echo "  build   Build the release binary"
	@echo "  wasm    Build the WebAssembly binary into web/ (needs the wasm Swift SDK)"
	@echo "  web     Serve web/ locally and open the wasm demo in a browser"
	@echo "  run     Build and run (pass args via ARGS=)"
	@echo "  rerun   Run the last build without rebuilding"
	@echo "  test    Run the test suite (test.sh)"
	@echo "  size    Print the binary size"
	@echo "  clean   Remove the build scratch directory"
	@echo "  help    Show this help message"
