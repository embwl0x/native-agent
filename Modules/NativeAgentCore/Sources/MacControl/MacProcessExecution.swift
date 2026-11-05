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

// Blueprint: | `MacProcessExecution.swift` | `ProcessExecution`, `ProcessRunResult`, `ProcessRunCancellation`, `ProcessRunIOFailure`: Process lifecycle |

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
    public let channels: [String]
    public init(result: ProcessRunResult, channels: [String] = []) {
        self.result = result
        self.channels = channels
    }
    public var errorDescription: String? { "Process cancelled after launch; captured output is retained in result." }
}

/// Retain real exit/output evidence when channels fail; incomplete exchange cannot establish success.
public struct ProcessRunIOFailure: Error, Sendable, LocalizedError {
    public let result: ProcessRunResult
    public let channels: [String]
    public var errorDescription: String? {
        """
            Subprocess exchange incomplete (\(channels.joined(separator: "; "))). Effects may have occurred; inspect the receiving system before repeating the \
            command.
            """
    }
}

public final class ProcessExecution: Sendable {
    public static let defaultOutputByteLimit = 1_048_576

    public init() {}

    /// Close nonblocking stdin on settlement so descendants retaining the pipe cannot hang the join.
    private final class _InputDelivery: @unchecked Sendable {
        private let queue = DispatchQueue(label: "NativeAgent.process.stdin")
        private let handle: FileHandle
        private let data: Data
        private let source: DispatchSourceWrite
        private let completion = DispatchGroup()
        private var offset = 0
        private var failure: String?

        init(handle: FileHandle, data: Data) throws {
            self.handle = handle
            self.data = data
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw MacControlError.ioFailure("process_stdin_setup_failed: \(errno)")
            }
            // A closed reader is a channel error, never SIGPIPE on the app.
            guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
                throw MacControlError.ioFailure("process_stdin_setup_failed: \(errno)")
            }
            source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            completion.enter()
            source.setEventHandler { [self] in writeAvailable() }
            source.setCancelHandler { [self] in
                do { try handle.close() }
                catch { failure = failure ?? "stdin close: \(error.localizedDescription)" }
                completion.leave()
                source.setEventHandler(handler: nil)
                source.setCancelHandler(handler: nil)
            }
            source.resume()
        }

        private func writeAvailable() {
            guard !source.isCancelled else { return }
            // Bound a callback so Stop/termination can retire this writer.
            for _ in 0..<64 {
                if offset == data.count { source.cancel(); return }
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
                }
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                else {
                    failure = "stdin write: errno \(errno), delivered \(offset) of \(data.count) bytes"
                    source.cancel()
                    return
                }
            }
        }

        func stop() {
            queue.async { [self] in
                guard !source.isCancelled else { return }
                if offset != data.count {
                    failure = "stdin incomplete: delivered \(offset) of \(data.count) bytes before process settlement"
                }
                source.cancel()
            }
        }

        func wait() async -> String? {
            await withCheckedContinuation { done in
                completion.notify(queue: queue) { [self] in done.resume(returning: failure) }
            }
        }
    }
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

    /// Timeout allows cooperative TERM then KILL; explicit cancellation kills immediately to stop descendant effects before acknowledgement.
    private final class _ProcessTermination: @unchecked Sendable {
        private let lock = NSLock()
        private let process: ManagedProcess
        private let onSettled: @Sendable () -> Void
        private var requested = false
        private var timeoutRequested = false
        private var finished = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let escalation = DispatchSemaphore(value: 0)

        init(process: ManagedProcess, onSettled: @escaping @Sendable () -> Void) {
            self.process = process; self.onSettled = onSettled
        }

        func request(timedOut: Bool) {
            lock.lock()
            if requested {
                let escalate = !timedOut && timeoutRequested && !finished
                lock.unlock()
                if escalate {
                    escalation.signal()
                    _ = ProcessTreeReaper.quiesceAndKill(process.groupSnapshot)
                }
                return
            }
            requested = true; timeoutRequested = timedOut
            lock.unlock()
            let worker = Thread { [self] in
                let snapshot = process.groupSnapshot
                if timedOut {
                    ProcessTreeReaper.signal(snapshot, signal: SIGTERM)
                    // Explicit cancellation ends the TERM grace period; group failure cannot select another signal path.
                    if process.terminationError == nil {
                        _ = escalation.wait(timeout: .now() + .seconds(2))
                    }
                }
                if process.isRunning && process.terminationError == nil {
                    _ = ProcessTreeReaper.quiesceAndKill(snapshot)
                }
                process.waitForSettlement()
                finish()
            }
            worker.qualityOfService = .userInitiated
            worker.start()
        }

        func waitIfRequested() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !requested || finished {
                    lock.unlock(); continuation.resume(); return
                }
                waiters.append(continuation); lock.unlock()
            }
        }

        private func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let pending = waiters; waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume() }
            onSettled()
        }

        var didTimeOut: Bool { lock.withLock { timeoutRequested } }
    }

    /// Attach termination ownership under launch admission so cancellation cannot race a child into existence.
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

    /// Share pipe draining, cancellation, timeout escalation and process-tree reaping across app and core callers.
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
        // Validate before launch so invalid timeouts cannot overflow Dispatch’s nanosecond conversion.
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
        let proc = ManagedProcess()
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
        let inputDelivery: _InputDelivery?
        if let inputPipe, let standardInput {
            inputDelivery = try _InputDelivery(handle: inputPipe.fileHandleForWriting, data: standardInput)
        } else { inputDelivery = nil }

        let outBuf = _Buffer(byteLimit: outputByteLimit)
        let errBuf = _Buffer(byteLimit: outputByteLimit)
        let outDrain: ProcessPipeDrain
        do {
            outDrain = try ProcessPipeDrain(handle: outPipe.fileHandleForReading) { outBuf.append($0) }
        } catch {
            inputDelivery?.stop()
            throw MacControlError.ioFailure(error.localizedDescription)
        }
        let errDrain: ProcessPipeDrain
        do {
            errDrain = try ProcessPipeDrain(handle: errPipe.fileHandleForReading) { errBuf.append($0) }
        } catch {
            inputDelivery?.stop()
            outDrain.stop()
            throw MacControlError.ioFailure(error.localizedDescription)
        }

        let completion = ContinuationOnce<Void>()
        proc.terminationHandler = { process in
            inputDelivery?.stop()
            if process.terminationError != nil { outDrain.stop(); errDrain.stop() }
            completion.resume(())
        }
        let launch = _ProcessLaunch()
        let termination: _ProcessTermination
        do {
            termination = try await withTaskCancellationHandler {
                try launch.start {
                    try proc.run()
                    return _ProcessTermination(process: proc, onSettled: {
                        inputDelivery?.stop()
                        outDrain.stop()
                        errDrain.stop()
                        completion.resume(())
                    })
                }
            } onCancel: { launch.cancel() }
        } catch {
            inputDelivery?.stop()
            proc.terminationHandler = nil
            outDrain.stop()
            errDrain.stop()
            if error is CancellationError { throw error }
            throw launchFailure(error)
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
        let inputFailure = await inputDelivery?.wait()
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
        var channelFailures: [String] = []
        if let terminationError = proc.terminationError { channelFailures.append(terminationError) }
        if let inputFailure { channelFailures.append(inputFailure) }
        if outDrain.captureReadFailed { channelFailures.append("stdout capture failed") }
        if errDrain.captureReadFailed { channelFailures.append("stderr capture failed") }
        if Task.isCancelled { throw ProcessRunCancellation(result: result, channels: channelFailures) }
        if !channelFailures.isEmpty {
            throw ProcessRunIOFailure(result: result, channels: channelFailures)
        }
        return result
    }

}
