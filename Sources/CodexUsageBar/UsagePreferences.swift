import CodexUsageCore
import Foundation

enum UsagePreferences {
    static let selectedTimeframeKey = "selectedTimeframe"

    static var selectedTimeframe: UsageTimeframe {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: selectedTimeframeKey) else {
                return .thirty
            }
            return UsageTimeframe(rawValue: rawValue) ?? .thirty
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedTimeframeKey)
        }
    }
}
