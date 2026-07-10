import CodexUsageCore
import Foundation

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

    private let client: UsageFetching
    private var refreshTask: Task<Void, Never>?

    init(client: UsageFetching, initialSnapshot: UsageSnapshot? = nil) {
        self.client = client
        snapshot = initialSnapshot
        if initialSnapshot != nil {
            state = .loaded
        }
    }

    var statusTitle: String {
        if let snapshot {
            let range = UsageRange(timeframe: UsagePreferences.selectedTimeframe, sourceBuckets: snapshot.sortedBuckets)
            return UsageFormatting.tokens(range.totalTokens)
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

    var lastError: String? {
        if case let .failed(message) = state {
            return message
        }
        return nil
    }

    func shouldRefresh(maxAge: TimeInterval) -> Bool {
        if refreshTask != nil {
            return false
        }
        guard let fetchedAt = snapshot?.fetchedAt else {
            return true
        }
        return Date().timeIntervalSince(fetchedAt) >= maxAge
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

    private func refreshNow() async {
        state = .loading
        do {
            snapshot = try await client.fetchUsageSnapshot()
            state = .loaded
        } catch {
            snapshot = nil
            state = .failed(Self.cleanErrorMessage(error))
        }
    }

    private static func cleanErrorMessage(_ error: Error) -> String {
        let message = String(describing: error)
        if message.count <= 240 {
            return message
        }
        return String(message.prefix(237)) + "..."
    }
}
