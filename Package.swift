// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "CodexUsageBar", targets: ["CodexUsageBar"]),
        .executable(name: "CodexUsageChecks", targets: ["CodexUsageChecks"])
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(
            name: "CodexUsageBar",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "CodexUsageChecks",
            dependencies: ["CodexUsageCore"]
        )
    ]
)
