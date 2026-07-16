import Combine
import CodexUsageCore
import Foundation

/// Selects the values that can honestly be presented for a timeframe. An absent
/// `dailyUsageBuckets` field means "the server did not provide daily data", which
/// is different from a present, empty (or all-zero) series.
struct UsageDisplaySelection {
    let range: UsageRange
    let hasDailyData: Bool
    let hasUnrepresentableTotal: Bool
    let hasSaturatedDailyValues: Bool
    let hasUnreconciledAllTimeTotal: Bool
    let isDailyHistoryPartial: Bool
    let totalTokens: Int64?
    let averageDailyTokens: Int64?
    let peakDailyTokens: Int64?
    let activeDays: Int?

    init(
        snapshot: UsageSnapshot,
        timeframe: UsageTimeframe,
        now: Date,
        calendar: Calendar
    ) {
        hasDailyData = snapshot.usage.dailyUsageBuckets != nil
        range = UsageRange(
            timeframe: timeframe,
            sourceBuckets: snapshot.usage.dailyUsageBuckets ?? [],
            now: now,
            calendar: calendar
        )
        hasUnrepresentableTotal = range.didOverflow
        hasSaturatedDailyValues = range.mergeDidOverflow

        // Saturated Int64 values are safe implementation bounds, not exact usage.
        // Never expose them as exact hero/average/peak metrics.
        let dailyTotal = hasDailyData && !hasUnrepresentableTotal ? range.totalTokens : nil
        let dailyPeak = hasDailyData && !hasSaturatedDailyValues ? range.peakDailyTokens : nil
        if timeframe == .all {
            let lifetime = snapshot.usage.summary.lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil }
            let summaryPeak = snapshot.usage.summary.peakDailyTokens.flatMap { $0 >= 0 ? $0 : nil }
            let combinedPeak = [summaryPeak, dailyPeak].compactMap { $0 }.max()
            // Summary fields cover history that may precede the available daily
            // buckets, but malformed/stale summaries must never understate the
            // concrete daily series shown directly below the hero value.
            if hasUnrepresentableTotal {
                totalTokens = nil
                peakDailyTokens = hasSaturatedDailyValues
                    ? nil
                    : combinedPeak
                // The lifetime total cannot be compared with a saturated sum,
                // but an exact peak summary can still prove that otherwise
                // exact visible daily history is incomplete.
                isDailyHistoryPartial = hasDailyData && !hasSaturatedDailyValues
                    && (summaryPeak.map { $0 > (dailyPeak ?? 0) } ?? false)
            } else {
                peakDailyTokens = combinedPeak
                isDailyHistoryPartial = hasDailyData && (
                    (lifetime.map { $0 > (dailyTotal ?? 0) } ?? false)
                        || (summaryPeak.map { $0 > (dailyPeak ?? 0) } ?? false)
                )
                let candidateTotal: Int64?
                if isDailyHistoryPartial {
                    // A concrete daily series is a subset when a summary proves
                    // earlier activity exists. Only a strictly larger lifetime
                    // total can then be exact; the visible subset sum cannot.
                    candidateTotal = lifetime.flatMap { value -> Int64? in
                        guard let dailyTotal, value > dailyTotal else { return nil }
                        return value
                    }
                } else {
                    candidateTotal = [lifetime, dailyTotal].compactMap { $0 }.max()
                }
                // A total below a claimed peak is impossible. Prefer an honest
                // unavailable total over independently trusting contradictory
                // summary fields.
                totalTokens = candidateTotal.flatMap { value -> Int64? in
                    guard combinedPeak.map({ value >= $0 }) ?? true else { return nil }
                    return value
                }
            }
        } else {
            totalTokens = dailyTotal
            peakDailyTokens = dailyPeak
            isDailyHistoryPartial = false
        }
        hasUnreconciledAllTimeTotal = timeframe == .all
            && !hasUnrepresentableTotal
            && totalTokens == nil
            && (hasDailyData
                || snapshot.usage.summary.lifetimeTokens != nil
                || snapshot.usage.summary.peakDailyTokens != nil)
        averageDailyTokens = hasDailyData && !hasUnrepresentableTotal && !isDailyHistoryPartial
            ? range.averageDailyTokens
            : nil
        activeDays = hasDailyData && !isDailyHistoryPartial ? range.activeDays : nil
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var menuSessionID = UUID()

    private let client: UsageFetching
    private let selectedTimeframe: () -> UsageTimeframe
    private let now: () -> Date
    private let calendar: Calendar
    private let locale: Locale
    private var refreshTask: Task<Void, Never>?

    init(
        client: UsageFetching,
        initialSnapshot: UsageSnapshot? = nil,
        initialState: LoadState? = nil,
        selectedTimeframe: @escaping () -> UsageTimeframe = { UsagePreferences.selectedTimeframe },
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.client = client
        self.selectedTimeframe = selectedTimeframe
        self.now = now
        self.calendar = calendar
        self.locale = locale
        snapshot = initialSnapshot
        state = initialState ?? (initialSnapshot == nil ? .idle : .loaded)
    }

    var statusTitle: String {
        if let snapshot {
            let selection = UsageDisplaySelection(
                snapshot: snapshot,
                timeframe: selectedTimeframe(),
                now: now(),
                calendar: calendar
            )
            let value = selection.totalTokens.map(UsageFormatting.tokens) ?? "n/a"
            return isShowingStaleSnapshot ? "\(value) !" : value
        }

        switch state {
        case .loading:
            return "Codex ..."
        case .failed:
            return "Codex ?"
        case .idle, .loaded:
            return "Codex"
        }
    }

    var statusAccessibilityValue: String {
        Self.accessibilityStatus(
            snapshot: snapshot,
            state: state,
            selectedTimeframe: selectedTimeframe(),
            now: now(),
            calendar: calendar,
            locale: locale
        )
    }

    static func accessibilityStatus(
        snapshot: UsageSnapshot?,
        state: LoadState,
        selectedTimeframe: UsageTimeframe,
        now: Date,
        calendar: Calendar,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        if let snapshot {
            let selection = UsageDisplaySelection(
                snapshot: snapshot,
                timeframe: selectedTimeframe,
                now: now,
                calendar: calendar
            )
            let tokens = selection.totalTokens.map {
                "\(UsageFormatting.fullTokens($0, locale: locale)) tokens"
            } ?? "Token total unavailable"
            let scopedTokens = "\(tokens), \(selectedTimeframe.heroTitle.lowercased())"
            let overflowWarning = selection.hasUnrepresentableTotal
                ? " Daily total exceeds the supported range."
                : ""
            let summaryWarning = selection.hasUnreconciledAllTimeTotal
                ? " All-time total is unavailable because summary data could not be reconciled."
                : ""
            if case .failed = state {
                return "\(scopedTokens).\(overflowWarning)\(summaryWarning) Showing last successful usage; refresh failed."
            }
            if case .loading = state {
                return "\(scopedTokens).\(overflowWarning)\(summaryWarning) Refreshing usage."
            }
            let warnings = overflowWarning + summaryWarning
            return warnings.isEmpty ? scopedTokens : "\(scopedTokens).\(warnings)"
        }
        switch state {
        case .loading:
            return "Loading Codex usage"
        case .failed:
            return "Codex usage unavailable"
        case .idle, .loaded:
            return "Codex usage not loaded"
        }
    }

    var lastError: String? {
        if case let .failed(message) = state {
            return message
        }
        return nil
    }

    var isShowingStaleSnapshot: Bool {
        snapshot != nil && lastError != nil
    }

    func shouldRefresh(maxAge: TimeInterval, now override: Date? = nil) -> Bool {
        if refreshTask != nil {
            return false
        }
        guard let fetchedAt = snapshot?.fetchedAt else {
            return true
        }
        let age = (override ?? now()).timeIntervalSince(fetchedAt)
        guard age.isFinite, maxAge.isFinite, maxAge >= 0 else { return true }
        // A wall-clock rollback makes a previously fetched snapshot appear to be
        // from the future. Treat it as stale instead of suppressing refresh until
        // the clock eventually catches up.
        return age < 0 || age >= maxAge
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
            self.refreshTask = nil
        }
    }

    func timeframePreferenceChanged() {
        objectWillChange.send()
    }

    func beginMenuSession() {
        menuSessionID = UUID()
    }

    func refreshNow() async {
        state = .loading
        do {
            snapshot = try await client.fetchUsageSnapshot()
            state = .loaded
        } catch is CancellationError {
            state = snapshot == nil ? .idle : .loaded
        } catch {
            state = .failed(Self.cleanErrorMessage(error))
        }
    }

    private static func cleanErrorMessage(_ error: Error) -> String {
        UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 240)
    }
}

/// Keeps arbitrary error descriptions safe and bounded before placing them in
/// the menu. `String.count` counts extended grapheme clusters, so an attacker can
/// otherwise hide thousands of combining scalars inside one apparent character.
enum UserFacingErrorMessage {
    static func clean(_ error: Error, maximumUnicodeScalars: Int) -> String {
        let redacted = DiagnosticSanitizer.clean(
            String(describing: error),
            maxCharacters: 4_096,
            maxUTF8Bytes: 16 * 1_024
        )
        return BoundedDisplayText.clean(
            redacted,
            maximumUnicodeScalars: maximumUnicodeScalars,
            emptyFallback: "Unknown error"
        )
    }
}

/// Normalizes untrusted single-line text without allocating from attacker-sized
/// input. Unicode line/paragraph separators are in `CharacterSet.newlines`, but
/// not in `controlCharacters` on macOS, so all whitespace is collapsed explicitly.
enum BoundedDisplayText {
    static func clean(
        _ value: String,
        maximumUnicodeScalars: Int,
        emptyFallback: String
    ) -> String {
        // Current callers use modest presentation limits. Cap arbitrary internal
        // calls as well so a hostile size cannot turn reserve capacity into an
        // allocation attack.
        let limit = min(max(0, maximumUnicodeScalars), 4_096)
        guard limit > 0 else { return "" }

        let suffixScalars = Array("...".unicodeScalars.prefix(limit))
        let inspectionLimit = max(256, limit * 8)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(limit)
        var pendingSpace = false
        var truncated = false
        var inspectedScalarCount = 0

        for scalar in value.unicodeScalars {
            guard inspectedScalarCount < inspectionLimit else {
                truncated = true
                break
            }
            inspectedScalarCount += 1
            let isUnsafe = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isUnsafe {
                pendingSpace = !output.isEmpty
                continue
            }

            if pendingSpace {
                guard output.count < limit else {
                    truncated = true
                    break
                }
                output.append(" ")
                pendingSpace = false
            }
            guard output.count < limit else {
                truncated = true
                break
            }
            output.append(scalar)
        }

        if output.isEmpty {
            return String(emptyFallback.unicodeScalars.prefix(limit))
        }
        if truncated {
            while output.count > limit - suffixScalars.count { output.removeLast() }
            while output.last == " " { output.removeLast() }
            output.append(contentsOf: suffixScalars)
        }
        return String(output)
    }
}
