// swift-tools-version: 5.9

import PackageDescription
#if os(macOS)
import Foundation
#endif

#if os(macOS)
// The standalone Apple Command Line Tools ship Swift Testing beside the
// developer frameworks, but `swift test` does not add that directory to its
// module or runtime search paths. Full Xcode toolchains already discover it;
// these flags make the test bundle build and link in a CLT-only setup. The
// Makefile's custom runner handles CLT's separate zero-test discovery bug.
let candidateDeveloperDirectories = [
    ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
    "/Applications/Xcode.app/Contents/Developer",
    "/Library/Developer/CommandLineTools"
].compactMap { $0 }
let testingDeveloperDirectory = candidateDeveloperDirectories.first { directory in
    FileManager.default.fileExists(
        atPath: "\(directory)/Library/Developer/Frameworks/Testing.framework"
    )
}
let testingSwiftSettings: [SwiftSetting] = testingDeveloperDirectory.map { directory in
    [.unsafeFlags(["-F", "\(directory)/Library/Developer/Frameworks"])]
} ?? []
let testingLinkerSettings: [LinkerSetting] = testingDeveloperDirectory.map { directory in
    [.unsafeFlags([
        "-F", "\(directory)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "\(directory)/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "\(directory)/Library/Developer/usr/lib"
    ])]
} ?? []
#else
let testingSwiftSettings: [SwiftSetting] = []
let testingLinkerSettings: [LinkerSetting] = []
#endif

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
        ),
        .testTarget(
            name: "CodexUsageCoreTests",
            dependencies: ["CodexUsageCore"],
            swiftSettings: testingSwiftSettings
        ),
        .testTarget(
            name: "CodexUsageBarTests",
            dependencies: ["CodexUsageBar", "CodexUsageCore", "CodexUsageUI"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        )
    ]
)
