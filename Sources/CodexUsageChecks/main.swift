import CodexUsageCore
import Darwin
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.failed(message)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw CheckFailure.failed(message)
    }
    return value
}

func expectThrows<T>(_ message: String, _ body: () throws -> T) throws {
    do {
        _ = try body()
    } catch {
        return
    }
    throw CheckFailure.failed(message)
}

func expectApproximatelyEqual(_ lhs: Double, _ rhs: Double, _ message: String) throws {
    try expect(abs(lhs - rhs) <= 0.000_001, message)
}

private final class SnapshotResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UsageSnapshot, Error>?

    func store(_ result: Result<UsageSnapshot, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<UsageSnapshot, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func fetchResult(_ client: CodexAppServerClient) throws -> Result<UsageSnapshot, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SnapshotResultBox()
    let task = Task.detached {
        do {
            box.store(.success(try await client.fetchUsageSnapshot()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + .seconds(8)) == .success else {
        task.cancel()
        _ = semaphore.wait(timeout: .now() + .seconds(2))
        throw CheckFailure.failed("Fake Codex app-server check timed out")
    }
    return try require(box.take(), "Fake Codex app-server check did not return a result")
}

func runFakeCodex(script: String, timeout: TimeInterval = 2) throws -> Result<UsageSnapshot, Error> {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("CodexUsageChecks-\(UUID().uuidString)", isDirectory: true)
    let executable = directory.appendingPathComponent("codex")
    let environmentKey = "CODEX_USAGE_BAR_CODEX_PATH"
    let previousValue = getenv(environmentKey).map { String(cString: $0) }

    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: directory)
    }
    try Data(script.utf8).write(to: executable)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    guard setenv(environmentKey, executable.path, 1) == 0 else {
        throw CheckFailure.failed("Could not configure fake Codex CLI path")
    }

    defer {
        if let previousValue {
            setenv(environmentKey, previousValue, 1)
        } else {
            unsetenv(environmentKey)
        }
    }

    return try fetchResult(CodexAppServerClient(timeout: timeout))
}

func fakeCodexScript(rateLimitAction: String) -> String {
    """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        *'"id":2'*)
          printf '%s\n' '{"id":2,"result":{"summary":{"lifetimeTokens":7,"peakDailyTokens":7,"longestRunningTurnSec":null,"currentStreakDays":1,"longestStreakDays":1},"dailyUsageBuckets":[{"startDate":"2026-07-08","tokens":7}]}}'
          ;;
    \(rateLimitAction)
      esac
    done
    """
}

func rollingThirtyDayTotalUsesCalendarWindow() throws {
    let buckets = [
        DailyUsageBucket(startDate: "2026-06-08", tokens: 999),
        DailyUsageBucket(startDate: "2026-06-09", tokens: 20),
        DailyUsageBucket(startDate: "2026-07-07", tokens: 100),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 1),
        DailyUsageBucket(startDate: "2026-07-09", tokens: 500)
    ]
    let now = try require(UsageWindows.date(from: "2026-07-08"), "Expected test date to parse")

    try expect(
        UsageWindows.rollingTotal(buckets: buckets, days: 30, now: now) == 121,
        "Rolling total should include June 9 through July 8 only"
    )
}

func filledDailySeriesPreservesMissingDays() throws {
    let buckets = [
        DailyUsageBucket(startDate: "2026-07-06", tokens: 11),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 13)
    ]
    let now = try require(UsageWindows.date(from: "2026-07-08"), "Expected test date to parse")
    let series = UsageWindows.filledDailySeries(buckets: buckets, days: 3, now: now)

    try expect(series == [
        DailyUsageBucket(startDate: "2026-07-06", tokens: 11),
        DailyUsageBucket(startDate: "2026-07-07", tokens: 0),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 13)
    ], "Filled daily series should include zero-token missing days")
}

func filledDailySeriesMergesDuplicateDates() throws {
    let buckets = [
        DailyUsageBucket(startDate: "2026-07-08", tokens: 10),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 15)
    ]
    let now = try require(UsageWindows.date(from: "2026-07-08"), "Expected test date to parse")

    try expect(
        UsageWindows.filledDailySeries(buckets: buckets, days: 1, now: now) == [
            DailyUsageBucket(startDate: "2026-07-08", tokens: 25)
        ],
        "Filled daily series should merge duplicate dates"
    )
}

func allTimeRangeMergesAndSortsDuplicateDates() throws {
    let range = UsageRange(timeframe: .all, sourceBuckets: [
        DailyUsageBucket(startDate: "2026-07-08", tokens: 10),
        DailyUsageBucket(startDate: "2026-07-07", tokens: 5),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 15)
    ])

    try expect(range.buckets == [
        DailyUsageBucket(startDate: "2026-07-07", tokens: 5),
        DailyUsageBucket(startDate: "2026-07-08", tokens: 25)
    ], "All-time range should merge duplicate dates and remain sorted")
    try expect(range.activeDays == 2, "All-time range should count unique active days")
    try expect(range.peakDailyTokens == 25, "All-time range should compute the merged peak")
}

func chartRangePreservesZeroUsageCalendarGaps() throws {
    let now = try require(UsageWindows.date(from: "2026-07-08"), "Expected test date to parse")
    let range = UsageRange(
        timeframe: .seven,
        sourceBuckets: [
            DailyUsageBucket(startDate: "2026-07-06", tokens: 11),
            DailyUsageBucket(startDate: "2026-07-08", tokens: 13)
        ],
        now: now
    )

    try expect(range.chartBuckets.count == 7, "Chart should retain every day in the selected window")
    try expect(
        range.chartBuckets.first(where: { $0.startDate == "2026-07-07" })?.tokens == 0,
        "Chart should retain zero-usage gaps"
    )

    let emptyRange = UsageRange(timeframe: .seven, sourceBuckets: [], now: now)
    try expect(emptyRange.peakDailyTokens == 0, "Empty range should report a zero peak")
    try expect(emptyRange.chartBuckets.allSatisfy { $0.tokens == 0 }, "Empty chart should contain only zero values")
}

func smoothedChartPreservesAnchorsAndBoundsEverySegment() throws {
    let values: [Int64] = [0, 80, 20, 120, 120, 10]
    let samplesPerSegment = 16
    let samples = UsageChartMath.smoothedSamples(
        values: values,
        samplesPerSegment: samplesPerSegment
    )

    try expect(
        samples.count == (values.count - 1) * samplesPerSegment + 1,
        "Smoothed chart should emit the expected number of samples"
    )
    for index in values.indices {
        try expectApproximatelyEqual(
            samples[index * samplesPerSegment].value,
            Double(values[index]),
            "Smoothed chart should pass through source anchor \(index)"
        )
    }

    for (index, sample) in samples.dropLast().enumerated() {
        let segment = index / samplesPerSegment
        let lower = Double(min(values[segment], values[segment + 1]))
        let upper = Double(max(values[segment], values[segment + 1]))
        try expect(sample.value >= lower, "Smoothed chart should not undershoot segment \(segment)")
        try expect(sample.value <= upper, "Smoothed chart should not overshoot segment \(segment)")
        try expect(sample.value >= 0, "Nonnegative chart data should remain nonnegative")
    }

    for segment in 0..<(values.count - 1) {
        let segmentSamples = samples[(segment * samplesPerSegment)...((segment + 1) * samplesPerSegment)]
        for (before, after) in zip(segmentSamples, segmentSamples.dropFirst()) {
            if values[segment] <= values[segment + 1] {
                try expect(after.value >= before.value, "Increasing segment \(segment) should remain monotone")
            } else {
                try expect(after.value <= before.value, "Decreasing segment \(segment) should remain monotone")
            }
        }
    }
}

func smallChartSeriesRemainUnsmoothed() throws {
    try expect(UsageChartMath.smoothedSamples(values: []).isEmpty, "Empty chart should have no samples")
    try expect(
        UsageChartMath.smoothedSamples(values: [42]) == [UsageChartSample(position: 0.5, value: 42)],
        "One-point chart should remain a single centered point"
    )
    try expect(
        UsageChartMath.smoothedSamples(values: [10, 30]) == [
            UsageChartSample(position: 0, value: 10),
            UsageChartSample(position: 1, value: 30)
        ],
        "Two-point chart should remain a straight segment"
    )
}

func smoothedChartSupportsNonuniformDates() throws {
    let values: [Int64] = [0, 100, 10]
    let positions = [0.0, 0.1, 1.0]
    let samplesPerSegment = 10
    let samples = UsageChartMath.smoothedSamples(
        values: values,
        positions: positions,
        samplesPerSegment: samplesPerSegment
    )

    try expectApproximatelyEqual(samples[0].position, 0, "First chart point should keep its date position")
    try expectApproximatelyEqual(samples[samplesPerSegment].position, 0.1, "Middle chart point should keep its date position")
    try expectApproximatelyEqual(samples[samplesPerSegment * 2].position, 1, "Last chart point should keep its date position")
    try expectApproximatelyEqual(samples[samplesPerSegment].value, 100, "Nonuniform smoothing should retain its middle anchor")
    try expect(samples[0..<samplesPerSegment].allSatisfy { $0.value >= 0 && $0.value <= 100 }, "First nonuniform segment should stay bounded")
    try expect(samples[samplesPerSegment...].allSatisfy { $0.value >= 10 && $0.value <= 100 }, "Second nonuniform segment should stay bounded")
    try expect(
        UsageChartMath.nearestIndex(to: 0.4, positions: [0, 0.2, 1]) == 1,
        "Hover selection should use actual nonuniform date positions"
    )
    try expect(
        UsageChartMath.tickIndices(positions: [0, 0.05, 0.4, 0.95, 1], maximumTickCount: 3) == [0, 2, 4],
        "Axis ticks should span nonuniform date positions"
    )
}

func chartMathRejectsNumericallyUnstablePositions() throws {
    let extreme = UsageChartMath.smoothedSamples(
        values: [0, 1, 2],
        positions: [-Double.greatestFiniteMagnitude, 0, Double.greatestFiniteMagnitude],
        samplesPerSegment: 4
    )
    try expect(extreme.allSatisfy { $0.position.isFinite && $0.value.isFinite }, "Extreme positions should fall back to finite samples")
    try expect(extreme.first?.position == 0 && extreme.last?.position == 1, "Extreme positions should fall back to normalized endpoints")

    let tinyInterval = UsageChartMath.smoothedSamples(
        values: [0, 1, 2],
        positions: [0, Double.leastNonzeroMagnitude, 1],
        samplesPerSegment: 4
    )
    try expect(tinyInterval.allSatisfy { $0.position.isFinite && $0.value.isFinite }, "Tiny intervals should fall back to finite samples")
    try expect(
        UsageChartMath.tickIndices(
            positions: [-Double.greatestFiniteMagnitude, 0, Double.greatestFiniteMagnitude],
            maximumTickCount: 2
        ) == [0, 2],
        "Unstable tick positions should retain range endpoints"
    )
    try expect(
        UsageChartMath.clampedCenter(
            proposed: 0,
            itemLength: 1,
            lowerBound: .nan,
            upperBound: 10
        ).isFinite,
        "Invalid clamping bounds should still return a finite fallback"
    )
}

func chartAxesAdaptTicksAndDateStylesToTimeframe() throws {
    try expect(UsageChartMath.tickIndices(pointCount: 0, maximumTickCount: 4) == [], "Empty chart should have no ticks")
    try expect(UsageChartMath.tickIndices(pointCount: 1, maximumTickCount: 4) == [0], "Single-point chart should have one tick")
    try expect(UsageChartMath.tickIndices(pointCount: 7, maximumTickCount: 4) == [0, 2, 4, 6], "Week chart ticks should include endpoints")
    try expect(UsageChartMath.tickIndices(pointCount: 30, maximumTickCount: 4) == [0, 10, 19, 29], "Month chart ticks should span the range")
    try expect(UsageChartMath.tickIndices(pointCount: 90, maximumTickCount: 3) == [0, 45, 89], "Quarter chart ticks should span the range")
    try expect(
        UsageChartAxisPolicy.policy(for: .seven) == UsageChartAxisPolicy(maximumTickCount: 7, dateLabelStyle: .singleLetterWeekday),
        "Week chart should label every day with a single letter"
    )
    try expect(
        UsageChartAxisPolicy.policy(for: .thirty) == UsageChartAxisPolicy(maximumTickCount: 4, dateLabelStyle: .numericMonthDay),
        "Month chart should use numeric date labels"
    )
    try expect(
        UsageChartAxisPolicy.policy(for: .ninety) == UsageChartAxisPolicy(maximumTickCount: 3, dateLabelStyle: .abbreviatedMonthDay),
        "Quarter chart should use fewer abbreviated date labels"
    )
    try expect(
        UsageChartAxisPolicy.policy(for: .all, spanDays: 500) == UsageChartAxisPolicy(maximumTickCount: 3, dateLabelStyle: .abbreviatedMonthYear),
        "Long all-time charts should use month and year labels"
    )
}

func chartSelectionSnapsAndTooltipStaysInBounds() throws {
    try expect(UsageChartMath.nearestIndex(to: 0.5, pointCount: 0) == nil, "Empty chart should not select a point")
    try expect(UsageChartMath.nearestIndex(to: .nan, pointCount: 5) == nil, "Invalid chart position should not select a point")
    try expect(UsageChartMath.nearestIndex(to: -1, pointCount: 5) == 0, "Selection should clamp before the plot")
    try expect(UsageChartMath.nearestIndex(to: 0.26, pointCount: 5) == 1, "Selection should snap to the nearest point")
    try expect(UsageChartMath.nearestIndex(to: 0.5, pointCount: 5) == 2, "Selection should snap at the midpoint")
    try expect(UsageChartMath.nearestIndex(to: 2, pointCount: 5) == 4, "Selection should clamp after the plot")

    try expect(
        UsageChartMath.clampedCenter(proposed: 0, itemLength: 120, lowerBound: 40, upperBound: 264) == 100,
        "Leading tooltip should stay inside the plot"
    )
    try expect(
        UsageChartMath.clampedCenter(proposed: 264, itemLength: 120, lowerBound: 40, upperBound: 264) == 204,
        "Trailing tooltip should stay inside the plot"
    )
    try expect(
        UsageChartMath.clampedCenter(proposed: 150, itemLength: 120, lowerBound: 40, upperBound: 264) == 150,
        "Centered tooltip should keep its proposed position"
    )
    try expect(
        UsageChartMath.clampedCenter(proposed: 100, itemLength: 400, lowerBound: 40, upperBound: 264) == 152,
        "Oversized tooltip should center in the available plot"
    )
}

func decodesUsageResponseWithNumericAndStringIntegers() throws {
    let json = """
    {
      "summary": {
        "lifetimeTokens": "123456789",
        "peakDailyTokens": 456,
        "longestRunningTurnSec": null,
        "currentStreakDays": 2,
        "longestStreakDays": "5"
      },
      "dailyUsageBuckets": [
        { "startDate": "2026-07-07", "tokens": "1000" },
        { "startDate": "2026-07-08", "tokens": 2000 }
      ]
    }
    """
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let decoded = try UsageDecoding.decodeUsageResult(from: object)

    try expect(decoded.summary.lifetimeTokens == 123_456_789, "Expected string lifetime token count to decode")
    try expect(decoded.summary.longestRunningTurnSec == nil, "Expected null duration to decode")
    try expect(decoded.summary.longestStreakDays == 5, "Expected string streak count to decode")
    try expect(decoded.dailyUsageBuckets?.map(\.tokens) == [1_000, 2_000], "Expected mixed token encodings to decode")
}

func rejectsInvalidFlexibleIntegersAndAllowsMissingOptionals() throws {
    let missingOptionals = """
    {
      "summary": { "lifetimeTokens": 10 },
      "dailyUsageBuckets": []
    }
    """
    let missingObject = try JSONSerialization.jsonObject(with: Data(missingOptionals.utf8))
    let decoded = try UsageDecoding.decodeUsageResult(from: missingObject)
    try expect(decoded.summary.lifetimeTokens == 10, "Expected present summary value")
    try expect(decoded.summary.peakDailyTokens == nil, "Expected missing optional summary value to decode as nil")

    for invalidTokens in ["1.5", "1e40"] {
        let json = """
        {
          "summary": {
            "lifetimeTokens": null,
            "peakDailyTokens": null,
            "longestRunningTurnSec": null,
            "currentStreakDays": null,
            "longestStreakDays": null
          },
          "dailyUsageBuckets": [{ "startDate": "2026-07-08", "tokens": \(invalidTokens) }]
        }
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        try expectThrows("Expected invalid numeric token value to be rejected") {
            try UsageDecoding.decodeUsageResult(from: object)
        }
    }
}

func rateLimitErrorIsBestEffort() throws {
    let action = """
        *'"id":3'*)
          printf '%s\\n' '{"id":3,"error":{"code":-32601,"message":"unsupported"}}'
          ;;
    """
    let snapshot = try runFakeCodex(script: fakeCodexScript(rateLimitAction: action)).get()
    try expect(snapshot.sortedBuckets.map(\.tokens) == [7], "Expected usage from fake Codex CLI")
    let rateLimits = try require(snapshot.rateLimits, "Expected a nonfatal rate-limit error warning")
    try expect(!rateLimits.hasMeaningfulData, "Rate-limit error warning must not masquerade as data")
    try expect(
        rateLimits.decodingIssues == ["response: optional request failed"],
        "Rate-limit error should preserve a bounded warning without discarding valid usage"
    )
}

func malformedRateLimitIsBestEffort() throws {
    let action = """
        *'"id":3'*)
          printf '%s\\n' '{"id":3,"result":"malformed"}'
          ;;
    """
    let snapshot = try runFakeCodex(script: fakeCodexScript(rateLimitAction: action)).get()
    try expect(snapshot.sortedBuckets.map(\.tokens) == [7], "Expected usage with malformed rate-limit response")
    let rateLimits = try require(snapshot.rateLimits, "Expected a malformed rate-limit warning")
    try expect(!rateLimits.hasMeaningfulData, "Malformed rate-limit warning must not masquerade as data")
    try expect(
        rateLimits.decodingIssues == ["response: malformed value"],
        "Malformed rate-limit response should remain a bounded, nonfatal warning"
    )
}

func missingRateLimitStillReturnsUsageAtTimeout() throws {
    let snapshot = try runFakeCodex(
        script: fakeCodexScript(rateLimitAction: ""),
        timeout: 2
    ).get()
    try expect(snapshot.sortedBuckets.map(\.tokens) == [7], "Expected usage when rate-limit response is missing")
    try expect(snapshot.rateLimits == nil, "Missing rate-limit response should produce no rate-limit snapshot")
}

func oversizedAppServerMessageIsRejected() throws {
    let action = """
        *'"id":2'*)
          /usr/bin/head -c 2097153 /dev/zero | /usr/bin/tr '\\000' x
          ;;
    """
    let script = """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
    \(action)
      esac
    done
    """
    let result = try runFakeCodex(script: script)
    switch result {
    case .success:
        throw CheckFailure.failed("Oversized app-server message should fail")
    case let .failure(error):
        try expect(
            String(describing: error).contains("oversized message"),
            "Expected an oversized-message error"
        )
    }
}

func preferredCodexRateLimitUsesCodexBucket() throws {
    let json = """
    {
      "rateLimits": { "limitId": "fallback", "limitName": null, "primary": null, "secondary": null, "credits": null, "individualLimit": null, "planType": null, "rateLimitReachedType": null },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex",
          "limitName": "Codex",
          "primary": { "usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1783471305 },
          "secondary": null,
          "credits": null,
          "individualLimit": null,
          "planType": "team",
          "rateLimitReachedType": null
        }
      },
      "rateLimitResetCredits": { "availableCount": "1" }
    }
    """
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let decoded = try UsageDecoding.decodeRateLimitsResult(from: object)

    try expect(decoded.preferredCodexLimit?.limitId == "codex", "Expected codex rate limit bucket")
    try expect(decoded.preferredCodexLimit?.primary?.usedPercent == 42, "Expected primary rate limit usage")
    try expect(decoded.rateLimitResetCredits?.availableCount == 1, "Expected reset credit count to decode")
}

func tokenFormattingIsCompact() throws {
    try expect(UsageFormatting.tokens(999) == "999", "Expected raw small token count")
    try expect(UsageFormatting.tokens(1_200) == "1.2K", "Expected K-format token count")
    try expect(UsageFormatting.tokens(149_009_942) == "149M", "Expected M-format token count")
    try expect(UsageFormatting.tokens(1_250_000_000) == "1.250B", "Expected B-format token count with 3 decimal places")
    try expect(UsageFormatting.tokens(150_400_000_000) == "150B", "Expected B-format token count to drop decimals above 100")
}

func chartYAxisRoundsToNiceNumbers() throws {
    try expect(UsageChartMath.niceAxisMaximum(0) == 0, "Zero peak should have a zero axis maximum")
    try expect(UsageChartMath.niceAxisMaximum(999) == 1_000, "Axis maximum should round up to the next nice number")
    try expect(UsageChartMath.niceAxisMaximum(1_500) == 2_000, "Axis maximum should round up within a decade")
    try expect(UsageChartMath.niceAxisMaximum(100) == 100, "An already-nice value should stay unchanged")
    try expect(
        UsageChartMath.niceAxisMaximum(4_181_000_000) == 5_000_000_000,
        "A B-range peak should round up to a nice multiple, not stay at its exact raw value"
    )

    try expect(UsageFormatting.axisTokens(0) == "0", "Zero should format as a plain axis label")
    try expect(UsageFormatting.axisTokens(500_000) == "500K", "Whole-number axis label should have no decimal")
    try expect(
        UsageFormatting.axisTokens(5_000_000_000) == "5B",
        "A nice round B-range axis label should not show trailing decimal zeros"
    )
    try expect(
        UsageFormatting.axisTokens(2_500_000_000) == "2.5B",
        "A nice half-step B-range axis label should show exactly one decimal"
    )
}

let checks: [(String, () throws -> Void)] = [
    ("rollingThirtyDayTotalUsesCalendarWindow", rollingThirtyDayTotalUsesCalendarWindow),
    ("filledDailySeriesPreservesMissingDays", filledDailySeriesPreservesMissingDays),
    ("filledDailySeriesMergesDuplicateDates", filledDailySeriesMergesDuplicateDates),
    ("allTimeRangeMergesAndSortsDuplicateDates", allTimeRangeMergesAndSortsDuplicateDates),
    ("chartRangePreservesZeroUsageCalendarGaps", chartRangePreservesZeroUsageCalendarGaps),
    ("smoothedChartPreservesAnchorsAndBoundsEverySegment", smoothedChartPreservesAnchorsAndBoundsEverySegment),
    ("smallChartSeriesRemainUnsmoothed", smallChartSeriesRemainUnsmoothed),
    ("smoothedChartSupportsNonuniformDates", smoothedChartSupportsNonuniformDates),
    ("chartMathRejectsNumericallyUnstablePositions", chartMathRejectsNumericallyUnstablePositions),
    ("chartAxesAdaptTicksAndDateStylesToTimeframe", chartAxesAdaptTicksAndDateStylesToTimeframe),
    ("chartSelectionSnapsAndTooltipStaysInBounds", chartSelectionSnapsAndTooltipStaysInBounds),
    ("decodesUsageResponseWithNumericAndStringIntegers", decodesUsageResponseWithNumericAndStringIntegers),
    ("rejectsInvalidFlexibleIntegersAndAllowsMissingOptionals", rejectsInvalidFlexibleIntegersAndAllowsMissingOptionals),
    ("preferredCodexRateLimitUsesCodexBucket", preferredCodexRateLimitUsesCodexBucket),
    ("tokenFormattingIsCompact", tokenFormattingIsCompact),
    ("chartYAxisRoundsToNiceNumbers", chartYAxisRoundsToNiceNumbers),
    ("rateLimitErrorIsBestEffort", rateLimitErrorIsBestEffort),
    ("malformedRateLimitIsBestEffort", malformedRateLimitIsBestEffort),
    ("missingRateLimitStillReturnsUsageAtTimeout", missingRateLimitStillReturnsUsageAtTimeout),
    ("oversizedAppServerMessageIsRejected", oversizedAppServerMessageIsRejected)
]

let checkArguments = Array(CommandLine.arguments.dropFirst())
if !checkArguments.isEmpty, checkArguments != ["--live"] {
    fputs("usage: CodexUsageChecks [--live]\n", stderr)
    exit(64)
}
let shouldRunLiveCheck = checkArguments == ["--live"]

do {
    for (name, check) in checks {
        try check()
        print("PASS \(name)")
    }

    if shouldRunLiveCheck {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SnapshotResultBox()
        let liveTask = Task.detached {
            do {
                box.store(.success(try await CodexAppServerClient(timeout: 20).fetchUsageSnapshot()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .seconds(25)) == .success else {
            liveTask.cancel()
            _ = semaphore.wait(timeout: .now() + .seconds(2))
            throw CheckFailure.failed("Live usage check exceeded its outer watchdog")
        }

        _ = try box.take()?.get() ?? {
            throw CheckFailure.failed("Live usage check did not complete")
        }()
        print("PASS liveAccountUsage response shape decoded")
    }
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
