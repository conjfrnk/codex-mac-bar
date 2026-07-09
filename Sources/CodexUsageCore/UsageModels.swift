import Foundation

public struct DailyUsageBucket: Decodable, Equatable, Identifiable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public var id: String { startDate }

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey {
        case startDate
        case tokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try container.decode(String.self, forKey: .startDate)
        tokens = try container.decodeFlexibleInt64(forKey: .tokens)
    }
}

public struct UsageSummary: Decodable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSec: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSec = longestRunningTurnSec
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }

    private enum CodingKeys: String, CodingKey {
        case lifetimeTokens
        case peakDailyTokens
        case longestRunningTurnSec
        case currentStreakDays
        case longestStreakDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifetimeTokens = try container.decodeFlexibleInt64IfPresent(forKey: .lifetimeTokens)
        peakDailyTokens = try container.decodeFlexibleInt64IfPresent(forKey: .peakDailyTokens)
        longestRunningTurnSec = try container.decodeFlexibleInt64IfPresent(forKey: .longestRunningTurnSec)
        currentStreakDays = try container.decodeFlexibleInt64IfPresent(forKey: .currentStreakDays)
        longestStreakDays = try container.decodeFlexibleInt64IfPresent(forKey: .longestStreakDays)
    }
}

public struct AccountTokenUsageResponse: Decodable, Equatable, Sendable {
    public let summary: UsageSummary
    public let dailyUsageBuckets: [DailyUsageBucket]?

    public init(summary: UsageSummary, dailyUsageBuckets: [DailyUsageBucket]?) {
        self.summary = summary
        self.dailyUsageBuckets = dailyUsageBuckets
    }
}

public struct RateLimitWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var resetDate: Date? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt > 10_000_000_000 ? resetsAt / 1_000 : resetsAt
        return Date(timeIntervalSince1970: seconds)
    }
}

public struct CreditsSnapshot: Decodable, Equatable, Sendable {
    public let remaining: Double?
    public let total: Double?
    public let used: Double?

    public init(remaining: Double?, total: Double?, used: Double?) {
        self.remaining = remaining
        self.total = total
        self.used = used
    }
}

public struct SpendControlLimitSnapshot: Decodable, Equatable, Sendable {
    public let usedPercent: Double?
    public let resetsAt: Double?

    public init(usedPercent: Double?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct RateLimitSnapshot: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let credits: CreditsSnapshot?
    public let individualLimit: SpendControlLimitSnapshot?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        limitId: String?,
        limitName: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?,
        individualLimit: SpendControlLimitSnapshot?,
        planType: String?,
        rateLimitReachedType: String?
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.individualLimit = individualLimit
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct RateLimitResetCreditsSummary: Decodable, Equatable, Sendable {
    public let availableCount: Int64

    public init(availableCount: Int64) {
        self.availableCount = availableCount
    }

    private enum CodingKeys: String, CodingKey {
        case availableCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decodeFlexibleInt64(forKey: .availableCount)
    }
}

public struct AccountRateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: RateLimitSnapshot?
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    public let rateLimitResetCredits: RateLimitResetCreditsSummary?

    public init(
        rateLimits: RateLimitSnapshot?,
        rateLimitsByLimitId: [String: RateLimitSnapshot]?,
        rateLimitResetCredits: RateLimitResetCreditsSummary?
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
    }

    public var preferredCodexLimit: RateLimitSnapshot? {
        if let codex = rateLimitsByLimitId?["codex"] {
            return codex
        }
        if let codex = rateLimitsByLimitId?.values.first(where: { $0.limitId == "codex" }) {
            return codex
        }
        return rateLimits
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let fetchedAt: Date
    public let usage: AccountTokenUsageResponse
    public let rateLimits: AccountRateLimitsResponse?

    public init(fetchedAt: Date, usage: AccountTokenUsageResponse, rateLimits: AccountRateLimitsResponse?) {
        self.fetchedAt = fetchedAt
        self.usage = usage
        self.rateLimits = rateLimits
    }

    public var sortedBuckets: [DailyUsageBucket] {
        UsageWindows.mergedDailyBuckets(usage.dailyUsageBuckets ?? [])
    }

    public func rollingTokenTotal(days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> Int64 {
        UsageWindows.rollingTotal(buckets: sortedBuckets, days: days, now: now, calendar: calendar)
    }

    public func bucketsForRollingWindow(days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [DailyUsageBucket] {
        UsageWindows.bucketsInRollingWindow(buckets: sortedBuckets, days: days, now: now, calendar: calendar)
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
        if let intValue = try? decode(Int64.self, forKey: key) {
            return intValue
        }
        if let doubleValue = try? decode(Double.self, forKey: key),
           doubleValue.isFinite,
           doubleValue.rounded(.towardZero) == doubleValue,
           doubleValue >= Double(Int64.min),
           doubleValue < Double(Int64.max) {
            return Int64(doubleValue)
        }
        if let stringValue = try? decode(String.self, forKey: key), let intValue = Int64(stringValue) {
            return intValue
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected an Int64-compatible value.")
        )
    }

    fileprivate func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if !contains(key) {
            return nil
        }
        if try decodeNil(forKey: key) {
            return nil
        }
        return try decodeFlexibleInt64(forKey: key)
    }
}
