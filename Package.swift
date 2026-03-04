// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCodeEmbedded",
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
            linkerSettings: [
                .linkedLibrary("curl")
            ]
        )
    ]
)
