# Build & Run

```
swiftly run swift build -c release +main-snapshot; .build/release/SwiftCodeEmbedded
```

# Check Binary Size

```
swiftly run swift build -c release +main-snapshot && ls -lh .build/release/SwiftCodeEmbedded
```
