import Foundation

/// The result of merging daily buckets. Invalid public-construction inputs are
/// rejected, while positive `Int64` overflow saturates at `Int64.max`.
public struct UsageBucketMergeResult: Equatable, Sendable {
    public let buckets: [DailyUsageBucket]
    public let didOverflow: Bool
    public let overflowedStartDates: Set<String>
    public let rejectedBucketCount: Int

    public init(
        buckets: [DailyUsageBucket],
        didOverflow: Bool,
        overflowedStartDates: Set<String> = [],
        rejectedBucketCount: Int
    ) {
        self.buckets = buckets
        self.didOverflow = didOverflow
        self.overflowedStartDates = overflowedStartDates
        self.rejectedBucketCount = rejectedBucketCount
    }
}

/// A nonnegative token total. Overflow is observable and uses saturation rather
/// than trapping, which keeps public helpers safe for manually constructed data.
public struct UsageTokenTotal: Equatable, Sendable {
    public let value: Int64
    public let didOverflow: Bool

    public init(value: Int64, didOverflow: Bool) {
        self.value = value
        self.didOverflow = didOverflow
    }
}

/// A parsed, canonical proleptic-Gregorian civil date.
struct UsageCivilDate: Equatable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    /// Zero-based ordinal within the supported 0001...9999 range.
    var ordinal: Int64 {
        let precedingYears = Int64(year - 1)
        var result = (precedingYears * 365)
            + (precedingYears / 4)
            - (precedingYears / 100)
            + (precedingYears / 400)
        let precedingMonthDays = [0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        result += Int64(precedingMonthDays[month])
        if month > 2, Self.isLeapYear(year) {
            result += 1
        }
        return result + Int64(day - 1)
    }

    var canonicalString: String {
        let yearDigits = Self.padded(year, width: 4)
        let monthDigits = Self.padded(month, width: 2)
        let dayDigits = Self.padded(day, width: 2)
        return "\(yearDigits)-\(monthDigits)-\(dayDigits)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.ordinal < rhs.ordinal
    }

    static func parse(_ value: String) -> Self? {
        // Consume at most eleven bytes. Public callers can construct buckets
        // directly, so rejecting a hostile multi-megabyte date must not copy or
        // scan the whole string merely to learn that it is too long.
        var iterator = value.utf8.makeIterator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(10)
        for _ in 0..<10 {
            guard let byte = iterator.next() else { return nil }
            bytes.append(byte)
        }
        guard iterator.next() == nil,
              bytes[4] == 45,
              bytes[7] == 45,
              let year = decimal(bytes[0...3]),
              let month = decimal(bytes[5...6]),
              let day = decimal(bytes[8...9]),
              (1...9_999).contains(year),
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day)
        else { return nil }
        return Self(year: year, month: month, day: day)
    }

    static func fromOrdinal(_ ordinal: Int64) -> Self? {
        guard ordinal >= 0,
              ordinal <= Self(year: 9_999, month: 12, day: 31).ordinal
        else { return nil }

        // Find the last year whose January 1 is not after the target. A binary
        // search avoids relying on Foundation's historical Gregorian cutover.
        var lowerYear = 1
        var upperYear = 10_000
        while lowerYear + 1 < upperYear {
            let candidate = lowerYear + ((upperYear - lowerYear) / 2)
            let start = Self(year: candidate, month: 1, day: 1).ordinal
            if start <= ordinal {
                lowerYear = candidate
            } else {
                upperYear = candidate
            }
        }

        var month = 1
        while month < 12 {
            let nextMonthStart = Self(year: lowerYear, month: month + 1, day: 1).ordinal
            guard nextMonthStart <= ordinal else { break }
            month += 1
        }
        let monthStart = Self(year: lowerYear, month: month, day: 1).ordinal
        return Self(year: lowerYear, month: month, day: Int(ordinal - monthStart) + 1)
    }

    func addingOneDay() -> Self? {
        let monthDays = Self.daysInMonth(month, year: year)
        if day < monthDays {
            return Self(year: year, month: month, day: day + 1)
        }
        if month < 12 {
            return Self(year: year, month: month + 1, day: 1)
        }
        guard year < 9_999 else { return nil }
        return Self(year: year + 1, month: 1, day: 1)
    }

    func subtractingOneDay() -> Self? {
        if day > 1 {
            return Self(year: year, month: month, day: day - 1)
        }
        if month > 1 {
            let priorMonth = month - 1
            return Self(year: year, month: priorMonth, day: Self.daysInMonth(priorMonth, year: year))
        }
        guard year > 1 else { return nil }
        return Self(year: year - 1, month: 12, day: 31)
    }

    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
        var result = 0
        for byte in bytes {
            guard (48...57).contains(byte) else { return nil }
            result = (result * 10) + Int(byte - 48)
        }
        return result
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

public enum UsageWindows {
    /// Fixed-window chart series are deliberately bounded; app timeframes need
    /// at most 90 points, and huge public inputs otherwise risk excessive memory.
    public static let maximumDenseSeriesDayCount = 10_000
    public static let maximumSparseChartPointCount = 20_000

    public static func isCanonicalBucketStartDate(_ value: String) -> Bool {
        UsageCivilDate.parse(value) != nil
    }

    public static func date(from bucketStartDate: String, timeZone: TimeZone = .current) -> Date? {
        guard let civilDate = UsageCivilDate.parse(bucketStartDate) else { return nil }

        // Darwin Foundation's Gregorian calendar applies the 1582 Julian/Gregorian
        // cutover even when callers need a proleptic Gregorian date. Build the
        // absolute instant from our civil ordinal instead. Prefer local midnight;
        // if a zone skips midnight during an offset transition, local noon is a
        // stable representative. An entirely skipped civil day has no Date.
        return representativeDate(for: civilDate, localSecond: 0, timeZone: timeZone)
            ?? representativeDate(for: civilDate, localSecond: 12 * 60 * 60, timeZone: timeZone)
    }

    public static func bucketStartString(for date: Date, timeZone: TimeZone = .current) -> String {
        guard let civilDate = civilDate(for: date, timeZone: timeZone) else { return "" }
        return civilDate.canonicalString
    }

    public static func mergedDailyBuckets(_ buckets: [DailyUsageBucket]) -> [DailyUsageBucket] {
        mergedDailyBucketsReportingOverflow(buckets).buckets
    }

    public static func mergedDailyBucketsReportingOverflow(
        _ buckets: [DailyUsageBucket]
    ) -> UsageBucketMergeResult {
        var totals: [String: Int64] = [:]
        var didOverflow = false
        var overflowedStartDates = Set<String>()
        var rejectedBucketCount = 0

        for bucket in buckets {
            guard UsageCivilDate.parse(bucket.startDate) != nil, bucket.tokens >= 0 else {
                rejectedBucketCount += 1
                continue
            }
            let existing = totals[bucket.startDate, default: 0]
            let (sum, overflow) = existing.addingReportingOverflow(bucket.tokens)
            if overflow {
                totals[bucket.startDate] = .max
                didOverflow = true
                overflowedStartDates.insert(bucket.startDate)
            } else {
                totals[bucket.startDate] = sum
            }
        }

        let merged = totals
            .map { DailyUsageBucket(startDate: $0.key, tokens: $0.value) }
            .sorted { $0.startDate < $1.startDate }
        return UsageBucketMergeResult(
            buckets: merged,
            didOverflow: didOverflow,
            overflowedStartDates: overflowedStartDates,
            rejectedBucketCount: rejectedBucketCount
        )
    }

    public static func bucketsInRollingWindow(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> [DailyUsageBucket] {
        guard days > 0,
              now.timeIntervalSinceReferenceDate.isFinite,
              let today = civilDate(for: now, timeZone: inputCalendar.timeZone),
              let dayOffset = Int64(exactly: days - 1)
        else { return [] }
        let lowerResult = today.ordinal.subtractingReportingOverflow(dayOffset)
        let lowerOrdinal = lowerResult.overflow ? Int64.min : lowerResult.partialValue
        let upperOrdinal = today.ordinal

        return buckets.filter { bucket in
            guard bucket.tokens >= 0,
                  let ordinal = UsageCivilDate.parse(bucket.startDate)?.ordinal
            else { return false }
            return ordinal >= lowerOrdinal && ordinal <= upperOrdinal
        }
    }

    public static func rollingTotal(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int64 {
        rollingTotalReportingOverflow(buckets: buckets, days: days, now: now, calendar: calendar).value
    }

    public static func rollingTotalReportingOverflow(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageTokenTotal {
        saturatingTotal(
            bucketsInRollingWindow(buckets: buckets, days: days, now: now, calendar: calendar)
        )
    }

    public static func filledDailySeries(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> [DailyUsageBucket] {
        guard days > 0,
              days <= maximumDenseSeriesDayCount,
              now.timeIntervalSinceReferenceDate.isFinite,
              let today = civilDate(for: now, timeZone: inputCalendar.timeZone),
              let dayOffset = Int64(exactly: days - 1),
              today.ordinal >= dayOffset
        else { return [] }
        let firstOrdinal = today.ordinal - dayOffset

        let tokenByDate = Dictionary(
            uniqueKeysWithValues: mergedDailyBuckets(buckets).map { ($0.startDate, $0.tokens) }
        )
        var result: [DailyUsageBucket] = []
        result.reserveCapacity(days)
        for offset in 0..<days {
            guard let ordinalOffset = Int64(exactly: offset),
                  let civilDate = UsageCivilDate.fromOrdinal(firstOrdinal + ordinalOffset)
            else { return [] }
            let key = civilDate.canonicalString
            result.append(DailyUsageBucket(startDate: key, tokens: tokenByDate[key] ?? 0))
        }
        return result
    }

    /// Inserts at most two zero-valued boundary points per civil-date gap, plus
    /// trailing idle boundaries through today. Memory therefore depends on the
    /// source bucket count, never on the number of omitted calendar years.
    public static func sparseDailyChartSeries(
        buckets: [DailyUsageBucket],
        through now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> [DailyUsageBucket] {
        let source = mergedDailyBuckets(buckets)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let first = source.first,
              var previousDate = UsageCivilDate.parse(first.startDate)
        else { return [] }

        var result: [DailyUsageBucket] = []
        let reserve = source.count.multipliedReportingOverflow(by: 3)
        if !reserve.overflow {
            result.reserveCapacity(min(reserve.partialValue, maximumSparseChartPointCount))
        }

        func append(_ bucket: DailyUsageBucket) {
            if result.last?.startDate == bucket.startDate {
                result[result.count - 1] = bucket
            } else {
                if result.count >= maximumSparseChartPointCount {
                    result = boundedChartSeries(
                        result,
                        limit: maximumSparseChartPointCount / 2
                    )
                }
                result.append(bucket)
            }
        }

        append(first)
        for bucket in source.dropFirst() {
            guard let currentDate = UsageCivilDate.parse(bucket.startDate) else { continue }
            let gap = currentDate.ordinal - previousDate.ordinal
            if gap > 1, let afterPrevious = previousDate.addingOneDay() {
                append(DailyUsageBucket(startDate: afterPrevious.canonicalString, tokens: 0))
                if gap > 2, let beforeCurrent = currentDate.subtractingOneDay() {
                    append(DailyUsageBucket(startDate: beforeCurrent.canonicalString, tokens: 0))
                }
            }
            append(bucket)
            previousDate = currentDate
        }

        if let today = civilDate(for: now, timeZone: inputCalendar.timeZone) {
            let trailingGap = today.ordinal - previousDate.ordinal
            if trailingGap > 0, let next = previousDate.addingOneDay() {
                append(DailyUsageBucket(startDate: next.canonicalString, tokens: 0))
                if trailingGap > 1 {
                    append(DailyUsageBucket(startDate: today.canonicalString, tokens: 0))
                }
            }
        }
        return boundedChartSeries(result, limit: maximumSparseChartPointCount)
    }

    private static let unixEpochOrdinal = UsageCivilDate(
        year: 1970,
        month: 1,
        day: 1
    ).ordinal

    private static func civilDate(for date: Date, timeZone: TimeZone) -> UsageCivilDate? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return nil }
        let localSeconds = seconds + Double(timeZone.secondsFromGMT(for: date))
        guard localSeconds.isFinite else { return nil }
        let dayOffset = floor(localSeconds / 86_400)

        let minimumOffset = -Double(unixEpochOrdinal)
        let maximumOffset = Double(
            UsageCivilDate(year: 9_999, month: 12, day: 31).ordinal - unixEpochOrdinal
        )
        guard dayOffset >= minimumOffset, dayOffset <= maximumOffset else { return nil }
        return UsageCivilDate.fromOrdinal(unixEpochOrdinal + Int64(dayOffset))
    }

    private static func representativeDate(
        for civilDate: UsageCivilDate,
        localSecond: Int,
        timeZone: TimeZone
    ) -> Date? {
        let dayOffset = civilDate.ordinal - unixEpochOrdinal
        let nominalSeconds = (Double(dayOffset) * 86_400) + Double(localSecond)

        // Collect offsets around the target and through fixed-point refinement.
        // This covers ordinary DST transitions and large international-date-line
        // moves without assuming a fixed or current offset.
        var offsets = Set<Int>()
        for probe in [-172_800.0, -86_400, 0, 86_400, 172_800] {
            let date = Date(timeIntervalSince1970: nominalSeconds + probe)
            offsets.insert(timeZone.secondsFromGMT(for: date))
        }
        var candidate = Date(timeIntervalSince1970: nominalSeconds)
        for _ in 0..<8 {
            let offset = timeZone.secondsFromGMT(for: candidate)
            offsets.insert(offset)
            candidate = Date(timeIntervalSince1970: nominalSeconds - Double(offset))
        }

        return offsets
            .map { Date(timeIntervalSince1970: nominalSeconds - Double($0)) }
            .filter { self.civilDate(for: $0, timeZone: timeZone) == civilDate }
            .min()
    }

    static func saturatingTotal(_ buckets: [DailyUsageBucket]) -> UsageTokenTotal {
        var total: Int64 = 0
        var didOverflow = false
        for bucket in buckets where bucket.tokens >= 0 {
            let (sum, overflow) = total.addingReportingOverflow(bucket.tokens)
            if overflow {
                total = .max
                didOverflow = true
            } else {
                total = sum
            }
        }
        return UsageTokenTotal(value: total, didOverflow: didOverflow)
    }

    /// Min/max binning retains endpoints, local zero gaps, and local peaks while
    /// keeping adversarially large public chart inputs within a fixed memory budget.
    private static func boundedChartSeries(
        _ buckets: [DailyUsageBucket],
        limit: Int
    ) -> [DailyUsageBucket] {
        guard limit >= 2, buckets.count > limit else { return buckets }
        let lastIndex = buckets.count - 1
        let interiorCount = lastIndex - 1
        let binCount = max(1, (limit - 2) / 2)
        var result: [DailyUsageBucket] = []
        result.reserveCapacity(limit)
        result.append(buckets[0])

        for bin in 0..<binCount {
            let start = 1 + ((bin * interiorCount) / binCount)
            let end = 1 + (((bin + 1) * interiorCount) / binCount)
            guard start < end else { continue }
            var minimumIndex = start
            var maximumIndex = start
            for index in (start + 1)..<end {
                if buckets[index].tokens < buckets[minimumIndex].tokens {
                    minimumIndex = index
                }
                if buckets[index].tokens > buckets[maximumIndex].tokens {
                    maximumIndex = index
                }
            }
            for index in [minimumIndex, maximumIndex].sorted()
                where result.last?.startDate != buckets[index].startDate {
                result.append(buckets[index])
            }
        }
        if result.last?.startDate != buckets[lastIndex].startDate {
            result.append(buckets[lastIndex])
        }
        return result
    }
}
