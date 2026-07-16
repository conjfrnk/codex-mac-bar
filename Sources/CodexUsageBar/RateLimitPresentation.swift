import CodexUsageCore
import Foundation

enum RateLimitPresentation {
    static func hasDataQualityIssues(_ response: AccountRateLimitsResponse?) -> Bool {
        response?.decodingIssues.isEmpty == false
    }

    static func resetDescription(
        timestamp: Double?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let date = resetDate(timestamp: timestamp)
        else { return "reset unavailable" }
        let interval = date.timeIntervalSince(now)
        if abs(interval) < 1 { return "resets now" }
        let relative = relativeReset(
            timestamp: timestamp,
            now: now,
            calendar: calendar,
            locale: locale
        )
        guard relative != "n/a" else { return "reset unavailable" }
        // A stale-but-still-open menu can cross the reset boundary. Keep the
        // surrounding verb in the same tense as the formatter's relative value.
        if interval < 0, relative != "now" {
            return "reset \(relative)"
        }
        return "resets \(relative)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "n/a" }
        return UsageFormatting.percent(value)
    }

    static func progress(_ value: Double?) -> Double {
        guard let value = validPercent(value) else { return 0 }
        return min(max(value, 0), 100)
    }

    static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func credits(_ snapshot: CreditsSnapshot) -> String {
        if snapshot.unlimited == true { return "Unlimited" }
        if snapshot.hasCredits == false { return "None" }
        if let balance = snapshot.balance {
            let sanitizedBalance = amount(balance)
            if sanitizedBalance != "n/a" { return sanitizedBalance }
        }
        if snapshot.hasCredits == true { return "Available" }
        let remaining = snapshot.remaining.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let total = snapshot.total.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let used = snapshot.used.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let remaining, let total, remaining <= total,
           let remainingText = finiteNonnegativeDecimal(remaining),
           let totalText = finiteNonnegativeDecimal(total) {
            return "\(remainingText) / \(totalText) remaining"
        }
        if let remaining, total == nil,
           let remainingText = finiteNonnegativeDecimal(remaining) {
            return "\(remainingText) remaining"
        }
        if let used, let total, used <= total,
           let usedText = finiteNonnegativeDecimal(used),
           let totalText = finiteNonnegativeDecimal(total) {
            return "\(usedText) / \(totalText) used"
        }
        if let used, let usedText = finiteNonnegativeDecimal(used) {
            return "\(usedText) used"
        }
        if let remaining, let remainingText = finiteNonnegativeDecimal(remaining) {
            // Preserve the independently valid field without presenting an
            // inconsistent remaining/total pair as meaningful.
            return "\(remainingText) remaining"
        }
        return "n/a"
    }

    private static func finiteNonnegativeDecimal(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        if value < Double(Int64.max), value.rounded(.towardZero) == value {
            return String(Int64(value))
        }
        return String(
            format: "%.15g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    static func amount(_ value: String?) -> String {
        text(value)
    }

    static func limitReachedStatus(_ value: String?) -> String? {
        guard value != nil else { return nil }
        let sanitized = text(value)
        return sanitized == "n/a" ? "Reported" : sanitized
    }

    static func text(_ value: String?) -> String {
        guard let value else { return "n/a" }
        return BoundedDisplayText.clean(
            value,
            maximumUnicodeScalars: 64,
            emptyFallback: "n/a"
        )
    }

    static func windowDuration(minutes: Int?) -> String {
        UsageFormatting.windowDuration(minutes: minutes)
    }

    static func relativeReset(
        timestamp: Double?,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return "n/a" }
        guard let date = resetDate(timestamp: timestamp) else { return "n/a" }
        let formatter = RelativeDateTimeFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func resetDate(timestamp: Double?) -> Date? {
        // The app-server contract defines Unix seconds. Do not silently reinterpret
        // large but valid values as milliseconds.
        guard let seconds = timestamp, seconds.isFinite else { return nil }
        // Foundation formatters are not useful outside the civil Date range.
        guard (0...253_402_300_799).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
