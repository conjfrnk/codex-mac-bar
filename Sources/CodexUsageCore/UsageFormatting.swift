import Foundation

public enum UsageFormatting {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func tokens(_ value: Int64) -> String {
        guard magnitude(of: value) >= 1_000 else { return "\(value)" }
        return abbreviated(value, axisStyle: false)
    }

    /// Like `tokens(_:)`, but trims trailing zeros for chart axis gridlines.
    /// Rounding is unit-aware: 999,999 is rendered as 1M, never 1000K.
    public static func axisTokens(_ value: Int64) -> String {
        guard magnitude(of: value) >= 1_000 else { return "\(value)" }
        return abbreviated(value, axisStyle: true)
    }

    public static func fullTokens(_ value: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        let value = value == 0 ? 0.0 : value
        let absolute = abs(value)
        if absolute >= 1_000_000_000 {
            return String(format: "%.1e%%", locale: posixLocale, value)
        }
        if value.rounded() == value {
            return String(format: "%.0f%%", locale: posixLocale, value)
        }
        let rendered = String(format: "%.1f", locale: posixLocale, value)
        return "\(rendered == "-0.0" ? "0.0" : rendered)%"
    }

    public static func duration(seconds: Int64?) -> String {
        guard let seconds, seconds >= 0 else { return "n/a" }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 { return "\(remainingSeconds)s" }
        return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
    }

    /// Formats the protocol's window duration without integer multiplication or
    /// DateComponents conversion, so nil, negative, and extreme public inputs are safe.
    public static func windowDuration(minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "n/a" }
        if minutes >= 1_440 {
            let days = minutes / 1_440
            let hours = (minutes % 1_440) / 60
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        return "\(minutes)m"
    }

    public static func relativeReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date,
              date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite
        else { return "n/a" }
        let delta = date.timeIntervalSinceReferenceDate - now.timeIntervalSinceReferenceDate
        guard delta.isFinite else { return "n/a" }
        let absolute = abs(delta)
        if absolute < 1 { return "now" }

        let unitSeconds = [1.0, 60.0, 3_600.0, 86_400.0]
        let suffixes = ["s", "m", "h", "d"]
        let promotionThresholds = [60.0, 60.0, 24.0]
        var unit = absolute < 60 ? 0 : (absolute < 3_600 ? 1 : (absolute < 86_400 ? 2 : 3))
        while unit < promotionThresholds.count,
              (absolute / unitSeconds[unit]).rounded() >= promotionThresholds[unit] {
            unit += 1
        }
        let quantity = absolute / unitSeconds[unit]
        guard quantity.isFinite else { return "n/a" }
        let amount = String(format: "%.0f%@", locale: posixLocale, quantity, suffixes[unit])
        return delta > 0 ? "in \(amount)" : "\(amount) ago"
    }

    private static func abbreviated(_ value: Int64, axisStyle: Bool) -> String {
        let sign = value < 0 ? "-" : ""
        let absolute = magnitude(of: value)
        let divisors: [Double] = [1, 1_000, 1_000_000, 1_000_000_000, 1_000_000_000_000]
        let suffixes = ["", "K", "M", "B", "T"]
        let tokenDigits = [0, 1, 1, 3, 2]
        var unit = min(Int(log10(absolute) / 3), suffixes.count - 1)

        while true {
            let scaled = absolute / divisors[unit]
            let digits = axisStyle ? 1 : (scaled >= 100 ? 0 : tokenDigits[unit])
            let rounded = rounded(scaled, fractionDigits: digits)
            if rounded >= 1_000, unit < suffixes.count - 1 {
                unit += 1
                continue
            }
            let number = formatted(rounded, fractionDigits: digits, trimZeros: axisStyle)
            return sign + number + suffixes[unit]
        }
    }

    private static func magnitude(of value: Int64) -> Double {
        abs(Double(value))
    }

    private static func rounded(_ value: Double, fractionDigits: Int) -> Double {
        let scale = pow(10, Double(fractionDigits))
        return (value * scale).rounded() / scale
    }

    private static func formatted(_ value: Double, fractionDigits: Int, trimZeros: Bool) -> String {
        var result = String(
            format: "%.*f",
            locale: posixLocale,
            fractionDigits,
            value
        )
        if trimZeros, result.contains(".") {
            while result.last == "0" { result.removeLast() }
            if result.last == "." { result.removeLast() }
        }
        return result
    }
}
