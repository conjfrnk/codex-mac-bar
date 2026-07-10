// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .library(name: "CodexUsageUI", targets: ["CodexUsageUI"]),
        .executable(name: "CodexUsageBar", targets: ["CodexUsageBar"]),
        .executable(name: "CodexUsageChecks", targets: ["CodexUsageChecks"]),
        .executable(name: "CodexUsageVisualChecks", targets: ["CodexUsageVisualChecks"])
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .target(
            name: "CodexUsageUI",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "CodexUsageBar",
            dependencies: ["CodexUsageCore", "CodexUsageUI"]
        ),
        .executableTarget(
            name: "CodexUsageChecks",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "CodexUsageVisualChecks",
            dependencies: ["CodexUsageCore", "CodexUsageUI"]
        )
    ]
)
