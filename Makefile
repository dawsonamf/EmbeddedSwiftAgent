SWIFT      = swiftly run swift +main-snapshot
SCRATCH    = /tmp/swiftcode-build
BINARY     = $(SCRATCH)/arm64-apple-macosx/release/EmbeddedSwiftAgent

# WebAssembly build (browser demo in web/). The SDK version must exactly match
# the +main-snapshot toolchain — see plans/wasm-port.md and README.
WASM_SDK     = swift-DEVELOPMENT-SNAPSHOT-2026-03-16-a_wasm-embedded
WASM_SCRATCH = /tmp/swiftcode-build-wasm
WASM_BINARY  = $(WASM_SCRATCH)/wasm32-unknown-wasip1/release/EmbeddedSwiftAgent.wasm

.PHONY: build run rerun test size clean help wasm
.DEFAULT_GOAL := help

build:
	$(SWIFT) build -c release --scratch-path $(SCRATCH) --disable-sandbox

wasm:
	$(SWIFT) build -c release --swift-sdk $(WASM_SDK) --scratch-path $(WASM_SCRATCH) --disable-sandbox
	@cp $(WASM_BINARY) web/EmbeddedSwiftAgent.wasm 2>/dev/null \
		|| cp $(WASM_SCRATCH)/wasm32-unknown-wasip1/release/EmbeddedSwiftAgent web/EmbeddedSwiftAgent.wasm
	@ls -lh web/EmbeddedSwiftAgent.wasm | awk '{print $$9 "  " $$5}'

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
	rm -rf $(SCRATCH) $(WASM_SCRATCH) web/EmbeddedSwiftAgent.wasm

help:
	@echo "Usage: make [target] [ARGS=...]"
	@echo ""
	@echo "Targets:"
	@echo "  build   Build the release binary"
	@echo "  wasm    Build the WebAssembly binary into web/ (needs the wasm Swift SDK)"
	@echo "  run     Build and run (pass args via ARGS=)"
	@echo "  rerun   Run the last build without rebuilding"
	@echo "  test    Run the test suite (test.sh)"
	@echo "  size    Print the binary size"
	@echo "  clean   Remove the build scratch directory"
	@echo "  help    Show this help message"
