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
    Task.detached {
        do {
            box.store(.success(try await client.fetchUsageSnapshot()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + .seconds(8)) == .success else {
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
        try? fileManager.removeItem(at: directory)
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
    try expect(snapshot.rateLimits == nil, "Rate-limit error should not discard valid usage")
}

func malformedRateLimitIsBestEffort() throws {
    let action = """
        *'"id":3'*)
          printf '%s\\n' '{"id":3,"result":"malformed"}'
          ;;
    """
    let snapshot = try runFakeCodex(script: fakeCodexScript(rateLimitAction: action)).get()
    try expect(snapshot.sortedBuckets.map(\.tokens) == [7], "Expected usage with malformed rate-limit response")
    try expect(snapshot.rateLimits == nil, "Malformed rate-limit response should be ignored")
}

func missingRateLimitStillReturnsUsageAtTimeout() throws {
    let snapshot = try runFakeCodex(
        script: fakeCodexScript(rateLimitAction: ""),
        timeout: 0.25
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

let checks: [(String, () throws -> Void)] = [
    ("rollingThirtyDayTotalUsesCalendarWindow", rollingThirtyDayTotalUsesCalendarWindow),
    ("filledDailySeriesPreservesMissingDays", filledDailySeriesPreservesMissingDays),
    ("filledDailySeriesMergesDuplicateDates", filledDailySeriesMergesDuplicateDates),
    ("allTimeRangeMergesAndSortsDuplicateDates", allTimeRangeMergesAndSortsDuplicateDates),
    ("chartRangePreservesZeroUsageCalendarGaps", chartRangePreservesZeroUsageCalendarGaps),
    ("decodesUsageResponseWithNumericAndStringIntegers", decodesUsageResponseWithNumericAndStringIntegers),
    ("rejectsInvalidFlexibleIntegersAndAllowsMissingOptionals", rejectsInvalidFlexibleIntegersAndAllowsMissingOptionals),
    ("preferredCodexRateLimitUsesCodexBucket", preferredCodexRateLimitUsesCodexBucket),
    ("tokenFormattingIsCompact", tokenFormattingIsCompact),
    ("rateLimitErrorIsBestEffort", rateLimitErrorIsBestEffort),
    ("malformedRateLimitIsBestEffort", malformedRateLimitIsBestEffort),
    ("missingRateLimitStillReturnsUsageAtTimeout", missingRateLimitStillReturnsUsageAtTimeout),
    ("oversizedAppServerMessageIsRejected", oversizedAppServerMessageIsRejected)
]

do {
    for (name, check) in checks {
        try check()
        print("PASS \(name)")
    }

    if CommandLine.arguments.contains("--live") {
        let semaphore = DispatchSemaphore(value: 0)
        var liveResult: Result<UsageSnapshot, Error>?
        Task.detached {
            do {
                liveResult = .success(try await CodexAppServerClient(timeout: 20).fetchUsageSnapshot())
            } catch {
                liveResult = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        let snapshot = try liveResult?.get() ?? {
            throw CheckFailure.failed("Live usage check did not complete")
        }()
        let buckets = snapshot.usage.dailyUsageBuckets ?? []
        let rollingTotal = snapshot.rollingTokenTotal()
        let primaryPercent = snapshot.rateLimits?.preferredCodexLimit?.primary?.usedPercent
        print("PASS liveAccountUsage buckets=\(buckets.count) rolling30=\(UsageFormatting.fullTokens(rollingTotal)) primary=\(primaryPercent.map { UsageFormatting.percent($0) } ?? "n/a")")
    }
} catch {
    fputs("FAIL \(error)\n", stderr)
    exit(1)
}
