SWIFT      = swiftly run swift +main-snapshot
SCRATCH    = /tmp/swiftcode-build
BINARY     = $(SCRATCH)/arm64-apple-macosx/release/EmbeddedSwiftAgent

.PHONY: build run rerun test size clean

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
	@ls -lh $(BINARY) | awk '{print $$5}'

clean:
	rm -rf $(SCRATCH)
