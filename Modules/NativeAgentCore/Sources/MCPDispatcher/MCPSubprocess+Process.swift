import Foundation
import Darwin
import NativeAgentCore
import PersistenceCore
import Research
import KnowledgeGraph
import CapabilityFoundry

// MARK: - Persistent stdin writer

/// Result of one serialized stdin frame write. The persistent writer resolves
/// this from its own native thread; neither success nor the monotonic deadline
/// depends on a callback returning to a shared GCD executor.
private enum _MCPStdinWriteOutcome: Sendable {
    case ok
    case failed(Int32)
    /// `writerStopped` records which side won the cancellation-vs-deadline
    /// race on the native writer. The actor must follow this committed result
    /// instead of re-deciding from later cancellation state.
    case timedOut(writerStopped: Bool)
}

/// Resume-once bridge between the native writer thread and an awaiting actor.
private final class _MCPStdinWriteLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<_MCPStdinWriteOutcome, Never>?

    func arm(_ value: CheckedContinuation<_MCPStdinWriteOutcome, Never>) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    func finish(_ outcome: _MCPStdinWriteOutcome) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(returning: outcome)
    }
}

/// Mutable timeout policy for one queued frame. Request cancellation can
/// downgrade its own already-enqueued write before the deadline wins, without
/// requiring the native writer to call back into the MCP actor.
private final class _MCPStdinWritePolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var stopWriterOnTimeout: Bool

    init(stopWriterOnTimeout: Bool) {
        self.stopWriterOnTimeout = stopWriterOnTimeout
    }

    func allowWriterToContinueAfterTimeout() {
        lock.lock()
        stopWriterOnTimeout = false
        lock.unlock()
    }

    func shouldStopWriterOnTimeout() -> Bool {
        lock.lock()
        let value = stopWriterOnTimeout
        lock.unlock()
        return value
    }
}

/// One persistent FIFO writer per MCP subprocess.
///
/// The pipe duplicate is nonblocking. A small frame normally completes in one
/// syscall; a full pipe waits in `poll(2)` alongside a private wake pipe until
/// writable, stopped, or its absolute monotonic deadline arrives. This avoids
/// both failure modes of the former DispatchIO implementation:
///
/// - an empty-pipe initialize frame cannot falsely lose to a starved callback;
/// - an oversized frame cannot block the MCP actor or outlive its exact write
///   deadline when the child stops reading.
private final class _MCPStdinWriter: @unchecked Sendable {
    private struct Request: Sendable {
        let data: Data
        let deadlineNanos: UInt64
        let latch: _MCPStdinWriteLatch
        let policy: _MCPStdinWritePolicy
    }

    private let descriptor: Int32
    private let wakeReadDescriptor: Int32
    private let wakeWriteDescriptor: Int32
    private let condition = NSCondition()
    private var requests: [Request] = []
    private var stopped = false
    private var started = false

    init(fileDescriptor: Int32) throws {
        let duplicate = Darwin.dup(fileDescriptor)
        guard duplicate >= 0 else { throw Self.posixError() }

        var wakeDescriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = wakeDescriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress!)
        }
        guard pipeResult == 0 else {
            let error = Self.posixError()
            Darwin.close(duplicate)
            throw error
        }

        do {
            try Self.makeNonblocking(duplicate)
            guard Darwin.fcntl(duplicate, F_SETNOSIGPIPE, 1) == 0 else {
                throw Self.posixError()
            }
            try Self.makeNonblocking(wakeDescriptors[0])
            try Self.makeNonblocking(wakeDescriptors[1])
        } catch {
            Darwin.close(duplicate)
            Darwin.close(wakeDescriptors[0])
            Darwin.close(wakeDescriptors[1])
            throw error
        }

        descriptor = duplicate
        wakeReadDescriptor = wakeDescriptors[0]
        wakeWriteDescriptor = wakeDescriptors[1]
    }

    func start() {
        condition.lock()
        guard !started, !stopped else {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        let thread = Thread { [self] in runLoop() }
        thread.name = "MCPSubprocess.stdin"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func submit(
        _ data: Data,
        timeout: TimeInterval,
        latch: _MCPStdinWriteLatch,
        policy: _MCPStdinWritePolicy
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = timeout.isFinite ? max(0, timeout) : 0
        let maximumSeconds = Double(UInt64.max / 1_000_000_000)
        let delta = UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
        let deadline = now > UInt64.max - delta ? UInt64.max : now + delta

        condition.lock()
        guard !stopped else {
            condition.unlock()
            latch.finish(.failed(ECANCELED))
            return
        }
        requests.append(Request(
            data: data,
            deadlineNanos: deadline,
            latch: latch,
            policy: policy
        ))
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        let abandoned = requests
        requests.removeAll(keepingCapacity: false)
        // Wake poll before releasing the lock. An idle worker may otherwise
        // observe the condition broadcast, exit, and close/reuse the wake fd
        // before this thread writes to it.
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) {
            Darwin.write(wakeWriteDescriptor, $0, 1)
        }
        condition.broadcast()
        condition.unlock()

        for request in abandoned {
            request.latch.finish(.failed(ECANCELED))
        }
    }

    private func runLoop() {
        while let request = nextRequest() {
            let outcome = write(request)
            let timeoutIsTerminal: Bool
            if case .timedOut = outcome {
                timeoutIsTerminal = request.policy.shouldStopWriterOnTimeout()
            } else {
                timeoutIsTerminal = false
            }
            // A fatal timeout closes admission BEFORE its actor continuation is
            // resumed. Otherwise executor starvation could let the native
            // writer dequeue and emit a later frame after one protocol frame
            // was lost but before the actor got CPU to terminate the child.
            let abandoned = timeoutIsTerminal ? stopAfterTerminalTimeout() : []
            let deliveredOutcome: _MCPStdinWriteOutcome
            if case .timedOut = outcome {
                deliveredOutcome = .timedOut(writerStopped: timeoutIsTerminal)
            } else {
                deliveredOutcome = outcome
            }
            request.latch.finish(deliveredOutcome)
            for queued in abandoned {
                queued.latch.finish(.failed(ECANCELED))
            }
            if timeoutIsTerminal { break }
        }
        Darwin.close(descriptor)
        Darwin.close(wakeReadDescriptor)
        Darwin.close(wakeWriteDescriptor)
    }

    private func nextRequest() -> Request? {
        condition.lock()
        while requests.isEmpty, !stopped {
            condition.wait()
        }
        let request = stopped ? nil : requests.removeFirst()
        condition.unlock()
        return request
    }

    private func stopAfterTerminalTimeout() -> [Request] {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return []
        }
        stopped = true
        let abandoned = requests
        requests.removeAll(keepingCapacity: false)
        condition.broadcast()
        condition.unlock()
        return abandoned
    }

    private func write(_ request: Request) -> _MCPStdinWriteOutcome {
        request.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return .ok }
            var offset = 0
            while offset < bytes.count {
                if isStopped() { return .failed(ECANCELED) }
                if DispatchTime.now().uptimeNanoseconds >= request.deadlineNanos {
                    return .timedOut(writerStopped: false)
                }

                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { return .failed(EPIPE) }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    return .failed(errno)
                }
                if let outcome = waitUntilWritable(deadlineNanos: request.deadlineNanos) {
                    return outcome
                }
            }
            return .ok
        }
    }

    /// Returns nil when stdin became writable; otherwise returns the terminal
    /// outcome for this request.
    private func waitUntilWritable(deadlineNanos: UInt64) -> _MCPStdinWriteOutcome? {
        while true {
            if isStopped() { return .failed(ECANCELED) }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineNanos else { return .timedOut(writerStopped: false) }
            let remainingNanos = deadlineNanos - now
            let roundedMilliseconds = max(
                1,
                (remainingNanos / 1_000_000) + (remainingNanos % 1_000_000 == 0 ? 0 : 1)
            )
            let timeoutMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptors = [
                pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: wakeReadDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let result = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), timeoutMilliseconds)
            }
            if result == 0 { return .timedOut(writerStopped: false) }
            if result < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            if descriptors[1].revents != 0 {
                drainWakePipe()
                if isStopped() { return .failed(ECANCELED) }
            }
            let stdinEvents = descriptors[0].revents
            if stdinEvents & Int16(POLLOUT) != 0 { return nil }
            if stdinEvents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                return .failed(EPIPE)
            }
        }
    }

    private func isStopped() -> Bool {
        condition.lock()
        let value = stopped
        condition.unlock()
        return value
    }

    private func drainWakePipe() {
        var buffer = [UInt8](repeating: 0, count: 16)
        while buffer.withUnsafeMutableBytes({ bytes in
            Darwin.read(wakeReadDescriptor, bytes.baseAddress, bytes.count)
        }) > 0 {}
    }

    private static func makeNonblocking(_ descriptor: Int32) throws {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

// MARK: - stderr tail ring

/// Bounded ring buffer for an MCP child's stderr.
///
/// F-B4 (2026-08-02): `stderrPipe` was assigned and NEVER read. A pipe has a
/// ~64KB kernel buffer; any MCP server that logs past it blocks forever in
/// `write(2)`, stops answering JSON-RPC, gets evicted as wedged, respawns, and
/// repeats — and the diagnostic bytes explaining why were thrown away. This
/// drains the pipe continuously (so the child can never block) while retaining
/// only the last `limit` bytes (so a chatty server can't grow memory without
/// bound). Written from the readabilityHandler's background queue, read from
/// the actor — hence the lock.
final class _MCPStderrTail: @unchecked Sendable {
    /// Retained tail size. 8KB is far below the pipe buffer yet large enough to
    /// carry a Python/Node traceback, which is what a death reason usually is.
    static let limit = 8 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var truncated = false

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        buffer.append(chunk)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
            truncated = true
        }
        lock.unlock()
    }

    /// Last-N-bytes snapshot as text, whitespace-trimmed. Empty when the child
    /// wrote nothing to stderr.
    func snapshot() -> String {
        lock.lock()
        let data = buffer
        let didTruncate = truncated
        lock.unlock()
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return didTruncate ? "…\(text)" : text
    }

    /// `snapshot()` clipped for embedding in a one-line error/eviction reason.
    func reasonFragment(maxLength: Int = 600) -> String {
        let text = snapshot()
        guard !text.isEmpty else { return "" }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return oneLine.count <= maxLength
            ? oneLine
            : "…" + String(oneLine.suffix(maxLength))
    }
}

// MARK: - MCPSubprocess

/// One live MCP stdio child process. The actor owns the `Process`, the
/// stdin/stdout pipes, the in-flight request waiters, and the spawn metadata
/// (pid + startedAt + lastUsedAt) that `MCPSubprocessPool` exposes via
/// session-status rows.
public actor MCPSubprocess {
    public let serverId: String
    public let command: String
    public let argv: [String]
    public let env: [String: String]?
    public let cwd: URL?
    /// Request timeout used by `request(...)`. Daemon uses 10s for initialize,
    /// 20s for the actual method — we use 20s as the single default for both.
    public var defaultTimeout: TimeInterval = 20

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Persistent native writer for the stdin pipe. It owns a duplicated
    /// nonblocking descriptor, serializes frames FIFO, and enforces deadlines
    /// with `poll(2)` rather than a callback/timer on a shared GCD executor.
    private var stdinWriter: _MCPStdinWriter?
    /// Deadline for a single framed stdin write. A pipe that stays full
    /// past this means the child stopped reading — we treat it as wedged,
    /// terminate it, and route through the unexpected-termination path so
    /// the pool evicts + arms backoff.
    public private(set) var writeTimeout: TimeInterval = 10
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// F-B4: bounded tail of the child's stderr, continuously drained so the
    /// child can never block writing to a full pipe. Survives `stop()` /
    /// `_processDidTerminate` teardown on purpose — the death reason is read
    /// AFTER the process is gone.
    private var stderrTail: _MCPStderrTail?
    private var reader: MCPFrameReader?
    /// Event-driven task that drains completed stdout frames only after the
    /// readability handler signals new bytes or EOF.
    private var drainTask: Task<Void, Never>?
    /// Test-visible evidence that an idle subprocess does not repeatedly call
    /// `MCPFrameReader.drain()`. Incremented once per coalesced stdout signal.
    private var stdoutDrainPassCount: UInt64 = 0
    private var nextRpcId: Int64 = 0
    /// Outstanding request waiters keyed by JSON-RPC id.
    private var waiters: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    /// Request ids whose waiter was cancelled while their OWN request frame may
    /// still be queued on stdin. A wedge-timeout on such a write must be treated
    /// as fire-and-forget (drop, no terminate) — the request is already abandoned
    /// client-side, and killing the whole subprocess over it would take down a
    /// server that may just be busy (W3d delta review, 2026-07-01). Entries are
    /// consumed at the write's resolution (success, failure, or wedge).
    private var cancelledRequestWrites: Set<Int64> = []
    /// Per-request native-writer policies let cancellation downgrade the
    /// request frame before its deadline. This preserves the no-terminate
    /// cancellation contract while fatal writes stop native FIFO admission
    /// atomically at timeout.
    private var requestWritePolicies: [Int64: _MCPStdinWritePolicy] = [:]
    /// Deterministic test gate for the cancellation-before-write-start race.
    /// Production leaves this false; it inserts no await or scheduling work.
    private var pauseRequestWritesForTesting = false
    private var pausedRequestWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedRequestWriteObservers: [CheckedContinuation<Void, Never>] = []
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
    /// Optional handler the pool installs so it can record a backoff when
    /// the child dies UNEXPECTEDLY (i.e. not via `stop()`). The handler is
    /// invoked with the exit status (or 0 if not exposed by Process) and a
    /// human-readable reason string. Runs OUTSIDE the actor — it must be
    /// `@Sendable` and route to its own actor to mutate state.
    private var terminationHandler: (@Sendable (Int32, String) -> Void)?
    /// Bug 3 fix (2026-05-31): when a process dies in the <1ms window
    /// between `proc.run()` and `MCPSubprocessPool.get(...)` installing
    /// its termination handler via `onUnexpectedTermination`, the
    /// terminationHandler bridge fires into `_processDidTerminate` with
    /// `terminationHandler == nil` and the crash silently evaporates —
    /// the pool then hands the dead process back to the caller as a
    /// "successful start" with no backoff. The fix: buffer the
    /// termination info here when no handler is installed yet, and
    /// replay it the moment `onUnexpectedTermination` sets one.
    private var pendingTermination: (status: Int32, reason: String)?
    /// Set to true by `stop()` so the terminationHandler can distinguish
    /// "we asked it to die" from "it crashed". A crash is the case where
    /// the OS-side termination fires while this flag is still false.
    private var didRequestStop = false
    private(set) public var startedAt: Date?
    private(set) public var lastUsedAt: Date?
    private var initialized = false

    public init(
        serverId: String,
        command: String,
        argv: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) {
        self.serverId = serverId
        self.command = command
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    /// Convenience that mirrors how the daemon spawns from a server record
    /// (single `command` string parsed with `shlex.split`).
    public static func fromServerCommand(
        serverId: String,
        command: String,
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) throws -> MCPSubprocess {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw MCPSubprocessError.missingCommand }
        // Minimal POSIX-ish argv split. The daemon uses `shlex.split` — we
        // mirror "quoted segments stay together, backslash escapes one char".
        let argv = MCPSubprocess.shlexSplit(trimmed)
        guard let first = argv.first else { throw MCPSubprocessError.missingCommand }
        return MCPSubprocess(
            serverId: serverId,
            command: first,
            argv: argv,
            env: env,
            cwd: cwd
        )
    }

    /// Returns the live pid of the underlying Process, or nil if not running.
    public var pid: Int32? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Spawn the child + perform the `initialize` + `notifications/initialized`
    /// handshake the daemon performs.
    public func start() async throws {
        if process?.isRunning == true { return }
        let proc = Process()
        // Resolve absolute command via /usr/bin/env so PATH lookup works.
        if command.hasPrefix("/") {
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = Array(argv.dropFirst())
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
        }
        if let cwd = cwd { proc.currentDirectoryURL = cwd }
        if let env = env {
            // Merge over the inherited env so PATH stays present.
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            proc.environment = merged
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        let frameReader = MCPFrameReader()
        let (stdoutEvents, stdoutSignal) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // readabilityHandler runs on a background queue — funnel each chunk
        // into the frame reader, then wake the actor's event consumer. The
        // one-element buffer intentionally coalesces bursts: MCPFrameReader
        // retains every frame, so one wake-up can drain many chunks without
        // an idle timer. readDataToEndOfFile would block waiting for EOF on a
        // long-lived MCP subprocess.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            frameReader.append(chunk)
            stdoutSignal.yield()
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                stdoutSignal.finish()
            }
        }

        // F-B4: drain stderr continuously into a bounded ring. Without this the
        // pipe fills at ~64KB and the child wedges in write(2) — it stops
        // answering JSON-RPC, gets evicted, respawns, and wedges again, with
        // the bytes that explain why discarded. We keep only the tail.
        let tail = _MCPStderrTail()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            tail.append(chunk)
        }

        // Capture a non-isolated bridge into the actor so the
        // terminationHandler (which fires off-actor) can route through to
        // our internal `_processDidTerminate` after-the-fact.
        let bridge = _TerminationBridge()
        proc.terminationHandler = { p in
            bridge.fire(status: p.terminationStatus, reason: Self.terminationReason(p))
        }

        do {
            try proc.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutSignal.finish()
            throw MCPSubprocessError.spawnFailed(
                Self.decorate(error.localizedDescription, withStderr: tail)
            )
        }

        let writer: _MCPStdinWriter
        do {
            writer = try _MCPStdinWriter(
                fileDescriptor: stdin.fileHandleForWriting.fileDescriptor
            )
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stdoutSignal.finish()
            proc.terminate()
            throw MCPSubprocessError.spawnFailed(
                Self.decorate("stdin writer: \(error.localizedDescription)", withStderr: tail)
            )
        }
        process = proc
        stdinHandle = stdin.fileHandleForWriting
        stdinWriter = writer
        writer.start()
        stdoutPipe = stdout
        stderrPipe = stderr
        stderrTail = tail
        reader = frameReader
        stdoutDrainPassCount = 0
        startedAt = Date()
        lastUsedAt = startedAt
        didRequestStop = false
        // Connect the bridge AFTER state is set so the handler closure
        // sees a fully-initialized actor when it fires.
        bridge.set { [weak self] status, reason in
            Task { await self?._processDidTerminate(status: status, reason: reason) }
        }

        // Consume only readability events. Multiple producer callbacks may be
        // coalesced into one event because the reader owns the complete frame
        // queue; after it becomes idle this task suspends without polling.
        drainTask = Task { [weak self] in
            for await _ in stdoutEvents {
                guard !Task.isCancelled, let self else { return }
                guard await self.consumeStdoutEvent(from: frameReader) else { return }
            }
        }

        // Initialize handshake — mirrors the retired daemon/8361. Any
        // failure past this point happened AFTER the child launched, so the
        // catch must tear the child down (same path stop()/stopAll() use)
        // before rethrowing — otherwise the handshake failure leaks an
        // orphaned subprocess.
        do {
            let initResp = try await sendRPC(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("NativeAgent"),
                        "version": .string("1.0.0"),
                    ]),
                ]),
                timeout: 10
            )
            // We don't enforce a shape on the initialize response — daemon also
            // doesn't (it just `_ = self.mcp_read_message(...)`).
            _ = initResp
            // notifications/initialized is a *notification* — no id, no waiter.
            try await sendNotification(method: "notifications/initialized", params: .object([:]))
        } catch {
            // F-B4: the handshake is where a misconfigured server dies (bad
            // interpreter, missing module, auth refusal) — and it explains
            // itself on stderr. Carry that tail into the thrown error instead
            // of discarding it; `stop()` below tears the child down but the
            // ring survives.
            let fragment = tail.reasonFragment()
            stop()
            if fragment.isEmpty { throw error }
            throw MCPSubprocessError.spawnFailed(
                "handshake failed: \(error) — stderr: \(fragment)"
            )
        }
        initialized = true
    }

    /// Test/diagnostic seam: last-8KB snapshot of the child's stderr.
    public func stderrTailSnapshot() -> String {
        stderrTail?.snapshot() ?? ""
    }

    private static func decorate(_ message: String, withStderr tail: _MCPStderrTail) -> String {
        let fragment = tail.reasonFragment()
        return fragment.isEmpty ? message : "\(message) — stderr: \(fragment)"
    }

    /// Send a JSON-RPC request and wait for its matching response. The id is
    /// generated internally to keep correlation honest — callers do not pass
    /// one in.
    public func request(
        method: String,
        params: JSONValue = .object([:]),
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        if process?.isRunning != true {
            throw MCPSubprocessError.streamClosed
        }
        let result = try await sendRPC(method: method, params: params, timeout: timeout ?? defaultTimeout)
        // Cancel wins a cancel-vs-queued-response race (W3d review note): if the
        // task was cancelled while a response was already draining into our
        // waiter, sendRPC resolves with a value — surface CancellationError here
        // so the contract (cancel takes priority) holds either way.
        try Task.checkCancellation()
        return result
    }

    /// Register a handler for server-initiated notifications. The handler is
    /// called from inside the actor; pass a `@Sendable` closure that captures
    /// nothing actor-isolated.
    public func notifications(handler: @escaping @Sendable (String, JSONValue) -> Void) {
        self.notificationHandler = handler
    }

    /// Install a handler that fires when the child process terminates
    /// UNEXPECTEDLY (i.e. without a preceding `stop()` call). Used by
    /// `MCPSubprocessPool` to record a crash + apply backoff so a crashloop
    /// can't flood `get(serverId:)` callers with respawns.
    ///
    /// Bug 3 fix (2026-05-31): if the process already terminated before
    /// this handler was installed (a sub-millisecond startup-exit race),
    /// `_processDidTerminate` stamped `pendingTermination` and returned
    /// without firing anything. Replay it here so the pool still arms its
    /// crash-backoff window — same effect as if the handler had been
    /// installed before termination.
    public func onUnexpectedTermination(
        _ handler: @escaping @Sendable (Int32, String) -> Void
    ) {
        self.terminationHandler = handler
        if let queued = pendingTermination {
            pendingTermination = nil
            handler(queued.status, queued.reason)
        }
    }

    /// Terminate the child process and clean up pipe handlers + waiters.
    public func stop() {
        // Set BEFORE terminate() so the terminationHandler that fires as a
        // consequence sees this as a requested stop, not a crash.
        didRequestStop = true
        drainTask?.cancel()
        drainTask = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinWriter?.stop()
        stdinWriter = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        requestWritePolicies.removeAll()
        cancelledRequestWrites.removeAll()
        resumePausedRequestWritesForTesting()
        stdoutPipe = nil
        stderrPipe = nil
        reader = nil
        startedAt = nil
        initialized = false
        // Fail outstanding waiters so callers don't hang.
        failAllWaiters(error: MCPSubprocessError.streamClosed)
    }

    /// Bug 1 fix (2026-05-31): drain-task entry point when the frame
    /// reader rejects a malformed frame. We force-terminate the
    /// child + route through the normal unexpected-termination handler
    /// so the pool evicts + arms backoff (same path a crash takes). We
    /// deliberately do NOT call `stop()` here: stop() sets
    /// `didRequestStop = true`, which would tell `_processDidTerminate`
    /// to swallow the termination callback, defeating the eviction.
    fileprivate func _terminateForMalformedFrame(notice: String) {
        guard let proc = process, proc.isRunning else { return }
        // SIGTERM the child. The termination handler bridge will fire
        // → `_processDidTerminate` → which (since `didRequestStop` stays
        // false) forwards to the pool's onUnexpectedTermination handler.
        // The pool eviction path runs there.
        proc.terminate()
        // Surface a precise lastError on the crash record by also
        // routing a synthetic termination through the handler. We do
        // BOTH (synthetic + real) because the real terminationHandler
        // might not fire promptly enough; the pool's recordCrash path is
        // idempotent-per-generation (see Bug 5 fix), so double-fire
        // results in exactly one crash record.
        if let handler = terminationHandler {
            handler(-1, "malformed frame: \(notice)")
        }
    }

    /// Invoked from the Process terminationHandler bridge. We swallow the
    /// callback for stops the actor requested itself (didRequestStop == true),
    /// and surface the rest via the registered onUnexpectedTermination
    /// handler — that's how `MCPSubprocessPool` records the crash + arms
    /// the backoff window.
    fileprivate func _processDidTerminate(status: Int32, reason: String) {
        if didRequestStop {
            // Self-initiated stop — nothing to do.
            return
        }
        // The child died on its own. Treat it like a stream close so
        // outstanding waiters fail cleanly, and notify the pool.
        //
        // Bug 3 fix (2026-05-31): if `onUnexpectedTermination` hasn't been
        // installed yet (the <1ms startup-exit race), buffer the
        // termination so the handler will replay it on install. Without
        // this, a process that exits within microseconds of start() would
        // silently evaporate — the pool would believe the start succeeded.
        // F-B4: fold the stderr tail into the eviction reason so the pool's
        // `lastError` (and the session-status row the user sees) carries WHY
        // the child died instead of a bare "exited (status=1)".
        let fragment = stderrTail?.reasonFragment() ?? ""
        let decoratedReason = fragment.isEmpty ? reason : "\(reason) — stderr: \(fragment)"
        if let handler = terminationHandler {
            handler(status, decoratedReason)
        } else {
            pendingTermination = (status: status, reason: decoratedReason)
        }
        // Drain everything: stop() also failAllWaiters for us, and we don't
        // want to call stop() here because Process is already dead.
        failAllWaiters(error: MCPSubprocessError.streamClosed)
        drainTask?.cancel()
        drainTask = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinWriter?.stop()
        stdinWriter = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        requestWritePolicies.removeAll()
        cancelledRequestWrites.removeAll()
        resumePausedRequestWritesForTesting()
        stdoutPipe = nil
        stderrPipe = nil
        reader = nil
        startedAt = nil
        initialized = false
    }

    /// Render a short human-readable reason for a terminated Process so the
    /// pool's recorded `lastError` reads sensibly in session-status rows.
    nonisolated static func terminationReason(_ p: Process) -> String {
        switch p.terminationReason {
        case .exit:
            return "exited (status=\(p.terminationStatus))"
        case .uncaughtSignal:
            return "killed by signal (status=\(p.terminationStatus))"
        @unknown default:
            return "terminated (status=\(p.terminationStatus))"
        }
    }

    // MARK: Private

    /// Drain one coalesced readability event. Returns false after terminal
    /// stream state so the event consumer exits. Framing, waiter correlation,
    /// malformed-output eviction, and EOF failure all remain actor-serialized.
    private func consumeStdoutEvent(from frameReader: MCPFrameReader) async -> Bool {
        stdoutDrainPassCount &+= 1
        let (frames, closed, malformed) = frameReader.drain()
        if let notice = malformed {
            // A malformed frame means the server is broken or logging to
            // stdout. Fail callers and evict it so the pool can respawn clean.
            failAllWaiters(error: MCPSubprocessError.malformedResponse(notice))
            _terminateForMalformedFrame(notice: notice)
            return false
        }
        for frame in frames {
            await handleIncomingFrame(frame)
        }
        if closed {
            failAllWaiters(error: MCPSubprocessError.streamClosed)
            return false
        }
        return true
    }

    private func sendRPC(
        method: String,
        params: JSONValue,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        nextRpcId += 1
        let rpcId = nextRpcId
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(rpcId),
            "method": .string(method),
            "params": params,
        ])
        lastUsedAt = Date()
        // Install the waiter BEFORE handing the frame to the native writer.
        // The actor suspends while that writer owns the bytes, so a fast
        // response could otherwise be drained before correlation existed.
        // Loop-A finding (2026-06-13): honor cooperative cancellation. Without
        // a cancellation handler a torn-down chat turn left this waiter pinned
        // until the timeout backstop (up to `timeout`s), inconsistent with the
        // rest of the codebase. On cancel we evict the waiter and resume
        // CancellationError immediately; failWaiter's removeValue guard keeps
        // resume-once intact if a response/timeout raced us. The pre-install
        // checkCancellation avoids installing a waiter at all when the task is
        // already cancelled (onCancel may fire before the waiter exists).
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, Error>) in
                // Install native-write policy in the SAME actor turn as the
                // waiter. `cancelWaiter` can now always downgrade a request
                // that exists, even when its unstructured write task has not
                // received executor time yet.
                let writePolicy = _MCPStdinWritePolicy(stopWriterOnTimeout: true)
                requestWritePolicies[rpcId] = writePolicy
                waiters[rpcId] = cont
                let waiterMethod = method
                Task { [weak self] in
                    do {
                        try await self?.writeFramed(
                            envelope,
                            label: waiterMethod,
                            rpcId: rpcId,
                            policyOverride: writePolicy
                        )
                    } catch {
                        await self?.failWaiter(id: rpcId, error: error)
                    }
                    await self?.clearCancelledWrite(rpcId)
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.timeOutWaiter(id: rpcId, method: waiterMethod, seconds: timeout)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: rpcId)
            }
        }
    }

    /// Cancel one in-flight waiter (cooperative Task cancellation). Evicts +
    /// resumes it with CancellationError FIRST so the caller unblocks
    /// immediately, then best-effort tells the server to stop working on this
    /// request id via the MCP `notifications/cancelled` notification. The
    /// subprocess itself stays alive to serve other requests — only THIS
    /// request is abandoned. If the waiter was already resolved by a
    /// response/timeout (removeValue misses) we send nothing: there is no live
    /// server-side request to cancel. The notification is fire-and-forget — a
    /// wedged/closed stdin just makes `writeFramed` throw, which we swallow.
    private func cancelWaiter(id: Int64) async {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        // Mark BEFORE resuming: if this request's own frame is the one wedging
        // stdin, its write-timeout must not terminate the subprocess.
        cancelledRequestWrites.insert(id)
        requestWritePolicies[id]?.allowWriterToContinueAfterTimeout()
        cont.resume(throwing: CancellationError())
        // MCP `notifications/cancelled` — params carry the id of the request
        // being cancelled + a human reason. No existing cancelled-notification
        // shape lived in this module; this mirrors the MCP spec.
        //
        // Fire-and-forget on a wedged stdin (W3d review, finding 3): pass
        // `terminateOnWedge: false` so a stalled write here NEVER kills the
        // subprocess — the request is already abandoned, and a live server
        // must not be torn down just because one best-effort cancel notice
        // couldn't be delivered. A short deadline keeps this cleanup from
        // pinning for the full `writeTimeout` on a wedged pipe.
        try? await sendNotification(
            method: "notifications/cancelled",
            params: .object([
                "requestId": .int(id),
                "reason": .string("client task cancelled"),
            ]),
            terminateOnWedge: false,
            deadlineOverride: 2.0
        )
    }

    private func sendNotification(
        method: String,
        params: JSONValue,
        terminateOnWedge: Bool = true,
        deadlineOverride: TimeInterval? = nil
    ) async throws {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        try await writeFramed(
            envelope,
            label: method,
            terminateOnWedge: terminateOnWedge,
            deadlineOverride: deadlineOverride
        )
    }

    /// - Parameters:
    ///   - terminateOnWedge: when true (the default, used by every request +
    ///     the initialize handshake), a stalled stdin write means the child
    ///     stopped reading and is treated as wedged — the channel is aborted
    ///     and the child terminated via the pool-eviction path. When FALSE
    ///     (the `notifications/cancelled` fire-and-forget path), a stalled
    ///     write is SILENTLY DROPPED: the request it cancels is already
    ///     abandoned client-side, and one un-deliverable cancel notice must
    ///     NEVER tear down a subprocess still serving other requests.
    ///   - deadlineOverride: caps this single write's stall deadline below the
    ///     subprocess `writeTimeout` — used so a best-effort cancel notice on a
    ///     wedged pipe resolves quickly instead of pinning for the full timeout.
    /// Clear a cancelled-write marker once its write resolved (any way).
    private func clearCancelledWrite(_ id: Int64) {
        cancelledRequestWrites.remove(id)
        requestWritePolicies.removeValue(forKey: id)
    }

    private func writeFramed(
        _ value: JSONValue,
        label: String,
        terminateOnWedge: Bool = true,
        deadlineOverride: TimeInterval? = nil,
        rpcId: Int64? = nil,
        policyOverride: _MCPStdinWritePolicy? = nil
    ) async throws {
        if rpcId != nil {
            await waitForRequestWritePermissionForTesting()
        }
        guard let writer = stdinWriter else { throw MCPSubprocessError.streamClosed }
        // Cancellation may win after waiter/policy installation but before
        // this task begins. Do not emit the abandoned request after its cancel
        // notification; skipping here also prevents a never-submitted request
        // from filling stdin and killing the shared subprocess later.
        if let rpcId, cancelledRequestWrites.contains(rpcId) {
            throw CancellationError()
        }
        // MCP stdio framing: one `<json>\n` message per line. The compact
        // (pretty: false) encoder never emits raw newlines — control chars
        // inside strings are escaped — so the body always fits on one line.
        let body = try value.serializedData(pretty: false)
        assert(!body.contains(0x0A), "MCP stdio body must be newline-free")
        var packet = body
        packet.append(0x0A)
        let deadline = deadlineOverride.map { min($0, writeTimeout) } ?? writeTimeout
        let latch = _MCPStdinWriteLatch()
        let policy = policyOverride
            ?? _MCPStdinWritePolicy(stopWriterOnTimeout: terminateOnWedge)
        if let rpcId {
            requestWritePolicies[rpcId] = policy
        }
        let outcome: _MCPStdinWriteOutcome = await withCheckedContinuation { cont in
            latch.arm(cont)
            writer.submit(packet, timeout: deadline, latch: latch, policy: policy)
        }
        switch outcome {
        case .ok:
            return
        case .failed:
            throw MCPSubprocessError.streamClosed
        case .timedOut(let writerStopped):
            // A CANCELLED request's own queued frame downgrades to
            // fire-and-forget: the caller already abandoned it, so a wedge
            // here must not kill a subprocess that may just be busy
            // (W3d delta review, 2026-07-01).
            if let rpcId {
                cancelledRequestWrites.remove(rpcId)
                requestWritePolicies.removeValue(forKey: rpcId)
            }
            if writerStopped {
                // Child stopped reading stdin (full pipe past the deadline) —
                // it's wedged. Abort the channel so the stuck write errors out,
                // and terminate via the unexpected-termination path so the pool
                // evicts + arms backoff (same recipe as malformed frames).
                stdinWriter?.stop()
                stdinWriter = nil
                try? stdinHandle?.close()
                stdinHandle = nil
                _terminateForWedgedStdin(notice: "stdin write (\(label)) stalled > \(deadline)s")
            }
            // Fire-and-forget/cancelled path: the expired frame is dropped, but
            // the writer and child remain available for later frames. The caller
            // has already abandoned this request and swallows the throw.
            throw MCPSubprocessError.timeout(method: "stdin write: \(label)", seconds: deadline)
        }
    }

    /// U5 W-E fix: stdin-wedge twin of `_terminateForMalformedFrame` — a
    /// child that stops draining stdin is as broken as one writing garbage
    /// to stdout. Deliberately NOT `stop()` (which would set
    /// `didRequestStop` and swallow the pool's eviction callback).
    private func _terminateForWedgedStdin(notice: String) {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        if let handler = terminationHandler {
            handler(-1, "stdin wedged: \(notice)")
        }
    }

    private func handleIncomingFrame(_ frame: JSONValue) async {
        guard case .object(let obj) = frame else { return }
        let idValue = obj["id"] ?? .null
        // U5 W-E fix: a frame with BOTH `id` and `method` is a
        // server-initiated REQUEST (ping, roots/list, sampling/...), not a
        // response. Previously any id-bearing frame fell into the waiter
        // lookup, missed, and was silently dropped — strict servers that
        // ping then wait would wedge. Reply pong to ping, -32601 to
        // everything else, and leave the waiters untouched.
        if case .string(let method) = obj["method"] ?? .null {
            if idValue != .null {
                await replyToServerRequest(id: idValue, method: method)
                return
            }
            // Notification — no id, has `method`.
            notificationHandler?(method, obj["params"] ?? .null)
            return
        }
        // Response — has an `id`, no `method`.
        if let rpcId = jsonValueAsInt64(idValue) {
            guard let cont = waiters.removeValue(forKey: rpcId) else { return }
            if case .object(let err) = obj["error"] ?? .null {
                var code = -1
                if let c = err["code"], case .int(let n) = c { code = Int(n) }
                else if let c = err["code"], case .double(let d) = c { code = Int(d) }
                var msg = "MCP error"
                if let m = err["message"], case .string(let s) = m { msg = s }
                cont.resume(throwing: MCPSubprocessError.rpcError(code: code, message: msg))
                return
            }
            cont.resume(returning: obj["result"] ?? .null)
        }
    }

    /// Answer a server→client JSON-RPC request. `ping` gets an empty-object
    /// result (the MCP pong); every other method gets a -32601 error so a
    /// spec-conformant server can proceed instead of waiting forever. The id
    /// is echoed back verbatim (servers may use string ids). Write failures
    /// are swallowed — if stdin is wedged/closed, the writeFramed deadline +
    /// termination machinery already handles the child.
    private func replyToServerRequest(id: JSONValue, method: String) async {
        let reply: JSONValue
        if method == "ping" {
            reply = .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([:]),
            ])
        } else {
            reply = .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .int(-32601),
                    "message": .string("Method not found: \(method)"),
                ]),
            ])
        }
        try? await writeFramed(reply, label: "reply:\(method)")
    }

    private func timeOutWaiter(id: Int64, method: String, seconds: Double) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: MCPSubprocessError.timeout(method: method, seconds: seconds))
    }

    /// Fail one in-flight waiter (write-path errors). No-op when the waiter
    /// was already resolved by a response/timeout.
    private func failWaiter(id: Int64, error: Error) {
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    /// Test seam — tighten the stdin-write deadline without waiting 10s.
    public func _setWriteTimeout(_ seconds: TimeInterval) {
        writeTimeout = seconds
    }

    func _pauseRequestWritesForTesting() {
        pauseRequestWritesForTesting = true
    }

    func _waitUntilRequestWritePausedForTesting() async {
        guard pauseRequestWritesForTesting,
              pausedRequestWriteWaiters.isEmpty
        else { return }
        await withCheckedContinuation { continuation in
            pausedRequestWriteObservers.append(continuation)
        }
    }

    func _resumeRequestWritesForTesting() {
        resumePausedRequestWritesForTesting()
    }

    /// Test seam for proving the stdout consumer stays suspended while idle.
    func _stdoutDrainPassCountForTesting() -> UInt64 {
        stdoutDrainPassCount
    }

    private func failAllWaiters(error: Error) {
        let snapshot = waiters
        waiters.removeAll()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }

    private func waitForRequestWritePermissionForTesting() async {
        guard pauseRequestWritesForTesting else { return }
        await withCheckedContinuation { continuation in
            pausedRequestWriteWaiters.append(continuation)
            let observers = pausedRequestWriteObservers
            pausedRequestWriteObservers.removeAll()
            for observer in observers {
                observer.resume()
            }
        }
    }

    private func resumePausedRequestWritesForTesting() {
        pauseRequestWritesForTesting = false
        let writeWaiters = pausedRequestWriteWaiters
        pausedRequestWriteWaiters.removeAll()
        for waiter in writeWaiters {
            waiter.resume()
        }
        let observers = pausedRequestWriteObservers
        pausedRequestWriteObservers.removeAll()
        for observer in observers {
            observer.resume()
        }
    }

    private nonisolated func jsonValueAsInt64(_ v: JSONValue) -> Int64? {
        switch v {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    // Minimal shlex-style split: respects single/double quotes and backslash
    // escapes. The daemon uses Python's shlex; this is the 90% subset that
    // covers every MCP server entry in `data/mcp/servers.json` today.
    nonisolated static func shlexSplit(_ input: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        var iter = input.makeIterator()
        while let ch = iter.next() {
            if let q = quote {
                if ch == q { quote = nil; continue }
                if ch == "\\", let nxt = iter.next() { current.append(nxt); continue }
                current.append(ch)
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch == "\\", let nxt = iter.next() { current.append(nxt); continue }
            if ch.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

// MARK: - Termination bridge

/// One-shot @Sendable bridge between Foundation.Process.terminationHandler
/// (which fires on a background queue, off any actor) and the owning
/// `MCPSubprocess` actor. The bridge is set up BEFORE proc.run() so the
/// terminationHandler can capture it; the actual routing closure is
/// installed AFTER the actor's state is fully wired up. If termination
/// fires before `set` (effectively impossible since `set` runs synchronously
/// after `proc.run()`), we queue the status and replay it on `set`.
fileprivate final class _TerminationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var routed: ((Int32, String) -> Void)?
    private var pending: (Int32, String)?

    func set(_ handler: @escaping @Sendable (Int32, String) -> Void) {
        lock.lock()
        routed = handler
        let queued = pending
        pending = nil
        lock.unlock()
        if let queued = queued { handler(queued.0, queued.1) }
    }

    func fire(status: Int32, reason: String) {
        lock.lock()
        let h = routed
        if h == nil { pending = (status, reason) }
        lock.unlock()
        h?(status, reason)
    }
}
