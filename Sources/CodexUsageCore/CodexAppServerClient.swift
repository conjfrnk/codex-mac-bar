import Foundation

public struct CodexAppServerClient: UsageFetching {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public func fetchUsageSnapshot() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try Self.fetchSynchronously(timeout: timeout)
        }.value
    }

    private static func fetchSynchronously(timeout: TimeInterval) throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = try CodexCLIResolver.resolve()
        process.arguments = ["app-server", "--stdio"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = AppServerResponseCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            if process.isRunning {
                process.terminate()
                if !process.waitUntilExit(timeout: 2) {
                    process.interrupt()
                }
            }
        }

        let writer = stdin.fileHandleForWriting
        try write(["method": "initialize", "id": 1, "params": [
            "clientInfo": [
                "name": "codex-usage-bar",
                "title": "Codex Usage Bar",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            ],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false
            ]
        ]], to: writer)

        let initializeDeadline = Date().addingTimeInterval(min(5, timeout))
        while Date() < initializeDeadline {
            if collector.didInitialize {
                break
            }
            if let error = collector.firstError {
                throw CodexAppServerError.server(error)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard collector.didInitialize else {
            throw CodexAppServerError.initializeTimeout
        }

        try write(["method": "initialized"], to: writer)
        try write(["method": "account/usage/read", "id": 2, "params": NSNull()], to: writer)
        try write(["method": "account/rateLimits/read", "id": 3, "params": NSNull()], to: writer)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if collector.isComplete {
                break
            }
            if collector.hasError {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return try collector.snapshot(fetchedAt: Date())
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}

private final class AppServerResponseCollector: @unchecked Sendable {
    private static let maxMessageBytes = 2 * 1024 * 1024
    private static let maxStoredErrors = 8

    private let lock = NSLock()
    private var buffer = Data()
    private var initialized = false
    private var usage: AccountTokenUsageResponse?
    private var rateLimits: AccountRateLimitsResponse?
    private var rateLimitsResolved = false
    private var errors: [String] = []

    var didInitialize: Bool {
        lock.withLock {
            initialized
        }
    }

    var firstError: String? {
        lock.withLock {
            errors.first
        }
    }

    var hasError: Bool {
        lock.withLock {
            !errors.isEmpty
        }
    }

    var isComplete: Bool {
        lock.withLock {
            usage != nil && rateLimitsResolved
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard errors.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.count <= Self.maxMessageBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    recordError("Codex app-server returned an oversized message.")
                    return
                }
                parseLine(line)
                if !errors.isEmpty {
                    buffer.removeAll(keepingCapacity: false)
                    return
                }
            }
            if buffer.count > Self.maxMessageBytes {
                buffer.removeAll(keepingCapacity: false)
                recordError("Codex app-server returned an oversized message.")
            }
        }
    }

    func snapshot(fetchedAt: Date) throws -> UsageSnapshot {
        try lock.withLock {
            if let usage {
                return UsageSnapshot(fetchedAt: fetchedAt, usage: usage, rateLimits: rateLimits)
            }

            if !errors.isEmpty {
                throw CodexAppServerError.server(errors.joined(separator: "\n"))
            }
            throw CodexAppServerError.timeout
        }
    }

    private func parseLine(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            guard let id = object["id"] as? Int else {
                return
            }

            if let error = object["error"] {
                if id == 3 {
                    rateLimitsResolved = true
                } else {
                    recordError(Self.describeError(error))
                }
                return
            }

            guard let result = object["result"] else {
                return
            }

            switch id {
            case 1:
                initialized = true
            case 2:
                usage = try UsageDecoding.decodeUsageResult(from: result)
            case 3:
                rateLimits = try? UsageDecoding.decodeRateLimitsResult(from: result)
                rateLimitsResolved = true
            default:
                break
            }
        } catch {
            recordError(String(describing: error))
        }
    }

    private func recordError(_ message: String) {
        if errors.count < Self.maxStoredErrors {
            errors.append(message)
        }
    }

    private static func describeError(_ error: Any) -> String {
        if let dictionary = error as? [String: Any] {
            if let message = dictionary["message"] as? String {
                return message
            }
            if let code = dictionary["code"] {
                return "Codex app-server error \(code)"
            }
        }
        return "Codex app-server returned an error."
    }
}

private enum CodexAppServerError: LocalizedError, CustomStringConvertible {
    case cliNotFound([String])
    case initializeTimeout
    case timeout
    case server(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .cliNotFound(paths):
            return "Could not find the Codex CLI. Checked: \(paths.joined(separator: ", "))"
        case .initializeTimeout:
            return "Timed out initializing Codex app-server."
        case .timeout:
            return "Timed out waiting for Codex usage."
        case let .server(message):
            return message
        }
    }
}

private enum CodexCLIResolver {
    static func resolve() throws -> URL {
        let candidates = candidatePaths()
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexAppServerError.cliNotFound(candidates)
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_USAGE_BAR_CODEX_PATH"], !override.isEmpty {
            paths.append(NSString(string: override).expandingTildeInPath)
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        paths.append(contentsOf: pathEntries.map { "\($0)/codex" })

        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/.npm-global/bin/codex"
        ])

        var seen = Set<String>()
        return paths.filter { path in
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
