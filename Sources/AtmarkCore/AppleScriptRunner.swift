import Darwin
import Foundation

/// Runs repository-authored AppleScript with caller values in argv, under
/// per-target serialization and bounded process resources.
public struct AppleScriptRunner: Sendable {
    public static let defaultQueueTimeout: Duration = .seconds(2)
    public static let defaultOperationTimeout: Duration = .seconds(15)
    public static let defaultMaximumOutputBytes = 1 * 1024 * 1024

    /// Kept as a source-compatible name for callers that used the original
    /// operation-time budget.
    public static let defaultTimeout = defaultOperationTimeout

    private let executable: URL
    private let lanes: AppleScriptLanes

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.executable = executable
        self.lanes = AppleScriptLanes()
    }

    /// Runs trusted `script` text on stdin and untrusted `arguments` in argv.
    /// Calls for one target bundle ID serialize; unrelated targets may overlap.
    public func run(
        script: String,
        arguments: [String] = [],
        targetBundleID: String,
        queueTimeout: Duration = AppleScriptRunner.defaultQueueTimeout,
        operationTimeout: Duration = AppleScriptRunner.defaultOperationTimeout,
        maximumOutputBytes: Int = AppleScriptRunner.defaultMaximumOutputBytes
    ) async throws -> String {
        guard targetBundleID.isEmpty == false else {
            throw AtmarkError(
                .invalidArgument,
                detail: "targetBundleID",
                hint: "Provide the bundle identifier of the app this repository-authored script targets."
            )
        }
        guard queueTimeout > .zero, operationTimeout > .zero else {
            throw AtmarkError(
                .invalidArgument,
                detail: "timeout",
                hint: "Queue and operation timeouts must both be greater than zero."
            )
        }
        guard maximumOutputBytes > 0 else {
            throw AtmarkError(
                .invalidArgument,
                detail: "maximumOutputBytes",
                hint: "Set maximumOutputBytes to a positive bounded value."
            )
        }

        return try await lanes.run(target: targetBundleID, timeout: queueTimeout) {
            try await Self.execute(
                executable: executable,
                script: script,
                arguments: arguments,
                timeout: operationTimeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }
    }

    private static func execute(
        executable: URL,
        script: String,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> String {
        let process: SpawnedProcess
        do {
            process = try SpawnedProcess.spawn(executable: executable, arguments: ["-"] + arguments)
        } catch {
            throw AtmarkError(
                .backendUnavailable,
                detail: "osascript",
                hint: "Could not run osascript. This is unexpected on macOS; check the system installation."
            )
        }

        let controller = ProcessGroupController(processGroupID: process.pid)
        let outputTask = BlockingOperation {
            readBounded(
                fileDescriptor: process.standardOutput,
                maximumBytes: maximumOutputBytes,
                overflow: .standardOutput,
                controller: controller
            )
        }
        let errorTask = BlockingOperation {
            readBounded(
                fileDescriptor: process.standardError,
                maximumBytes: maximumOutputBytes,
                overflow: .standardError,
                controller: controller
            )
        }
        let waitTask = BlockingOperation { waitForProcess(process.pid) }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                controller.requestTermination(.timeout)
            } catch {
                // The direct child completed before its operation budget.
            }
        }

        let status = await withTaskCancellationHandler {
            writeAll(Data(script.utf8), to: process.standardInput)
            close(process.standardInput)
            return await waitTask.value()
        } onCancel: {
            controller.requestTermination(.cancelled)
        }
        timeoutTask.cancel()
        if Task.isCancelled { controller.requestTermination(.cancelled) }

        // A process-group leader may exit while a descendant keeps the output
        // pipes open. The operation owns that entire group, so completion also
        // cleans up any such descendant before waiting for EOF.
        if controller.reason == nil && processGroupExists(process.pid) {
            controller.requestCleanup()
        }
        await controller.waitForEscalation()

        let output = await outputTask.value()
        let errors = await errorTask.value()

        switch controller.reason {
        case .cancelled:
            throw CancellationError()
        case .timeout:
            throw AtmarkError(
                .timeout,
                detail: "applescript",
                hint: "The app did not respond within \(timeout). Retry, or narrow the request."
            )
        case .standardOutput, .standardError:
            throw AtmarkError(
                .backendUnavailable,
                detail: "applescript_output",
                hint: "The script exceeded its bounded output budget. Narrow the request and retry."
            )
        case nil:
            break
        }

        guard exitedSuccessfully(status) else {
            throw error(from: String(decoding: errors, as: UTF8.self))
        }

        // Only trailing line endings from the executable are removed. Leading
        // or trailing spaces may be user data and must survive unchanged.
        var text = String(decoding: output, as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }

    static func error(from stderr: String) -> AtmarkError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.contains("-1743") || text.localizedCaseInsensitiveContains("Not authorized") {
            return AtmarkError(
                .permissionDenied,
                detail: "automation",
                hint: "Grant Atmark control of this app in System Settings › Privacy & Security › Automation, then retry."
            )
        }
        if text.contains("-600") || text.contains("-609")
            || text.localizedCaseInsensitiveContains("Application isn't running")
        {
            return AtmarkError(
                .appNotRunning,
                detail: "target",
                hint: "Open the app and retry. Atmark does not launch apps on your behalf."
            )
        }
        return AtmarkError(
            .backendUnavailable,
            detail: "applescript",
            hint: text.isEmpty ? "The script failed with no diagnostic." : String(text.prefix(200))
        )
    }
}

private actor AppleScriptLanes {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct Lane {
        var owner: UUID?
        var waiters: [Waiter] = []
    }

    private var lanes: [String: Lane] = [:]

    func run<T: Sendable>(
        target: String,
        timeout: Duration,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(target: target, id: id, timeout: timeout)
        defer { release(target: target, id: id) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(target: String, id: UUID, timeout: Duration) async throws {
        var lane = lanes[target] ?? Lane()
        guard lane.owner != nil else {
            lane.owner = id
            lanes[target] = lane
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.failWaiter(target: target, id: id, error: Self.queueTimeoutError)
                }
                lane.waiters.append(Waiter(id: id, continuation: continuation, timeoutTask: timeoutTask))
                lanes[target] = lane
            }
        } onCancel: {
            Task { await self.failWaiter(target: target, id: id, error: CancellationError()) }
        }
    }

    private func release(target: String, id: UUID) {
        guard var lane = lanes[target], lane.owner == id else { return }
        guard lane.waiters.isEmpty == false else {
            lanes[target] = nil
            return
        }

        let waiter = lane.waiters.removeFirst()
        waiter.timeoutTask.cancel()
        lane.owner = waiter.id
        lanes[target] = lane
        waiter.continuation.resume()
    }

    private func failWaiter(target: String, id: UUID, error: any Error) {
        guard var lane = lanes[target],
              let index = lane.waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = lane.waiters.remove(at: index)
        waiter.timeoutTask.cancel()
        lanes[target] = lane
        waiter.continuation.resume(throwing: error)
    }

    private static var queueTimeoutError: AtmarkError {
        AtmarkError(
            .timeout,
            detail: "applescript_queue",
            hint: "The target app is still busy. Narrow the request or retry after the current operation finishes."
        )
    }
}

private struct SpawnedProcess: Sendable {
    let pid: pid_t
    let standardInput: Int32
    let standardOutput: Int32
    let standardError: Int32

    static func spawn(executable: URL, arguments: [String]) throws -> SpawnedProcess {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&output) == 0 else {
            close(input[0]); close(input[1])
            throw POSIXError(.EMFILE)
        }
        guard pipe(&errors) == 0 else {
            close(input[0]); close(input[1]); close(output[0]); close(output[1])
            throw POSIXError(.EMFILE)
        }
        guard fcntl(input[1], F_SETNOSIGPIPE, 1) == 0 else {
            close(input[0]); close(input[1]); close(output[0]); close(output[1])
            close(errors[0]); close(errors[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionsInitialized = false
        var attributesInitialized = false
        defer {
            if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        }

        func requireZero(_ status: Int32) throws {
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
        }

        do {
            try requireZero(posix_spawn_file_actions_init(&actions))
            actionsInitialized = true
            try requireZero(posix_spawnattr_init(&attributes))
            attributesInitialized = true
            try requireZero(posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ))
            try requireZero(posix_spawnattr_setpgroup(&attributes, 0))

            try requireZero(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO))
            try requireZero(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
            try requireZero(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
            for descriptor in input + output + errors {
                try requireZero(posix_spawn_file_actions_addclose(&actions, descriptor))
            }

            let strings = [executable.path(percentEncoded: false)] + arguments
            let duplicated = strings.map { strdup($0) }
            defer { duplicated.forEach { free($0) } }
            var argv = duplicated + [nil]
            var pid: pid_t = 0
            let status = argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &pid,
                    executable.path(percentEncoded: false),
                    &actions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
            try requireZero(status)

            close(input[0]); close(output[1]); close(errors[1])
            return SpawnedProcess(
                pid: pid,
                standardInput: input[1],
                standardOutput: output[0],
                standardError: errors[0]
            )
        } catch {
            for descriptor in input + output + errors where descriptor >= 0 {
                close(descriptor)
            }
            throw error
        }
    }
}

private enum TerminationReason: Sendable {
    case cancelled
    case timeout
    case standardOutput
    case standardError
}

/// `read(2)` and `waitpid(2)` are blocking syscalls. Running them in detached
/// Swift tasks can exhaust the cooperative executor when several apps are busy,
/// starving the very timeout tasks that must stop them. This narrow bridge owns
/// one GCD work item and resumes one checked continuation with its value.
private final class BlockingOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    init(operation: @escaping @Sendable () -> Value) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            finish(operation())
        }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Value? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    private func finish(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            if let continuation {
                self.continuation = nil
                return continuation
            }
            result = value
            return nil
        }
        waiting?.resume(returning: value)
    }
}

private final class ProcessGroupController: @unchecked Sendable {
    private let lock = NSLock()
    private let processGroupID: pid_t
    private var storedReason: TerminationReason?
    private var escalation: Task<Void, Never>?

    init(processGroupID: pid_t) {
        self.processGroupID = processGroupID
    }

    var reason: TerminationReason? {
        lock.withLock { storedReason }
    }

    func requestTermination(_ reason: TerminationReason) {
        lock.withLock {
            guard storedReason == nil else { return }
            storedReason = reason
            startEscalationLocked()
        }
    }

    func requestCleanup() {
        lock.withLock { startEscalationLocked() }
    }

    func waitForEscalation() async {
        let task = lock.withLock { escalation }
        await task?.value
    }

    private func startEscalationLocked() {
        guard escalation == nil else { return }
        kill(-processGroupID, SIGTERM)
        let group = processGroupID
        escalation = Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            if processGroupExists(group) {
                kill(-group, SIGKILL)
            }
        }
    }
}

private func readBounded(
    fileDescriptor: Int32,
    maximumBytes: Int,
    overflow: TerminationReason,
    controller: ProcessGroupController
) -> Data {
    defer { close(fileDescriptor) }
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    while true {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 { return collected }
        if count < 0 {
            if errno == EINTR { continue }
            return collected
        }

        let remaining = maximumBytes - collected.count
        if count > remaining {
            if remaining > 0 { collected.append(contentsOf: buffer.prefix(remaining)) }
            controller.requestTermination(overflow)
            return collected
        }
        collected.append(contentsOf: buffer.prefix(count))
    }
}

private func writeAll(_ data: Data, to fileDescriptor: Int32) {
    data.withUnsafeBytes { rawBuffer in
        guard var address = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let count = write(fileDescriptor, address, remaining)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            remaining -= count
            address = address.advanced(by: count)
        }
    }
}

private func waitForProcess(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { return -1 }
    }
    return status
}

private func exitedSuccessfully(_ status: Int32) -> Bool {
    status >= 0 && (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0
}

private func processGroupExists(_ processGroupID: pid_t) -> Bool {
    if kill(-processGroupID, 0) == 0 { return true }
    return errno == EPERM
}
