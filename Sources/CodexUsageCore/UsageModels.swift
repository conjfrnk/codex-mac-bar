import Foundation

public struct DailyUsageBucket: Decodable, Equatable, Identifiable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public var id: String { startDate }

    /// Public construction remains source-compatible. Aggregation helpers reject
    /// malformed dates and negative tokens instead of trapping or corrupting totals.
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
        let decodedStartDate = try container.decode(String.self, forKey: .startDate)
        guard UsageWindows.isCanonicalBucketStartDate(decodedStartDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startDate,
                in: container,
                debugDescription: "Expected a canonical, valid ASCII YYYY-MM-DD Gregorian date."
            )
        }
        startDate = decodedStartDate
        tokens = try container.decodeNonnegativeFlexibleInt64(forKey: .tokens)
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
        lifetimeTokens = try container.decodeNonnegativeFlexibleInt64IfPresent(forKey: .lifetimeTokens)
        peakDailyTokens = try container.decodeNonnegativeFlexibleInt64IfPresent(forKey: .peakDailyTokens)
        longestRunningTurnSec = try container.decodeNonnegativeFlexibleInt64IfPresent(forKey: .longestRunningTurnSec)
        currentStreakDays = try container.decodeNonnegativeFlexibleInt64IfPresent(forKey: .currentStreakDays)
        longestStreakDays = try container.decodeNonnegativeFlexibleInt64IfPresent(forKey: .longestStreakDays)
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

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMins
        case resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeFiniteNonnegativeDouble(forKey: .usedPercent)
        windowDurationMins = try container.decodeNonnegativeIntIfPresent(forKey: .windowDurationMins)
        resetsAt = try container.decodeFiniteNonnegativeDoubleIfPresent(forKey: .resetsAt)
    }

    public var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite else { return nil }
        // The current app-server protocol expresses this field in Unix seconds.
        return Date(timeIntervalSince1970: resetsAt)
    }
}

public struct CreditsSnapshot: Decodable, Equatable, Sendable {
    /// Current app-server fields.
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?
    /// Legacy fields retained so older Codex CLI payloads remain decodable.
    public let remaining: Double?
    public let total: Double?
    public let used: Double?
    public let decodingIssues: [String]

    public init(
        remaining: Double?,
        total: Double?,
        used: Double?,
        hasCredits: Bool? = nil,
        unlimited: Bool? = nil,
        balance: String? = nil,
        decodingIssues: [String] = []
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
        self.remaining = remaining
        self.total = total
        self.used = used
        self.decodingIssues = decodingIssues
    }

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.init(
            remaining: nil,
            total: nil,
            used: nil,
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: balance
        )
    }

    private enum CodingKeys: String, CodingKey {
        case remaining
        case total
        case used
        case hasCredits
        case unlimited
        case balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []
        hasCredits = container.decodeLossyIfPresent(Bool.self, forKey: .hasCredits, issues: &issues)
        unlimited = container.decodeLossyIfPresent(Bool.self, forKey: .unlimited, issues: &issues)
        balance = container.decodeLossyIfPresent(String.self, forKey: .balance, issues: &issues)
        remaining = container.decodeLossyFiniteNonnegativeDoubleIfPresent(forKey: .remaining, issues: &issues)
        total = container.decodeLossyFiniteNonnegativeDoubleIfPresent(forKey: .total, issues: &issues)
        used = container.decodeLossyFiniteNonnegativeDoubleIfPresent(forKey: .used, issues: &issues)
        decodingIssues = issues
    }
}

public struct SpendControlLimitSnapshot: Decodable, Equatable, Sendable {
    /// Current app-server fields. `usedPercent` is derived from
    /// `remainingPercent` when the current shape is present.
    public let limit: String?
    public let used: String?
    public let remainingPercent: Int?
    public let usedPercent: Double?
    public let resetsAt: Double?
    public let decodingIssues: [String]

    public init(
        usedPercent: Double?,
        resetsAt: Double?,
        limit: String? = nil,
        used: String? = nil,
        remainingPercent: Int? = nil,
        decodingIssues: [String] = []
    ) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.decodingIssues = decodingIssues
    }

    public init(limit: String, used: String, remainingPercent: Int, resetsAt: Double) {
        self.init(
            usedPercent: (0...100).contains(remainingPercent)
                ? 100 - Double(remainingPercent)
                : nil,
            resetsAt: resetsAt,
            limit: limit,
            used: used,
            remainingPercent: (0...100).contains(remainingPercent) ? remainingPercent : nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case resetsAt
        case limit
        case used
        case remainingPercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []
        limit = container.decodeLossyIfPresent(String.self, forKey: .limit, issues: &issues)
        used = container.decodeLossyIfPresent(String.self, forKey: .used, issues: &issues)
        let decodedRemainingPercent = container.decodeLossyFlexibleIntIfPresent(
            forKey: .remainingPercent,
            issues: &issues
        )
        if let decodedRemainingPercent, (0...100).contains(decodedRemainingPercent) {
            remainingPercent = decodedRemainingPercent
        } else {
            remainingPercent = nil
            if decodedRemainingPercent != nil {
                issues.append("remainingPercent: expected a value from 0 through 100")
            }
        }
        let legacyUsedPercent = container.decodeLossyFiniteNonnegativeDoubleIfPresent(
            forKey: .usedPercent,
            issues: &issues
        )
        usedPercent = remainingPercent.map { 100 - Double($0) } ?? legacyUsedPercent
        resetsAt = container.decodeLossyFiniteNonnegativeDoubleIfPresent(forKey: .resetsAt, issues: &issues)
        decodingIssues = issues
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
    /// Malformed optional fields are omitted independently and reported here.
    public let decodingIssues: [String]

    public init(
        limitId: String?,
        limitName: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?,
        individualLimit: SpendControlLimitSnapshot?,
        planType: String?,
        rateLimitReachedType: String?,
        decodingIssues: [String] = []
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.individualLimit = individualLimit
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.decodingIssues = decodingIssues
    }

    private enum CodingKeys: String, CodingKey {
        case limitId
        case limitName
        case primary
        case secondary
        case credits
        case individualLimit
        case planType
        case rateLimitReachedType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []
        limitId = container.decodeLossyIfPresent(String.self, forKey: .limitId, issues: &issues)
        limitName = container.decodeLossyIfPresent(String.self, forKey: .limitName, issues: &issues)
        primary = container.decodeLossyIfPresent(RateLimitWindow.self, forKey: .primary, issues: &issues)
        secondary = container.decodeLossyIfPresent(RateLimitWindow.self, forKey: .secondary, issues: &issues)
        credits = container.decodeLossyIfPresent(CreditsSnapshot.self, forKey: .credits, issues: &issues)
        individualLimit = container.decodeLossyIfPresent(
            SpendControlLimitSnapshot.self,
            forKey: .individualLimit,
            issues: &issues
        )
        planType = container.decodeLossyIfPresent(String.self, forKey: .planType, issues: &issues)
        rateLimitReachedType = container.decodeLossyIfPresent(
            String.self,
            forKey: .rateLimitReachedType,
            issues: &issues
        )
        if let credits {
            issues.append(contentsOf: credits.decodingIssues.map { "credits.\($0)" })
        }
        if let individualLimit {
            issues.append(contentsOf: individualLimit.decodingIssues.map { "individualLimit.\($0)" })
        }
        decodingIssues = issues
    }

    /// Identifiers and decoding metadata alone do not make a snapshot useful to
    /// the presentation. This distinction lets a lossy, effectively empty map
    /// entry fall back to the still-valid legacy top-level snapshot.
    public var hasMeaningfulPresentationData: Bool {
        primary != nil
            || secondary != nil
            || credits?.hasMeaningfulPresentationData == true
            || individualLimit?.hasMeaningfulPresentationData == true
            || planType?.hasDisplayableContent == true
            || rateLimitReachedType?.hasDisplayableContent == true
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
        availableCount = try container.decodeNonnegativeFlexibleInt64(forKey: .availableCount)
    }
}

public struct AccountRateLimitsResponse: Decodable, Equatable, Sendable {
    private static let malformedResponseIssue = "response: malformed value"
    private static let failedRequestIssue = "response: optional request failed"

    public let rateLimits: RateLimitSnapshot?
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    public let rateLimitResetCredits: RateLimitResetCreditsSummary?
    /// Paths of malformed optional fields that were omitted while valid siblings survived.
    public let decodingIssues: [String]

    public init(
        rateLimits: RateLimitSnapshot?,
        rateLimitsByLimitId: [String: RateLimitSnapshot]?,
        rateLimitResetCredits: RateLimitResetCreditsSummary?,
        decodingIssues: [String] = []
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
        self.decodingIssues = decodingIssues
    }

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case rateLimitResetCredits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var issues: [String] = []
        rateLimits = container.decodeLossyIfPresent(
            RateLimitSnapshot.self,
            forKey: .rateLimits,
            issues: &issues
        )

        if container.contains(.rateLimitsByLimitId),
           (try? container.decodeNil(forKey: .rateLimitsByLimitId)) != true {
            do {
                let nested = try container.nestedContainer(
                    keyedBy: DynamicCodingKey.self,
                    forKey: .rateLimitsByLimitId
                )
                var snapshots: [String: RateLimitSnapshot] = [:]
                for key in nested.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                    do {
                        snapshots[key.stringValue] = try nested.decode(RateLimitSnapshot.self, forKey: key)
                    } catch {
                        issues.append("rateLimitsByLimitId.\(key.stringValue): \(error.localizedDescription)")
                    }
                }
                rateLimitsByLimitId = snapshots
            } catch {
                rateLimitsByLimitId = nil
                issues.append("rateLimitsByLimitId: \(error.localizedDescription)")
            }
        } else {
            rateLimitsByLimitId = nil
        }

        rateLimitResetCredits = container.decodeLossyIfPresent(
            RateLimitResetCreditsSummary.self,
            forKey: .rateLimitResetCredits,
            issues: &issues
        )
        if let rateLimits {
            issues.append(contentsOf: rateLimits.decodingIssues.map { "rateLimits.\($0)" })
        }
        if let rateLimitsByLimitId {
            for key in rateLimitsByLimitId.keys.sorted() {
                guard let snapshot = rateLimitsByLimitId[key] else { continue }
                issues.append(contentsOf: snapshot.decodingIssues.map {
                    "rateLimitsByLimitId.\(key).\($0)"
                })
            }
        }
        decodingIssues = issues
    }

    public var preferredCodexLimit: RateLimitSnapshot? {
        if let codex = rateLimitsByLimitId?["codex"], codex.hasMeaningfulPresentationData {
            return codex
        }
        if let key = rateLimitsByLimitId?.keys.sorted().first(where: {
            rateLimitsByLimitId?[$0]?.limitId == "codex"
                && rateLimitsByLimitId?[$0]?.hasMeaningfulPresentationData == true
        }) {
            return rateLimitsByLimitId?[key]
        }
        guard rateLimits?.hasMeaningfulPresentationData == true else { return nil }
        return rateLimits
    }

    /// True when the response contains something the rate-limit presentation
    /// can actually show. Data-quality warnings do not count as availability.
    public var hasMeaningfulData: Bool {
        rateLimitResetCredits != nil
            || preferredCodexLimit?.hasMeaningfulPresentationData == true
    }

    /// A malformed optional result must not discard valid usage, but it must
    /// remain distinguishable from a server that supplied no rate-limit data.
    static func malformedOuterResponse() -> Self {
        Self(
            rateLimits: nil,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil,
            decodingIssues: [malformedResponseIssue]
        )
    }

    /// Request 3 is optional across CLI versions. Preserve its failure as one
    /// bounded, nonfatal warning without exposing an arbitrary server message.
    static func failedOptionalRequest() -> Self {
        Self(
            rateLimits: nil,
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: nil,
            decodingIssues: [failedRequestIssue]
        )
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

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension CreditsSnapshot {
    var hasMeaningfulPresentationData: Bool {
        hasCredits != nil
            || unlimited == true
            || balance?.hasDisplayableContent == true
            || remaining != nil
            || used != nil
    }
}

private extension SpendControlLimitSnapshot {
    var hasMeaningfulPresentationData: Bool {
        limit?.hasDisplayableContent == true
            || used?.hasDisplayableContent == true
            || remainingPercent != nil
            || usedPercent != nil
            || resetsAt?.isPresentableUnixTimestamp == true
    }
}

private extension String {
    var hasDisplayableContent: Bool {
        unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !scalar.isUnsafeFormatCharacter
        }
    }
}

private extension Double {
    var isPresentableUnixTimestamp: Bool {
        isFinite && (0...253_402_300_799).contains(self)
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleInt64(forKey key: Key) throws -> Int64 {
        // JSONDecoder's Int64 and Double paths can round a fractional JSON number
        // into an integer before this code sees it (notably above 2^53). Decimal
        // preserves useful lexical precision and lets Int64 reject ordinary
        // fractions and out-of-range values before binary conversion. A generic
        // Decoder cannot expose a lexeme once Foundation has rounded beyond
        // Decimal precision; strict raw payload callers use UsageDecoding's Data
        // or Any entry points, which validate number-token provenance first.
        if let decimalValue = try? decode(Decimal.self, forKey: key),
           let intValue = Int64(NSDecimalNumber(decimal: decimalValue).stringValue) {
            return intValue
        }
        if let stringValue = try? decode(String.self, forKey: key), let intValue = Int64(stringValue) {
            return intValue
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected an Int64-compatible value."
            )
        )
    }

    fileprivate func decodeNonnegativeFlexibleInt64(forKey key: Key) throws -> Int64 {
        let value = try decodeFlexibleInt64(forKey: key)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a nonnegative count or duration."
            )
        }
        return value
    }

    fileprivate func decodeNonnegativeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeNonnegativeFlexibleInt64(forKey: key)
    }

    fileprivate func decodeNonnegativeIntIfPresent(forKey key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let value = try decodeNonnegativeFlexibleInt64(forKey: key)
        guard let result = Int(exactly: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Value does not fit in Int."
            )
        }
        return result
    }

    fileprivate func decodeLossyFlexibleIntIfPresent(
        forKey key: Key,
        issues: inout [String]
    ) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        do {
            let value = try decodeFlexibleInt64(forKey: key)
            guard let result = Int(exactly: value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: self,
                    debugDescription: "Value does not fit in Int."
                )
            }
            return result
        } catch {
            issues.append("\(key.stringValue): \(error.localizedDescription)")
            return nil
        }
    }

    fileprivate func decodeFiniteNonnegativeDouble(forKey key: Key) throws -> Double {
        let value = try decode(Double.self, forKey: key)
        guard value.isFinite, value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Expected a finite nonnegative number."
            )
        }
        return value
    }

    fileprivate func decodeFiniteNonnegativeDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeFiniteNonnegativeDouble(forKey: key)
    }

    fileprivate func decodeLossyIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        issues: inout [String]
    ) -> T? {
        guard contains(key) else { return nil }
        do {
            if try decodeNil(forKey: key) { return nil }
            return try decode(type, forKey: key)
        } catch {
            issues.append("\(key.stringValue): \(error.localizedDescription)")
            return nil
        }
    }

    fileprivate func decodeLossyFiniteNonnegativeDoubleIfPresent(
        forKey key: Key,
        issues: inout [String]
    ) -> Double? {
        guard contains(key) else { return nil }
        do {
            if try decodeNil(forKey: key) { return nil }
            return try decodeFiniteNonnegativeDouble(forKey: key)
        } catch {
            issues.append("\(key.stringValue): \(error.localizedDescription)")
            return nil
        }
    }
}
