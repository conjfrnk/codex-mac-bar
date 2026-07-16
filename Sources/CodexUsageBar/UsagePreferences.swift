import CodexUsageCore
import Darwin
import Foundation

enum UsagePreferences {
    static let selectedTimeframeKey = "selectedTimeframe"
    static let codexExecutablePathKey = "codexExecutablePath"
    static let codexExecutableEnvironmentKey = "CODEX_USAGE_BAR_CODEX_PATH"

    typealias EnvironmentSetter = (_ key: String, _ value: String) -> Void

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

    /// Applies a previously validated user selection before the first request is
    /// started. If the executable has since moved or lost execute permission,
    /// discard only our stale preference and leave any caller-provided process
    /// environment override untouched so the core resolver can still fall back.
    @discardableResult
    static func applyPersistedCodexExecutable(
        preferences: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setEnvironment: EnvironmentSetter = setProcessEnvironment
    ) -> Bool {
        guard let path = preferences.string(forKey: codexExecutablePathKey),
              isExecutableRegularFile(at: URL(fileURLWithPath: path))
        else {
            preferences.removeObject(forKey: codexExecutablePathKey)
            return false
        }
        // A process-level override is more explicit than a saved UI choice and
        // is particularly useful for hermetic diagnostics and troubleshooting.
        if environment[codexExecutableEnvironmentKey]?.isEmpty == false {
            return false
        }
        setEnvironment(codexExecutableEnvironmentKey, path)
        return true
    }

    /// Validates without launching the selected binary, then persists and applies
    /// the exact standardized path used by the app-server resolver.
    @discardableResult
    static func setCodexExecutable(
        _ url: URL,
        preferences: UserDefaults = .standard,
        setEnvironment: EnvironmentSetter = setProcessEnvironment
    ) throws -> String {
        let standardizedURL = url.standardizedFileURL
        guard isExecutableRegularFile(at: standardizedURL) else {
            throw CodexExecutablePreferenceError.notExecutableRegularFile
        }
        let path = standardizedURL.path
        preferences.set(path, forKey: codexExecutablePathKey)
        setEnvironment(codexExecutableEnvironmentKey, path)
        return path
    }

    static func isExecutableRegularFile(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
            && fileManager.isExecutableFile(atPath: url.path)
    }

    private static func setProcessEnvironment(key: String, value: String) {
        Darwin.setenv(key, value, 1)
    }
}

enum CodexExecutablePreferenceError: Error, LocalizedError {
    case notExecutableRegularFile

    var errorDescription: String? {
        "The selected item is not an executable regular file."
    }
}
