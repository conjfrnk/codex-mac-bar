import Foundation

public enum UsageFormatting {
    public static func tokens(_ value: Int64) -> String {
        let absValue = abs(Double(value))
        let sign = value < 0 ? "-" : ""

        switch absValue {
        case 0..<1_000:
            return "\(value)"
        case 1_000..<1_000_000:
            return sign + compact(absValue / 1_000, suffix: "K", maximumFractionDigits: 1)
        case 1_000_000..<1_000_000_000:
            return sign + compact(absValue / 1_000_000, suffix: "M", maximumFractionDigits: 1)
        case 1_000_000_000..<1_000_000_000_000:
            return sign + compact(absValue / 1_000_000_000, suffix: "B", maximumFractionDigits: 3)
        default:
            return sign + compact(absValue / 1_000_000_000_000, suffix: "T", maximumFractionDigits: 2)
        }
    }

    public static func fullTokens(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func percent(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return String(format: "%.1f%%", value)
    }

    public static func duration(seconds: Int64?) -> String {
        guard let seconds else { return "n/a" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    public static func relativeReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "n/a" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func compact(_ value: Double, suffix: String, maximumFractionDigits: Int) -> String {
        let digits = value >= 100 ? 0 : maximumFractionDigits
        let format = digits == 0 ? "%.0f%@" : "%.\(digits)f%@"
        return String(format: format, value, suffix)
    }
}
