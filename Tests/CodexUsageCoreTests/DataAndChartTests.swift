import Dispatch
import Foundation
import Testing
@testable import CodexUsageCore

@Suite
struct DataAndChartTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(_ value: String) throws -> Date {
        try #require(UsageWindows.date(from: value, timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    @Test
    func testCanonicalCivilDatesAreExactAndLeapAware() throws {
        for valid in [
            "0001-01-01", "1582-10-10", "2000-02-29", "2024-02-29", "9999-12-31"
        ] {
            #expect(UsageWindows.isCanonicalBucketStartDate(valid), "\(valid)")
            let date = try #require(
                UsageWindows.date(from: valid, timeZone: TimeZone(secondsFromGMT: 0)!),
                "\(valid)"
            )
            #expect(
                UsageWindows.bucketStartString(
                    for: date,
                    timeZone: TimeZone(secondsFromGMT: 0)!
                ) == valid,
                "\(valid)"
            )
        }
        for invalid in [
            "0000-01-01", "10000-01-01", "1900-02-29", "2026-02-30",
            "2026-13-01", "2026-00-01", "2026-01-00", "2026-1-01",
            "2026-01-1", "２０２６-01-01", "2026/01/01", "2026-01-01x"
        ] {
            #expect(!UsageWindows.isCanonicalBucketStartDate(invalid), "\(invalid)")
            #expect(UsageWindows.date(from: invalid) == nil, "\(invalid)")
        }

        let hostileLongDate = "2026-01-01" + String(repeating: "x", count: 1_000_000)
        #expect(!UsageWindows.isCanonicalBucketStartDate(hostileLongDate))
        #expect(UsageWindows.date(from: hostileLongDate) == nil)
        #expect(
            UsageWindows.mergedDailyBucketsReportingOverflow([
                DailyUsageBucket(startDate: hostileLongDate, tokens: 1)
            ]).rejectedBucketCount == 1
        )

        let apia = try #require(TimeZone(identifier: "Pacific/Apia"))
        #expect(UsageWindows.date(from: "2011-12-30", timeZone: apia) == nil)
    }

    @Test
    func testNonfiniteDatesAreRejectedAtPublicWindowBoundaries() {
        let source = [DailyUsageBucket(startDate: "2026-01-01", tokens: 10)]
        for invalidNow in [
            Date(timeIntervalSinceReferenceDate: .nan),
            Date(timeIntervalSinceReferenceDate: .infinity),
            Date(timeIntervalSinceReferenceDate: -.infinity)
        ] {
            #expect(UsageWindows.bucketStartString(for: invalidNow).isEmpty)
            #expect(
                UsageWindows.bucketsInRollingWindow(
                    buckets: source,
                    now: invalidNow,
                    calendar: utcCalendar
                ).isEmpty
            )
            #expect(
                UsageWindows.filledDailySeries(
                    buckets: source,
                    now: invalidNow,
                    calendar: utcCalendar
                ).isEmpty
            )
            #expect(
                UsageWindows.sparseDailyChartSeries(
                    buckets: source,
                    through: invalidNow,
                    calendar: utcCalendar
                ).isEmpty
            )
            let range = UsageRange(
                timeframe: .all,
                sourceBuckets: source,
                now: invalidNow,
                calendar: utcCalendar
            )
            #expect(range.buckets.isEmpty)
            #expect(range.chartBuckets.isEmpty)
            #expect(range.calendarDayCount == 0)
            #expect(range.totalTokens == 0)
        }
    }

    @Test
    func testDecodedBucketsRejectInvalidDatesAndNegativeUsage() throws {
        for bucketJSON in [
            #"{"startDate":"2026-02-30","tokens":1}"#,
            #"{"startDate":"2026-2-03","tokens":1}"#,
            #"{"startDate":"2026-02-03","tokens":-1}"#,
            #"{"startDate":"2026-02-03","tokens":9007199254740992.1}"#
        ] {
            #expect(throws: (any Error).self, "\(bucketJSON)") {
                try JSONDecoder().decode(DailyUsageBucket.self, from: Data(bucketJSON.utf8))
            }
        }

        let exactLargeInteger = try JSONDecoder().decode(
            DailyUsageBucket.self,
            from: Data(#"{"startDate":"2026-02-03","tokens":9007199254740992}"#.utf8)
        )
        #expect(exactLargeInteger.tokens == 9_007_199_254_740_992)
    }

    @Test
    func testUsageAnyDecodingRejectsFloatingCountsAndCyclicGraphs() throws {
        let fractionalJSON = #"""
        {
          "summary":{"lifetimeTokens":1},
          "dailyUsageBuckets":[{"startDate":"2026-02-03","tokens":9007199254740992.1}]
        }
        """#
        let fractional = try JSONSerialization.jsonObject(with: Data(fractionalJSON.utf8))
        #expect(throws: (any Error).self) {
            try UsageDecoding.decodeUsageResult(from: fractional)
        }

        let cyclic = NSMutableDictionary()
        cyclic["self"] = cyclic
        #expect(throws: (any Error).self) {
            try UsageDecoding.decode([String: String].self, from: cyclic)
        }

        let invalidScalars: [Any] = [
            Date(), Data([0x01]), Set([1]), Double.nan, Double.infinity
        ]
        for invalid in invalidScalars {
            #expect(throws: (any Error).self) {
                try UsageDecoding.decode(String.self, from: invalid)
            }
        }
    }

    @Test
    func testStrictUsageDataDecodingRejectsFractionsBeyondDecimalPrecision() throws {
        let fractionalPayloads = [
            #"{"summary":{"lifetimeTokens":1.000000000000000000000000000000000000001}}"#,
            #"{"summary":{"lifetimeTokens":1},"dailyUsageBuckets":[{"startDate":"2026-01-01","tokens":1.000000000000000000000000000000000000001}]}"#
        ]
        for payload in fractionalPayloads {
            #expect(throws: (any Error).self, "\(payload)") {
                try UsageDecoding.decodeUsageData(Data(payload.utf8))
            }
        }

        let exact = try UsageDecoding.decodeUsageData(
            Data(
                #"{"summary":{"lifetimeTokens":9223372036854775807},"dailyUsageBuckets":[{"startDate":"2026-01-01","tokens":1}]}"#.utf8
            )
        )
        #expect(exact.summary.lifetimeTokens == Int64.max)
        #expect(exact.dailyUsageBuckets?.first?.tokens == 1)

        let rateLimits = try UsageDecoding.decodeRateLimitsData(Data(#"{}"#.utf8))
        #expect(rateLimits.rateLimits == nil)
        #expect(rateLimits.rateLimitsByLimitId == nil)
        #expect(rateLimits.rateLimitResetCredits == nil)
        #expect(rateLimits.decodingIssues.isEmpty)
    }

    @Test
    func testRateAnyDecodingCannotRoundFractionalIntegerFields() throws {
        let json = #"""
        {
          "rateLimits": {
            "primary": {
              "usedPercent": 12,
              "windowDurationMins": 9007199254740992.1
            },
            "secondary": {"usedPercent": 34, "windowDurationMins": 300},
            "individualLimit": {
              "limit": "100",
              "remainingPercent": 63.000000000000000001
            }
          },
          "rateLimitResetCredits": {"availableCount": 9007199254740992.1}
        }
        """#
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let decoded = try UsageDecoding.decodeRateLimitsResult(from: object)
        let limit = try #require(decoded.rateLimits)
        #expect(limit.primary == nil)
        #expect(limit.secondary?.windowDurationMins == 300)
        #expect(limit.individualLimit?.remainingPercent == nil)
        #expect(limit.individualLimit?.usedPercent == nil)
        #expect(decoded.rateLimitResetCredits == nil)

        let direct = try JSONDecoder().decode(
            SpendControlLimitSnapshot.self,
            from: Data(#"{"remainingPercent":63.000000000000000001}"#.utf8)
        )
        #expect(direct.remainingPercent == nil)
        #expect(direct.usedPercent == nil)
        #expect(!direct.decodingIssues.isEmpty)
    }

    @Test
    func testDecodedSummaryCountsAndDurationsRejectNegatives() {
        let fields = [
            "lifetimeTokens", "peakDailyTokens", "longestRunningTurnSec",
            "currentStreakDays", "longestStreakDays"
        ]
        for field in fields {
            let json = "{\"\(field)\":-1}"
            #expect(throws: (any Error).self, "\(field)") {
                try JSONDecoder().decode(UsageSummary.self, from: Data(json.utf8))
            }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RateLimitResetCreditsSummary.self,
                from: Data(#"{"availableCount":-1}"#.utf8)
            )
        }
    }

    @Test
    func testRateLimitDecodingPreservesValidSiblingsAndReportsBadFields() throws {
        let json = #"""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 10, "windowDurationMins": -1, "resetsAt": 1700000000 },
            "secondary": { "usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1800000000 },
            "credits": { "remaining": -2, "total": 10, "used": 3 },
            "planType": "team"
          },
          "rateLimitsByLimitId": {
            "bad": "not-an-object",
            "codex": { "limitId": "codex", "primary": { "usedPercent": 42 } }
          },
          "rateLimitResetCredits": { "availableCount": -1 }
        }
        """#
        let decoded = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: Data(json.utf8))

        #expect(decoded.rateLimits?.primary == nil)
        #expect(decoded.rateLimits?.secondary?.windowDurationMins == 10_080)
        #expect(decoded.rateLimits?.credits?.remaining == nil)
        #expect(decoded.rateLimits?.credits?.total == 10)
        #expect(decoded.rateLimits?.credits?.used == 3)
        #expect(decoded.rateLimits?.planType == "team")
        #expect(decoded.rateLimitsByLimitId?["bad"] == nil)
        #expect(decoded.rateLimitsByLimitId?["codex"]?.primary?.usedPercent == 42)
        #expect(decoded.rateLimitResetCredits == nil)
        #expect(!decoded.decodingIssues.isEmpty)
    }

    @Test
    func testMalformedRateLimitMapIssuesHaveStableKeyOrder() throws {
        let json = #"""
        {
          "rateLimitsByLimitId": {
            "zeta": "not-an-object",
            "alpha": false,
            "middle": 42
          }
        }
        """#
        let decoded = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: Data(json.utf8))
        let paths = decoded.decodingIssues.map { issue in
            String(issue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
        }
        #expect(paths == [
            "rateLimitsByLimitId.alpha",
            "rateLimitsByLimitId.middle",
            "rateLimitsByLimitId.zeta"
        ])
    }

    @Test
    func testCurrentRateLimitCreditAndSpendControlShapesDecode() throws {
        let json = #"""
        {
          "rateLimits": {
            "limitId": "codex",
            "credits": {
              "hasCredits": true,
              "unlimited": false,
              "balance": "12.50"
            },
            "individualLimit": {
              "limit": "100.00",
              "used": "37.00",
              "remainingPercent": 63,
              "resetsAt": 1800000000
            },
            "rateLimitReachedType": "weekly"
          }
        }
        """#
        let decoded = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: Data(json.utf8))
        let limit = try #require(decoded.preferredCodexLimit)

        #expect(limit.credits?.hasCredits == true)
        #expect(limit.credits?.unlimited == false)
        #expect(limit.credits?.balance == "12.50")
        #expect(limit.individualLimit?.limit == "100.00")
        #expect(limit.individualLimit?.used == "37.00")
        #expect(limit.individualLimit?.remainingPercent == 63)
        #expect(limit.individualLimit?.usedPercent == 37)
        #expect(limit.individualLimit?.resetsAt == 1_800_000_000)
        #expect(limit.rateLimitReachedType == "weekly")
        #expect(decoded.decodingIssues.isEmpty)
    }

    @Test
    func testResetTimestampIsAlwaysProtocolSeconds() {
        let seconds = 13_000_000_000.0
        let window = RateLimitWindow(usedPercent: 1, windowDurationMins: nil, resetsAt: seconds)
        #expect(window.resetDate?.timeIntervalSince1970 == seconds)
    }

    @Test
    func testUsageDecodingDoesNotShareMutableDecoderState() {
        let first = UsageDecoding.decoder
        first.keyDecodingStrategy = .convertFromSnakeCase
        let second = UsageDecoding.decoder
        #expect(first !== second)
        if case .useDefaultKeys = second.keyDecodingStrategy {
            // Expected independent default state.
        } else {
            Issue.record("A new decoder inherited mutable state from an earlier caller")
        }
    }

    @Test
    func testMergeAndTotalsRejectMalformedConstructionAndSaturateOverflow() throws {
        let buckets = [
            DailyUsageBucket(startDate: "2026-01-01", tokens: .max),
            DailyUsageBucket(startDate: "2026-01-01", tokens: 1),
            DailyUsageBucket(startDate: "not-a-date", tokens: 10),
            DailyUsageBucket(startDate: "2026-01-02", tokens: -1)
        ]
        let merged = UsageWindows.mergedDailyBucketsReportingOverflow(buckets)
        #expect(merged.buckets == [DailyUsageBucket(startDate: "2026-01-01", tokens: .max)])
        #expect(merged.didOverflow)
        #expect(merged.rejectedBucketCount == 2)

        let now = try utcDate("2026-01-02")
        let total = UsageWindows.rollingTotalReportingOverflow(
            buckets: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: .max),
                DailyUsageBucket(startDate: "2026-01-02", tokens: 1)
            ],
            days: 2,
            now: now,
            calendar: utcCalendar
        )
        #expect(total.value == .max)
        #expect(total.didOverflow)

        let totalOnlyOverflow = UsageRange(
            timeframe: .all,
            sourceBuckets: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: .max),
                DailyUsageBucket(startDate: "2026-01-02", tokens: 1)
            ],
            now: now,
            calendar: utcCalendar
        )
        #expect(totalOnlyOverflow.didOverflow)
        #expect(!totalOnlyOverflow.mergeDidOverflow)
        #expect(totalOnlyOverflow.totalDidOverflow)

        let mergeOverflow = UsageRange(
            timeframe: .all,
            sourceBuckets: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: .max),
                DailyUsageBucket(startDate: "2026-01-01", tokens: 1)
            ],
            now: now,
            calendar: utcCalendar
        )
        #expect(mergeOverflow.didOverflow)
        #expect(mergeOverflow.mergeDidOverflow)
        #expect(!mergeOverflow.totalDidOverflow)

        let oldOverflow = [
            DailyUsageBucket(startDate: "2020-01-01", tokens: .max),
            DailyUsageBucket(startDate: "2020-01-01", tokens: 1),
            DailyUsageBucket(startDate: "2026-01-02", tokens: 100)
        ]
        let currentRange = UsageRange(
            timeframe: .seven,
            sourceBuckets: oldOverflow,
            now: now,
            calendar: utcCalendar
        )
        #expect(currentRange.totalTokens == 100)
        #expect(!currentRange.didOverflow)
        #expect(!currentRange.mergeDidOverflow)
        #expect(!currentRange.totalDidOverflow)
        let allRange = UsageRange(
            timeframe: .all,
            sourceBuckets: oldOverflow,
            now: now,
            calendar: utcCalendar
        )
        #expect(allRange.didOverflow)
        #expect(allRange.mergeDidOverflow)
        #expect(UsageWindows.filledDailySeries(buckets: [], days: .max) == [])
    }

    @Test
    func testAllTimeRangeUsesSourceTotalsButSparseCalendarGeometry() throws {
        let range = UsageRange(
            timeframe: .all,
            sourceBuckets: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: 100),
                DailyUsageBucket(startDate: "2026-01-04", tokens: 40)
            ],
            now: try utcDate("2026-01-06"),
            calendar: utcCalendar
        )
        #expect(range.buckets.map(\.startDate) == ["2026-01-01", "2026-01-04"])
        #expect(range.historyBuckets.map(\.startDate) == ["2026-01-01", "2026-01-04"])
        #expect(
            range.chartBuckets == [
                DailyUsageBucket(startDate: "2026-01-01", tokens: 100),
                DailyUsageBucket(startDate: "2026-01-02", tokens: 0),
                DailyUsageBucket(startDate: "2026-01-03", tokens: 0),
                DailyUsageBucket(startDate: "2026-01-04", tokens: 40),
                DailyUsageBucket(startDate: "2026-01-05", tokens: 0),
                DailyUsageBucket(startDate: "2026-01-06", tokens: 0)
            ]
        )
        #expect(range.chartPositions == [0, 0.2, 0.4, 0.6, 0.8, 1])
        #expect(range.totalTokens == 140)
        #expect(range.peakDailyTokens == 100)
        #expect(range.activeDays == 2)
        #expect(range.calendarDayCount == 6)
        #expect(range.averageDailyTokens == 23)
    }

    @Test
    func testSparseGeometryDoesNotExpandAcrossAttackerControlledYearSpan() throws {
        let series = UsageWindows.sparseDailyChartSeries(
            buckets: [
                DailyUsageBucket(startDate: "0001-01-01", tokens: 1),
                DailyUsageBucket(startDate: "9999-12-31", tokens: 2)
            ],
            through: try utcDate("2026-01-01"),
            calendar: utcCalendar
        )
        #expect(series.count == 4)
        #expect(series.first?.startDate == "0001-01-01")
        #expect(series.last?.startDate == "9999-12-31")
        #expect(series.map(\.tokens) == [1, 0, 0, 2])
    }

    @Test
    func testNormalizedPositionsUseCivilDaysAndWholeSeriesFallback() {
        #expect(
            UsageChartMath.normalizedCalendarDayPositions(for: [
                DailyUsageBucket(startDate: "2026-03-07", tokens: 1),
                DailyUsageBucket(startDate: "2026-03-08", tokens: 2),
                DailyUsageBucket(startDate: "2026-03-09", tokens: 3)
            ]) == [0, 0.5, 1]
        )
        #expect(
            UsageChartMath.normalizedCalendarDayPositions(for: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: 1),
                DailyUsageBucket(startDate: "2026-01-02", tokens: 2),
                DailyUsageBucket(startDate: "2026-01-11", tokens: 3)
            ]) == [0, 0.1, 1]
        )
        #expect(
            UsageChartMath.normalizedCalendarDayPositions(for: [
                DailyUsageBucket(startDate: "2026-01-01", tokens: 1),
                DailyUsageBucket(startDate: "bad", tokens: 2),
                DailyUsageBucket(startDate: "2026-01-11", tokens: 3)
            ]) == [0, 0.5, 1]
        )
    }

    @Test
    func testLargeTickSelectionDoesNotRevalidateForEveryTick() {
        let pointCount = 100_000
        let positions = (0..<pointCount).map { Double($0) / Double(pointCount - 1) }
        let start = DispatchTime.now().uptimeNanoseconds

        let ticks = UsageChartMath.tickIndices(
            positions: positions,
            maximumTickCount: UsageChartMath.maximumTickCount
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        #expect(ticks.count == UsageChartMath.maximumTickCount)
        #expect(ticks.first == 0)
        #expect(ticks.last == pointCount - 1)
        #expect(elapsed < 2, "Tick selection should be O(points + ticks log points), took \(elapsed)s")
    }

    @Test
    func testSmoothingBudgetsOutputAndRetainsEndpointsAndSpike() {
        #expect(
            UsageChartMath.smoothedSamples(values: [1, 2, 3], samplesPerSegment: .max).count
                <= UsageChartMath.maximumSmoothedSampleCount
        )
        var values = Array(repeating: Int64(0), count: UsageChartMath.maximumSmoothedSampleCount + 1)
        values[values.count / 2] = .max
        let samples = UsageChartMath.smoothedSamples(values: values, samplesPerSegment: .max)
        #expect(samples.count <= UsageChartMath.maximumSmoothedSampleCount)
        #expect(samples.first?.position == 0)
        #expect(samples.last?.position == 1)
        #expect(samples.map(\.value).max() == Double(Int64.max))

        let positions = values.indices.map { Double($0) / Double(values.count - 1) }
        let renderSamples = UsageChartMath.renderSamples(
            values: values,
            positions: positions,
            maximumSampleCount: 900
        )
        #expect(renderSamples.count <= 900)
        #expect(renderSamples.first?.position == 0)
        #expect(renderSamples.last?.position == 1)
        #expect(renderSamples.map(\.value).max() == Double(Int64.max))

        let tinyValues: [Int64] = [0, 9, 0, 1]
        let tinyPositions = [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0]
        let twoSamples = UsageChartMath.renderSamples(
            values: tinyValues,
            positions: tinyPositions,
            maximumSampleCount: 2
        )
        #expect(twoSamples.count == 2)
        #expect(twoSamples.first?.position == 0)
        #expect(twoSamples.last?.position == 1)
        let threeSamples = UsageChartMath.renderSamples(
            values: tinyValues,
            positions: tinyPositions,
            maximumSampleCount: 3
        )
        #expect(threeSamples.count == 3)
        #expect(threeSamples.map(\.value).contains(9))
        let subrangeSamples = UsageChartMath.renderSamples(
            values: [0, 3, 9, 10],
            positions: [0.2, 0.3, 0.7, 0.8],
            maximumSampleCount: 3
        )
        #expect(subrangeSamples.map(\.value) == [0, 3, 10])

        let hostilePositions = Array(repeating: Double.nan, count: 100_001)
        let fallbackTicks = UsageChartMath.tickIndices(
            positions: hostilePositions,
            maximumTickCount: 5
        )
        #expect(fallbackTicks == [0, 25_000, 50_000, 75_000, 100_000])
        #expect(UsageChartMath.nearestIndex(to: 0.5, positions: hostilePositions) == 50_000)
    }

    @Test
    func testNiceAxisMaximumIsIntegerSafeAndNeverBelowInput() {
        let values: [Int64] = [1, 9, 10, 999, 1_500, 5_000_000_000, 5_000_000_000_000_000_001, .max]
        for value in values {
            #expect(UsageChartMath.niceAxisMaximum(value) >= value)
        }
        #expect(UsageChartMath.niceAxisMaximum(999) == 1_000)
        #expect(UsageChartMath.niceAxisMaximum(1_500) == 2_000)
        #expect(UsageChartMath.niceAxisMaximum(.max) == .max)
    }

    @Test
    func testCompactFormattingPromotesRoundedUnitBoundariesForBothSigns() {
        #expect(UsageFormatting.tokens(999_999) == "1.0M")
        #expect(UsageFormatting.tokens(-999_999) == "-1.0M")
        #expect(UsageFormatting.axisTokens(999_999) == "1M")
        #expect(UsageFormatting.axisTokens(-999_999) == "-1M")
        #expect(UsageFormatting.tokens(999_999_999) == "1.000B")
        #expect(UsageFormatting.axisTokens(999_999_999) == "1B")
    }

    @Test
    func testFullTokenFormattingUsesTheExplicitLocaleAndKeepsItsDefaultedCall() {
        let value: Int64 = 1_234_567
        #expect(
            UsageFormatting.fullTokens(value, locale: Locale(identifier: "en_US_POSIX"))
                == "1,234,567"
        )
        #expect(
            UsageFormatting.fullTokens(value, locale: Locale(identifier: "de_DE"))
                == "1.234.567"
        )
        #expect(!UsageFormatting.fullTokens(value).isEmpty)
    }

    @Test
    func testExtremeFormattingNeverUsesTrappingIntegerConversions() {
        #expect(UsageFormatting.percent(.nan) == "n/a")
        #expect(UsageFormatting.percent(.infinity) == "n/a")
        #expect(UsageFormatting.percent(-0.0) == "0%")
        #expect(UsageFormatting.percent(-Double.leastNonzeroMagnitude) == "0.0%")
        #expect(UsageFormatting.percent(-0.000_01) == "0.0%")
        #expect(UsageFormatting.percent(-0.049) == "0.0%")
        #expect(UsageFormatting.percent(-0.051) == "-0.1%")
        #expect(UsageFormatting.percent(1e300).hasSuffix("%"))
        #expect(UsageFormatting.duration(seconds: -1) == "n/a")
        #expect(!UsageFormatting.duration(seconds: .max).isEmpty)
        #expect(UsageFormatting.windowDuration(minutes: nil) == "n/a")
        #expect(UsageFormatting.windowDuration(minutes: -1) == "n/a")
        #expect(UsageFormatting.windowDuration(minutes: 300) == "5h")
        #expect(UsageFormatting.windowDuration(minutes: 10_080) == "7d")
        #expect(!UsageFormatting.windowDuration(minutes: .max).isEmpty)
        #expect(
            UsageFormatting.relativeReset(Date(timeIntervalSinceReferenceDate: .nan)) == "n/a"
        )
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(
            UsageFormatting.relativeReset(
                Date(timeIntervalSinceReferenceDate: 59.6),
                now: now
            ) == "in 1m"
        )
        #expect(
            UsageFormatting.relativeReset(
                Date(timeIntervalSinceReferenceDate: 3_599.6),
                now: now
            ) == "in 1h"
        )
    }
}
