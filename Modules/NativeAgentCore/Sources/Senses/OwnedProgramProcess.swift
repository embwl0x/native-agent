import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramProcess.swift` | Shared helper process framing, IO and deadlines |
/// Pipe callbacks frame IO; the requesting task interprets and executes under its own Trust.
final class OwnedProgramProcess: @unchecked Sendable {
    enum Event: Sendable { case line(Data), ended(String) }
    let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nativeagent.program.stdin")
    private var writeSource: DispatchSourceWrite?
    private var writeBuffer = Data()
    private var writeOffset = 0
    private var writerAwake = false
    private var writerClosed = false
    private var buffered = Data()
    private var stderr = Data()
    private var stopping = false
    private var tree: ProcessTreeSnapshot?
    let scratch: URL
    private var onFailure: @Sendable (SenseFailure) -> Void
    private var terminalFailure: SenseFailure?
    private var execution: (id: Int, kind: OwnedProgram.Kind, progress: ProgramProgressWindow)?
    private var deadlineTask: Task<Void, Never>?
    private var resources: Task<Void, Never>?
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var failure: SenseFailure? { lock.withLock { terminalFailure } }
    func processIdentities() -> [ProcessTreeIdentity] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree)
        tree = snapshot
        return snapshot.descendants + (snapshot.rootIdentity.map { [$0] } ?? [])
    }
    init(helper: URL, profile: String, scratch: URL, memoryBytes: UInt64? = nil,
         onFailure: @escaping @Sendable (SenseFailure) -> Void = { _ in }) throws {
        self.scratch = scratch; self.onFailure = onFailure
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(128))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, helper.path, "--scratch", scratch.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": scratch.path, "TMPDIR": scratch.path]
        process.currentDirectoryURL = scratch
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            lock.lock(); stderr.append(data); stderr = Data(stderr.suffix(4_096)); lock.unlock()
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        // Keep the transport alive until the child is reaped, even if its
        // runner has already retired the slot. Break the retain on real exit.
        process.terminationHandler = { [self] process in
            process.terminationHandler = nil
            lock.lock()
            let tail = String(decoding: stderr, as: UTF8.self)
            if !stopping {
                let failure = SenseFailure(code: "crashed", message: "Program helper exited (\(process.terminationStatus)): \(tail)")
                terminalFailure = failure; onFailure(failure)
                stopping = true; execution = nil
            }
            if let tree {
                _ = ProcessTreeReaper.quiesceAndKill(ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree))
            }
            lock.unlock()
            sink.yield(.ended("Sense helper at \(helper.path) exited (\(process.terminationStatus)): \(tail) Tell the person about this NativeAgent helper failure; preserve its error output."))
            sink.finish()
            lock.withLock { deadlineTask?.cancel(); resources?.cancel() }
            writeQueue.sync { closeWriter() }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: scratch)
        }
        do {
            let fd = input.fileHandleForWriting.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                throw SenseFailure(code: "spawn_failed", message: "Sense helper stdin could not be made nonblocking.")
            }
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
            source.setEventHandler { [weak self] in self?.drainWrites() }
            source.setCancelHandler { [input] in try? input.fileHandleForWriting.close() }
            writeSource = source
            try process.run()
            ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(pid)
            lock.lock(); tree = ProcessTreeReaper.snapshot(rootPID: pid)
            // Process-tree RSS has no confirmed equivalent threshold event. Retain the
            // one-second sample, owned and cancelled by this helper transport.
            if let memoryBytes, !stopping { resources = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    var memory: UInt64 = 0
                    var accounted = false
                    for identity in self.processIdentities() {
                        var info = proc_taskinfo()
                        let size = Int32(MemoryLayout<proc_taskinfo>.size)
                        guard proc_pidinfo(identity.pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
                        memory += info.pti_resident_size; accounted = true
                    }
                    if !accounted {
                        if self.isRunning { self.fail(SenseFailure(code: "resource_limit", message: "Sense helper resource accounting is unavailable.")) }
                        return
                    }
                    if memory > memoryBytes {
                        self.fail(SenseFailure(code: "resource_limit", message: "Sense helper exceeded its memory cap.")); return
                    }
                }
            } }
            lock.unlock()
        }
        catch {
            process.terminationHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            writeQueue.sync { closeWriter() }
            sink.finish()
            // Resource exhaustion passes; anything else needs a repair.
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError ?? error as NSError
            let busy = cause.domain == NSPOSIXErrorDomain && [EAGAIN, ENOMEM, EMFILE, ENFILE].contains(Int32(cause.code))
            throw SenseFailure(code: busy ? "spawn_busy" : "spawn_failed", message: "Tell the person: NativeAgent's sense helper at \(helper.path) could not launch: \(error.localizedDescription)")
        }
    }
    func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        guard data.count <= 24 * 1_024 * 1_024 else { throw SenseFailure(code: "input_limit", message: "Sense material exceeds the helper input limit.") }
        data.append(0x0a)
        try writeQueue.sync {
            guard !writerClosed else { throw SenseFailure(code: "crashed", message: "Sense helper stdin is closed.") }
            guard writeBuffer.count - writeOffset + data.count <= 24 * 1_024 * 1_024 + 1 else {
                throw SenseFailure(code: "input_limit", message: "Sense helper exceeded its input queue limit.")
            }
            if writeOffset > 0 { writeBuffer.removeFirst(writeOffset); writeOffset = 0 }
            writeBuffer.append(data)
            if !writerAwake { writerAwake = true; writeSource?.resume() }
        }
    }
    private func drainWrites() {
        guard !writerClosed else { return }
        while writeOffset < writeBuffer.count {
            let count = writeBuffer.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { errno = EINVAL; return -1 }
                return Darwin.write(input.fileHandleForWriting.fileDescriptor,
                    base.advanced(by: writeOffset), bytes.count - writeOffset)
            }
            if count > 0 { writeOffset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            onFailure(SenseFailure(code: "crashed", message: "Sense helper stdin write failed."))
            sink.yield(.ended("Sense helper stdin write failed.")); sink.finish()
            closeWriter(); return
        }
        writeBuffer.removeAll(keepingCapacity: true); writeOffset = 0
        writerAwake = false; writeSource?.suspend()
    }
    private func closeWriter() {
        guard !writerClosed else { return }
        writerClosed = true
        if !writerAwake { writeSource?.resume(); writerAwake = true }
        writeSource?.cancel(); writeSource = nil
        writeBuffer.removeAll()
    }
    private func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.isEmpty { output.fileHandleForReading.readabilityHandler = nil; return }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 0x0a) {
            let line = Data(buffered[..<newline]); buffered.removeSubrange(...newline)
            if line.count > 24 * 1_024 * 1_024 {
                failLocked(SenseFailure(code: "output_limit", message: "Sense helper exceeded its output line limit.")); return
            }
            if case .dropped = sink.yield(.line(line)) {
                failLocked(SenseFailure(code: "output_limit", message: "Program helper exceeded its pending message limit.")); return
            }
        }
        if buffered.count > 24 * 1_024 * 1_024 {
            failLocked(SenseFailure(code: "output_limit", message: "Sense helper exceeded its output line limit."))
        }
    }
    func begin(id: Int, kind: OwnedProgram.Kind, seconds: Double, onFailure: (@Sendable (SenseFailure) -> Void)? = nil) {
        lock.withLock {
            if let onFailure { self.onFailure = onFailure }
            execution = (id, kind, ProgramProgressWindow(seconds: seconds))
            armDeadlineLocked()
        }
    }
    func renewProgress(_ id: Int) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !stopping, execution?.id == id else { throw CancellationError() }
            execution?.progress.renew()
        }
    }
    func suspend(_ id: Int) throws -> ContinuousClock.Instant {
        try lock.withLock {
            guard !stopping, execution?.id == id else { throw CancellationError() }
            deadlineTask?.cancel()
            return .now
        }
    }
    func resume(_ id: Int, since started: ContinuousClock.Instant) throws {
        try lock.withLock {
            guard !stopping, var current = execution, current.id == id else { throw CancellationError() }
            current.progress.resume(after: started)
            execution = current
            armDeadlineLocked()
        }
    }
    func end(_ id: Int) {
        lock.withLock {
            guard execution?.id == id else { return }
            execution = nil; deadlineTask?.cancel(); deadlineTask = nil
        }
    }
    func claimCompletion(_ id: Int) throws {
        try lock.withLock {
            if let terminalFailure { throw terminalFailure }
            guard !stopping, execution?.id == id else { throw CancellationError() }
            execution = nil; deadlineTask?.cancel(); deadlineTask = nil
        }
    }
    private func armDeadlineLocked() {
        deadlineTask?.cancel()
        guard let id = execution?.id else { return }
        deadlineTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.lock.withLock({ () -> ContinuousClock.Instant? in
                    guard let current = self?.execution, current.id == id, self?.stopping == false else { return nil }
                    return current.progress.deadline
                }) else { return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                self?.lock.withLock {
                    guard !Task.isCancelled, let current = self?.execution, current.id == id,
                          ContinuousClock.now >= current.progress.deadline else { return }
                    self?.failLocked(SenseFailure(code: "timeout", message: current.kind == .sense
                        ? "Sense helper stalled without progress." : "Owned program stalled without progress."))
                }
            }
        }
    }
    private func fail(_ failure: SenseFailure) {
        lock.withLock { failLocked(failure) }
    }
    private func failLocked(_ failure: SenseFailure) {
        guard !stopping else { return }
        terminalFailure = failure
        onFailure(failure)
        if let id = execution?.id,
           let data = try? JSONEncoder().encode(JSONValue.object([
                "id": .int(Int64(id)), "type": .string("failed"),
                "failure": (try? JSONValue.fromEncodable(failure)) ?? .null])) {
            sink.yield(.line(data))
        }
        stopLocked()
    }
    func stop() { lock.lock(); defer { lock.unlock() }; stopLocked() }
    private func stopLocked() {
        guard !stopping else { return }
        stopping = true
        deadlineTask?.cancel(); resources?.cancel(); execution = nil
        sink.finish()
        // Swift senses may have a compiler/runtime child. Freeze and kill the
        // identity-checked tree, including observed descendants after a crash.
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: tree)
        tree = ProcessTreeReaper.quiesceAndKill(snapshot)
        writeQueue.sync { closeWriter() }
    }
}
func text(_ value: JSONValue?) -> String {
    value?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
