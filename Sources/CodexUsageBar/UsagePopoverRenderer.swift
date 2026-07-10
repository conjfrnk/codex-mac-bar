import AppKit
import CodexUsageCore
import SwiftUI

@MainActor
enum UsagePopoverRenderer {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) throws -> Bool {
        guard let commandIndex = arguments.firstIndex(of: "--render-popover") else {
            return false
        }
        let pathIndex = arguments.index(after: commandIndex)
        guard arguments.indices.contains(pathIndex) else {
            throw PopoverRenderFailure("--render-popover requires an output path")
        }

        let appearance = option("--appearance", in: arguments) ?? "light"
        guard appearance == "light" || appearance == "dark" else {
            throw PopoverRenderFailure("--appearance must be light or dark")
        }
        let width = try dimension("--width", defaultValue: 300, in: arguments)
        let height = try dimension("--height", defaultValue: 560, in: arguments)
        let size = NSSize(width: width, height: height)
        let outputURL = URL(fileURLWithPath: arguments[pathIndex])
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let snapshot = fixtureSnapshot()
        let viewModel = UsageViewModel(
            client: FixtureUsageClient(snapshot: snapshot),
            initialSnapshot: snapshot
        )
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let backgroundColor = appearance == "dark"
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor.white
        let rootView = ZStack {
            Color(nsColor: backgroundColor)
            UsagePopoverView(viewModel: viewModel, viewportSize: size)
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(scheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let nsAppearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        hostingView.appearance = nsAppearance
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = backgroundColor.cgColor

        let containerView = NSView(frame: hostingView.frame)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = backgroundColor.cgColor
        containerView.addSubview(hostingView)
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = nsAppearance
        window.backgroundColor = backgroundColor
        window.contentView = containerView
        hostingView.frame = containerView.bounds
        containerView.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let representation = containerView.bitmapImageRepForCachingDisplay(in: containerView.bounds) else {
            throw PopoverRenderFailure("Could not allocate the popover bitmap")
        }
        containerView.cacheDisplay(in: containerView.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]),
              data.count > 10_000
        else {
            throw PopoverRenderFailure("Could not encode a nonempty popover PNG")
        }
        try data.write(to: outputURL, options: .atomic)
        print("PASS render popover appearance=\(appearance) size=\(Int(width))x\(Int(height)) bytes=\(data.count) path=\(outputURL.path)")
        return true
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func dimension(
        _ name: String,
        defaultValue: Double,
        in arguments: [String]
    ) throws -> Double {
        guard let rawValue = option(name, in: arguments) else { return defaultValue }
        guard let value = Double(rawValue), value.isFinite, value >= 220, value <= 2_000 else {
            throw PopoverRenderFailure("\(name) must be between 220 and 2000")
        }
        return value
    }

    private static func fixtureSnapshot() -> UsageSnapshot {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let buckets = (0..<120).compactMap { offset -> DailyUsageBucket? in
            guard let date = calendar.date(byAdding: .day, value: offset - 119, to: today) else {
                return nil
            }
            let tokens = offset.isMultiple(of: 11)
                ? Int64(0)
                : Int64(((offset + 3) * (offset + 17) * 71_123) % 9_000_000)
            return DailyUsageBucket(
                startDate: UsageWindows.bucketStartString(for: date, timeZone: calendar.timeZone),
                tokens: tokens
            )
        }
        let total = buckets.reduce(Int64(0)) { $0 + $1.tokens }
        let usage = AccountTokenUsageResponse(
            summary: UsageSummary(
                lifetimeTokens: total,
                peakDailyTokens: buckets.map(\.tokens).max(),
                longestRunningTurnSec: 5_400,
                currentStreakDays: 8,
                longestStreakDays: 21
            ),
            dailyUsageBuckets: buckets
        )
        let limit = RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(
                usedPercent: 64,
                windowDurationMins: 300,
                resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970
            ),
            secondary: RateLimitWindow(
                usedPercent: 31.5,
                windowDurationMins: 10_080,
                resetsAt: now.addingTimeInterval(86_400).timeIntervalSince1970
            ),
            credits: CreditsSnapshot(remaining: 14, total: 20, used: 6),
            individualLimit: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )
        let rateLimits = AccountRateLimitsResponse(
            rateLimits: limit,
            rateLimitsByLimitId: ["codex": limit],
            rateLimitResetCredits: RateLimitResetCreditsSummary(availableCount: 2)
        )
        return UsageSnapshot(fetchedAt: now, usage: usage, rateLimits: rateLimits)
    }
}

private struct FixtureUsageClient: UsageFetching {
    let snapshot: UsageSnapshot

    func fetchUsageSnapshot() async throws -> UsageSnapshot {
        snapshot
    }
}

private struct PopoverRenderFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
