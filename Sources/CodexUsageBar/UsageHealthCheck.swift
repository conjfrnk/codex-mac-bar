import CodexUsageCore
import Dispatch
import Foundation

enum UsageHealthCheckError: Error, CustomStringConvertible, Equatable {
    case invalidArguments
    case timedOut
    case missingResult

    var description: String {
        switch self {
        case .invalidArguments:
            return "--check must be used by itself"
        case .timedOut:
            return "Codex app-server diagnostic timed out"
        case .missingResult:
            return "Codex app-server diagnostic returned no result"
        }
    }
}

enum UsageHealthCheck {
    typealias Fetch = @Sendable () async throws -> UsageSnapshot
    typealias Output = (String) -> Void

    /// Formats the process boundary's only failure output. Keep this separate
    /// from the fetch path so even resolver errors containing configured paths
    /// pass through the same bounded credential redaction as UI diagnostics.
    static func failureLine(for error: Error) -> String {
        "FAIL \(UserFacingErrorMessage.clean(error, maximumUnicodeScalars: 240))"
    }

    /// Runs a deliberately narrow, headless connectivity diagnostic. Output
    /// describes capabilities only: account totals and rate-limit values never
    /// leave the fetched snapshot.
    static func runIfRequested(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        waitTimeout: TimeInterval = 22,
        fetch: @escaping Fetch = {
            try await CodexAppServerClient(timeout: 20).fetchUsageSnapshot()
        },
        output: Output = { print($0) }
    ) throws -> Bool {
        guard arguments.contains("--check") else { return false }
        guard arguments == ["--check"] else {
            throw UsageHealthCheckError.invalidArguments
        }

        let snapshot = try fetchSynchronously(
            waitTimeout: waitTimeout,
            fetch: fetch
        ).get()
        let rateLimitStatus = snapshot.rateLimits?.hasMeaningfulData == true
            ? "available"
            : "unavailable"
        output(
            "PASS Codex app-server connection; usage available; "
                + "rate limits \(rateLimitStatus)"
        )
        return true
    }

    private static func fetchSynchronously(
        waitTimeout: TimeInterval,
        fetch: @escaping Fetch
    ) throws -> Result<UsageSnapshot, Error> {
        let resultBox = HealthCheckResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            do {
                resultBox.store(.success(try await fetch()))
            } catch {
                resultBox.store(.failure(error))
            }
            semaphore.signal()
        }

        let boundedTimeout = waitTimeout.isFinite
            ? min(max(waitTimeout, 0.01), 300)
            : 22
        guard semaphore.wait(timeout: .now() + boundedTimeout) == .success else {
            task.cancel()
            throw UsageHealthCheckError.timedOut
        }
        guard let result = resultBox.take() else {
            throw UsageHealthCheckError.missingResult
        }
        return result
    }
}

private final class HealthCheckResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UsageSnapshot, Error>?

    func store(_ result: Result<UsageSnapshot, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<UsageSnapshot, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
