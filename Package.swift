// swift-tools-version: 6.0
import PackageDescription

#if os(macOS)
let platformLinkerFlags: [LinkerSetting] = [
    .unsafeFlags(["-use-ld=/usr/bin/ld"]),
]
#else
let platformLinkerFlags: [LinkerSetting] = [
    .linkedLibrary("bsd"),
]
#endif

let package = Package(
    name: "SwiftCodeEmbedded",
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
            name: "SwiftCodeEmbedded",
            dependencies: ["Ccurl", "CcJSON", "Cstdio"],
            path: "Sources/SwiftCodeEmbedded",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .unsafeFlags(["-whole-module-optimization"]),
            ],
            linkerSettings: [
                .linkedLibrary("curl"),
            ] + platformLinkerFlags
        )
    ]
)
