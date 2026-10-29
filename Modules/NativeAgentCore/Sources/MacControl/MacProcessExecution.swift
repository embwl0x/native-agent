import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import OSAKit
import os
#endif

// Blueprint: | `MacProcessExecution.swift` | `ProcessExecution`, `ProcessRunResult` and `ProcessRunCancellation`: shared process launch, bounded capture, pipe-setup error translation, cancellation settlement, timeout escalation and identity-bound process-tree reaping; SSH and local callers use the same runner |

public struct ProcessRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

/// Stop ended a launched process. Its drained output belongs to settlement.
public struct ProcessRunCancellation: Error, Sendable, LocalizedError {
    public let result: ProcessRunResult
    public var errorDescription: String? { "Process cancelled after launch; captured output is retained in result." }
}

public final class ProcessExecution: Sendable {
    public static let defaultOutputByteLimit = 1_048_576

    public init() {}
    final class _Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let byteLimit: Int
        private var data = Data()
        private var droppedBytes = 0

        init(byteLimit: Int?) {
            self.byteLimit = max(0, byteLimit ?? ProcessExecution.defaultOutputByteLimit)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            let room = max(0, byteLimit - data.count)
            if room > 0 { data.append(chunk.prefix(room)) }
            droppedBytes += max(0, chunk.count - room)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return droppedBytes > 0
        }
    }


    /// Owns process-tree termination for timeout and parent Task cancellation.
    /// Timeout gets a cooperative SIGTERM -> SIGKILL window; explicit user
    /// cancellation SIGKILLs immediately so descendants cannot continue side
    /// effects after cancellation has been acknowledged.
    private final class _ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let initialTree: ProcessTreeSnapshot
        private let onSettled: @Sendable () -> Void
        private var requested = false
        private var timeoutRequested = false
        private var cancelEscalationRequested = false
        private var activeTerminationTree: ProcessTreeSnapshot?
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let cancelEscalationSignal = DispatchSemaphore(value: 0)

        init(
            process: Process,
            initialTree: ProcessTreeSnapshot,
            onSettled: @escaping @Sendable () -> Void
        ) {
            self.process = process
            self.initialTree = initialTree
            self.onSettled = onSettled
        }

        func request(timedOut: Bool) {
            lock.lock()
            if requested {
                // A deadline may already own the graceful TERM window when the
                // parent Task is explicitly cancelled. Cancellation is the
                // stronger motor instruction: wake the existing termination
                // worker so it freezes, rescans, and KILLs the identity-bound
                // tree immediately instead of allowing side effects to continue
                // through the rest of the grace period. The original worker
                // remains the only owner of waitUntilExit/finish.
                let shouldEscalate = !timedOut
                    && timeoutRequested
                    && !finished
                    && !cancelEscalationRequested
                let escalationTree = shouldEscalate ? activeTerminationTree : nil
                if shouldEscalate {
                    cancelEscalationRequested = true
                }
                lock.unlock()
                if shouldEscalate {
                    cancelEscalationSignal.signal()
                    if let escalationTree {
                        // Do the motor stop on the cancellation caller that is
                        // already running. Merely waking the timeout worker can
                        // leave it CPU-starved under machine load. This path
                        // performs signals only; the original worker remains
                        // the sole owner of waitUntilExit and finish/resume.
                        let refreshed = ProcessTreeReaper.snapshot(
                            rootPID: escalationTree.rootPID,
                            retaining: escalationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(refreshed)
                    }
                }
                return
            }
            requested = true
            timeoutRequested = timedOut
            let pid = process.processIdentifier
            lock.unlock()
            guard pid > 0 else {
                finish()
                return
            }

            // Snapshot descendants before signaling the shell. Once the root
            // exits, a surviving grandchild may be reparented and disappear
            // from a later parent-only traversal.
            let terminationTree = Self.captureTree(rootPID: pid, retaining: initialTree)
            lock.lock()
            activeTerminationTree = terminationTree
            let cancellationAlreadyEscalated = cancelEscalationRequested
            lock.unlock()
            if cancellationAlreadyEscalated {
                let refreshed = ProcessTreeReaper.snapshot(
                    rootPID: terminationTree.rootPID,
                    retaining: terminationTree
                )
                _ = ProcessTreeReaper.quiesceAndKill(refreshed)
            }
            let worker = Thread { [self, process] in
                // User cancellation is not a graceful-shutdown request: it is
                // an instruction that no descendant may continue producing
                // side effects. Freeze the tree before the kill/rescan so a
                // shell cannot fork a job-control child between enumeration
                // and its own death. Timeout retains the cooperative TERM window.
                if !timedOut {
                    let frozenTree = ProcessTreeReaper.quiesceAndKill(terminationTree)
                    if process.isRunning { process.waitUntilExit() }
                    let settledTree = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: frozenTree
                    )
                    if ProcessTreeReaper.hasLiveDescendant(in: settledTree) {
                        ProcessTreeReaper.signal(settledTree, signal: SIGKILL)
                    }
                    finish()
                    return
                }
                ProcessTreeReaper.signal(terminationTree, signal: SIGTERM)

                // Preserve the established two-second graceful shutdown
                // budget, but finish immediately once the identity-bound tree
                // and direct Process have actually settled.
                let deadline = DispatchTime.now() + .seconds(2)
                while DispatchTime.now() < deadline {
                    let refreshed = ProcessTreeReaper.snapshot(
                        rootPID: pid,
                        retaining: terminationTree
                    )
                    if !process.isRunning
                        && !ProcessTreeReaper.hasLiveDescendant(in: refreshed) {
                        break
                    }
                    if cancellationEscalationWasRequested() {
                        // Rescan from the original identity-bound snapshot
                        // before freezing/KILLing. This retains descendants that
                        // were reparented after the root received SIGTERM while
                        // still refusing PID-reuse matches.
                        let escalationTree = ProcessTreeReaper.snapshot(
                            rootPID: pid,
                            retaining: terminationTree
                        )
                        _ = ProcessTreeReaper.quiesceAndKill(escalationTree)
                        if process.isRunning { process.waitUntilExit() }
                        finish()
                        return
                    }
                    _ = cancelEscalationSignal.wait(timeout: .now() + .milliseconds(5))
                }

                let killTree = ProcessTreeReaper.snapshot(
                    rootPID: pid,
                    retaining: terminationTree
                )
                if process.isRunning || ProcessTreeReaper.hasLiveDescendant(in: killTree) {
                    _ = ProcessTreeReaper.quiesceAndKill(killTree)
                }
                if process.isRunning { process.waitUntilExit() }
                finish()
            }
            worker.qualityOfService = .userInitiated
            worker.start()
        }

        static func captureTree(rootPID: Int32, retaining prior: ProcessTreeSnapshot? = nil) -> ProcessTreeSnapshot {
            let tree = ProcessTreeReaper.snapshot(rootPID: rootPID, retaining: prior)
            #if canImport(Darwin)
            // A shell may have exited and reparented its pipe-owning children.
            // Capture group members at launch even if the root has already
            // exited. Later scans retain those identities and reject a reused
            // root PID; signals never rely on a naked process-group id.
            guard rootPID > 0 else { return tree }
            if let prior {
                if let liveRoot = ProcessTreeReaper.snapshot(rootPID: rootPID).rootIdentity,
                   liveRoot != prior.rootIdentity { return tree }
                guard prior.rootIdentity != nil || !prior.descendants.isEmpty else { return tree }
            }
            let earliest = prior?.rootIdentity ?? tree.rootIdentity ?? prior?.descendants.min {
                ($0.startSeconds, $0.startMicroseconds) < ($1.startSeconds, $1.startMicroseconds)
            }
            let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(rootPID), nil, 0)
            guard bytes > 0 else { return tree }
            var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride + 16)
            let used = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(rootPID), &pids,
                                    Int32(pids.count * MemoryLayout<Int32>.stride))
            var identities = tree.descendants
            for pid in pids.prefix(max(0, Int(used)) / MemoryLayout<Int32>.stride) where pid > 0 && pid != rootPID {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                      info.pbi_pgid == UInt32(rootPID)
                else { continue }
                if let earliest,
                   (info.pbi_start_tvsec, info.pbi_start_tvusec) < (earliest.startSeconds, earliest.startMicroseconds) {
                    continue
                }
                let identity = ProcessTreeIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                                                   startMicroseconds: info.pbi_start_tvusec)
                if !identities.contains(identity) { identities.append(identity) }
            }
            return ProcessTreeSnapshot(rootPID: tree.rootPID, rootIdentity: tree.rootIdentity, descendants: identities)
            #else
            return tree
            #endif
        }

        private func cancellationEscalationWasRequested() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelEscalationRequested
        }

        func waitIfRequested() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !requested || finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            activeTerminationTree = nil
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
            onSettled()
        }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timeoutRequested
        }
    }

    /// Launch and cancellation share admission; cancellation before admission
    /// cannot race a child into existence. The termination owner is attached
    /// while that admission is held, before a cancellation can proceed.
    private final class _ProcessLaunch: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var termination: _ProcessTermination?

        func start(_ body: () throws -> _ProcessTermination) throws -> _ProcessTermination {
            lock.lock()
            defer { lock.unlock() }
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            let owner = try body()
            termination = owner
            return owner
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let owner = termination
            lock.unlock()
            owner?.request(timedOut: false)
        }
    }

    /// The native deadline waiter is independent of the cooperative executor and wakes on completion/cancellation.
    private final class _ProcessDeadline: @unchecked Sendable {
        private let lock = NSLock()
        private let wake = DispatchSemaphore(value: 0)
        private var cancelled = false

        func start(deadline: DispatchTime, action: @escaping @Sendable () -> Void) {
            let thread = Thread { [weak self] in
                guard let self else { return }
                let result = wake.wait(timeout: deadline)
                lock.lock()
                let shouldFire = result == .timedOut && !cancelled
                lock.unlock()
                if shouldFire { action() }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            wake.signal()
        }
    }

    public func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessRunResult {
        try await run(
            executable: executable,
            arguments: arguments,
            currentDirectory: nil,
            environment: nil,
            standardInput: nil,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            outputByteLimit: nil
        )
    }

    /// Shared event-driven subprocess seam for app and core callers that need
    /// a working directory, an exact environment, or stdin. This remains the
    /// same lifecycle owner as the instance entry point above: pipe
    /// draining, cancellation, timeout escalation, and process-tree reaping
    /// must not be reimplemented by each feature.
    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        standardInput: Data?,
        timeoutSeconds: TimeInterval?,
        outputByteLimit: Int? = nil,
        launchFailure: @Sendable (Error) -> Error = { MacControlError.ioFailure("Process.run() failed: \($0)") }
    ) async throws -> ProcessRunResult {
        // Validate before launch, including Dispatch's nanosecond conversion.
        try Task.checkCancellation()
        let timeoutDeadline: DispatchTime?
        if let timeoutSeconds {
            let epoch = DispatchTime.now().uptimeNanoseconds
            guard timeoutSeconds.isFinite, timeoutSeconds > 0,
                  let milliseconds = Int(exactly: (timeoutSeconds * 1_000).rounded(.up)),
                  milliseconds > 0,
                  epoch <= UInt64(Int64.max),
                  UInt64(milliseconds) <= (UInt64(Int64.max) - epoch) / 1_000_000 else {
                throw MacControlError.ioFailure("invalid_process_timeout: deadline must be finite, positive and representable")
            }
            timeoutDeadline = DispatchTime(uptimeNanoseconds: epoch + UInt64(milliseconds) * 1_000_000)
        } else { timeoutDeadline = nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = currentDirectory
        proc.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inputPipe = standardInput.map { _ in Pipe() }
        proc.standardInput = inputPipe ?? FileHandle.nullDevice

        let outBuf = _Buffer(byteLimit: outputByteLimit)
        let errBuf = _Buffer(byteLimit: outputByteLimit)
        let outDrain: ProcessPipeDrain
        do {
            outDrain = try ProcessPipeDrain(handle: outPipe.fileHandleForReading) { outBuf.append($0) }
        } catch {
            throw MacControlError.ioFailure(error.localizedDescription)
        }
        let errDrain: ProcessPipeDrain
        do {
            errDrain = try ProcessPipeDrain(handle: errPipe.fileHandleForReading) { errBuf.append($0) }
        } catch {
            outDrain.stop()
            throw MacControlError.ioFailure(error.localizedDescription)
        }

        let completion = ContinuationOnce<Void>()
        proc.terminationHandler = { _ in completion.resume(()) }
        let launch = _ProcessLaunch()
        let termination: _ProcessTermination
        do {
            termination = try await withTaskCancellationHandler {
                try launch.start {
                    try proc.run()
                    let initialTree = _ProcessTermination.captureTree(rootPID: proc.processIdentifier)
                    ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(proc.processIdentifier)
                    return _ProcessTermination(process: proc, initialTree: initialTree, onSettled: {
                        outDrain.stop()
                        errDrain.stop()
                        completion.resume(())
                    })
                }
            } onCancel: { launch.cancel() }
        } catch {
            proc.terminationHandler = nil
            outDrain.stop()
            errDrain.stop()
            if error is CancellationError { throw error }
            throw launchFailure(error)
        }
        if let inputPipe, let standardInput {
            // A helper may accept a payload larger than the pipe buffer. Feed
            // it off-thread so the event-driven termination path remains able
            // to enforce its deadline if the child stops reading.
            let handle = inputPipe.fileHandleForWriting
            let writer = Thread {
                try? handle.write(contentsOf: standardInput)
                try? handle.close()
            }
            writer.qualityOfService = .utility
            writer.start()
        }
        let deadline = _ProcessDeadline()
        if let timeoutDeadline {
            deadline.start(deadline: timeoutDeadline) {
                termination.request(timedOut: true)
            }
        }
        await withTaskCancellationHandler {
            await completion.wait()
            await outDrain.wait()
            await errDrain.wait()
            await termination.waitIfRequested()
            deadline.cancel()
        } onCancel: {
            termination.request(timedOut: false)
        }
        proc.terminationHandler = nil
        let outData = outBuf.snapshot()
        let errData = errBuf.snapshot()
        let result = ProcessRunResult(
            exitCode: proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: termination.didTimeOut,
            stdoutTruncated: outBuf.truncated,
            stderrTruncated: errBuf.truncated
        )
        if Task.isCancelled { throw ProcessRunCancellation(result: result) }
        if errDrain.captureReadFailed {
            throw MacControlError.ioFailure("process_stderr_read_failed: subprocess stderr capture failed")
        }
        return result
    }

}
