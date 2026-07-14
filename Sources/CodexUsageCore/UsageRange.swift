import Foundation

public enum UsageTimeframe: String, CaseIterable, Identifiable, Sendable {
    case seven
    case thirty
    case ninety
    case all

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .seven:
            return "Week"
        case .thirty:
            return "Month"
        case .ninety:
            return "Quarter"
        case .all:
            return "All"
        }
    }

    public var heroTitle: String {
        switch self {
        case .seven:
            return "Last 7 days (rolling)"
        case .thirty:
            return "Last 30 days (rolling)"
        case .ninety:
            return "Last 90 days (rolling)"
        case .all:
            return "All time"
        }
    }

    public var historyTitle: String {
        switch self {
        case .seven:
            return "Week active-day history"
        case .thirty:
            return "Month active-day history"
        case .ninety:
            return "Quarter active-day history"
        case .all:
            return "Active-day history"
        }
    }

    public var days: Int? {
        switch self {
        case .seven:
            return 7
        case .thirty:
            return 30
        case .ninety:
            return 90
        case .all:
            return nil
        }
    }
}

public struct UsageRange: Sendable {
    /// Source-based merged buckets. For `.all`, zero-filled chart boundary
    /// points deliberately do not affect totals, history, peaks, or active days.
    public let buckets: [DailyUsageBucket]
    public let chartBuckets: [DailyUsageBucket]
    /// Normalized proleptic-Gregorian civil-day coordinates for `chartBuckets`.
    /// Computing these once keeps line, ticks, and hit testing in agreement.
    public let chartPositions: [Double]
    /// Inclusive calendar days represented by the average. All-time ranges run
    /// from their first source day through the later of today or the last source
    /// day; fixed ranges use their explicitly filled day count.
    public let calendarDayCount: Int
    public let totalTokens: Int64
    /// True when duplicate merging or total accumulation saturated at Int64.max.
    public let didOverflow: Bool
    /// True when one or more same-day bucket values saturated while merging.
    public let mergeDidOverflow: Bool
    /// True when summing otherwise merged selected days saturated.
    public let totalDidOverflow: Bool
    /// Invalid canonical dates and negative manually constructed usage buckets.
    public let rejectedBucketCount: Int

    public init(
        timeframe: UsageTimeframe,
        sourceBuckets: [DailyUsageBucket],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let mergeResult = UsageWindows.mergedDailyBucketsReportingOverflow(sourceBuckets)
        let mergedBuckets = mergeResult.buckets
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            buckets = []
            chartBuckets = []
            chartPositions = []
            calendarDayCount = 0
            totalTokens = 0
            didOverflow = false
            mergeDidOverflow = false
            totalDidOverflow = false
            rejectedBucketCount = mergeResult.rejectedBucketCount
            return
        }
        let selectedBuckets: [DailyUsageBucket]
        let selectedChartBuckets: [DailyUsageBucket]
        let selectedCalendarDayCount: Int

        if let days = timeframe.days {
            selectedBuckets = UsageWindows.filledDailySeries(
                buckets: mergedBuckets,
                days: days,
                now: now,
                calendar: calendar
            )
            selectedChartBuckets = selectedBuckets
            selectedCalendarDayCount = selectedBuckets.count
        } else {
            selectedBuckets = mergedBuckets
            selectedChartBuckets = UsageWindows.sparseDailyChartSeries(
                buckets: mergedBuckets,
                through: now,
                calendar: calendar
            )
            selectedCalendarDayCount = Self.allTimeCalendarDayCount(
                buckets: mergedBuckets,
                now: now,
                timeZone: calendar.timeZone
            )
        }

        let total = UsageWindows.saturatingTotal(selectedBuckets)
        let selectedStartDates = Set(selectedBuckets.map(\.startDate))
        let selectedMergeDidOverflow = !mergeResult.overflowedStartDates.isDisjoint(
            with: selectedStartDates
        )
        buckets = selectedBuckets
        chartBuckets = selectedChartBuckets
        chartPositions = UsageChartMath.normalizedCalendarDayPositions(for: selectedChartBuckets)
        calendarDayCount = selectedCalendarDayCount
        totalTokens = total.value
        didOverflow = selectedMergeDidOverflow || total.didOverflow
        mergeDidOverflow = selectedMergeDidOverflow
        totalDidOverflow = total.didOverflow
        rejectedBucketCount = mergeResult.rejectedBucketCount
    }

    public var historyBuckets: [DailyUsageBucket] {
        buckets.filter { $0.tokens > 0 }
    }

    public var activeDays: Int {
        buckets.filter { $0.tokens > 0 }.count
    }

    public var peakDailyTokens: Int64 {
        buckets.map(\.tokens).max() ?? 0
    }

    public var averageDailyTokens: Int64 {
        guard calendarDayCount > 0,
              let divisor = Int64(exactly: calendarDayCount)
        else { return 0 }
        return totalTokens / divisor
    }

    private static func allTimeCalendarDayCount(
        buckets: [DailyUsageBucket],
        now: Date,
        timeZone: TimeZone
    ) -> Int {
        guard let first = buckets.first.flatMap({ UsageCivilDate.parse($0.startDate) }),
              let last = buckets.last.flatMap({ UsageCivilDate.parse($0.startDate) })
        else { return 0 }

        let todayKey = UsageWindows.bucketStartString(for: now, timeZone: timeZone)
        let today = UsageCivilDate.parse(todayKey)
        let endpointOrdinal = max(last.ordinal, today?.ordinal ?? last.ordinal)
        let (distance, overflow) = endpointOrdinal.subtractingReportingOverflow(first.ordinal)
        guard !overflow, distance >= 0 else { return 0 }
        let (inclusiveCount, additionOverflow) = distance.addingReportingOverflow(1)
        guard !additionOverflow, let result = Int(exactly: inclusiveCount) else { return Int.max }
        return result
    }
}
