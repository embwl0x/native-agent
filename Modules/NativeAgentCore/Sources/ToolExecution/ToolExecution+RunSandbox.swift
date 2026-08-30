import Foundation
import NativeAgentCore
import PersistenceCore

/// Sandbox config for invoking a tool subprocess.
public struct ToolRunSandbox: Sendable {
    public let toolRoot: URL
    public let entrypoint: String
    public let timeoutSeconds: Int
    public let executableCommand: String

    public init(
        toolRoot: URL,
        entrypoint: String = "tool.swift",
        timeoutSeconds: Int = 10,
        executableCommand: String = "/usr/bin/swift"
    ) {
        self.toolRoot = toolRoot
        self.entrypoint = entrypoint
        self.timeoutSeconds = timeoutSeconds
        self.executableCommand = executableCommand
    }
}

public struct ToolRunResult: Sendable, Codable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let durationSeconds: Double
    public let timedOut: Bool
    public let parsedOutput: JSONValue?

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        durationSeconds: Double,
        timedOut: Bool,
        parsedOutput: JSONValue?
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.timedOut = timedOut
        self.parsedOutput = parsedOutput
    }
}

public enum ToolRunError: Error, LocalizedError {
    case toolNotActive(id: String, currentStatus: String)
    case fingerprintMismatch(expected: String, actual: String)
    case entrypointMissing(path: String)
    case spawnFailed(String)
    case timeout
    case outputLimitExceeded(stream: String, limitBytes: Int)
    case nonZeroExit(code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotActive(let id, let status):
            return "Tool \(id) is not active (status=\(status))"
        case .fingerprintMismatch(let expected, let actual):
            return "Tool code fingerprint mismatch (expected=\(expected) actual=\(actual))"
        case .entrypointMissing(let path):
            return "Tool entrypoint missing at \(path)"
        case .spawnFailed(let why):
            return "Failed to spawn tool subprocess: \(why)"
        case .timeout:
            return "Tool subprocess exceeded timeout and was killed"
        case .outputLimitExceeded(let stream, let limitBytes):
            return "Tool subprocess exceeded the \(limitBytes)-byte \(stream) capture limit and was killed"
        case .nonZeroExit(let code, let stderr):
            return "Tool subprocess exited \(code): \(stderr)"
        }
    }
}

/// SHA-256 fingerprint over manifest.json + entrypoint + tests.json bytes,
/// interleaved with `<basename>\0<bytes>\0` markers. Mirrors the daemon's
/// `tool_code_fingerprint`.
public func computeToolCodeFingerprint(toolRoot: URL, entrypointName: String) -> String {
    let entrypointURL = toolRoot.appendingPathComponent(entrypointName)
    let paths: [URL] = [
        toolRoot.appendingPathComponent("manifest.json"),
        entrypointURL,
        toolRoot.appendingPathComponent("tests.json"),
    ]
    var hasher = SHA256Streaming()
    for path in paths {
        let name = path.lastPathComponent
        hasher.update(Data(name.utf8))
        hasher.update(Data([0]))
        if let bytes = try? Data(contentsOf: path) {
            hasher.update(bytes)
        }
        hasher.update(Data([0]))
    }
    return hasher.finalizeHex()
}

/// Test-only escalation timeline events. Emitted from the reap thread so a
/// regression can prove the SIGTERM→grace→SIGKILL sequence actually ran (and
/// was not shortcut by a spurious cancellation signal). Never used in
/// production paths — the observer is nil unless a test installs one.
public enum ToolRunEscalationEvent: Sendable, Equatable {
    case initialWaitEnded(exited: Bool, cancelled: Bool, timedOut: Bool)
    case sigterm
    case sigkill
    case reaped
}

public actor ToolRunSandboxRunner {
    /// A tool result is provider-bound data, not an archival log. Keep each
    /// pipe comfortably above ordinary structured results while preventing a
    /// noisy or compromised subprocess from retaining memory until timeout.
    private static let maximumCapturedBytesPerStream = 4 * 1_024 * 1_024

    public init() {}

    /// Grace window (ms) between SIGTERM and SIGKILL in the reap escalation.
    /// Overridable via `_setEscalationGraceMillis` so a cancel-during-grace
    /// regression can widen the window and land its cancel deterministically.
    private var escalationGraceMillis: Int = 200
    /// Test observer for the escalation timeline (see `ToolRunEscalationEvent`).
    private var escalationObserver: (@Sendable (ToolRunEscalationEvent) -> Void)?

    /// Test seam — widen the SIGTERM→SIGKILL grace window.
    public func _setEscalationGraceMillis(_ ms: Int) { escalationGraceMillis = max(1, ms) }
    /// Test seam — observe the reap escalation timeline.
    public func _setEscalationObserver(_ observer: (@Sendable (ToolRunEscalationEvent) -> Void)?) {
        escalationObserver = observer
    }

    /// Invoke the tool with `input` as compact-JSON on stdin. Capture
    /// stdout/stderr/exitCode. Kill after timeoutSeconds. Returns ToolRunResult.
    public func runTool(
        sandbox: ToolRunSandbox,
        input: JSONValue,
        expectedFingerprint: String?,
        actualFingerprint: String?
    ) async throws -> ToolRunResult {
        if let expected = expectedFingerprint, !expected.isEmpty {
            let actual = actualFingerprint ?? computeToolCodeFingerprint(
                toolRoot: sandbox.toolRoot, entrypointName: sandbox.entrypoint
            )
            if expected != actual {
                throw ToolRunError.fingerprintMismatch(expected: expected, actual: actual)
            }
        }

        let entrypointURL = sandbox.toolRoot.appendingPathComponent(sandbox.entrypoint)
        if !FileManager.default.fileExists(atPath: entrypointURL.path) {
            throw ToolRunError.entrypointMissing(path: entrypointURL.path)
        }

        // If the enclosing Task was already cancelled before we spawn, bail
        // loud before creating a subprocess at all — no orphan to reap.
        try Task.checkCancellation()

        let inputBytes = try input.serializedData(pretty: false)

        let process = Process()
        let parts = sandbox.executableCommand.split(separator: " ").map(String.init)
        if parts.first == "/usr/bin/env" && parts.count >= 2 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = Array(parts.dropFirst()) + [entrypointURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: parts.first ?? "/usr/bin/env")
            process.arguments = Array(parts.dropFirst()) + [entrypointURL.path]
        }
        process.currentDirectoryURL = sandbox.toolRoot

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinWriter = try PipeInputWriter(
            handle: stdinPipe.fileHandleForWriting,
            input: inputBytes
        )
        // Two-channel wake accounting so cancellation can never corrupt the
        // kill escalation (W3d review, finding 1):
        //   • terminationSignal — signaled ONLY by the process terminationHandler
        //     (a genuine child exit). Consumed ONLY by the escalation grace-waits
        //     below. Because nothing else can signal it, a grace-wait that ends
        //     in `.success` PROVES the child died; `.timedOut` PROVES it is still
        //     alive. The escalation is therefore unpollutable.
        //   • wakeSignal — signaled by the terminationHandler (prompt wake on a
        //     real exit) AND by `onCancel` (prompt wake on cancellation).
        //     Consumed ONLY by the initial wait's slice loop; its counts never
        //     reach a grace-wait, so a cancel can never shortcut SIGTERM→SIGKILL.
        //   • terminatedBox — set ONLY by the terminationHandler; the escalation
        //     consults this flag (not raw wait results) to decide "already gone".
        let terminationSignal = DispatchSemaphore(value: 0)
        let wakeSignal = DispatchSemaphore(value: 0)
        let terminatedBox = TerminatedFlag()
        process.terminationHandler = { _ in
            terminatedBox.set(true)
            terminationSignal.signal()
            wakeSignal.signal()
        }

        let outputLimitBox = OutputLimitBox()
        let stdoutBuf = PipeCaptureBuffer(
            stream: "stdout",
            limitBytes: Self.maximumCapturedBytesPerStream,
            overflow: outputLimitBox
        )
        let stderrBuf = PipeCaptureBuffer(
            stream: "stderr",
            limitBytes: Self.maximumCapturedBytesPerStream,
            overflow: outputLimitBox
        )
        // Drain stdout/stderr continuously while the tool runs. This deliberately
        // avoids FileHandle.readabilityHandler: Foundation implements it with a
        // dispatch source, and full-suite parallel subprocess churn can close the
        // pipe while libdispatch still owns that source, tripping
        // "Unexpected EV_VANISHED". A nonblocking POSIX read loop has an explicit
        // stop point and no hidden descriptor owner.
        let stdoutDrain = try PipeDrainLoop(
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            buffer: stdoutBuf
        )
        let stderrDrain = try PipeDrainLoop(
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            buffer: stderrBuf
        )
        outputLimitBox.setWakeHandler { wakeSignal.signal() }
        stdoutDrain.start()
        stderrDrain.start()

        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            try process.run()
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            stdoutDrain.stopAndWait()
            stderrDrain.stopAndWait()
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw ToolRunError.spawnFailed(String(describing: error))
        }
        let childPid = process.processIdentifier
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(childPid)
        defer {
            if process.isRunning {
                ProcessTreeReaper.quiesceAndKill(
                    ProcessTreeReaper.snapshot(rootPID: childPid)
                )
            }
        }

        // Feed stdin off-thread without a blocking write. A descendant may
        // retain the read end after the direct child exits, so child exit alone
        // does not guarantee EPIPE or release this writer's input/thread.
        stdinWriter.start()

        let timeoutSeconds = max(1, sandbox.timeoutSeconds)
        let timedOutBox = TimedOutBox()
        let cancelledBox = CancelFlag()
        let pidRef = process
        let graceMillis = escalationGraceMillis
        let observer = escalationObserver

        // Wait for the child to exit, hit its timeout, or the enclosing Task to
        // be cancelled. `onCancel` bridges Swift cancellation onto the dedicated
        // reap thread by flipping `cancelledBox` and poking `wakeSignal` — it
        // NEVER touches `terminationSignal`, so the SIGTERM→grace→SIGKILL
        // escalation's grace-waits (which consult `terminationSignal` alone) can
        // only ever end on a genuine child exit. The block runs the SAME reap
        // escalation for a timeout and a cancel, so the child is reaped on both
        // paths — no orphaned process.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // A dedicated thread is intentional. Full-suite subprocess
                // churn can saturate the shared GCD pool; cancellation/reaping
                // is lifecycle-critical and must not wait behind unrelated
                // global-queue work.
                let reaper = Thread {
                    // Initial wait is purely event/deadline driven. A child
                    // exit and cancellation both signal `wakeSignal`; no
                    // periodic polling heartbeat is needed.
                    let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
                    while true {
                        if terminatedBox.get() { break }
                        if cancelledBox.get() { break }
                        if outputLimitBox.exceeded != nil { break }
                        if wakeSignal.wait(timeout: deadline) == .timedOut { break }
                    }

                    let didExit = terminatedBox.get()
                    let wasCancelled = cancelledBox.get()
                    let exceededOutputLimit = outputLimitBox.exceeded != nil
                    observer?(.initialWaitEnded(
                        exited: didExit,
                        cancelled: wasCancelled,
                        timedOut: !didExit && !wasCancelled && !exceededOutputLimit
                    ))

                    if !didExit {
                        // Timeout or cancel — escalate to reap the child.
                        // Cancellation takes priority over timeout for the
                        // surfaced error; only stamp timedOut when NOT cancelled.
                        if !wasCancelled && !exceededOutputLimit { timedOutBox.set(true) }
                        let terminationTree = ProcessTreeReaper.snapshot(rootPID: childPid)
                        ProcessTreeReaper.signal(terminationTree, signal: SIGTERM)
                        observer?(.sigterm)
                        // Grace-wait consults `terminationSignal` ALONE. It can
                        // ONLY end early on a genuine exit — a cancel that lands
                        // during this window signals `wakeSignal`, never this
                        // semaphore, so it cannot shortcut the SIGKILL. Consult
                        // `terminatedBox` too, belt-and-suspenders, so the kill
                        // decision keys on the real-exit flag rather than a raw
                        // wait result.
                        let graceExpired = terminationSignal.wait(
                            timeout: .now() + .milliseconds(graceMillis)
                        ) == .timedOut
                        let killTree = ProcessTreeReaper.snapshot(
                            rootPID: childPid,
                            retaining: terminationTree
                        )
                        if (graceExpired && !terminatedBox.get())
                            || ProcessTreeReaper.hasLiveDescendant(in: killTree) {
                            // Freeze the verified tree, rescan it, then kill.
                            // A one-shot leaf-first SIGKILL leaves a narrow
                            // scan-vs-fork race where the tool can create a new
                            // child after the snapshot and orphan it as the
                            // parent dies.
                            ProcessTreeReaper.quiesceAndKill(killTree)
                            observer?(.sigkill)
                        }
                        // Do not make prompt cancellation depend on the
                        // scheduling latency of Foundation's termination
                        // callback. `waitUntilExit` performs the authoritative
                        // reap on this dedicated thread after the direct PID has
                        // received an unignorable SIGKILL when needed.
                        if pidRef.isRunning { pidRef.waitUntilExit() }
                        observer?(.reaped)
                    }
                    cont.resume()
                }
                reaper.qualityOfService = .userInitiated
                reaper.start()
            }
        } onCancel: {
            cancelledBox.set(true)
            // Wake the initial wait's slice loop NOW. Signals `wakeSignal` ONLY —
            // never `terminationSignal` — so the escalation grace-waits stay
            // honest (a spurious cancel can't be mistaken for a child exit).
            wakeSignal.signal()
        }
        process.terminationHandler = nil
        stdinWriter.stopAndWait()

        let endNs = DispatchTime.now().uptimeNanoseconds
        let duration = Double(endNs &- startNs) / 1_000_000_000.0

        // Stop the readers after the direct child exits. A grandchild may keep a
        // write end inherited from stdout/stderr open forever, so the readers do
        // not wait for EOF here.
        stdoutDrain.stopAndWait()
        stderrDrain.stopAndWait()
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        // Cancellation is loud and takes priority: the child was reaped by the
        // escalation above (the function-scope `defer` is a final SIGKILL
        // backstop), the drain threads are joined, so surface CancellationError
        // rather than a silent partial result. Checked before `timedOut`
        // because a cancel never stamps `timedOutBox`.
        if cancelledBox.get() {
            throw CancellationError()
        }

        if let exceeded = outputLimitBox.exceeded {
            throw ToolRunError.outputLimitExceeded(
                stream: exceeded.stream,
                limitBytes: exceeded.limitBytes
            )
        }

        let stdoutData = stdoutBuf.data
        let stderrData = stderrBuf.data

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
        let exit = process.terminationStatus
        let timedOut = timedOutBox.get()

        if timedOut {
            throw ToolRunError.timeout
        }

        let parsed: JSONValue? = (try? JSONValue.parse(stdoutData))

        if exit != 0 {
            throw ToolRunError.nonZeroExit(code: exit, stderr: stderrStr)
        }

        return ToolRunResult(
            stdout: stdoutStr,
            stderr: stderrStr,
            exitCode: exit,
            durationSeconds: duration,
            timedOut: false,
            parsedOutput: parsed
        )
    }
}

// MARK: - Helpers

private final class TimedOutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe cancellation flag — flipped by the `onCancel` handler (which
/// runs off-actor on the cancelling task's thread) and read on the GCD wait
/// thread + the actor after the wait resumes.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Thread-safe real-exit flag — set ONLY by the process terminationHandler
/// (which fires off-actor on a background queue) and read on the reap thread.
/// The escalation keys its "already gone?" decision on this, not on raw
/// semaphore wait results, so a cancel can never masquerade as a child exit.
private final class TerminatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// Thread-safe capture buffer for subprocess pipes — appended from drain
// workers, read on the actor after exit.
final class OutputLimitBox: @unchecked Sendable {
    struct Exceeded: Sendable {
        let stream: String
        let limitBytes: Int
    }

    private let lock = NSLock()
    private var value: Exceeded?
    private var wakeHandler: (@Sendable () -> Void)?

    var exceeded: Exceeded? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setWakeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        wakeHandler = handler
        let shouldWake = value != nil
        lock.unlock()
        if shouldWake { handler() }
    }

    func markExceeded(stream: String, limitBytes: Int) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = Exceeded(stream: stream, limitBytes: limitBytes)
        let handler = wakeHandler
        lock.unlock()
        handler?()
    }
}

final class PipeCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let stream: String
    private let limitBytes: Int
    private let overflow: OutputLimitBox

    init(stream: String, limitBytes: Int, overflow: OutputLimitBox) {
        self.stream = stream
        self.limitBytes = limitBytes
        self.overflow = overflow
    }

    func append(_ chunk: Data) {
        lock.lock()
        let available = max(0, limitBytes - storage.count)
        if available > 0 {
            storage.append(chunk.prefix(available))
        }
        let exceeded = chunk.count > available
        lock.unlock()
        if exceeded {
            overflow.markExceeded(stream: stream, limitBytes: limitBytes)
        }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Foundation Pipe handles are not close-on-exec by default. A subprocess
/// inheriting a stop-channel writer could keep our POLLHUP edge from arriving.
func makeToolSandboxWakePipe() throws -> Pipe {
    let pipe = Pipe()
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
        let flags = fcntl(handle.fileDescriptor, F_GETFD, 0)
        guard flags >= 0,
              fcntl(handle.fileDescriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ToolRunError.spawnFailed("stop pipe setup failed (errno \(errno))")
        }
    }
    return pipe
}

/// One input payload, with an explicit lifetime bounded by the tool invocation.
/// Full stdin waits on writability OR a private stop pipe, with no polling tick.
final class PipeInputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let input: Data
    private let wake: Pipe
    private let lock = NSLock()
    private let done = DispatchGroup()
    private var started = false
    private var stopped = false

    init(handle: FileHandle, input: Data) throws {
        self.handle = handle
        self.input = input
        self.wake = try makeToolSandboxWakePipe()
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw ToolRunError.spawnFailed("stdin pipe setup failed (errno \(errno))")
        }
    }

    func start() {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return }
        started = true
        done.enter()
        lock.unlock()
        let thread = Thread { [self] in
            defer {
                try? handle.close()
                done.leave()
            }
            input.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    if isStopped() { return }
                    let written = Darwin.write(handle.fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                    if written > 0 { offset += written; continue }
                    if written == 0 { return }
                    if errno == EINTR { continue }
                    guard errno == EAGAIN || errno == EWOULDBLOCK else { return }
                    guard waitUntilWritable() else { return }
                }
            }
        }
        thread.name = "ToolRunSandbox.stdin"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopAndWait() {
        lock.lock()
        let signalStop = !stopped
        stopped = true
        let wasStarted = started
        lock.unlock()
        // Closing this private write end wakes poll with POLLHUP. No write can
        // block, and the data descriptor stays owned by the writer until join.
        if signalStop { try? wake.fileHandleForWriting.close() }
        if wasStarted { done.wait() } else { try? handle.close() }
    }

    private func waitUntilWritable() -> Bool {
        while !isStopped() {
            var descriptors = [
                pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: wake.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let result = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), -1)
            }
            if result < 0 {
                if errno == EINTR { continue }
                return false
            }
            if descriptors[1].revents != 0 { return false }
            if descriptors[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
            if descriptors[0].revents & Int16(POLLOUT) != 0 { return true }
        }
        return false
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

final class PipeDrainLoop: @unchecked Sendable {
    private let fd: Int32
    private let buffer: PipeCaptureBuffer
    private let wake: Pipe
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var started = false

    init(fileDescriptor: Int32, buffer: PipeCaptureBuffer) throws {
        self.fd = fileDescriptor
        self.buffer = buffer
        self.wake = try makeToolSandboxWakePipe()
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let thread = Thread { [self] in
            defer { done.signal() }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            var stopBytesRemaining: Int?
            while true {
                while true {
                    if stopBytesRemaining == nil, isStopped() {
                        // A surviving descendant can refill the pipe forever,
                        // so EAGAIN is not a shutdown boundary. Preserve only
                        // the finite backlog already queued at stop, then join
                        // before the caller closes (and may reuse) this FD.
                        var available: Int32 = 0
                        // Darwin FIONREAD = _IOR('f', 127, int). Swift cannot
                        // import the sizeof-based C macro from sys/filio.h.
                        let fionread: UInt = 0x4000_0000 | (UInt(MemoryLayout<Int32>.size) << 16)
                            | (UInt(0x66) << 8) | 127
                        guard ioctl(fd, fionread, &available) == 0 else { return }
                        stopBytesRemaining = max(0, Int(available))
                    }
                    let count = min(chunk.count, stopBytesRemaining ?? chunk.count)
                    if count == 0 { return }
                    let n = read(fd, &chunk, count)
                    if n > 0 {
                        buffer.append(Data(bytes: chunk, count: n))
                        if let remaining = stopBytesRemaining {
                            stopBytesRemaining = remaining - n
                        }
                        continue
                    }
                    if n == 0 { return } // EOF: all writers closed.
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return
                }

                // Stop may have arrived just after EAGAIN while the exiting
                // parent queued its final bytes. Re-enter the snapshot path
                // instead of dropping that tail here.
                if isStopped() { continue }
                // Quiet tools need no heartbeat. Wait for readable bytes/EOF
                // or our private stop edge; unlike readabilityHandler this
                // has no hidden dispatch-source descriptor owner.
                var descriptors = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                ]
                let ready = descriptors.withUnsafeMutableBufferPointer {
                    Darwin.poll($0.baseAddress, nfds_t($0.count), -1)
                }
                if ready < 0, errno != EINTR { return }
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopAndWait() {
        lock.lock()
        let signalStop = !stopped
        stopped = true
        let wasStarted = started
        lock.unlock()
        if signalStop { try? wake.fileHandleForWriting.close() }
        if wasStarted {
            // The stopped reader consumes a finite nonblocking snapshot. Do
            // not time out and close its descriptor while it still owns it.
            done.wait()
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

// Minimal streaming SHA-256 wrapper over CommonCrypto.
import CommonCrypto

private struct SHA256Streaming {
    private var ctx = CC_SHA256_CTX()
    init() { CC_SHA256_Init(&ctx) }
    mutating func update(_ data: Data) {
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress, buf.count > 0 {
                CC_SHA256_Update(&ctx, base, CC_LONG(buf.count))
            }
        }
    }
    mutating func finalizeHex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
