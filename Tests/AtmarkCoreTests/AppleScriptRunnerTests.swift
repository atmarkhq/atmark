import Darwin
import Foundation
import Testing

@testable import AtmarkCore

/// Uses controlled `/bin/sh` fixtures. No test invokes osascript, another app,
/// Apple Events, or any TCC-protected data.
@Suite("AppleScript runner budgets")
struct AppleScriptRunnerTests {
    private var runner: AppleScriptRunner {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/stdin-script-fixture.sh")
        return AppleScriptRunner(executable: executable)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "atmark runner \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForFile(_ url: URL, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false {
            guard clock.now < deadline else {
                throw AtmarkError(.timeout, detail: "test_fixture")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitUntilGone(_ pid: pid_t, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processExists(pid) {
            guard clock.now < deadline else {
                throw AtmarkError(.timeout, detail: "surviving_child")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func pid(from url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    @Test("arguments remain argv values and are never interpolated")
    func injectionPayloadIsInert() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "injected")
        let payload = #"$(touch \"\#(marker.path(percentEncoded: false))\"); ' \" end run"#

        let output = try await runner.run(
            script: #"printf '%s' "$0""#,
            arguments: [payload],
            targetBundleID: "test.arguments"
        )

        #expect(output == payload)
        #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) == false)
    }

    @Test("normal execution preserves argument order and whitespace")
    func normalExecution() async throws {
        let output = try await runner.run(
            script: #"printf ' %s|%s|%s ' "$0" "$1" "$2""#,
            arguments: ["a", "b", "c"],
            targetBundleID: "test.normal"
        )
        #expect(output == " a|b|c ")
    }

    @Test("calls for the same target serialize")
    func sameTargetSerializes() async throws {
        let runner = runner
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appending(path: "started")
        let release = directory.appending(path: "release")
        let events = directory.appending(path: "events")
        let first = Task {
            try await runner.run(
                script: """
                    printf started > "$0"
                    while [ ! -e "$1" ]; do sleep 0.01; done
                    printf first >> "$2"
                    """,
                arguments: [started.path(percentEncoded: false), release.path(percentEncoded: false), events.path(percentEncoded: false)],
                targetBundleID: "test.same-target"
            )
        }
        try await waitForFile(started)

        let second = Task {
            try await runner.run(
                script: #"printf second >> "$0""#,
                arguments: [events.path(percentEncoded: false)],
                targetBundleID: "test.same-target"
            )
        }
        for _ in 0..<20 { await Task.yield() }
        try Data().write(to: release)

        _ = try await first.value
        _ = try await second.value
        #expect(try String(contentsOf: events, encoding: .utf8) == "firstsecond")
    }

    @Test("different target bundle IDs execute concurrently")
    func differentTargetsOverlap() async throws {
        let runner = runner
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appending(path: "started")
        let release = directory.appending(path: "release")
        let concurrent = directory.appending(path: "concurrent")
        let blocked = Task {
            try await runner.run(
                script: """
                    printf started > "$0"
                    while [ ! -e "$1" ]; do sleep 0.01; done
                    """,
                arguments: [started.path(percentEncoded: false), release.path(percentEncoded: false)],
                targetBundleID: "test.target-a"
            )
        }
        try await waitForFile(started)

        _ = try await runner.run(
            script: #"printf concurrent > "$0""#,
            arguments: [concurrent.path(percentEncoded: false)],
            targetBundleID: "test.target-b",
            queueTimeout: .milliseconds(200)
        )
        #expect(FileManager.default.fileExists(atPath: concurrent.path(percentEncoded: false)) == true)

        try Data().write(to: release)
        _ = try await blocked.value
    }

    @Test("same-target queue wait has a bounded timeout and never launches")
    func queueTimeout() async throws {
        let runner = runner
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appending(path: "started")
        let release = directory.appending(path: "release")
        let secondStarted = directory.appending(path: "second-started")
        let blocked = Task {
            try await runner.run(
                script: """
                    printf started > "$0"
                    while [ ! -e "$1" ]; do sleep 0.01; done
                    """,
                arguments: [started.path(percentEncoded: false), release.path(percentEncoded: false)],
                targetBundleID: "test.queue"
            )
        }
        try await waitForFile(started)

        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: #"printf launched > "$0""#,
                arguments: [secondStarted.path(percentEncoded: false)],
                targetBundleID: "test.queue",
                queueTimeout: .milliseconds(100)
            )
        }
        #expect(error?.code == .timeout)
        #expect(error?.detail == "applescript_queue")
        #expect(FileManager.default.fileExists(atPath: secondStarted.path(percentEncoded: false)) == false)

        try Data().write(to: release)
        _ = try await blocked.value
    }

    @Test("cancelling a queued call never launches it or blocks the next waiter")
    func queuedCancellation() async throws {
        let runner = runner
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appending(path: "started")
        let release = directory.appending(path: "release")
        let cancelledStarted = directory.appending(path: "cancelled-started")
        let nextStarted = directory.appending(path: "next-started")
        let owner = Task {
            try await runner.run(
                script: """
                    printf started > "$0"
                    while [ ! -e "$1" ]; do sleep 0.01; done
                    """,
                arguments: [started.path(percentEncoded: false), release.path(percentEncoded: false)],
                targetBundleID: "test.queue-cancellation"
            )
        }
        try await waitForFile(started)

        let cancelled = Task {
            try await runner.run(
                script: #"printf launched > "$0""#,
                arguments: [cancelledStarted.path(percentEncoded: false)],
                targetBundleID: "test.queue-cancellation"
            )
        }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        let next = Task {
            try await runner.run(
                script: #"printf launched > "$0""#,
                arguments: [nextStarted.path(percentEncoded: false)],
                targetBundleID: "test.queue-cancellation"
            )
        }
        try Data().write(to: release)
        _ = try await owner.value
        _ = try await next.value

        #expect(FileManager.default.fileExists(
            atPath: cancelledStarted.path(percentEncoded: false)
        ) == false)
        #expect(FileManager.default.fileExists(
            atPath: nextStarted.path(percentEncoded: false)
        ) == true)
    }

    @Test("operation timeout terminates the process group")
    func operationTimeout() async {
        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: "while :; do sleep 1; done",
                targetBundleID: "test.operation-timeout",
                operationTimeout: .milliseconds(100)
            )
        }
        #expect(error?.code == .timeout)
    }

    @Test("oversized stdout is bounded and terminates the process group")
    func stdoutOverflow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appending(path: "descendant")
        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: """
                    /bin/sh -c 'trap "" TERM; printf "%s" $$ > "$1"; while :; do sleep 1; done' child "$0" &
                    while [ ! -s "$0" ]; do sleep 0.01; done
                    while :; do printf 0123456789abcdef; done
                    """,
                arguments: [descendantPIDFile.path(percentEncoded: false)],
                targetBundleID: "test.stdout-overflow",
                maximumOutputBytes: 1_024
            )
        }
        #expect(error?.detail == "applescript_output")
        try await waitUntilGone(try pid(from: descendantPIDFile))
    }

    @Test("oversized stderr is bounded and terminates the process group")
    func stderrOverflow() async {
        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: "while :; do printf 0123456789abcdef >&2; done",
                targetBundleID: "test.stderr-overflow",
                maximumOutputBytes: 1_024
            )
        }
        #expect(error?.detail == "applescript_output")
    }

    @Test("task cancellation terminates the process group and reaps the direct child")
    func cancellation() async throws {
        let runner = runner
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "pid")
        let descendantPIDFile = directory.appending(path: "descendant")
        let task = Task {
            try await runner.run(
                script: """
                    printf '%s' $$ > "$0"
                    /bin/sh -c 'trap "" TERM; printf "%s" $$ > "$1"; while :; do sleep 1; done' child "$1" &
                    while [ ! -s "$1" ]; do sleep 0.01; done
                    while :; do sleep 1; done
                    """,
                arguments: [
                    pidFile.path(percentEncoded: false),
                    descendantPIDFile.path(percentEncoded: false),
                ],
                targetBundleID: "test.cancellation"
            )
        }
        try await waitForFile(pidFile)
        try await waitForFile(descendantPIDFile)
        let childPID = try pid(from: pidFile)
        let descendantPID = try pid(from: descendantPIDFile)

        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await waitUntilGone(childPID)
        try await waitUntilGone(descendantPID)
    }

    @Test("spawn failure maps to the existing backend error")
    func spawnFailure() async {
        let missing = AppleScriptRunner(executable: URL(fileURLWithPath: "/nonexistent/atmark-fixture"))
        let error = await #expect(throws: AtmarkError.self) {
            try await missing.run(script: "exit 0", targetBundleID: "test.spawn-failure")
        }
        #expect(error?.code == .backendUnavailable)
        #expect(error?.detail == "osascript")
    }

    @Test("an executable that closes stdin immediately cannot raise SIGPIPE")
    func immediateExitIsSafe() async throws {
        let immediate = AppleScriptRunner(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let output = try await immediate.run(
            script: String(repeating: "trusted-script\n", count: 10_000),
            targetBundleID: "test.immediate-exit"
        )
        #expect(output.isEmpty == true)
    }

    @Test("nonzero exit preserves existing bounded stderr mapping")
    func normalFailure() async {
        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: "printf 'controlled diagnostic' >&2; exit 3",
                targetBundleID: "test.failure"
            )
        }
        #expect(error?.code == .backendUnavailable)
        #expect(error?.hint.contains("controlled diagnostic") == true)
    }

    @Test("a descendant is killed even after its process-group leader exits")
    func leaderExitStillCleansDescendant() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appending(path: "descendant")
        _ = try await runner.run(
            script: """
                /bin/sh -c 'trap "" TERM; printf "%s" $$ > "$1"; while :; do sleep 1; done' child "$0" &
                while [ ! -s "$0" ]; do sleep 0.01; done
                exit 0
                """,
            arguments: [descendantPIDFile.path(percentEncoded: false)],
            targetBundleID: "test.orphan-cleanup"
        )

        let descendantPID = try pid(from: descendantPIDFile)
        try await waitUntilGone(descendantPID)
    }

    @Test("timeout leaves no TERM-ignoring descendant alive")
    func timeoutLeavesNoChild() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantPIDFile = directory.appending(path: "descendant")
        let error = await #expect(throws: AtmarkError.self) {
            try await runner.run(
                script: """
                    /bin/sh -c 'trap "" TERM; printf "%s" $$ > "$1"; while :; do sleep 1; done' child "$0" &
                    while [ ! -s "$0" ]; do sleep 0.01; done
                    while :; do sleep 1; done
                """,
                arguments: [descendantPIDFile.path(percentEncoded: false)],
                targetBundleID: "test.timeout-child",
                operationTimeout: .seconds(1)
            )
        }
        #expect(error?.code == .timeout)
        let descendantPID = try pid(from: descendantPIDFile)
        try await waitUntilGone(descendantPID)
    }

    @Test("error mapping keeps actionable Automation and app state codes")
    func errorMapping() {
        #expect(AppleScriptRunner.error(from: "Not authorized (-1743)").code == .permissionDenied)
        #expect(AppleScriptRunner.error(from: "Application isn't running (-600)").code == .appNotRunning)
    }
}
