// swift-tools-version:6.2
// `.macOS(.v26)` requires PackageDescription 6.2 — it is unavailable at 6.1.

import PackageDescription

let package = Package(
    name: "Atmark",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AtmarkApp", targets: ["AtmarkApp"]),
        .executable(name: "atmark-shim", targets: ["atmark-shim"]),
    ],
    dependencies: [
        // Pinned exactly: the SDK is pre-1.0 and this task mapped 0.12.1's
        // transport contract in detail (see the skeleton task's
        // research/swift-sdk-surface.md). A minor bump can move that contract,
        // so upgrades are a deliberate act, not a resolution side effect.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        // The MCP SDK ships no HTTP listener; we supply one. Parent decision O4.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
    ],
    targets: [
        // Transport- and UI-independent core. Imports nothing from the SDK, NIO,
        // SwiftUI, or AppKit — enforced by the dependency graph for the packages
        // and by ImportBoundaryTests for the system frameworks.
        .target(name: "AtmarkCore"),

        .target(name: "AtmarkModules", dependencies: ["AtmarkCore"]),

        .target(
            name: "AtmarkServer",
            dependencies: [
                "AtmarkCore",
                "AtmarkModules",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),

        .executableTarget(name: "AtmarkApp", dependencies: ["AtmarkCore", "AtmarkServer"]),

        .target(
            name: "AtmarkShim",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),

        .executableTarget(name: "atmark-shim", dependencies: ["AtmarkShim"]),

        .testTarget(
            name: "AtmarkCoreTests",
            dependencies: ["AtmarkCore"],
            exclude: ["Fixtures"]
        ),
        .testTarget(name: "AtmarkServerTests", dependencies: ["AtmarkServer"]),
        .testTarget(
            name: "AtmarkAppTests",
            dependencies: ["AtmarkApp", "AtmarkCore", "AtmarkServer"]
        ),
        .testTarget(
            name: "AtmarkShimTests",
            dependencies: ["AtmarkShim", "AtmarkServer", "AtmarkCore", .product(name: "MCP", package: "swift-sdk")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
