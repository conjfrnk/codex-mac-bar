import Darwin
import Foundation
import Testing
@testable import CodexUsageCore

@Suite(.serialized)
struct TransportTests {
    @Test
    func testResolverRejectsDirectoryOverrideWithoutFallingThrough() throws {
        let validExecutable = try TemporaryExecutable(script: "#!/bin/sh\nexit 0\n")
        let directoryOverride = validExecutable.directory.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryOverride, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryOverride.path)

        #expect(FileManager.default.isExecutableFile(atPath: directoryOverride.path))
        #expect(!CodexCLIResolver.isExecutableRegularFile(atPath: directoryOverride.path))

        let environment = [
            "CODEX_USAGE_BAR_CODEX_PATH": directoryOverride.path,
            "PATH": validExecutable.directory.path
        ]
        do {
            _ = try CodexCLIResolver.resolve(environment: environment)
            Issue.record("Expected an authoritative invalid-override error")
        } catch CodexAppServerError.invalidCLIOverride(let path) {
            #expect(path == directoryOverride.path)
        } catch {
            Issue.record(error, "Expected an authoritative invalid-override error")
        }
    }

    @Test
    func testResolverAcceptsExecutableRegularFileOverride() throws {
        let executable = try TemporaryExecutable(script: "#!/bin/sh\nexit 0\n")
        let resolved = try CodexCLIResolver.resolve(environment: [
            "CODEX_USAGE_BAR_CODEX_PATH": executable.url.path,
            "PATH": ""
        ])

        #expect(resolved.standardizedFileURL == executable.url.standardizedFileURL)
    }

    @Test
    func testInvalidTimeoutsAreRejectedBeforeLaunch() async throws {
        let executable = try TemporaryExecutable(script: "#!/bin/sh\nexit 99\n")

        for timeout in [0, -1, .infinity, .nan] {
            let client = CodexAppServerClient(timeout: timeout, executableURL: executable.url)
            do {
                _ = try await client.fetchUsageSnapshot()
                Issue.record("Expected timeout \(timeout) to be rejected")
            } catch CodexAppServerError.invalidTimeout {
                // Expected.
            } catch {
                Issue.record(error, "Expected an invalid-timeout error for \(timeout)")
            }
        }
    }

    @Test
    func testEarlyExitReportsBoundedSanitizedStderr() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        printf 'early diagnostic\\001\\n' >&2
        i=0
        while [ "$i" -lt 200 ]; do
          printf '0123456789abcdefghijklmnopqrstuvwxyz' >&2
          i=$((i + 1))
        done
        exit 23
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Expected an early-exit failure")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("exited early"), "\(description)")
            #expect(description.contains("23"), "\(description)")
            #expect(description.contains("early diagnostic"), "\(description)")
            #expect(!description.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            })
            #expect(description.count < 700, "Child stderr must remain tightly bounded")
        }
    }

    @Test
    func testEarlyExitBoundsHostileUnicodeStderrByUTF8Bytes() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        printf 'unicode diagnostic A' >&2
        i=0
        while [ "$i" -lt 10000 ]; do
          printf '\\314\\201' >&2
          i=$((i + 1))
        done
        exit 29
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Expected an early-exit failure")
        } catch {
            let description = String(describing: error)
            #expect(description.contains("unicode diagnostic"), "\(description)")
            #expect(description.contains("[truncated]"), "\(description)")
            #expect(description.count < 700, "Diagnostic presentation length must remain bounded")
            #expect(description.utf8.count < 2_300, "Diagnostic UTF-8 storage must remain bounded")
        }
    }

    @Test
    func testInheritedOutputDescriptorsCannotHangOrCrashDrainerTeardown() async throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageInheritedPipe-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: descendantPIDFile) }

        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        pid_file=\(shellSingleQuoted(descendantPIDFile.path))
        (
          trap '' HUP
          while :; do
            printf 'inherited descriptor traffic\\n' >&2 || exit 0
          done
        ) &
        descendant_pid=$!
        pid_temp="${pid_file}.tmp.$$"
        printf '%s' "$descendant_pid" > "$pid_temp"
        mv "$pid_temp" "$pid_file"

        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\\n' '\(usageResponse)' ;;
            *'"id":3'*) exit 0 ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let pid = try? readPID(at: descendantPIDFile) else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }

        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = try await client.fetchUsageSnapshot()
        let descendantPID = try readPID(at: descendantPIDFile)
        let exited = await waitForProcessToDisappear(descendantPID, timeout: 0.5)

        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(elapsedSeconds(since: start) < 1.2, "Inherited descriptors must not hang cleanup")
        #expect(
            exited,
            "The descendant process group must be cleaned up even when it inherits output descriptors"
        )
        if !exited {
            _ = Darwin.kill(descendantPID, SIGKILL)
        }
    }

    @Test
    func testBrokenStdinBeforeInitializationThrowsWithoutTerminatingCaller() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        exec 0<&-
        while :; do :; done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03,
            startupWriteDelay: 0.3
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Expected a broken-stdin write failure")
        } catch CodexAppServerError.initializeTimeout {
            // The child and parent are scheduled independently. If the initialize
            // write wins the race with the shell closing fd 0, a bounded timeout is
            // the valid result; the post-initialize case below covers EPIPE exactly.
        } catch {
            #expect(String(describing: error).contains("write"), "Unexpected error: \(error)")
        }
        #expect(Bool(true), "The throwing write path must leave the caller process alive")
    }

    @Test
    func testBrokenStdinAfterInitializationThrowsWithoutTerminatingCaller() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        exec 0<&-
        while :; do :; done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Expected a post-initialization broken-stdin write failure")
        } catch {
            #expect(String(describing: error).contains("write"), "Unexpected error: \(error)")
        }
        #expect(Bool(true), "The throwing write path must leave the caller process alive")
    }

    @Test
    func testUsageReturnsAfterShortGraceWhenRateLimitsNeverReply() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(rateLimitAction: ""))
        let client = CodexAppServerClient(
            timeout: 2,
            executableURL: executable.url,
            rateLimitGrace: 0.08,
            signalGrace: 0.03
        )
        let start = DispatchTime.now().uptimeNanoseconds

        let snapshot = try await client.fetchUsageSnapshot()
        let elapsed = elapsedSeconds(since: start)

        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(snapshot.rateLimits == nil)
        #expect(elapsed < 0.8, "Optional rate limits must not consume the overall timeout")
    }

    @Test
    func testMalformedProtocolDataAfterUsageRemainsFatal() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: "",
            postUsageAction: "printf '%s\\n' 'this is not JSON'"
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.15,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Malformed protocol data must not be hidden by an earlier usage result")
        } catch {
            #expect(
                String(describing: error).contains("malformed JSON-RPC data"),
                "Unexpected error: \(error)"
            )
        }
    }

    @Test
    func testUnsolicitedFutureResponsesAreRejected() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        printf '%s\\n' '{"id":1,"result":{}}'
        printf '%s\\n' '\(usageResponse)'
        printf '%s\\n' '\(rateLimitResponse)'
        while IFS= read -r line; do :; done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("Responses emitted before their requests must be rejected")
        } catch {
            #expect(String(describing: error).contains("unexpected or duplicate response ID"))
        }
    }

    @Test
    func testBooleanResponseIDCannotSatisfyInitialize() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\\n' '{"id":true,"result":{}}' ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("A JSON boolean must not compare equal to numeric response ID 1")
        } catch {
            #expect(String(describing: error).contains("without an id or method"))
        }
    }

    @Test
    func testFractionalResponseIDCannotRoundIntoPendingIntegerID() async throws {
        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\n' '{"id":1.00000000000000000001,"result":{}}' ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("A fractional JSON ID must not round into integer request ID 1")
        } catch {
            #expect(String(describing: error).contains("without an id or method"))
        }
    }

    @Test
    func testDuplicateResponseIDIsRejectedInsteadOfOverwritingUsage() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: "printf '%s\\n' '\(rateLimitResponse)'",
            postUsageAction: "printf '%s\\n' '\(usageResponse)'"
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("A duplicate response must not silently replace earlier data")
        } catch {
            #expect(String(describing: error).contains("unexpected or duplicate response ID 2"))
        }
    }

    @Test
    func testPartialTrailingFrameAtEOFRemainsFatalAfterUsage() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: "exit 0",
            postUsageAction: "printf '%s' '{\"id\":3'"
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("A truncated trailing JSON-RPC frame must not be hidden by valid usage")
        } catch {
            #expect(
                String(describing: error).contains("malformed JSON-RPC data"),
                "Unexpected error: \(error)"
            )
        }
    }

    @Test
    func testInheritedWriterCannotHidePartialTrailingFrameAfterCleanExit() async throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageTrailingWriter-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: descendantPIDFile) }

        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        pid_file=\(shellSingleQuoted(descendantPIDFile.path))
        (
          trap '' HUP TERM INT
          while :; do sleep 10; done
        ) &
        descendant_pid=$!
        printf '%s' "$descendant_pid" > "$pid_file"

        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\n' '\(usageResponse)' ;;
            *'"id":3'*) printf '%s' '{"id":3'; exit 0 ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let pid = try? readPID(at: descendantPIDFile) else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("An inherited writer must not hide a truncated trailing response")
        } catch {
            let description = String(describing: error)
            #expect(
                description.contains("malformed JSON-RPC data")
                    || description.contains("output did not close"),
                "Unexpected error: \(description)"
            )
        }
        if let descendantPID = try? readPID(at: descendantPIDFile) {
            let exited = await waitForProcessToDisappear(descendantPID, timeout: 0.5)
            #expect(exited)
        }
    }

    @Test
    func testBlankFrameFloodIsProcessedWithinBoundedTime() async throws {
        let floodAction = "/usr/bin/yes '' | /usr/bin/head -c 4194304"
        let rateAction = "printf '%s\\n' '\(rateLimitResponse)'"
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: rateAction,
            preUsageAction: floodAction
        ))
        let client = CodexAppServerClient(
            timeout: 2,
            executableURL: executable.url,
            rateLimitGrace: 1,
            signalGrace: 0.03
        )
        let start = DispatchTime.now().uptimeNanoseconds

        let snapshot = try await client.fetchUsageSnapshot()

        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(snapshot.rateLimits?.preferredCodexLimit?.primary?.usedPercent == 42)
        #expect(elapsedSeconds(since: start) < 1.2, "Tiny-frame parsing must remain linear")
    }

    @Test
    func testNormalEOFWithValidUsageReturnsSnapshot() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(rateLimitAction: "exit 0"))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        let snapshot = try await client.fetchUsageSnapshot()
        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(snapshot.rateLimits == nil)
    }

    @Test
    func testNonzeroExitAfterValidUsageIsNotMasked() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: "printf 'fatal after usage\\n' >&2; exit 42"
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("A nonzero app-server exit must not be hidden by valid usage")
        } catch CodexAppServerError.processExited(let status, let reason, let stderr) {
            #expect(status == 42)
            #expect(reason == .exit)
            #expect(stderr?.contains("fatal after usage") == true)
        } catch {
            Issue.record(error, "Expected a process-exit error")
        }
    }

    @Test
    func testImmediateNonzeroExitAfterAllResponsesIsNotMasked() async throws {
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: "printf '%s\\n' '\(rateLimitResponse)'; printf 'fatal after complete\\n' >&2; exit 43"
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("An immediate crash after complete responses must remain observable")
        } catch CodexAppServerError.processExited(let status, let reason, let stderr) {
            #expect(status == 43)
            #expect(reason == .exit)
            #expect(stderr?.contains("fatal after complete") == true)
        } catch {
            Issue.record(error, "Expected a process-exit error")
        }
    }

    @Test
    func testOptionalRateDeadlineCannotPreemptCompleteResponseStabilityCheck() async throws {
        let rateAction = "sleep 0.019; printf '%s\\n' '\(rateLimitResponse)'; sleep 0.01; exit 44"
        let executable = try TemporaryExecutable(script: fakeServerScript(
            rateLimitAction: rateAction
        ))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.02,
            signalGrace: 0.03
        )

        do {
            _ = try await client.fetchUsageSnapshot()
            Issue.record("The earlier optional deadline must not mask a post-completion crash")
        } catch CodexAppServerError.processExited(let status, let reason, _) {
            #expect(status == 44)
            #expect(reason == .exit)
        } catch {
            Issue.record(error, "Expected a process-exit error")
        }
    }

    @Test
    func testRateLimitsArrivingWithinGraceAreIncluded() async throws {
        let rateAction = "sleep 0.08; printf '%s\\n' '\(rateLimitResponse)'"
        let executable = try TemporaryExecutable(script: fakeServerScript(rateLimitAction: rateAction))
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.2,
            signalGrace: 0.03
        )

        let snapshot = try await client.fetchUsageSnapshot()
        #expect(snapshot.rateLimits?.preferredCodexLimit?.primary?.usedPercent == 42)
    }

    @Test
    func testParentCancellationStopsAndReapsDirectChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageCancellation-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        printf '%s' "$$" > \(shellSingleQuoted(pidFile.path))
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 10,
            executableURL: executable.url,
            rateLimitGrace: 0.05,
            signalGrace: 0.03
        )

        let fetch = Task { try await client.fetchUsageSnapshot() }
        let pid = try await waitForPID(at: pidFile, timeout: 1)
        let start = DispatchTime.now().uptimeNanoseconds
        fetch.cancel()

        do {
            _ = try await fetch.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record(error, "Expected CancellationError")
        }

        #expect(elapsedSeconds(since: start) < 0.8, "Cancellation should propagate promptly")
        assertProcessIsGone(pid)
    }

    @Test
    func testResistantDirectChildIsKilledAndReaped() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageResistant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        trap '' TERM INT
        printf '%s' "$$" > \(shellSingleQuoted(pidFile.path))
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            *'"id":2'*)
              printf '%s\\n' '\(usageResponse)'
              ;;
            *'"id":3'*)
              while :; do :; done
              ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.06,
            signalGrace: 0.04
        )

        // This independent watchdog only targets the unique child PID and is cancelled
        // on the normal path. It prevents a regression in cleanup from hanging the test.
        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let pid = try? readPID(at: pidFile) else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }

        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = try await client.fetchUsageSnapshot()
        let pid = try readPID(at: pidFile)

        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(elapsedSeconds(since: start) < 0.9, "Signal escalation should be bounded")
        assertProcessIsGone(pid)
    }

    @Test
    func testSuccessfulFetchKillsResistantDescendantProcessGroup() async throws {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageResistantDescendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: descendantPIDFile) }

        let executable = try TemporaryExecutable(script: """
        #!/bin/sh
        set -eu
        pid_file=\(shellSingleQuoted(descendantPIDFile.path))
        (
          trap '' HUP TERM INT
          while :; do sleep 10; done
        ) &
        descendant_pid=$!
        pid_temp="${pid_file}.tmp.$$"
        printf '%s' "$descendant_pid" > "$pid_temp"
        mv "$pid_temp" "$pid_file"

        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\\n' '\(usageResponse)' ;;
            *'"id":3'*) : ;;
          esac
        done
        """)
        let client = CodexAppServerClient(
            timeout: 1,
            executableURL: executable.url,
            rateLimitGrace: 0.06,
            signalGrace: 0.04
        )

        let watchdog = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let pid = try? readPID(at: descendantPIDFile) else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
        defer { watchdog.cancel() }

        let snapshot = try await client.fetchUsageSnapshot()
        let descendantPID = try readPID(at: descendantPIDFile)
        let exited = await waitForProcessToDisappear(descendantPID, timeout: 0.5)

        #expect(snapshot.sortedBuckets.map(\.tokens) == [7])
        #expect(exited, "Cleanup must kill app-server descendants that resist polite signals")
        if !exited {
            _ = Darwin.kill(descendantPID, SIGKILL)
        }
    }
}

private let usageResponse = #"{"id":2,"result":{"summary":{"lifetimeTokens":7,"peakDailyTokens":7,"longestRunningTurnSec":null,"currentStreakDays":1,"longestStreakDays":1},"dailyUsageBuckets":[{"startDate":"2026-07-08","tokens":7}]}}"#
private let rateLimitResponse = #"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42}}}}"#

private func fakeServerScript(
    rateLimitAction: String,
    preUsageAction: String = "",
    postUsageAction: String = ""
) -> String {
    """
    #!/bin/sh
    set -eu
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        *'"id":2'*)
          \(preUsageAction)
          printf '%s\\n' '\(usageResponse)'
          \(postUsageAction)
          ;;
        *'"id":3'*)
          \(rateLimitAction)
          ;;
      esac
    done
    """
}

private final class TemporaryExecutable {
    let directory: URL
    let url: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageTransportTests-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("codex")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func elapsedSeconds(since start: UInt64) -> TimeInterval {
    let now = DispatchTime.now().uptimeNanoseconds
    return Double(now - start) / 1_000_000_000
}

private func waitForPID(at url: URL, timeout: TimeInterval) async throws -> pid_t {
    let start = DispatchTime.now().uptimeNanoseconds
    while elapsedSeconds(since: start) < timeout {
        if let pid = try? readPID(at: url) {
            return pid
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw NSError(domain: "TransportTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for child PID"
    ])
}

private func readPID(at url: URL) throws -> pid_t {
    let value = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(value), pid > 0 else {
        throw NSError(domain: "TransportTests", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Invalid child PID"
        ])
    }
    return pid
}

private func assertProcessIsGone(
    _ pid: pid_t,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    errno = 0
    let result = Darwin.kill(pid, 0)
    let errorNumber = errno
    #expect(result == -1, sourceLocation: sourceLocation)
    #expect(errorNumber == ESRCH, sourceLocation: sourceLocation)
}

private func waitForProcessToDisappear(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while elapsedSeconds(since: start) < timeout {
        errno = 0
        if Darwin.kill(pid, 0) == -1, errno == ESRCH {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    errno = 0
    return Darwin.kill(pid, 0) == -1 && errno == ESRCH
}
