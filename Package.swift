// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexWatch",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "CodexWatchCore", targets: ["CodexWatchCore"]),
        .library(name: "CodexBridgeKit", targets: ["CodexBridgeKit"]),
        .executable(name: "codex-watch-bridge", targets: ["CodexWatchBridge"]),
        .executable(name: "codex-watch-self-test", targets: ["CodexWatchSelfTest"]),
        .executable(name: "agent-bridge-mac-dev", targets: ["AgentBridgeMacDev"]),
    ],
    targets: [
        .target(
            name: "CodexWatchCore"
        ),
        .target(
            name: "CodexBridgeKit",
            dependencies: ["CodexWatchCore"],
            linkerSettings: [
                .linkedFramework("MultipeerConnectivity"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "CodexWatchBridge",
            dependencies: ["CodexWatchCore", "CodexBridgeKit"]
        ),
        .executableTarget(
            name: "CodexWatchSelfTest",
            dependencies: ["CodexWatchCore", "CodexBridgeKit"]
        ),
        .executableTarget(
            name: "AgentBridgeMacDev",
            dependencies: ["CodexWatchCore", "CodexBridgeKit"],
            path: "Apps/Mac",
            exclude: ["Localizable.xcstrings"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "CodexWatchCoreTests",
            dependencies: ["CodexWatchCore"]
        ),
        .testTarget(
            name: "CodexBridgeKitTests",
            dependencies: ["CodexWatchCore", "CodexBridgeKit"]
        ),
    ]
)
