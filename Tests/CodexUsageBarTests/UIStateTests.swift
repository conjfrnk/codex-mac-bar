import AppKit
import Combine
import CodexUsageCore
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import CodexUsageBar
@testable import CodexUsageUI

@Suite
struct UIStateTests {
    @Test
    @MainActor
    func testRequiresApprovalIsRegisteredAndCanBeUnregisteredWithoutReregistering() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let settingsOpener = FakeLaunchAtLoginSettingsOpener()
        let controller = LaunchAtLoginController(
            service: service,
            settingsOpener: settingsOpener
        )

        #expect(controller.state == .requiresApproval)
        #expect(controller.isEnabled)
        #expect(controller.canToggle)
        #expect(controller.requiresApproval)

        controller.openSystemSettingsLoginItems()
        #expect(settingsOpener.openCount == 1)

        controller.setEnabled(true)
        #expect(service.registerCount == 0)

        controller.setEnabled(false)
        #expect(service.unregisterCount == 1)
        #expect(controller.state == .disabled)
        controller.openSystemSettingsLoginItems()
        #expect(settingsOpener.openCount == 1)
    }

    @Test
    @MainActor
    func testNotFoundIsUnavailableAndCannotBeToggled() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        #expect(controller.state == .unavailable("Login item is unavailable in this build"))
        #expect(!controller.isEnabled)
        #expect(!controller.canToggle)
        controller.setEnabled(true)
        #expect(service.registerCount == 0)
    }

    @Test
    @MainActor
    func testLaunchOperationErrorDoesNotPermanentlyDisableRetry() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestFailure.expected
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(controller.state == .disabled)
        #expect(controller.canToggle)
        #expect(controller.statusText != nil)
        controller.refresh()
        #expect(controller.statusText == nil)
    }

    @Test
    @MainActor
    func testPresentationTickerIsTolerantAndStopsWithTheMenuLifecycle() {
        var now = fixedNow
        let ticker = UsagePresentationTicker(now: { now })

        #expect(UsagePresentationTicker.cadence == 30)
        #expect(UsagePresentationTicker.tolerance == 5)
        #expect(!ticker.isRunning)
        #expect(ticker.date == fixedNow)

        ticker.start()
        #expect(ticker.isRunning)
        now = fixedNow.addingTimeInterval(31)
        ticker.updateDate()
        #expect(ticker.date == now)

        ticker.stop()
        #expect(!ticker.isRunning)
    }

    @Test
    func testCodexExecutableSelectionValidatesPersistsAndAppliesWithoutLaunching() throws {
        let suiteName = "local.codex-usage-bar.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately not a runnable program. Validation must inspect file type
        // and permissions only; attempting to launch it would fail this test.
        let executable = directory.appendingPathComponent("codex")
        try Data("not an executable format".utf8).write(to: executable)
        #expect(Darwin.chmod(executable.path, 0o700) == 0)

        var appliedEnvironment: [String: String] = [:]
        let storedPath = try UsagePreferences.setCodexExecutable(
            executable,
            preferences: preferences,
            setEnvironment: { appliedEnvironment[$0] = $1 }
        )
        #expect(storedPath == executable.standardizedFileURL.path)
        #expect(preferences.string(forKey: UsagePreferences.codexExecutablePathKey) == storedPath)
        #expect(
            appliedEnvironment[UsagePreferences.codexExecutableEnvironmentKey] == storedPath
        )

        appliedEnvironment.removeAll()
        #expect(UsagePreferences.applyPersistedCodexExecutable(
            preferences: preferences,
            environment: [:],
            setEnvironment: { appliedEnvironment[$0] = $1 }
        ))
        #expect(
            appliedEnvironment[UsagePreferences.codexExecutableEnvironmentKey] == storedPath
        )

        #expect(Darwin.chmod(executable.path, 0o600) == 0)
        appliedEnvironment.removeAll()
        #expect(!UsagePreferences.applyPersistedCodexExecutable(
            preferences: preferences,
            environment: [:],
            setEnvironment: { appliedEnvironment[$0] = $1 }
        ))
        #expect(preferences.string(forKey: UsagePreferences.codexExecutablePathKey) == nil)
        #expect(appliedEnvironment.isEmpty)

        #expect(throws: CodexExecutablePreferenceError.self) {
            try UsagePreferences.setCodexExecutable(
                directory,
                preferences: preferences,
                setEnvironment: { _, _ in }
            )
        }
    }

    @Test
    func testExplicitCodexEnvironmentOverrideWinsOverPersistedSelection() throws {
        let suiteName = "local.codex-usage-bar.tests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let executable = URL(fileURLWithPath: "/bin/sh")
        preferences.set(executable.path, forKey: UsagePreferences.codexExecutablePathKey)
        var appliedEnvironment: [String: String] = [:]

        #expect(!UsagePreferences.applyPersistedCodexExecutable(
            preferences: preferences,
            environment: [UsagePreferences.codexExecutableEnvironmentKey: "/tmp/fake-codex"],
            setEnvironment: { appliedEnvironment[$0] = $1 }
        ))
        #expect(appliedEnvironment.isEmpty)
        #expect(
            preferences.string(forKey: UsagePreferences.codexExecutablePathKey)
                == executable.path
        )
    }

    @Test
    @MainActor
    func testTransientRefreshFailureRetainsAndMarksLastGoodSnapshot() async {
        let original = makeSnapshot(
            fetchedAt: fixedNow,
            dailyBuckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 42)]
        )
        let client = FailingUsageClient()
        let model = UsageViewModel(
            client: client,
            initialSnapshot: original,
            selectedTimeframe: { .seven },
            now: { fixedNow },
            calendar: utcCalendar
        )

        await model.refreshNow()

        #expect(model.snapshot == original)
        #expect(model.state == .failed("expected"))
        #expect(model.isShowingStaleSnapshot)
        #expect(model.statusTitle == "42 !")
        #expect(
            model.statusAccessibilityValue
                == "42 tokens, last 7 days (rolling). Showing last successful usage; refresh failed."
        )
    }

    @Test
    @MainActor
    func testClockRollbackAndNonfiniteAgesForceRefresh() {
        let futureSnapshot = makeSnapshot(
            fetchedAt: fixedNow.addingTimeInterval(60),
            dailyBuckets: []
        )
        let model = UsageViewModel(client: FailingUsageClient(), initialSnapshot: futureSnapshot)

        #expect(model.shouldRefresh(maxAge: 300, now: fixedNow))
        #expect(model.shouldRefresh(maxAge: .nan, now: fixedNow))
        #expect(model.shouldRefresh(
            maxAge: 300,
            now: Date(timeIntervalSinceReferenceDate: .nan)
        ))
        #expect(UsagePopoverView.elapsedText(
            since: futureSnapshot.fetchedAt,
            now: fixedNow
        ) == "clock changed")

        let injectedClockModel = UsageViewModel(
            client: FailingUsageClient(),
            initialSnapshot: makeSnapshot(
                fetchedAt: fixedNow.addingTimeInterval(-301),
                dailyBuckets: []
            ),
            now: { fixedNow }
        )
        #expect(injectedClockModel.shouldRefresh(maxAge: 300))
    }

    @Test
    @MainActor
    func testAllTimeSelectionPrefersSummaryWhenDailyDataIsAbsent() {
        let snapshot = makeSnapshot(
            dailyBuckets: nil,
            lifetimeTokens: 9_000,
            peakDailyTokens: 800
        )

        let selection = UsageDisplaySelection(
            snapshot: snapshot,
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(!selection.hasDailyData)
        #expect(!selection.isDailyHistoryPartial)
        #expect(selection.totalTokens == 9_000)
        #expect(selection.peakDailyTokens == 800)
        #expect(selection.averageDailyTokens == nil)
        #expect(selection.activeDays == nil)
    }

    @Test
    @MainActor
    func testAllTimeSummaryCannotUnderstateDisplayedDailyData() {
        let selection = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: [
                    DailyUsageBucket(startDate: "2026-07-12", tokens: 100),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: 200)
                ],
                lifetimeTokens: 10,
                peakDailyTokens: 5
            ),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(selection.totalTokens == 300)
        #expect(selection.peakDailyTokens == 200)
        #expect(!selection.isDailyHistoryPartial)
    }

    @Test
    @MainActor
    func testAllTimePartialHistoryWithoutCredibleLifetimeHidesExactTotal() {
        let selection = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: [
                    DailyUsageBucket(startDate: "2026-07-12", tokens: 100),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: 200)
                ],
                lifetimeTokens: nil,
                peakDailyTokens: 800
            ),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(selection.isDailyHistoryPartial)
        #expect(selection.hasUnreconciledAllTimeTotal)
        #expect(selection.totalTokens == nil)
        #expect(selection.peakDailyTokens == 800)
        #expect(selection.averageDailyTokens == nil)
        #expect(selection.activeDays == nil)
    }

    @Test
    @MainActor
    func testAllTimeContradictorySummaryNeverDisplaysTotalBelowPeak() {
        let selection = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: nil,
                lifetimeTokens: 100,
                peakDailyTokens: 800
            ),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(!selection.hasDailyData)
        #expect(selection.hasUnreconciledAllTimeTotal)
        #expect(selection.totalTokens == nil)
        #expect(selection.peakDailyTokens == 800)
    }

    @Test
    @MainActor
    func testOverflowedAggregatesAreNeverPresentedAsExactMetrics() {
        let snapshot = makeSnapshot(
            dailyBuckets: [
                DailyUsageBucket(startDate: "2026-07-12", tokens: .max),
                DailyUsageBucket(startDate: "2026-07-13", tokens: .max)
            ],
            lifetimeTokens: .max,
            peakDailyTokens: .max
        )

        for timeframe in [UsageTimeframe.seven, .all] {
            let selection = UsageDisplaySelection(
                snapshot: snapshot,
                timeframe: timeframe,
                now: fixedNow,
                calendar: utcCalendar
            )
            #expect(selection.range.didOverflow)
            #expect(selection.hasUnrepresentableTotal)
            #expect(!selection.hasSaturatedDailyValues)
            #expect(selection.totalTokens == nil)
            #expect(selection.averageDailyTokens == nil)
            #expect(selection.peakDailyTokens == .max)
            #expect(selection.activeDays == 2)
        }

        let model = UsageViewModel(
            client: FailingUsageClient(),
            initialSnapshot: snapshot,
            selectedTimeframe: { .all },
            now: { fixedNow },
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(model.statusTitle == "n/a")
        #expect(
            model.statusAccessibilityValue
                == "Token total unavailable, all time. Daily total exceeds the supported range."
        )

        let mergedOverflow = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: [
                    DailyUsageBucket(startDate: "2026-07-13", tokens: .max),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: 1)
                ]
            ),
            timeframe: .seven,
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(mergedOverflow.hasUnrepresentableTotal)
        #expect(mergedOverflow.hasSaturatedDailyValues)
        #expect(mergedOverflow.peakDailyTokens == nil)

        let overflowingPartialHistory = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: [
                    DailyUsageBucket(startDate: "2026-07-12", tokens: (.max / 2) + 1),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: (.max / 2) + 1)
                ],
                lifetimeTokens: .max,
                peakDailyTokens: .max
            ),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(overflowingPartialHistory.hasUnrepresentableTotal)
        #expect(!overflowingPartialHistory.hasSaturatedDailyValues)
        #expect(overflowingPartialHistory.isDailyHistoryPartial)
        #expect(overflowingPartialHistory.peakDailyTokens == .max)
        #expect(overflowingPartialHistory.activeDays == nil)
    }

    @Test
    @MainActor
    func testAllTimePartialDailyHistoryDoesNotClaimLifetimeAverageOrActiveDays() {
        let selection = UsageDisplaySelection(
            snapshot: makeSnapshot(
                dailyBuckets: [
                    DailyUsageBucket(startDate: "2026-07-12", tokens: 100),
                    DailyUsageBucket(startDate: "2026-07-13", tokens: 200)
                ],
                lifetimeTokens: 9_000,
                peakDailyTokens: 800
            ),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(selection.isDailyHistoryPartial)
        #expect(selection.totalTokens == 9_000)
        #expect(selection.peakDailyTokens == 800)
        #expect(selection.averageDailyTokens == nil)
        #expect(selection.activeDays == nil)
    }

    @Test
    @MainActor
    func testMissingDailyDataIsDifferentFromPresentZeroUsage() {
        let missing = UsageDisplaySelection(
            snapshot: makeSnapshot(dailyBuckets: nil),
            timeframe: .seven,
            now: fixedNow,
            calendar: utcCalendar
        )
        let zero = UsageDisplaySelection(
            snapshot: makeSnapshot(dailyBuckets: []),
            timeframe: .seven,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(missing.totalTokens == nil)
        #expect(missing.activeDays == nil)
        #expect(!missing.hasDailyData)
        #expect(zero.totalTokens == 0)
        #expect(zero.averageDailyTokens == 0)
        #expect(zero.peakDailyTokens == 0)
        #expect(zero.activeDays == 0)
        #expect(zero.hasDailyData)

        let allTimeZero = UsageDisplaySelection(
            snapshot: makeSnapshot(dailyBuckets: [], lifetimeTokens: 0, peakDailyTokens: 0),
            timeframe: .all,
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(allTimeZero.hasDailyData)
        #expect(allTimeZero.totalTokens == 0)
        #expect(allTimeZero.activeDays == 0)
        #expect(allTimeZero.range.chartBuckets.isEmpty)
    }

    @Test
    func testEveryHistoryLengthPaginatesAndClampsPersistedPage() {
        let firstPage = DailyHistoryPagination(rowCount: 7, requestedPage: 0)
        #expect(firstPage.page == 0)
        #expect(firstPage.pageCount == 2)
        #expect(firstPage.rowRange == 0..<6)
        let secondPage = DailyHistoryPagination(rowCount: 7, requestedPage: 1)
        #expect(secondPage.page == 1)
        #expect(secondPage.pageCount == 2)
        #expect(secondPage.rowRange == 6..<7)

        let formerlyOldest = DailyHistoryPagination(rowCount: 13, requestedPage: 2)
        #expect(formerlyOldest.page == 2)
        let afterShrink = DailyHistoryPagination(rowCount: 2, requestedPage: formerlyOldest.page)
        #expect(afterShrink.page == 0)
        let afterGrowth = DailyHistoryPagination(rowCount: 13, requestedPage: afterShrink.page)
        #expect(afterGrowth.page == 0, "a shrunken list must not rebound to a stale page")

        let extreme = DailyHistoryPagination(rowCount: Int.max, requestedPage: Int.max)
        #expect(extreme.rowRange.upperBound == Int.max)
        #expect(extreme.page == extreme.pageCount - 1)
    }

    @Test
    func testRelativeClockAndRateFormattingAreDeterministicAndBounded() {
        #expect(
            UsagePopoverView.elapsedText(
                since: Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 1_065)
            ) == "1m ago"
        )
        #expect(RateLimitPresentation.windowDuration(minutes: 90) == "1h 30m")
        #expect(
            RateLimitPresentation.windowDuration(minutes: Int.max) == "6405119470038038d 18h"
        )
        #expect(RateLimitPresentation.windowDuration(minutes: -1) == "n/a")
        #expect(RateLimitPresentation.percent(.infinity) == "n/a")
        #expect(RateLimitPresentation.percent(-1) == "n/a")
        #expect(RateLimitPresentation.validPercent(nil) == nil)
        #expect(RateLimitPresentation.validPercent(.nan) == nil)
        #expect(RateLimitPresentation.validPercent(-1) == nil)
        #expect(RateLimitPresentation.validPercent(0) == 0)
        #expect(
            RateLimitPresentation.relativeReset(
                timestamp: -1,
                now: fixedNow,
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "n/a"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: nil,
                now: fixedNow,
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "reset unavailable"
        )
        let dstStart = Date(timeIntervalSince1970: 1_772_956_800)
        let dstTarget = dstStart.addingTimeInterval(23 * 60 * 60)
        let utc = utcCalendar
        var losAngeles = utcCalendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(
            RateLimitPresentation.relativeReset(
                timestamp: dstTarget.timeIntervalSince1970,
                now: dstStart,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "in 23h"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: dstTarget.timeIntervalSince1970,
                now: dstStart,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "resets in 23h"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: fixedNow.timeIntervalSince1970 - 3_600,
                now: fixedNow,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "reset 1h ago"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: fixedNow.timeIntervalSince1970,
                now: fixedNow,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "resets now"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: fixedNow.timeIntervalSince1970 - 0.5,
                now: fixedNow,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "resets now"
        )
        #expect(
            RateLimitPresentation.resetDescription(
                timestamp: fixedNow.timeIntervalSince1970 + 0.5,
                now: fixedNow,
                calendar: utc,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "resets now"
        )
        #expect(
            RateLimitPresentation.relativeReset(
                timestamp: dstTarget.timeIntervalSince1970,
                now: dstStart,
                calendar: losAngeles,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "in 1d"
        )
        #expect(
            RateLimitPresentation.relativeReset(
                timestamp: fixedNow.timeIntervalSince1970 + 60,
                now: Date(timeIntervalSinceReferenceDate: .nan),
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "n/a"
        )
    }

    @Test
    func testExtremeAxisLabelStaysWithinChartGutterBudget() {
        let label = UsageChartAxisLabel.text(Int64.max)
        #expect(label == "9.2e18")
        #expect(label.count <= 7)
    }

    @Test
    @MainActor
    func testZeroActivityChartHasConsistentAccessibilityValue() {
        let zero = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 0)],
            maxTokens: 0,
            timeframe: .seven,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let empty = UsageLineChart(
            buckets: [],
            maxTokens: 0,
            timeframe: .seven,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(zero.accessibilityValue == "No activity")
        #expect(empty.accessibilityValue == "No activity")
        let selectedZero = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 0)],
            maxTokens: 0,
            timeframe: .seven,
            selectedIndex: 0,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(selectedZero.accessibilityValue == "Jul 13, 2026, 0 tokens")

        let inconsistentScale = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 1)],
            maxTokens: -1,
            timeframe: .seven,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(inconsistentScale.accessibilityValue == "No point selected")

        let negativeUsage = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "bad\u{0001}", tokens: -1)],
            maxTokens: 10,
            timeframe: .seven,
            selectedIndex: 0,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(negativeUsage.accessibilityValue == "Invalid date, 0 tokens")

        let invalidDate = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "bad\u{0001}", tokens: 1)],
            maxTokens: 1,
            timeframe: .seven,
            selectedIndex: 0,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(invalidDate.accessibilityValue == "Invalid date, 1 tokens")

        let historicalDate = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "1582-10-10", tokens: 1)],
            maxTokens: 1,
            timeframe: .all,
            selectedIndex: 0,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(historicalDate.accessibilityValue == "1582-10-10, 1 tokens")

        var buddhistCalendar = Calendar(identifier: .buddhist)
        buddhistCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        buddhistCalendar.locale = Locale(identifier: "en_US_POSIX")
        let localizedCalendarDate = UsageLineChart(
            buckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 1)],
            maxTokens: 1,
            timeframe: .all,
            selectedIndex: 0,
            calendar: buddhistCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(localizedCalendarDate.accessibilityValue.contains("2569"))
        #expect(UsageLineChart.validPositions([0, 0.6, 1], count: 3))
        #expect(!UsageLineChart.validPositions([0.4, 0.6], count: 2))
        #expect(
            UsageLineChart.nonoverlappingTickIndices(
                positions: [0, 0.000_000_274, 0.000_000_548, 0.999_999_7, 1],
                maximumTickCount: 3,
                plotWidth: 204,
                labelWidth: 56
            ) == [0, 4]
        )
        let regularMonthPositions = (0..<30).map { Double($0) / 29 }
        #expect(
            UsageLineChart.nonoverlappingTickIndices(
                positions: regularMonthPositions,
                maximumTickCount: 4,
                plotWidth: 218,
                labelWidth: 32
            ) == [0, 10, 19, 29]
        )
    }

    @Test
    func testRateLimitDecodingIssuesArePresentedAsPartialData() {
        let response = AccountRateLimitsResponse(
            rateLimits: nil,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil,
            decodingIssues: ["rateLimits.primary"]
        )
        #expect(RateLimitPresentation.hasDataQualityIssues(response))
        #expect(!RateLimitPresentation.hasDataQualityIssues(nil))
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(hasCredits: true, unlimited: true, balance: nil)
            ) == "Unlimited"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(remaining: 12, total: 20, used: 8)
            ) == "12 / 20 remaining"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(remaining: 0.001, total: nil, used: nil)
            ) == "0.001 remaining"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(remaining: nil, total: 20, used: 8)
            ) == "8 / 20 used"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(remaining: nil, total: nil, used: 8)
            ) == "8 used"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(remaining: 30, total: 20, used: 8)
            ) == "8 / 20 used"
        )
        #expect(
            RateLimitPresentation.credits(
                CreditsSnapshot(
                    remaining: nil,
                    total: nil,
                    used: nil,
                    hasCredits: true,
                    unlimited: false,
                    balance: "\u{0001}"
                )
            ) == "Available"
        )
        #expect(RateLimitPresentation.amount(" 12.50\u{0001} ") == "12.50")
        let bounded = RateLimitPresentation.amount(String(repeating: "x", count: 100))
        #expect(bounded.unicodeScalars.count == 64)
        #expect(bounded.hasSuffix("..."))
        let combining = RateLimitPresentation.text(String(repeating: "\u{0301}", count: 10_000))
        #expect(combining.unicodeScalars.count == 64)
        #expect(combining.hasSuffix("..."))
        #expect(RateLimitPresentation.text("team\u{0001}") == "team")
        #expect(RateLimitPresentation.text("team\u{2028}pro\u{2029}plan") == "team pro plan")
        #expect(RateLimitPresentation.limitReachedStatus(nil) == nil)
        #expect(RateLimitPresentation.limitReachedStatus("weekly\u{0001}\nlimit") == "weekly limit")
        #expect(RateLimitPresentation.limitReachedStatus("\u{0001}") == "Reported")
    }

    @Test
    @MainActor
    func testChartConstructionAcceptsExtremeUntrustedSelections() {
        let buckets = [DailyUsageBucket(startDate: "2026-07-13", tokens: 1)]
        _ = UsageLineChart(
            buckets: buckets,
            maxTokens: 1,
            timeframe: .seven,
            selectedIndex: .min
        )
        _ = UsageLineChart(
            buckets: buckets,
            maxTokens: 1,
            timeframe: .seven,
            selectedIndex: .max
        )
        #expect(UsageLineChart.renderSampleBudget(plotWidth: 225) == 900)
        #expect(UsageLineChart.renderSampleBudget(plotWidth: .infinity) == 4_096)
        #expect(UsageLineChart.renderSampleBudget(plotWidth: .nan) == 4_096)
    }

    @Test
    @MainActor
    func testStatusItemAccessibilityDescribesUnitsAndState() {
        let loadedSnapshot = makeSnapshot(
            dailyBuckets: [DailyUsageBucket(startDate: "2026-07-13", tokens: 42)]
        )
        #expect(
            UsageViewModel.accessibilityStatus(
                snapshot: loadedSnapshot,
                state: .loaded,
                selectedTimeframe: .seven,
                now: fixedNow,
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "42 tokens, last 7 days (rolling)"
        )
        #expect(
            UsageViewModel.accessibilityStatus(
                snapshot: nil,
                state: .loading,
                selectedTimeframe: .seven,
                now: fixedNow,
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "Loading Codex usage"
        )
        #expect(
            UsageViewModel.accessibilityStatus(
                snapshot: nil,
                state: .failed("expected"),
                selectedTimeframe: .seven,
                now: fixedNow,
                calendar: utcCalendar,
                locale: Locale(identifier: "en_US_POSIX")
            ) == "Codex usage unavailable"
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try! #require(item.button)
        AppDelegate.configureStatusButtonAccessibility(button, value: "42 tokens")
        #expect(button.accessibilityLabel() == "Codex usage")
        #expect(button.accessibilityValue() as? String == "42 tokens")
        #expect(button.accessibilityHelp() == "Open the Codex usage menu")
    }

    @Test
    @MainActor
    func testHostedChartSynchronizesParentSelectionChanges() throws {
        let model = HostedChartSelectionModel(index: 0)
        let buckets = (1...7).map {
            DailyUsageBucket(startDate: "2026-07-0\($0)", tokens: Int64($0 * 100))
        }
        let root = HostedChartSelectionProbe(model: model, buckets: buckets)
            .frame(width: 300, height: 186)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 186)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let before = try hostedPNG(of: hostingView)

        model.index = 6
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        let after = try hostedPNG(of: hostingView)

        #expect(before != after, "Changing selectedIndex must move the hosted marker and tooltip")
    }

    @Test
    func testUserFacingErrorsAreScalarBoundedSanitizedAndEllipsized() {
        let hostileMessage = "visible\u{0001}\u{2028}\u{2029}" + String(repeating: "\u{0301}", count: 400)
        let error = DescribedFailure(description: hostileMessage)
        let cleaned = UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 240)

        #expect(cleaned.unicodeScalars.count == 240)
        #expect(cleaned.hasSuffix("..."))
        #expect(cleaned.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.illegalCharacters.contains($0)
                && !CharacterSet.newlines.contains($0)
        })
        #expect(
            UserFacingErrorMessage.clean(
                DescribedFailure(description: "left\u{2028}\u{2029}right"),
                maximumUnicodeScalars: 240
            ) == "left right"
        )
        #expect(
            UserFacingErrorMessage.clean(
                DescribedFailure(description: "\u{2028}\u{2029}"),
                maximumUnicodeScalars: 240
            ) == "Unknown error"
        )
        #expect(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: -1).isEmpty)
        #expect(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 0).isEmpty)
        #expect(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 1) == ".")
        #expect(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 2) == "..")
        #expect(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 3) == "...")

        let exactlyAtLimit = String(repeating: "x", count: 64)
        for ignorableSuffix in [" ", "\u{2028}", "\u{0001}", " \u{2028}\u{0001}"] {
            #expect(
                BoundedDisplayText.clean(
                    exactlyAtLimit + ignorableSuffix,
                    maximumUnicodeScalars: 64,
                    emptyFallback: "n/a"
                ) == exactlyAtLimit
            )
        }

        let whitespaceFlood = DescribedFailure(
            description: String(repeating: "\u{2028}", count: 100_000)
        )
        #expect(
            UserFacingErrorMessage.clean(whitespaceFlood, maximumUnicodeScalars: 240)
                == "Unknown error"
        )
        let trailingFlood = "visible " + String(repeating: "\u{2029}", count: 100_000)
        let boundedTrailingFlood = BoundedDisplayText.clean(
            trailingFlood,
            maximumUnicodeScalars: 64,
            emptyFallback: "n/a"
        )
        #expect(boundedTrailingFlood.unicodeScalars.count <= 64)
        #expect(boundedTrailingFlood.hasSuffix("..."))
    }
}

private enum TestFailure: Error {
    case expected
}

private struct DescribedFailure: Error, CustomStringConvertible {
    let description: String
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private final class FakeLaunchAtLoginSettingsOpener: LaunchAtLoginSettingsOpening {
    private(set) var openCount = 0

    func openSystemSettingsLoginItems() {
        openCount += 1
    }
}

private struct FailingUsageClient: UsageFetching {
    func fetchUsageSnapshot() async throws -> UsageSnapshot {
        throw TestFailure.expected
    }
}

@MainActor
private final class HostedChartSelectionModel: ObservableObject {
    @Published var index: Int

    init(index: Int) {
        self.index = index
    }
}

private struct HostedChartSelectionProbe: View {
    @ObservedObject var model: HostedChartSelectionModel
    let buckets: [DailyUsageBucket]

    var body: some View {
        UsageLineChart(
            buckets: buckets,
            maxTokens: buckets.map(\.tokens).max() ?? 0,
            timeframe: .seven,
            selectedIndex: model.index,
            calendar: utcCalendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
private func hostedPNG(of view: NSView) throws -> Data {
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw DescribedFailure(description: "Could not allocate hosted test bitmap")
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw DescribedFailure(description: "Could not encode hosted test bitmap")
    }
    return data
}

private let fixedNow = Date(timeIntervalSince1970: 1_784_020_800)

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func makeSnapshot(
    fetchedAt: Date = fixedNow,
    dailyBuckets: [DailyUsageBucket]?,
    lifetimeTokens: Int64? = nil,
    peakDailyTokens: Int64? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        fetchedAt: fetchedAt,
        usage: AccountTokenUsageResponse(
            summary: UsageSummary(
                lifetimeTokens: lifetimeTokens,
                peakDailyTokens: peakDailyTokens,
                longestRunningTurnSec: nil,
                currentStreakDays: nil,
                longestStreakDays: nil
            ),
            dailyUsageBuckets: dailyBuckets
        ),
        rateLimits: nil
    )
}
