// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmbeddedSwiftAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "Ccurl",
            path: "Sources/Ccurl",
            pkgConfig: "libcurl",
            providers: [
                .brew(["curl"]),
                .apt(["libcurl4-openssl-dev"])
            ]
        ),
        .target(
            name: "CcJSON",
            path: "Sources/CcJSON",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Cstdio",
            path: "Sources/Cstdio",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "EmbeddedSwiftAgent",
            dependencies: [
                // curl only backs the native HTTP implementation; the wasm build
                // talks to the browser's fetch through JS imports instead (see
                // HTTPWasm.swift and web/agent.js).
                .target(name: "Ccurl", condition: .when(platforms: [.macOS, .linux])),
                "CcJSON",
                "Cstdio",
            ],
            path: "Sources/EmbeddedSwiftAgent",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .unsafeFlags(["-whole-module-optimization"]),
            ],
            linkerSettings: [
                .linkedLibrary("curl", .when(platforms: [.macOS, .linux])),
                .linkedLibrary("bsd", .when(platforms: [.linux])),
                .unsafeFlags(["-use-ld=/usr/bin/ld"], .when(platforms: [.macOS])),
                // DWARF + name sections are ~70% of the wasm binary otherwise.
                .unsafeFlags(["-Xlinker", "--strip-all"], .when(platforms: [.wasi])),
            ]
        )
    ]
)
