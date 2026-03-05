SWIFT    = swiftly run swift +main-snapshot
BINARY   = .build/release/SwiftCodeEmbedded

.PHONY: build run test size clean

build:
	$(SWIFT) build -c release

run: build
	$(BINARY)

test:
	./test.sh

size: build
	@ls -lh $(BINARY) | awk '{print $$5}'

clean:
	rm -rf .build
