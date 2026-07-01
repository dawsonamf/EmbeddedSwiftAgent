SWIFT      = swiftly run swift +main-snapshot
SCRATCH    = /tmp/swiftcode-build
BINARY     = $(SCRATCH)/arm64-apple-macosx/release/EmbeddedSwiftAgent

.PHONY: build run rerun test size clean help
.DEFAULT_GOAL := help

build:
	$(SWIFT) build -c release --scratch-path $(SCRATCH) --disable-sandbox

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
	@echo "  run     Build and run (pass args via ARGS=)"
	@echo "  rerun   Run the last build without rebuilding"
	@echo "  test    Run the test suite (test.sh)"
	@echo "  size    Print the binary size"
	@echo "  clean   Remove the build scratch directory"
	@echo "  help    Show this help message"
