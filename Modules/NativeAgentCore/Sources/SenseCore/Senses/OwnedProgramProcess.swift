import Dispatch
import Synchronization
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramProcess.swift` | Shared helper process framing, IO and deadlines |
/// Interpret pipe messages in the requesting task so host execution retains its Trust.
// The writer queue owns the dispatch source and its pending pipe bytes.
final class OwnedProgramProcess: @unchecked Sendable {
    enum Event: Sendable { case frame(PlugFrame), ended(String) }
    let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let process = ManagedProcess()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private struct State {
        var buffered = Data()
        var stderr = Data()
        var stopping = false
        var tree: ProcessTreeSnapshot?
        var onFailure: @Sendable (SenseFailure) -> Void
        var terminalFailure: SenseFailure?
        /// A sense entry runs with no progress window (SENSES.md); other program kinds keep ONE_DOOR's renewable one.
        var execution: (id: Int, progress: ProgramProgressWindow?)?
        var deadlineTask: Task<Void, Never>?
        var resources: Task<Void, Never>?
        var opened = false
    }
    private let state: Mutex<State>
    private let writeQueue = DispatchQueue(label: "nativeagent.program.stdin")
    private var writeSource: DispatchSourceWrite?
    private var writeBuffer = Data()
    private var writeOffset = 0
    private var writerAwake = false
    private var writerClosed = false
    let scratch: URL
    private let memoryBytes: UInt64
    var pid: Int32 { process.processIdentifier }
    var isReady: Bool { state.withLock { state in state.opened && !state.stopping && process.isRunning } }
    var isRunning: Bool { state.withLock { state in !state.stopping && process.isRunning } }
    var failure: SenseFailure? { state.withLock { state in state.terminalFailure } }
    init(helper: URL, profile: String, scratch: URL, memoryBytes: UInt64 = HelperSenseRunner.Limits().memoryBytes,
         onFailure: @escaping @Sendable (SenseFailure) -> Void = { _ in },
         onExit: @escaping @Sendable (OwnedProgramProcess) -> Void = { _ in }) throws {
        self.scratch = scratch; self.state = Mutex(State(onFailure: onFailure))
        self.memoryBytes = memoryBytes
        (events, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(128))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, helper.path, "--scratch", scratch.path, "--memory-bytes", String(memoryBytes)]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": scratch.path, "TMPDIR": scratch.path]
        process.currentDirectoryURL = scratch
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let stdout = try ProcessPipeDrain(handle: output.fileHandleForReading, onData: { [weak self] in
            self?.receive($0)
        }, onEnd: { [weak self] end in
            guard let self else { return }
            state.withLock { state in
                switch end {
                case .eof where process.isRunning:
                    failLocked(&state, SenseFailure(code: "crashed", message: "Sense helper stdout reached EOF."))
                case .failed(let detail):
                    failLocked(&state, SenseFailure(code: "crashed", message: detail))
                default: break
                }
            }
        })
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            state.withLock { state in state.stderr.append(data); state.stderr = Data(state.stderr.suffix(4_096)) }
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        // Retain transport until the child is reaped, even after slot retirement; break the retain only on real exit.
        process.terminationHandler = { [self] process in
            process.terminationHandler = nil
            if process.terminationError != nil { stdout.stop() }
            stdout.waitForEOF()
            let (tail, reportExit) = state.withLock { state in
                let tail = String(decoding: state.stderr, as: UTF8.self)
                let reportExit = !state.stopping
                if let detail = process.terminationError {
                    let failure = SenseFailure(code: "termination_incomplete", message: detail)
                    state.terminalFailure = failure; onFailure(failure)
                    state.stopping = true; clearExecutionLocked(&state)
                }
                if !state.stopping {
                    let failure = SenseFailure(code: "crashed", message: "Program helper exited (\(process.terminationStatus)): \(tail)")
                    state.terminalFailure = failure; onFailure(failure)
                    state.stopping = true; clearExecutionLocked(&state)
                }
                return (tail, reportExit)
            }
            if reportExit {
                sink.yield(.ended(process.terminationError ?? """
                    Sense helper at \(helper.path) exited (\(process.terminationStatus)): \(tail) Tell the person about this NativeAgent helper failure; \
                    preserve its error output.
                    """))
            }
            sink.finish()
            writeQueue.sync { closeWriter() }
            errors.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: scratch)
            onExit(self)
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
            state.withLock { state in state.tree = ProcessTreeReaper.snapshot(rootPID: pid) }
        }
        catch {
            process.terminationHandler = nil
            stdout.stopAndWait()
            errors.fileHandleForReading.readabilityHandler = nil
            writeQueue.sync { closeWriter() }
            sink.finish()
            // Resource exhaustion must remain distinct from failures requiring repair.
            let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError ?? error as NSError
            let busy = cause.domain == NSPOSIXErrorDomain && [EAGAIN, ENOMEM, EMFILE, ENFILE].contains(Int32(cause.code))
            throw SenseFailure(code: busy ? "spawn_busy" : "spawn_failed", message: """
                Tell the person: NativeAgent's sense helper at \(helper.path) could not launch: \(error.localizedDescription)
                """)
        }
    }
    func send(_ message: JSONValue, flags: UInt8 = 0, payload: Data = Data()) throws {
        let data = try PlugFrame(header: message, flags: flags, payload: payload).encoded()
        try writeQueue.sync {
            guard !writerClosed else { throw SenseFailure(code: "crashed", message: "Sense helper stdin is closed.") }
            guard writeBuffer.count - writeOffset + data.count <= PlugFrame.limit + 10 else {
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
            let count = unsafe writeBuffer.withUnsafeBytes { bytes -> Int in
                guard let base = unsafe bytes.baseAddress else { errno = EINVAL; return -1 }
                return unsafe Darwin.write(input.fileHandleForWriting.fileDescriptor,
                    base.advanced(by: writeOffset), bytes.count - writeOffset)
            }
            if count > 0 { writeOffset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            closeWriter()
            DispatchQueue.global(qos: .utility).async { [self] in
                state.withLock { state in failLocked(&state, SenseFailure(code: "crashed", message: "Sense helper stdin write failed.")) }
            }
            return
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
        state.withLock { state in
            state.buffered.append(data)
            do {
                while let frame = try PlugFrame.take(from: &state.buffered) {
                    if !state.opened {
                        guard frame.flags == 0, try JSONValue.parse(frame.header) == .object(["type": .string("ready")]) else {
                            throw SenseFailure(code: "bad_frame", message: "Missing helper readiness frame.")
                        }
                        state.opened = true
                        continue
                    }
                    if case .dropped = sink.yield(.frame(frame)) {
                        throw SenseFailure(code: "output_limit", message: "Program helper exceeded its pending message limit.")
                    }
                }
            } catch { failLocked(&state, SenseFailure(error, code: "bad_frame")) }
        }
    }
    func begin(id: Int, seconds: Double?, onFailure: (@Sendable (SenseFailure) -> Void)? = nil) {
        state.withLock { state in
            if let onFailure { state.onFailure = onFailure }
            guard !state.stopping else { return }
            state.execution = (id, seconds.map(ProgramProgressWindow.init(seconds:)))
            state.resources?.cancel()
            state.resources = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    self.state.withLock { state in
                        guard !Task.isCancelled, state.execution?.id == id else { return }
                        self.checkMemoryLocked(&state)
                    }
                }
            }
            armDeadlineLocked(&state)
        }
    }
    func renewProgress(_ id: Int) throws {
        try Task.checkCancellation()
        try state.withLock { state in
            try checkExecutionLocked(&state, id)
            state.execution?.progress?.renew()
        }
    }
    func suspend(_ id: Int) throws -> ContinuousClock.Instant {
        try state.withLock { state in
            try checkExecutionLocked(&state, id)
            state.deadlineTask?.cancel()
            return .now
        }
    }
    func resume(_ id: Int, since started: ContinuousClock.Instant) throws {
        try state.withLock { state in
            try checkExecutionLocked(&state, id)
            state.execution?.progress?.resume(after: started)
            armDeadlineLocked(&state)
        }
    }
    func end(_ id: Int) {
        state.withLock { state in
            guard state.execution?.id == id else { return }
            clearExecutionLocked(&state)
        }
    }
    func claimCompletion(_ id: Int) throws {
        try state.withLock { state in
            try checkExecutionLocked(&state, id)
            checkMemoryLocked(&state)
            if let failure = state.terminalFailure { throw failure }
            clearExecutionLocked(&state)
            state.stderr.removeAll()
        }
    }
    private func checkExecutionLocked(_ state: inout State, _ id: Int) throws {
        if let failure = state.terminalFailure { throw failure }
        guard !state.stopping, state.execution?.id == id else { throw CancellationError() }
    }
    private func clearExecutionLocked(_ state: inout State) {
        state.execution = nil
        state.onFailure = { _ in }
        state.deadlineTask?.cancel(); state.deadlineTask = nil
        state.resources?.cancel(); state.resources = nil
    }
    private func checkMemoryLocked(_ state: inout State) {
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: state.tree)
        state.tree = snapshot
        if let detail = snapshot.inspectionFailure {
            failLocked(&state, SenseFailure(code: "resource_unavailable", message: detail))
            return
        }
        var memory: UInt64 = 0
        var accounted = false
        for identity in snapshot.descendants + (snapshot.rootIdentity.map { [$0] } ?? []) {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let read = unsafe proc_pidinfo(identity.pid, PROC_PIDTASKINFO, 0, &info, size)
            if read <= 0, errno == ESRCH { continue }
            guard read == size else {
                failLocked(&state, SenseFailure(code: "resource_unavailable", message: "Memory use of helper process \(identity.pid) is unknown."))
                return
            }
            memory += info.pti_resident_size
            accounted = true
        }
        if !accounted {
            failLocked(&state, SenseFailure(code: "resource_limit", message: "Helper resource accounting is unavailable."))
        } else if memory > memoryBytes {
            failLocked(&state, SenseFailure(code: "resource_limit", message: "Program helper exceeded its memory cap."))
        }
    }
    private func armDeadlineLocked(_ state: inout State) {
        state.deadlineTask?.cancel()
        guard let id = state.execution?.id, state.execution?.progress != nil else { return }
        state.deadlineTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.state.withLock({ state -> ContinuousClock.Instant? in
                    guard let current = state.execution, current.id == id, state.stopping == false else { return nil }
                    return current.progress?.deadline
                }) else { return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                self?.state.withLock { state in
                    guard !Task.isCancelled, let current = state.execution, current.id == id,
                          let deadline = current.progress?.deadline, ContinuousClock.now >= deadline else { return }
                    self?.failLocked(&state, SenseFailure(code: "timeout", message: "Owned program stalled without progress."))
                }
            }
        }
    }
    private func failLocked(_ state: inout State, _ failure: SenseFailure) {
        guard !state.stopping else { return }
        state.terminalFailure = failure
        state.onFailure(failure)
        stopLocked(&state)
    }
    func stop() {
        state.withLock { state in
            sink.finish()
            stopLocked(&state)
        }
    }
    private func stopLocked(_ state: inout State) {
        guard !state.stopping else { return }
        state.stopping = true
        clearExecutionLocked(&state)
        // Freeze and kill the identity-checked process tree because helpers may leave compiler/runtime descendants after a crash.
        let snapshot = ProcessTreeReaper.snapshot(rootPID: pid, retaining: state.tree)
        state.tree = ProcessTreeReaper.quiesceAndKill(snapshot)
        if let detail = process.terminationError {
            let failure = SenseFailure(code: "termination_incomplete", message: detail)
            state.terminalFailure = failure; state.onFailure(failure)
        }
        writeQueue.sync { closeWriter() }
    }
}

public struct PlugFrame: Sendable {
    public static let limit = 24 * 1024 * 1024
    public let header: Data
    public let flags: UInt8
    public let payload: Data

    public init(header: Data, flags: UInt8 = 0, payload: Data = Data()) {
        self.header = header
        self.flags = flags
        self.payload = payload
    }

    public init(header: JSONValue, flags: UInt8 = 0, payload: Data = Data()) throws {
        self.init(header: try Self.json(header), flags: flags, payload: payload)
    }

    public static func json(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    private static func validate(_ flags: UInt8, _ header: Int, _ payload: Int) throws(SenseFailure) {
        guard flags <= 2, header > 0, header + payload <= limit, flags != 0 || payload == 0 else {
            throw SenseFailure(code: "bad_frame", message: "Invalid plug frame flags or length.")
        }
    }

    public func encoded() throws(SenseFailure) -> Data {
        try Self.validate(flags, header.count, payload.count)
        var bytes = Data([1, flags])
        for length in [header.count, payload.count] {
            var word = UInt32(length).bigEndian
            withUnsafeBytes(of: &word) { unsafe bytes.append(contentsOf: $0) }
        }
        bytes.append(header)
        bytes.append(payload)
        return bytes
    }

    public static func lengths(_ buffer: Data) throws(SenseFailure) -> (UInt8, Int, Int) {
        guard buffer.count >= 10 else { throw SenseFailure(code: "bad_frame", message: "Truncated frame prefix.") }
        let start = buffer.startIndex
        guard buffer[start] == 1 else { throw SenseFailure(code: "bad_frame", message: "Unknown plug version.") }
        func length(_ offset: Int) -> Int {
            buffer[(start + offset)..<(start + offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let flags = buffer[start + 1], head = length(2), payload = length(6)
        try validate(flags, head, payload)
        return (flags, head, payload)
    }

    public static func take(from buffer: inout Data) throws(SenseFailure) -> PlugFrame? {
        guard buffer.count >= 10 else { return nil }
        let start = buffer.startIndex
        let (flags, head, payload) = try lengths(buffer)
        let middle = start + 10 + head, end = middle + payload
        guard buffer.endIndex >= end else { return nil }
        let frame = PlugFrame(header: buffer.subdata(in: start + 10..<middle), flags: flags,
                              payload: buffer.subdata(in: middle..<end))
        buffer.removeSubrange(start..<end)
        return frame
    }
}
