SWIFT      = swiftly run swift +main-snapshot
SCRATCH    = /tmp/swiftcode-build
BINARY     = $(SCRATCH)/arm64-apple-macosx/release/SwiftCodeEmbedded

.PHONY: build run test size clean

build:
	$(SWIFT) build -c release --scratch-path $(SCRATCH) --disable-sandbox

run: build
	$(BINARY)

test:
	./test.sh

size: build
	@ls -lh $(BINARY) | awk '{print $$5}'

clean:
	rm -rf $(SCRATCH)
