# Build & Run

```
c; xcrun swift build -c release && strip .build/release/SwiftCodeEmbedded; .build/release/SwiftCodeEmbedded
```

# Check Binary Size

```
cd SwiftCodeEmbedded && xcrun swift build -c release && ls -lh .build/release/SwiftCodeEmbedded
```
