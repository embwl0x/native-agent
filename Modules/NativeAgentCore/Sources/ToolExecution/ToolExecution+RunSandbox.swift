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

        let stdoutBuf = PipeCaptureBuffer()
        let stderrBuf = PipeCaptureBuffer()
        // Drain stdout/stderr continuously while the tool runs. This deliberately
        // avoids FileHandle.readabilityHandler: Foundation implements it with a
        // dispatch source, and full-suite parallel subprocess churn can close the
        // pipe while libdispatch still owns that source, tripping
        // "Unexpected EV_VANISHED". A nonblocking POSIX read loop has an explicit
        // stop point and no hidden descriptor owner.
        let stdoutDrain = PipeDrainLoop(
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            buffer: stdoutBuf
        )
        let stderrDrain = PipeDrainLoop(
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            buffer: stderrBuf
        )
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
                ProcessTreeReaper.signal(
                    ProcessTreeReaper.snapshot(rootPID: childPid),
                    signal: SIGKILL
                )
            }
        }

        // Feed stdin off-thread: a synchronous write of more than the pipe
        // buffer to a tool that never reads stdin would otherwise pin this
        // cooperative-pool thread until the watchdog kill. Child exit closes
        // the read end, which unblocks the writer with EPIPE (swallowed).
        let stdinWriter = Thread {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: inputBytes)
            try? stdinPipe.fileHandleForWriting.close()
        }
        stdinWriter.qualityOfService = .userInitiated
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
                        if wakeSignal.wait(timeout: deadline) == .timedOut { break }
                    }

                    let didExit = terminatedBox.get()
                    let wasCancelled = cancelledBox.get()
                    observer?(.initialWaitEnded(
                        exited: didExit,
                        cancelled: wasCancelled,
                        timedOut: !didExit && !wasCancelled
                    ))

                    if !didExit {
                        // Timeout or cancel — escalate to reap the child.
                        // Cancellation takes priority over timeout for the
                        // surfaced error; only stamp timedOut when NOT cancelled.
                        if !wasCancelled { timedOutBox.set(true) }
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
                            ProcessTreeReaper.signal(killTree, signal: SIGKILL)
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
private final class PipeCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) { lock.lock(); storage.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class PipeDrainLoop: @unchecked Sendable {
    private let fd: Int32
    private let buffer: PipeCaptureBuffer
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var started = false

    init(fileDescriptor: Int32, buffer: PipeCaptureBuffer) {
        self.fd = fileDescriptor
        self.buffer = buffer
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
            while true {
                var madeProgress = false
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n > 0 {
                        madeProgress = true
                        buffer.append(Data(bytes: chunk, count: n))
                        continue
                    }
                    if n == 0 { return } // EOF: all writers closed.
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return
                }

                if isStopped() { return }
                if madeProgress {
                    usleep(1_000)
                } else {
                    usleep(5_000)
                }
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopAndWait() {
        lock.lock()
        stopped = true
        let wasStarted = started
        lock.unlock()
        if wasStarted {
            _ = done.wait(timeout: .now() + .seconds(5))
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
