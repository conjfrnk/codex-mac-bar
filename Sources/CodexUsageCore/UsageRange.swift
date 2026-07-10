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
            return "7-day history"
        case .thirty:
            return "30-day history"
        case .ninety:
            return "90-day history"
        case .all:
            return "Daily history"
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
    public let buckets: [DailyUsageBucket]

    public init(
        timeframe: UsageTimeframe,
        sourceBuckets: [DailyUsageBucket],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let mergedBuckets = UsageWindows.mergedDailyBuckets(sourceBuckets)
        if let days = timeframe.days {
            buckets = UsageWindows.filledDailySeries(
                buckets: mergedBuckets,
                days: days,
                now: now,
                calendar: calendar
            )
        } else {
            buckets = mergedBuckets
        }
    }

    public var historyBuckets: [DailyUsageBucket] {
        buckets.filter { $0.tokens > 0 }
    }

    public var chartBuckets: [DailyUsageBucket] {
        buckets
    }

    public var totalTokens: Int64 {
        buckets.reduce(Int64(0)) { $0 + $1.tokens }
    }

    public var activeDays: Int {
        buckets.filter { $0.tokens > 0 }.count
    }

    public var peakDailyTokens: Int64 {
        buckets.map(\.tokens).max() ?? 0
    }

    public var averageDailyTokens: Int64 {
        guard !buckets.isEmpty else { return 0 }
        return totalTokens / Int64(buckets.count)
    }
}
