// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ValidationRelayCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ValidationRelayCore", targets: ["ValidationRelayCore"])
    ],
    targets: [
        .target(
            name: "ValidationRelayCore",
            path: "ValidationRelay",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "Info.plist",
                "LogView.swift",
                "Preview Content",
                "Relay.swift",
                "ValidationData.swift",
                "ValidationRelay-Bridging-Header.h",
                "ValidationRelay.entitlements",
                "ValidationRelayApp.swift",
                "absd.defs"
            ],
            sources: ["RelayCredentials.swift", "ReconnectPolicy.swift"]
        ),
        .testTarget(
            name: "ValidationRelayCoreTests",
            dependencies: ["ValidationRelayCore"],
            path: "Tests/ValidationRelayCoreTests"
        )
    ]
)
