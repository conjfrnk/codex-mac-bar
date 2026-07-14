import Darwin
import Dispatch
import Foundation
import CoreFoundation

public struct CodexAppServerClient: UsageFetching {
    public var timeout: TimeInterval

    private let executableURL: URL?
    private let rateLimitGrace: TimeInterval
    private let signalGrace: TimeInterval
    private let startupWriteDelay: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
        executableURL = nil
        rateLimitGrace = 0.35
        signalGrace = 0.15
        startupWriteDelay = 0
    }

    init(
        timeout: TimeInterval,
        executableURL: URL,
        rateLimitGrace: TimeInterval = 0.35,
        signalGrace: TimeInterval = 0.15,
        startupWriteDelay: TimeInterval = 0
    ) {
        self.timeout = timeout
        self.executableURL = executableURL
        self.rateLimitGrace = rateLimitGrace
        self.signalGrace = signalGrace
        self.startupWriteDelay = startupWriteDelay
    }

    public func fetchUsageSnapshot() async throws -> UsageSnapshot {
        let worker = Task.detached(priority: .utility) {
            try Self.fetchSynchronously(
                timeout: timeout,
                executableURL: executableURL,
                rateLimitGrace: rateLimitGrace,
                signalGrace: signalGrace,
                startupWriteDelay: startupWriteDelay
            )
        }

        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func fetchSynchronously(
        timeout: TimeInterval,
        executableURL: URL?,
        rateLimitGrace: TimeInterval,
        signalGrace: TimeInterval,
        startupWriteDelay: TimeInterval
    ) throws -> UsageSnapshot {
        let deadline = try MonotonicDeadline(timeout: timeout)
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = try executableURL ?? CodexCLIResolver.resolve()
        process.arguments = ["app-server", "--stdio"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let writer = stdin.fileHandleForWriting
        guard Darwin.fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let message = String(cString: Darwin.strerror(errno))
            throw CodexAppServerError.transport(
                "Could not configure Codex app-server input: \(DiagnosticSanitizer.clean(message))"
            )
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = AppServerResponseCollector()
        let stderrCapture = BoundedDataCapture(maxBytes: 16 * 1024)
        let stdoutDrainer = FileHandleDrainer(
            handle: stdout.fileHandleForReading,
            label: "CodexUsageBar.stdout",
            onData: { collector.append($0) },
            onEOF: { collector.finishInputAtEOF() },
            onUnexpectedError: { collector.recordTransportError("Could not read Codex app-server output: \($0)") }
        )
        let stderrDrainer = FileHandleDrainer(
            handle: stderr.fileHandleForReading,
            label: "CodexUsageBar.stderr",
            onData: { stderrCapture.append($0) },
            onEOF: {},
            onUnexpectedError: { _ in }
        )

        do {
            try process.run()
        } catch {
            try? writer.close()
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
            throw CodexAppServerError.launchFailed(DiagnosticSanitizer.clean(String(describing: error)))
        }

        // Foundation launches a Process in its own process group on macOS. Capture
        // that fact while the direct child is known to exist; cleanup can then
        // signal descendants that inherited the app-server's pipes as well as the
        // direct child. Never signal a group unless ownership was verified, because
        // a shared group could include the menu-bar app itself.
        let processGroupID = ownedProcessGroupID(for: process)

        do {
            // Process.run() duplicates these child-side endpoints. Keeping the parent's
            // copies open would suppress EPIPE on stdin and EOF on stdout/stderr forever.
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()
        } catch {
            try? writer.close()
            terminateAndReap(
                process,
                processGroupID: processGroupID,
                signalGrace: normalizedGrace(signalGrace)
            )
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close()
            try? stderr.fileHandleForWriting.close()
            throw CodexAppServerError.transport(
                "Could not configure Codex app-server pipes: \(DiagnosticSanitizer.clean(String(describing: error)))"
            )
        }

        stdoutDrainer.start()
        stderrDrainer.start()

        defer {
            try? writer.close()
            terminateAndReap(
                process,
                processGroupID: processGroupID,
                signalGrace: normalizedGrace(signalGrace)
            )

            // Reaping the direct child normally closes both pipe writers. Never let an
            // inherited descriptor in a descendant keep either reader alive indefinitely.
            _ = stdoutDrainer.waitForCompletion(timeout: 0.10)
            _ = stderrDrainer.waitForCompletion(timeout: 0.10)
            stdoutDrainer.stopAndWait(timeout: 0.10)
            stderrDrainer.stopAndWait(timeout: 0.10)
        }

        if startupWriteDelay.isFinite, startupWriteDelay > 0 {
            let delayDeadline = deadline.instant(after: min(startupWriteDelay, 1))
            while MonotonicDeadline.now < delayDeadline {
                try Task.checkCancellation()
                deadline.sleepForPoll(until: delayDeadline)
            }
            guard !deadline.hasPassed else {
                throw CodexAppServerError.initializeTimeout
            }
        }

        try send([
            "method": "initialize", "id": 1, "params": [
                "clientInfo": [
                    "name": "codex-usage-bar",
                    "title": "Codex Usage Bar",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false
                ]
            ]
        ], expectingResponseID: 1, to: writer, process: process,
           stdoutDrainer: stdoutDrainer, stderrDrainer: stderrDrainer,
           collector: collector, stderrCapture: stderrCapture)

        while !collector.didInitialize {
            try Task.checkCancellation()
            if let error = collector.fatalErrorDescription {
                throw CodexAppServerError.server(error)
            }
            if !process.isRunning {
                throw childExitError(
                    process: process,
                    stdoutDrainer: stdoutDrainer,
                    stderrDrainer: stderrDrainer,
                    collector: collector,
                    stderrCapture: stderrCapture
                )
            }
            if deadline.hasPassed {
                throw CodexAppServerError.initializeTimeout
            }
            deadline.sleepForPoll()
        }

        try Task.checkCancellation()
        guard !deadline.hasPassed else {
            throw CodexAppServerError.timeout
        }

        try send(["method": "initialized"], to: writer, process: process,
                 stdoutDrainer: stdoutDrainer, stderrDrainer: stderrDrainer,
                 collector: collector, stderrCapture: stderrCapture)
        try send(
                 ["method": "account/usage/read", "id": 2, "params": NSNull()],
                 expectingResponseID: 2, to: writer,
                 process: process, stdoutDrainer: stdoutDrainer, stderrDrainer: stderrDrainer,
                 collector: collector, stderrCapture: stderrCapture)
        try send(
                 ["method": "account/rateLimits/read", "id": 3, "params": NSNull()],
                 expectingResponseID: 3, to: writer,
                 process: process, stdoutDrainer: stdoutDrainer, stderrDrainer: stderrDrainer,
                 collector: collector, stderrCapture: stderrCapture)

        var optionalRateLimitDeadline: UInt64?
        var completeResponseDeadline: UInt64?
        while true {
            try Task.checkCancellation()

            if let error = collector.fatalErrorDescription {
                throw CodexAppServerError.server(error)
            }
            let isComplete = collector.isComplete
            if isComplete, completeResponseDeadline == nil {
                optionalRateLimitDeadline = nil
                // A server that emits syntactically valid responses and then
                // immediately crashes must not have its nonzero exit masked by
                // the fast path. The real app-server is long-lived, so a short
                // stability window catches that failure without waiting for EOF.
                completeResponseDeadline = deadline.instant(after: 0.05)
            } else if !isComplete, collector.hasUsage {
                if optionalRateLimitDeadline == nil {
                    optionalRateLimitDeadline = deadline.instant(
                        after: normalizedGrace(rateLimitGrace, fallback: 0.35)
                    )
                }
            }

            if !process.isRunning {
                return try snapshotAfterChildExit(
                    process: process,
                    processGroupID: processGroupID,
                    signalGrace: normalizedGrace(signalGrace),
                    stdoutDrainer: stdoutDrainer,
                    stderrDrainer: stderrDrainer,
                    collector: collector,
                    stderrCapture: stderrCapture
                )
            }

            if let completeResponseDeadline,
               MonotonicDeadline.now >= completeResponseDeadline {
                return try collector.snapshot(fetchedAt: Date())
            }
            if let optionalRateLimitDeadline,
               MonotonicDeadline.now >= optionalRateLimitDeadline {
                return try collector.snapshot(fetchedAt: Date())
            }

            if deadline.hasPassed {
                if collector.hasUsage {
                    return try collector.snapshot(fetchedAt: Date())
                }
                throw CodexAppServerError.timeout
            }
            let nextSecondaryDeadline = [completeResponseDeadline, optionalRateLimitDeadline]
                .compactMap { $0 }
                .min()
            deadline.sleepForPoll(until: nextSecondaryDeadline)
        }
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0a)
        try handle.write(contentsOf: data)
    }

    private static func send(
        _ object: [String: Any],
        expectingResponseID: Int? = nil,
        to handle: FileHandle,
        process: Process,
        stdoutDrainer: FileHandleDrainer,
        stderrDrainer: FileHandleDrainer,
        collector: AppServerResponseCollector,
        stderrCapture: BoundedDataCapture
    ) throws {
        if let expectingResponseID {
            collector.expectResponse(id: expectingResponseID)
        }
        do {
            try write(object, to: handle)
        } catch {
            // A failed pipe write can race the Process state update by a few milliseconds.
            if process.isRunning {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !process.isRunning {
                let exitError = childExitError(
                    process: process,
                    stdoutDrainer: stdoutDrainer,
                    stderrDrainer: stderrDrainer,
                    collector: collector,
                    stderrCapture: stderrCapture
                )
                // A CLI may close after sending the required usage response and before
                // accepting the best-effort rate-limit request.
                if collector.hasUsage,
                   collector.fatalErrorDescription == nil,
                   processExitedSuccessfully(process) {
                    return
                }
                throw exitError
            }
            throw CodexAppServerError.transport(
                "Could not write to Codex app-server: \(DiagnosticSanitizer.clean(String(describing: error)))"
            )
        }
    }

    private static func childExitError(
        process: Process,
        stdoutDrainer: FileHandleDrainer,
        stderrDrainer: FileHandleDrainer,
        collector: AppServerResponseCollector,
        stderrCapture: BoundedDataCapture
    ) -> Error {
        _ = stdoutDrainer.waitForCompletion(timeout: 0.05)
        _ = stderrDrainer.waitForCompletion(timeout: 0.05)

        if let error = collector.fatalErrorDescription {
            return CodexAppServerError.server(error)
        }

        return CodexAppServerError.processExited(
            status: process.terminationStatus,
            reason: process.terminationReason,
            stderr: stderrCapture.diagnostic
        )
    }

    private static func snapshotAfterChildExit(
        process: Process,
        processGroupID: pid_t?,
        signalGrace: TimeInterval,
        stdoutDrainer: FileHandleDrainer,
        stderrDrainer: FileHandleDrainer,
        collector: AppServerResponseCollector,
        stderrCapture: BoundedDataCapture
    ) throws -> UsageSnapshot {
        // A direct child can exit zero while a descendant keeps its output pipe
        // open. Kill the verified group first, then require natural stdout EOF so
        // the collector validates any buffered trailing frame before success.
        terminateAndReap(
            process,
            processGroupID: processGroupID,
            signalGrace: signalGrace
        )
        let stdoutCompleted = stdoutDrainer.waitForCompletion(timeout: 0.10)
        let stderrCompleted = stderrDrainer.waitForCompletion(timeout: 0.10)
        if !stdoutCompleted {
            collector.recordTransportError(
                "Codex app-server output did not close after the process exited."
            )
            stdoutDrainer.stopAndWait(timeout: 0.10)
        }
        if !stderrCompleted {
            stderrDrainer.stopAndWait(timeout: 0.10)
        }

        if let error = collector.fatalErrorDescription {
            throw CodexAppServerError.server(error)
        }
        if collector.hasUsage, processExitedSuccessfully(process) {
            return try collector.snapshot(fetchedAt: Date())
        }
        throw CodexAppServerError.processExited(
            status: process.terminationStatus,
            reason: process.terminationReason,
            stderr: stderrCapture.diagnostic
        )
    }

    private static func ownedProcessGroupID(for process: Process) -> pid_t? {
        let pid = process.processIdentifier
        guard pid > 1, Darwin.getpgid(pid) == pid else { return nil }
        return pid
    }

    private static func processExitedSuccessfully(_ process: Process) -> Bool {
        !process.isRunning
            && process.terminationReason == .exit
            && process.terminationStatus == 0
    }

    private static func terminateAndReap(
        _ process: Process,
        processGroupID: pid_t?,
        signalGrace: TimeInterval
    ) {
        guard process.processIdentifier > 0 else { return }

        signalProcessTree(process, processGroupID: processGroupID, signal: SIGTERM)
        _ = waitUntilProcessTreeExits(
            process,
            processGroupID: processGroupID,
            timeout: signalGrace
        )

        if process.isRunning || processGroupExists(processGroupID) {
            signalProcessTree(process, processGroupID: processGroupID, signal: SIGINT)
            _ = waitUntilProcessTreeExits(
                process,
                processGroupID: processGroupID,
                timeout: signalGrace
            )
        }
        if process.isRunning || processGroupExists(processGroupID) {
            signalProcessTree(process, processGroupID: processGroupID, signal: SIGKILL)
        }

        // The Process is our direct child. After SIGKILL (if it was needed), this is
        // the definitive wait that reaps it instead of leaving a zombie behind.
        process.waitUntilExit()
    }

    private static func signalProcessTree(
        _ process: Process,
        processGroupID: pid_t?,
        signal: Int32
    ) {
        if let processGroupID, processGroupID > 1 {
            _ = Darwin.kill(-processGroupID, signal)
        }
        // Also target the direct child in case it changed groups after launch.
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, signal)
        }
    }

    private static func processGroupExists(_ processGroupID: pid_t?) -> Bool {
        guard let processGroupID, processGroupID > 1 else { return false }
        errno = 0
        return Darwin.kill(-processGroupID, 0) == 0 || errno == EPERM
    }

    private static func waitUntilProcessTreeExits(
        _ process: Process,
        processGroupID: pid_t?,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = MonotonicDeadline.now.addingReportingOverflow(
            UInt64(max(0, timeout) * 1_000_000_000)
        )
        while process.isRunning || processGroupExists(processGroupID) {
            let now = MonotonicDeadline.now
            guard !deadline.overflow, now < deadline.partialValue else { return false }
            let remaining = deadline.partialValue - now
            Thread.sleep(
                forTimeInterval: Double(min(remaining, 10_000_000)) / 1_000_000_000
            )
        }
        return true
    }

    private static func normalizedGrace(_ value: TimeInterval, fallback: TimeInterval = 0.15) -> TimeInterval {
        guard value.isFinite, value > 0 else { return fallback }
        return min(value, 1)
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
    private var pendingResponseIDs = Set<Int>()
    private var resolvedResponseIDs = Set<Int>()

    var didInitialize: Bool {
        lock.withLock { initialized }
    }

    var fatalErrorDescription: String? {
        lock.withLock {
            errors.isEmpty ? nil : errors.joined(separator: "\n")
        }
    }

    var hasUsage: Bool {
        lock.withLock { usage != nil }
    }

    var isComplete: Bool {
        lock.withLock { usage != nil && rateLimitsResolved }
    }

    func expectResponse(id: Int) {
        lock.withLock {
            guard !pendingResponseIDs.contains(id), !resolvedResponseIDs.contains(id) else {
                recordError("Codex app-server request ID \(id) was registered more than once.")
                return
            }
            pendingResponseIDs.insert(id)
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard errors.isEmpty else { return }
            if buffer.isEmpty, data.allSatisfy({ $0 == 0x0a }) {
                return
            }
            buffer.append(data)

            // Scan the accumulated bytes once and remove the consumed prefix once.
            // Repeatedly deleting the first byte made a flood of blank/tiny frames
            // quadratic within every read chunk.
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0a) {
                let lineCount = buffer.distance(from: lineStart, to: newline)
                guard lineCount <= Self.maxMessageBytes else {
                    buffer.removeAll(keepingCapacity: false)
                    recordError("Codex app-server returned an oversized message.")
                    return
                }
                if lineCount > 0 {
                    parseLine(Data(buffer[lineStart..<newline]))
                }
                if !errors.isEmpty {
                    buffer.removeAll(keepingCapacity: false)
                    return
                }
                lineStart = buffer.index(after: newline)
            }
            if lineStart != buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
            if buffer.count > Self.maxMessageBytes {
                buffer.removeAll(keepingCapacity: false)
                recordError("Codex app-server returned an oversized message.")
            }
        }
    }

    func finishInputAtEOF() {
        lock.withLock {
            guard errors.isEmpty else {
                buffer.removeAll(keepingCapacity: false)
                return
            }

            let trailing = buffer
            buffer.removeAll(keepingCapacity: false)
            guard trailing.contains(where: { !Self.isJSONWhitespace($0) }) else { return }

            // Be liberal about a complete final JSON value without a newline, while
            // never hiding a truncated/malformed frame that follows valid usage.
            parseLine(trailing)
        }
    }

    func recordTransportError(_ message: String) {
        lock.withLock {
            recordError(message)
        }
    }

    func snapshot(fetchedAt: Date) throws -> UsageSnapshot {
        try lock.withLock {
            if !errors.isEmpty {
                throw CodexAppServerError.server(errors.joined(separator: "\n"))
            }
            if let usage {
                return UsageSnapshot(fetchedAt: fetchedAt, usage: usage, rateLimits: rateLimits)
            }
            throw CodexAppServerError.timeout
        }
    }

    private func parseLine(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard let object = value as? [String: Any] else {
                recordError("Codex app-server returned a non-object JSON-RPC message.")
                return
            }

            let rawID = object["id"]
            guard let id = Self.integerResponseID(from: rawID) else {
                // Notifications are valid JSON-RPC messages and do not carry an id,
                // but an arbitrary object is not a notification.
                if rawID != nil || object["method"] as? String == nil {
                    recordError("Codex app-server returned a JSON-RPC message without an id or method.")
                }
                return
            }
            guard pendingResponseIDs.remove(id) != nil else {
                recordError("Codex app-server returned an unexpected or duplicate response ID \(id).")
                return
            }
            resolvedResponseIDs.insert(id)
            if let error = object["error"] {
                if id == 3 {
                    rateLimitsResolved = true
                } else {
                    recordError(Self.describeError(error))
                }
                return
            }

            guard let result = object["result"] else {
                recordError("Codex app-server response \(id) contained neither a result nor an error.")
                return
            }

            switch id {
            case 1:
                initialized = true
            case 2:
                usage = try UsageDecoding.decodeUsageResult(from: result)
            case 3:
                // Rate limits are optional across CLI versions. A response resolves the
                // optional request even when that version's shape is not understood.
                rateLimits = try? UsageDecoding.decodeRateLimitsResult(from: result)
                rateLimitsResolved = true
            default:
                break
            }
        } catch {
            recordError("Codex app-server returned malformed JSON-RPC data: \(error)")
        }
    }

    private func recordError(_ message: String) {
        if errors.count < Self.maxStoredErrors {
            errors.append(DiagnosticSanitizer.clean(message))
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

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }

    private static func integerResponseID(from value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              let integer = Int(number.stringValue)
        else { return nil }
        return integer
    }
}

enum CodexAppServerError: LocalizedError, CustomStringConvertible {
    case cliNotFound([String])
    case invalidCLIOverride(String)
    case invalidTimeout
    case launchFailed(String)
    case initializeTimeout
    case timeout
    case processExited(status: Int32, reason: Process.TerminationReason, stderr: String?)
    case transport(String)
    case server(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case let .cliNotFound(paths):
            return "Could not find the Codex CLI. Checked: \(paths.joined(separator: ", "))"
        case let .invalidCLIOverride(path):
            return "CODEX_USAGE_BAR_CODEX_PATH is not an executable regular file: \(path)"
        case .invalidTimeout:
            return "Codex app-server timeout must be finite and greater than zero."
        case let .launchFailed(message):
            return "Could not launch Codex app-server: \(message)"
        case .initializeTimeout:
            return "Timed out initializing Codex app-server."
        case .timeout:
            return "Timed out waiting for Codex usage."
        case let .processExited(status, reason, stderr):
            let kind = reason == .uncaughtSignal ? "signal" : "status"
            let diagnostic = stderr.map { " Stderr: \($0)" } ?? ""
            return "Codex app-server exited early with \(kind) \(status).\(diagnostic)"
        case let .transport(message), let .server(message):
            return message
        }
    }
}

enum CodexCLIResolver {
    private static let overrideKey = "CODEX_USAGE_BAR_CODEX_PATH"

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment[overrideKey] {
            let expanded = NSString(string: override).expandingTildeInPath
            guard !override.isEmpty, isExecutableRegularFile(atPath: expanded) else {
                throw CodexAppServerError.invalidCLIOverride(expanded)
            }
            return URL(fileURLWithPath: expanded)
        }

        let candidates = candidatePaths(environment: environment)
        for path in candidates where isExecutableRegularFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexAppServerError.cliNotFound(candidates)
    }

    static func isExecutableRegularFile(atPath path: String) -> Bool {
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func candidatePaths(environment: [String: String]) -> [String] {
        var paths: [String] = []
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

private struct MonotonicDeadline {
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    private let end: UInt64

    init(timeout: TimeInterval) throws {
        let start = Self.now
        guard timeout.isFinite, timeout > 0 else {
            throw CodexAppServerError.invalidTimeout
        }

        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds >= 1, nanoseconds < Double(UInt64.max) else {
            throw CodexAppServerError.invalidTimeout
        }
        let result = start.addingReportingOverflow(UInt64(nanoseconds.rounded(.up)))
        guard !result.overflow else {
            throw CodexAppServerError.invalidTimeout
        }
        end = result.partialValue
    }

    var hasPassed: Bool { Self.now >= end }

    func instant(after interval: TimeInterval) -> UInt64 {
        let now = Self.now
        let bounded = max(0, interval) * 1_000_000_000
        let delta = UInt64(min(bounded, Double(UInt64.max - now)))
        return min(end, now + delta)
    }

    func sleepForPoll(until secondaryDeadline: UInt64? = nil) {
        let now = Self.now
        let nextDeadline = min(end, secondaryDeadline ?? end)
        guard now < nextDeadline else { return }
        let remaining = nextDeadline - now
        let pollNanoseconds = min(remaining, 10_000_000)
        Thread.sleep(forTimeInterval: Double(pollNanoseconds) / 1_000_000_000)
    }
}

private final class FileHandleDrainer: @unchecked Sendable {
    // Darwin's FIONREAD is _IOR('f', 127, int). Swift cannot import that C macro,
    // so keep its stable Darwin ioctl value here to size each throwing FileHandle read.
    private static let bytesAvailableRequest = UInt(0x4004_667f)

    private let handle: FileHandle
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let group = DispatchGroup()
    private let stateLock = NSLock()
    private let onData: @Sendable (Data) -> Void
    private let onEOF: @Sendable () -> Void
    private let onUnexpectedError: @Sendable (Error) -> Void
    private var started = false
    private var stopping = false

    init(
        handle: FileHandle,
        label: String,
        onData: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void,
        onUnexpectedError: @escaping @Sendable (Error) -> Void
    ) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        queue = DispatchQueue(label: label, qos: .utility)
        self.onData = onData
        self.onEOF = onEOF
        self.onUnexpectedError = onUnexpectedError
    }

    func start() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !started, !stopping else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        group.enter()
        queue.async { [self] in
            defer { group.leave() }
            do {
                while let data = try readAvailableChunk(), !data.isEmpty {
                    onData(data)
                }
                let reachedNaturalEOF = stateLock.withLock { !stopping }
                if reachedNaturalEOF {
                    onEOF()
                }
            } catch {
                let wasStopping = stateLock.withLock { stopping }
                if !wasStopping {
                    onUnexpectedError(error)
                }
            }
        }
    }

    private func readAvailableChunk() throws -> Data? {
        guard let firstByte = try handle.read(upToCount: 1), !firstByte.isEmpty else {
            return nil
        }

        var chunk = firstByte
        while chunk.count < 16 * 1024 {
            let available = stateLock.withLock { () -> Int32 in
                // FileHandle.fileDescriptor raises an Objective-C exception after close.
                // Keep close and ioctl mutually exclusive and use the descriptor captured
                // while the handle was known to be open, so teardown cannot race this call
                // or redirect it to a subsequently reused descriptor.
                guard !stopping else { return 0 }
                var available = Int32(0)
                guard Darwin.ioctl(descriptor, Self.bytesAvailableRequest, &available) == 0 else {
                    return 0
                }
                return available
            }
            guard available > 0 else {
                break
            }

            let count = min(Int(available), 16 * 1024 - chunk.count)
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                break
            }
            chunk.append(data)
        }
        return chunk
    }

    @discardableResult
    func waitForCompletion(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func stopAndWait(timeout: TimeInterval) {
        stateLock.withLock {
            guard !stopping else { return }
            stopping = true
            try? handle.close()
        }
        _ = waitForCompletion(timeout: timeout)
    }
}

private final class BoundedDataCapture: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ incoming: Data) {
        lock.withLock {
            let remaining = max(0, maxBytes - data.count)
            if remaining > 0 {
                data.append(incoming.prefix(remaining))
            }
            if incoming.count > remaining {
                truncated = true
            }
        }
    }

    var diagnostic: String? {
        lock.withLock {
            guard !data.isEmpty else { return nil }
            let suffix = truncated ? " [truncated]" : ""
            let message = DiagnosticSanitizer.clean(String(decoding: data, as: UTF8.self))
            guard !message.isEmpty else { return truncated ? "[truncated]" : nil }
            return message + suffix
        }
    }
}

private enum DiagnosticSanitizer {
    static func clean(
        _ input: String,
        maxCharacters: Int = 512,
        maxUTF8Bytes: Int = 2 * 1024
    ) -> String {
        let characterLimit = max(0, maxCharacters)
        let byteLimit = max(0, maxUTF8Bytes)
        guard characterLimit > 0, byteLimit > 0 else { return "" }

        var sanitized = ""
        sanitized.reserveCapacity(min(input.utf8.count, byteLimit))
        var utf8Bytes = 0
        var previousWasSpace = false

        for scalar in input.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let scalarToAppend: Unicode.Scalar?
            if isControl || isWhitespace {
                if !previousWasSpace && !sanitized.isEmpty {
                    scalarToAppend = " "
                } else {
                    scalarToAppend = nil
                }
                previousWasSpace = true
            } else {
                scalarToAppend = scalar
                previousWasSpace = false
            }

            guard let scalarToAppend else { continue }
            let scalarBytes = scalarToAppend.utf8ByteCount
            if utf8Bytes > byteLimit - scalarBytes {
                break
            }
            sanitized.unicodeScalars.append(scalarToAppend)
            utf8Bytes += scalarBytes
        }

        let presentationBounded = String(sanitized.prefix(characterLimit))
        return presentationBounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Unicode.Scalar {
    var utf8ByteCount: Int {
        switch value {
        case 0 ... 0x7f: 1
        case 0x80 ... 0x7ff: 2
        case 0x800 ... 0xffff: 3
        default: 4
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
