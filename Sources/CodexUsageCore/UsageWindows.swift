import Foundation

public enum UsageWindows {
    private static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static func date(from bucketStartDate: String, timeZone: TimeZone = .current) -> Date? {
        dateFormatter(timeZone: timeZone).date(from: bucketStartDate)
    }

    public static func bucketStartString(for date: Date, timeZone: TimeZone = .current) -> String {
        dateFormatter(timeZone: timeZone).string(from: date)
    }

    public static func mergedDailyBuckets(_ buckets: [DailyUsageBucket]) -> [DailyUsageBucket] {
        let totals = buckets.reduce(into: [String: Int64]()) { result, bucket in
            result[bucket.startDate, default: 0] += bucket.tokens
        }
        return totals
            .map { DailyUsageBucket(startDate: $0.key, tokens: $0.value) }
            .sorted { $0.startDate < $1.startDate }
    }

    public static func bucketsInRollingWindow(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> [DailyUsageBucket] {
        guard days > 0 else { return [] }
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone

        let today = calendar.startOfDay(for: now)
        guard let lowerBound = calendar.date(byAdding: .day, value: -(days - 1), to: today),
              let upperBound = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let formatter = dateFormatter(timeZone: calendar.timeZone)
        return buckets.filter { bucket in
            guard let bucketDate = formatter.date(from: bucket.startDate) else { return false }
            return bucketDate >= lowerBound && bucketDate < upperBound
        }
    }

    public static func rollingTotal(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int64 {
        bucketsInRollingWindow(buckets: buckets, days: days, now: now, calendar: calendar)
            .reduce(Int64(0)) { $0 + $1.tokens }
    }

    public static func filledDailySeries(
        buckets: [DailyUsageBucket],
        days: Int = 30,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> [DailyUsageBucket] {
        guard days > 0 else { return [] }
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone

        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return []
        }

        let tokenByDate = Dictionary(
            uniqueKeysWithValues: mergedDailyBuckets(buckets).map { ($0.startDate, $0.tokens) }
        )
        let formatter = dateFormatter(timeZone: calendar.timeZone)
        return (0..<days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }
            let key = formatter.string(from: date)
            return DailyUsageBucket(startDate: key, tokens: tokenByDate[key] ?? 0)
        }
    }
}
