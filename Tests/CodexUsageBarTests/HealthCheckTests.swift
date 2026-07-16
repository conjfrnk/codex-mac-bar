import CodexUsageCore
import Foundation
import Testing
@testable import CodexUsageBar

extension RendererTests {
    @Test
    func checkReportsCapabilitiesWithoutUsageValues() throws {
        let snapshot = usageSnapshot(
            lifetimeTokens: 987_654_321,
            rateLimits: AccountRateLimitsResponse(
                rateLimits: nil,
                rateLimitsByLimitId: nil,
                rateLimitResetCredits: RateLimitResetCreditsSummary(availableCount: 2)
            )
        )
        var lines: [String] = []

        #expect(try UsageHealthCheck.runIfRequested(
            arguments: ["--check"],
            fetch: { snapshot },
            output: { lines.append($0) }
        ))
        #expect(lines == [
            "PASS Codex app-server connection; usage available; rate limits available"
        ])
        #expect(!lines.joined().contains("987654321"))
        #expect(!lines.joined().contains("987,654,321"))
    }

    @Test
    func checkReportsOptionalRateLimitsAsUnavailable() throws {
        var lines: [String] = []

        #expect(try UsageHealthCheck.runIfRequested(
            arguments: ["--check"],
            fetch: { usageSnapshot(lifetimeTokens: 7, rateLimits: nil) },
            output: { lines.append($0) }
        ))
        #expect(lines == [
            "PASS Codex app-server connection; usage available; rate limits unavailable"
        ])
    }

    @Test
    func unrelatedArgumentsDoNotStartDiagnostic() throws {
        let fetchCount = LockedCounter()

        #expect(try !UsageHealthCheck.runIfRequested(
            arguments: ["--render-popover", "/tmp/fixture.png"],
            fetch: {
                fetchCount.increment()
                return usageSnapshot(lifetimeTokens: 1, rateLimits: nil)
            }
        ))
        #expect(fetchCount.value == 0)
    }

    @Test
    func checkRejectsMixedArgumentsBeforeFetching() {
        let fetchCount = LockedCounter()

        #expect(throws: UsageHealthCheckError.invalidArguments) {
            try UsageHealthCheck.runIfRequested(
                arguments: ["--check", "--render-popover"],
                fetch: {
                    fetchCount.increment()
                    return usageSnapshot(lifetimeTokens: 1, rateLimits: nil)
                }
            )
        }
        #expect(fetchCount.value == 0)
    }

    @Test
    func checkPropagatesSanitizedClientFailureWithoutSuccessOutput() {
        var lines: [String] = []

        #expect(throws: SyntheticCheckFailure.self) {
            try UsageHealthCheck.runIfRequested(
                arguments: ["--check"],
                fetch: { throw SyntheticCheckFailure() },
                output: { lines.append($0) }
            )
        }
        #expect(lines.isEmpty)

        let failureLine = UsageHealthCheck.failureLine(for: SyntheticCheckFailure())
        #expect(failureLine.hasPrefix("FAIL "))
        #expect(failureLine.contains("[REDACTED]"))
        #expect(!failureLine.contains("synthetic-path-secret"))
        #expect(!failureLine.contains("synthetic-bearer-secret"))
    }

    @Test
    func checkHasABoundedOuterTimeout() {
        #expect(throws: UsageHealthCheckError.timedOut) {
            try UsageHealthCheck.runIfRequested(
                arguments: ["--check"],
                waitTimeout: 0.01,
                fetch: {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return usageSnapshot(lifetimeTokens: 1, rateLimits: nil)
                }
            )
        }
    }
}

private struct SyntheticCheckFailure: Error, CustomStringConvertible {
    var description: String {
        "CODEX_USAGE_BAR_CODEX_PATH=/tmp/token=synthetic-path-secret/codex "
            + "Authorization: Bearer synthetic-bearer-secret"
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func usageSnapshot(
    lifetimeTokens: Int64,
    rateLimits: AccountRateLimitsResponse?
) -> UsageSnapshot {
    UsageSnapshot(
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        usage: AccountTokenUsageResponse(
            summary: UsageSummary(
                lifetimeTokens: lifetimeTokens,
                peakDailyTokens: lifetimeTokens,
                longestRunningTurnSec: nil,
                currentStreakDays: nil,
                longestStreakDays: nil
            ),
            dailyUsageBuckets: [
                DailyUsageBucket(startDate: "2027-01-15", tokens: lifetimeTokens)
            ]
        ),
        rateLimits: rateLimits
    )
}
