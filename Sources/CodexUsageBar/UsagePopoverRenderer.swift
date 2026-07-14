import AppKit
import CodexUsageCore
import SwiftUI

@MainActor
enum UsagePopoverRenderer {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) throws -> Bool {
        guard let options = try parse(arguments: arguments) else {
            return false
        }
        let size = NSSize(width: options.width, height: options.height)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let scenario = fixtureScenario(options.fixture)
        let viewModel = UsageViewModel(
            client: FixtureUsageClient(snapshot: scenario.fetchSnapshot),
            initialSnapshot: scenario.snapshot,
            initialState: scenario.state,
            selectedTimeframe: { options.timeframe },
            now: { fixtureNow },
            calendar: fixtureCalendar
        )
        guard let isolatedPreferences = UserDefaults(
            suiteName: "local.codex-usage-bar.render.\(UUID().uuidString)"
        ) else {
            throw PopoverRenderFailure("Could not create isolated render preferences")
        }
        let launchAtLogin = LaunchAtLoginController(
            service: RenderLaunchAtLoginService(status: scenario.loginStatus)
        )
        let scheme: ColorScheme = options.appearance == .dark ? .dark : .light
        let backgroundColor = options.appearance == .dark
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor.white
        let rootView = ZStack {
            Color(nsColor: backgroundColor)
            UsagePopoverView(
                viewModel: viewModel,
                viewportSize: size,
                preferences: isolatedPreferences,
                initialTimeframe: options.timeframe,
                launchAtLoginController: launchAtLogin,
                clock: .fixed(
                    fixtureNow,
                    calendar: fixtureCalendar,
                    locale: Locale(identifier: "en_US_POSIX")
                )
            )
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(scheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let nsAppearance = NSAppearance(named: options.appearance == .dark ? .darkAqua : .aqua)
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
        try validateLandmarkPixels(representation, size: size, fixture: options.fixture)
        guard let data = representation.representation(using: .png, properties: [:]),
              data.count > 10_000
        else {
            throw PopoverRenderFailure("Could not encode a nonempty popover PNG")
        }
        try data.write(to: outputURL, options: .atomic)
        print(
            "PASS render popover appearance=\(options.appearance.rawValue) "
                + "timeframe=\(options.timeframe.rawValue) size=\(options.width)x\(options.height) "
                + "fixture=\(options.fixture.rawValue) "
                + "bytes=\(data.count) path=\(outputURL.path)"
        )
        return true
    }

    private static func validateLandmarkPixels(
        _ image: NSBitmapImageRep,
        size: NSSize,
        fixture: PopoverRenderOptions.Fixture
    ) throws {
        guard image.pixelsWide > 0,
              image.pixelsHigh > 0,
              let background = image.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB)
        else { throw PopoverRenderFailure("Popover bitmap has no readable pixels") }

        // Keep these regions disjoint. A single aggregate header check could be
        // satisfied by the logo even if the title or hero value disappeared.
        let headerLandmarks: [(String, CGRect, CGFloat)] = [
            ("header logo", CGRect(x: 14, y: 8, width: 44, height: 64), 120),
            ("header title", CGRect(x: 58, y: 8, width: 90, height: 64), 60),
            (
                "header value",
                CGRect(x: size.width - 112, y: 8, width: 100, height: 64),
                fixture == .loading ? 12 : 30
            )
        ]
        for (name, region, minimumInk) in headerLandmarks {
            try requireInk(
                name: name,
                region: region,
                minimum: minimumInk,
                image: image,
                size: size,
                background: background
            )
        }

        if fixture == .loading || fixture == .error {
            try requireInk(
                name: "status and actions",
                region: CGRect(x: 12, y: 75, width: size.width - 24, height: 210),
                minimum: fixture == .loading ? 350 : 500,
                image: image,
                size: size,
                background: background
            )
            return
        }

        let commonLandmarks: [(String, CGRect, CGFloat)] = [
            ("timeframe tabs", CGRect(x: 12, y: 80, width: size.width - 24, height: 65), 300),
            ("summary", CGRect(x: 12, y: 145, width: size.width - 24, height: 150), 500),
            ("chart", CGRect(x: 12, y: 280, width: size.width - 24, height: 190), 700)
        ]
        for (name, region, minimumInk) in commonLandmarks {
            try requireInk(
                name: name,
                region: region,
                minimum: minimumInk,
                image: image,
                size: size,
                background: background
            )
        }

        let historyRegion = size.height >= 1_000
            ? CGRect(x: 12, y: 580, width: size.width - 24, height: 180)
            : CGRect(x: 12, y: 470, width: size.width - 24, height: max(size.height - 470, 1))
        try requireInk(
            name: "daily history",
            region: historyRegion,
            minimum: 300,
            image: image,
            size: size,
            background: background
        )

        // The lower sections are intentionally below the fold at normal menu
        // heights. Only assert them when the requested bitmap is tall enough to
        // contain every landmark region in full.
        if size.height >= 1_200 {
            // These fixtures have either a single history status row or only two
            // active rows in place of the normal six, so all subsequent sections
            // move upward. Validate the actual state-specific layout instead of
            // treating success-state coordinates as a universal invariant.
            let lowerLandmarks: [(String, CGRect, CGFloat)] = fixture.hasCompactHistoryLayout
                ? [
                    ("rate limits", CGRect(x: 12, y: 520, width: size.width - 24, height: 420), 700),
                    ("refresh footer", CGRect(x: 12, y: 850, width: size.width - 24, height: 120), 150),
                    ("actions", CGRect(x: 12, y: 900, width: size.width - 24, height: 220), 300)
                ]
                : [
                    ("rate limits", CGRect(x: 12, y: 740, width: size.width - 24, height: 290), 700),
                    ("refresh footer", CGRect(x: 12, y: 1_020, width: size.width - 24, height: 75), 150),
                    ("actions", CGRect(x: 12, y: 1_080, width: size.width - 24, height: 120), 300)
                ]
            for (name, region, minimumInk) in lowerLandmarks {
                try requireInk(
                    name: name,
                    region: region,
                    minimum: minimumInk,
                    image: image,
                    size: size,
                    background: background
                )
            }
        }

        let chromaticChartInk = normalizedPixelCount(
            image: image,
            size: size,
            region: CGRect(x: 45, y: 300, width: size.width - 57, height: 175)
        ) { color in
            let components = [color.redComponent, color.greenComponent, color.blueComponent]
            guard let minimum = components.min(), let maximum = components.max() else { return false }
            return maximum - minimum > 0.08 && colorDistance(color, background) > 0.12
        }
        if fixture.hasActiveChart {
            guard chromaticChartInk >= 25 else {
                throw PopoverRenderFailure("Popover chart has no detectable usage stroke")
            }
        } else {
            guard chromaticChartInk < 25 else {
                throw PopoverRenderFailure("Popover no-activity fixture unexpectedly rendered a usage stroke")
            }
        }
    }

    private static func requireInk(
        name: String,
        region: CGRect,
        minimum: CGFloat,
        image: NSBitmapImageRep,
        size: NSSize,
        background: NSColor
    ) throws {
        let ink = normalizedPixelCount(image: image, size: size, region: region) { color in
            colorDistance(color, background) > 0.18
        }
        guard ink >= minimum else {
            throw PopoverRenderFailure(
                "Popover \(name) landmark rendered only \(Int(ink)) point-normalized ink pixels"
            )
        }
    }

    private static func normalizedPixelCount(
        image: NSBitmapImageRep,
        size: NSSize,
        region: CGRect,
        predicate: (NSColor) -> Bool
    ) -> CGFloat {
        let scaleX = CGFloat(image.pixelsWide) / size.width
        let scaleY = CGFloat(image.pixelsHigh) / size.height
        let clipped = region.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return 0 }
        let minimumX = max(0, Int((clipped.minX * scaleX).rounded(.down)))
        let maximumX = min(image.pixelsWide - 1, Int((clipped.maxX * scaleX).rounded(.up)))
        let minimumY = max(0, Int((clipped.minY * scaleY).rounded(.down)))
        let maximumY = min(image.pixelsHigh - 1, Int((clipped.maxY * scaleY).rounded(.up)))
        var count = 0
        for y in minimumY...maximumY {
            for x in minimumX...maximumX {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      predicate(color)
                else { continue }
                count += 1
            }
        }
        return CGFloat(count) / max(scaleX * scaleY, 1)
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent)
            + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent)
            + abs(lhs.alphaComponent - rhs.alphaComponent)
    }

    static func parse(arguments: [String]) throws -> PopoverRenderOptions? {
        let tokens = Array(arguments.dropFirst())
        guard tokens.contains("--render-popover") else { return nil }

        var outputPath: String?
        var appearance: PopoverRenderOptions.Appearance = .light
        var timeframe: UsageTimeframe = .thirty
        var fixture: PopoverRenderOptions.Fixture = .success
        var width = 300
        var height = 560
        var seen = Set<String>()
        var index = 0

        func operand(after option: String, at index: Int) throws -> String {
            let operandIndex = index + 1
            guard tokens.indices.contains(operandIndex), !tokens[operandIndex].hasPrefix("--") else {
                throw PopoverRenderFailure("\(option) requires a value")
            }
            return tokens[operandIndex]
        }

        while index < tokens.count {
            let option = tokens[index]
            guard ["--render-popover", "--appearance", "--timeframe", "--fixture", "--width", "--height"].contains(option) else {
                throw PopoverRenderFailure("Unknown render option: \(option)")
            }
            guard seen.insert(option).inserted else {
                throw PopoverRenderFailure("Duplicate render option: \(option)")
            }
            let rawValue = try operand(after: option, at: index)

            switch option {
            case "--render-popover":
                outputPath = rawValue
            case "--appearance":
                guard let parsed = PopoverRenderOptions.Appearance(rawValue: rawValue) else {
                    throw PopoverRenderFailure("--appearance must be light or dark")
                }
                appearance = parsed
            case "--timeframe":
                guard let parsed = UsageTimeframe(rawValue: rawValue) else {
                    throw PopoverRenderFailure("--timeframe must be one of: seven, thirty, ninety, all")
                }
                timeframe = parsed
            case "--fixture":
                guard let parsed = PopoverRenderOptions.Fixture(rawValue: rawValue) else {
                    throw PopoverRenderFailure(
                        "--fixture must be one of: \(PopoverRenderOptions.Fixture.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                fixture = parsed
            case "--width":
                width = try dimension(rawValue, option: option, range: 260...2_000)
            case "--height":
                height = try dimension(rawValue, option: option, range: 560...2_000)
            default:
                break
            }
            index += 2
        }

        guard let outputPath else {
            throw PopoverRenderFailure("--render-popover requires an output path")
        }
        return PopoverRenderOptions(
            outputPath: outputPath,
            appearance: appearance,
            timeframe: timeframe,
            fixture: fixture,
            width: width,
            height: height
        )
    }

    private static func dimension(
        _ rawValue: String,
        option: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = Int(rawValue), range.contains(value) else {
            throw PopoverRenderFailure(
                "\(option) must be a whole number between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return value
    }

    private static func fixtureSnapshot() -> UsageSnapshot {
        let now = fixtureNow
        let calendar = fixtureCalendar
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
            credits: CreditsSnapshot(hasCredits: true, unlimited: false, balance: "14.00"),
            individualLimit: SpendControlLimitSnapshot(
                limit: "100.00",
                used: "37.00",
                remainingPercent: 63,
                resetsAt: fixtureNow.timeIntervalSince1970 + 3_600
            ),
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

    private static func fixtureScenario(
        _ fixture: PopoverRenderOptions.Fixture
    ) -> FixtureScenario {
        let base = fixtureSnapshot()
        let defaultScenario = FixtureScenario(
            snapshot: base,
            state: .loaded,
            fetchSnapshot: base,
            loginStatus: .notRegistered
        )
        switch fixture {
        case .success:
            return defaultScenario
        case .loading:
            return FixtureScenario(
                snapshot: nil,
                state: .loading,
                fetchSnapshot: base,
                loginStatus: .notRegistered
            )
        case .error:
            return FixtureScenario(
                snapshot: nil,
                state: .failed("Codex app-server fixture unavailable"),
                fetchSnapshot: base,
                loginStatus: .notRegistered
            )
        case .stale:
            return FixtureScenario(
                snapshot: base,
                state: .failed("Network connection unavailable"),
                fetchSnapshot: base,
                loginStatus: .notRegistered
            )
        case .missingDaily:
            let usage = AccountTokenUsageResponse(
                summary: base.usage.summary,
                dailyUsageBuckets: nil
            )
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: usage,
                    rateLimits: base.rateLimits
                )
            )
        case .emptyDaily:
            let usage = AccountTokenUsageResponse(
                summary: UsageSummary(
                    lifetimeTokens: 0,
                    peakDailyTokens: 0,
                    longestRunningTurnSec: 0,
                    currentStreakDays: 0,
                    longestStreakDays: 0
                ),
                dailyUsageBuckets: []
            )
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: usage,
                    rateLimits: base.rateLimits
                )
            )
        case .zero:
            let zeroBuckets = (base.usage.dailyUsageBuckets ?? []).map {
                DailyUsageBucket(startDate: $0.startDate, tokens: 0)
            }
            let usage = AccountTokenUsageResponse(
                summary: UsageSummary(
                    lifetimeTokens: 0,
                    peakDailyTokens: 0,
                    longestRunningTurnSec: 0,
                    currentStreakDays: 0,
                    longestStreakDays: 0
                ),
                dailyUsageBuckets: zeroBuckets
            )
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: usage,
                    rateLimits: base.rateLimits
                )
            )
        case .overflow:
            let usage = AccountTokenUsageResponse(
                summary: UsageSummary(
                    lifetimeTokens: .max,
                    peakDailyTokens: .max,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: [
                    DailyUsageBucket(startDate: "2026-07-12", tokens: .max),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: .max)
                ]
            )
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: usage,
                    rateLimits: base.rateLimits
                )
            )
        case .partial:
            let partialBuckets = Array((base.usage.dailyUsageBuckets ?? []).suffix(6))
            let usage = AccountTokenUsageResponse(
                summary: base.usage.summary,
                dailyUsageBuckets: partialBuckets
            )
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: usage,
                    rateLimits: base.rateLimits
                )
            )
        case .malformedRate:
            let rateLimits = base.rateLimits.map {
                AccountRateLimitsResponse(
                    rateLimits: $0.rateLimits,
                    rateLimitsByLimitId: $0.rateLimitsByLimitId,
                    rateLimitResetCredits: $0.rateLimitResetCredits,
                    decodingIssues: ["rateLimits.primary: malformed fixture field omitted"]
                )
            }
            return defaultScenario.replacing(
                snapshot: UsageSnapshot(
                    fetchedAt: base.fetchedAt,
                    usage: base.usage,
                    rateLimits: rateLimits
                )
            )
        case .loginApproval:
            return FixtureScenario(
                snapshot: base,
                state: .loaded,
                fetchSnapshot: base,
                loginStatus: .requiresApproval
            )
        }
    }

    static let fixtureNow = Date(timeIntervalSince1970: 1_783_944_000)

    static var fixtureCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

struct PopoverRenderOptions: Equatable {
    enum Appearance: String, Equatable {
        case light
        case dark
    }

    enum Fixture: String, CaseIterable, Equatable {
        case success
        case loading
        case error
        case stale
        case missingDaily = "missing-daily"
        case emptyDaily = "empty-daily"
        case zero
        case overflow
        case partial
        case malformedRate = "malformed-rate"
        case loginApproval = "login-approval"

        var hasActiveChart: Bool {
            switch self {
            case .loading, .error, .missingDaily, .emptyDaily, .zero:
                return false
            case .success, .stale, .overflow, .partial, .malformedRate, .loginApproval:
                return true
            }
        }

        var hasCompactHistoryLayout: Bool {
            switch self {
            case .missingDaily, .emptyDaily, .zero, .overflow:
                return true
            case .success, .loading, .error, .stale, .partial, .malformedRate, .loginApproval:
                return false
            }
        }
    }

    let outputPath: String
    let appearance: Appearance
    let timeframe: UsageTimeframe
    let fixture: Fixture
    let width: Int
    let height: Int
}

private struct FixtureScenario {
    let snapshot: UsageSnapshot?
    let state: UsageViewModel.LoadState
    let fetchSnapshot: UsageSnapshot
    let loginStatus: LaunchAtLoginServiceStatus

    func replacing(snapshot: UsageSnapshot) -> Self {
        Self(
            snapshot: snapshot,
            state: state,
            fetchSnapshot: snapshot,
            loginStatus: loginStatus
        )
    }
}

private struct FixtureUsageClient: UsageFetching {
    let snapshot: UsageSnapshot

    func fetchUsageSnapshot() async throws -> UsageSnapshot {
        snapshot
    }
}

private struct RenderLaunchAtLoginService: LaunchAtLoginServicing {
    let status: LaunchAtLoginServiceStatus

    func register() throws {
        throw PopoverRenderFailure("Render fixture must not register a login item")
    }

    func unregister() throws {
        throw PopoverRenderFailure("Render fixture must not unregister a login item")
    }
}

private struct PopoverRenderFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
