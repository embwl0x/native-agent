import Foundation
@preconcurrency import Dispatch
import NativeAgentCore

#if DEBUG
internal enum CodexAdapterDebugCounters {
    internal static let timeoutScheduled = LockBox(0)
    internal static let timeoutCancelled = LockBox(0)
}
#endif

/// Incremental UTF-8 decoder for chunked byte streams. A multibyte codepoint
/// (2-4 bytes) can be split across two reads; naive per-read decoding drops
/// the partial-byte read entirely. This holds the trailing 1-3 bytes of an
/// in-progress codepoint until the continuation bytes arrive on the next read.
/// Thread-safe via NSLock — `readabilityHandler` can fire on any background queue.
/// `drain()` is the end-of-stream flush; any still-malformed trailing bytes
/// are dropped (count reported via the returned tuple) instead of producing
/// U+FFFD, since the consumer pastes deltas verbatim into UI and a stray
/// replacement character reads worse than a silent drop of a known-bad byte run.
final class Utf8StreamDecoder: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    init() {}
    /// Append `new`, return the decodable prefix (or nil if nothing new is
    /// decodable yet — bytes stay in the buffer for next call).
    func append(_ new: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(new)
        if buffer.isEmpty { return nil }
        if let s = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return s.isEmpty ? nil : s
        }
        let maxDrop = Swift.min(3, buffer.count)
        for drop in 1...maxDrop {
            let prefixCount = buffer.count - drop
            let prefix = buffer.prefix(prefixCount)
            if let s = String(data: prefix, encoding: .utf8) {
                buffer = Data(buffer.suffix(drop))
                return s.isEmpty ? nil : s
            }
        }
        return nil
    }
    /// End-of-stream flush. Returns (decoded-tail, dropped-byte-count).
    /// `dropped > 0` means the final bytes weren't valid UTF-8 and were
    /// discarded; caller may log it.
    func drain() -> (tail: String?, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        if buffer.isEmpty { return (nil, 0) }
        if let s = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: true)
            return (s.isEmpty ? nil : s, 0)
        }
        let n = buffer.count
        buffer.removeAll(keepingCapacity: true)
        return (nil, n)
    }
}

final class LockBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { self.value = v }
    func swap(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
    func mutate<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class NonblockingPipeReader: @unchecked Sendable {
    private let fd: Int32
    private let onData: @Sendable (Data) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var started = false

    init(fileDescriptor: Int32, onData: @escaping @Sendable (Data) -> Void) {
        self.fd = fileDescriptor
        self.onData = onData
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

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { done.signal() }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var madeProgress = false
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n > 0 {
                        madeProgress = true
                        onData(Data(bytes: chunk, count: n))
                        continue
                    }
                    if n == 0 { return }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    return
                }
                if isStopped() { return }
                usleep(madeProgress ? 1_000 : 5_000)
            }
        }
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

/// Result of a Codex CLI invocation (or any subprocess runner injected for tests).
public struct CodexProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Mutable, thread-safe slot for a runner to publish its terminate-handle.
/// `CodexAdapter.complete()` wraps the runner call in
/// `withTaskCancellationHandler` and, if the consumer cancels, invokes the
/// terminator registered here so the Process is actually killed instead of
/// continuing to run silently after the caller is gone.
/// This terminator is STICKY — a fire() arriving before register() will trigger the handler the moment register() is called, closing the spawn-vs-register race.
public final class CodexTerminator: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var fired: Bool = false
    public init() {}
    public func register(_ h: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldFireImmediately = fired
        handler = h
        lock.unlock()
        // If fire() arrived before register(), run the handler now so the
        // cancel signal is not silently dropped due to ordering. This closes
        // the race where withTaskCancellationHandler's onCancel runs before
        // the runner has spawned + registered the process terminator.
        if shouldFireImmediately { h() }
    }
    public func fire() {
        lock.lock()
        fired = true
        let h = handler
        lock.unlock()
        h?()
    }
}

/// Inputs handed to the runner. Tests inspect this to assert correct args/stdin.
/// `terminator` is the runner's hook to publish a cancellation callback —
/// runners that spawn a Process should call `terminator.register { proc.terminate() }`
/// right after `proc.run()` so a cancelled consumer kills the process instead
/// of letting it run to completion in the background.
public struct CodexProcessInvocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var stdin: String
    public var timeout: TimeInterval
    public var terminator: CodexTerminator
    /// Optional full child-process environment. Rooted secondary runtimes use
    /// this to bind CODEX_HOME/NATIVE_AGENT_DATA_ROOT instead of silently
    /// reading the operator's personal Codex home.
    public var environment: [String: String]?
    public init(
        executable: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        terminator: CodexTerminator = CodexTerminator(),
        environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.timeout = timeout
        self.terminator = terminator
        self.environment = environment
    }
}

/// Subprocess runner closure type. Tests inject a mock; production uses the
/// real-Process runner below.
public typealias CodexProcessRunner = @Sendable (CodexProcessInvocation) async throws -> CodexProcessResult

/// Streaming subprocess runner closure type. Yields each stdout chunk as a
/// decoded UTF-8 string as the process emits it. Tests inject a mock that
/// drives the continuation directly; production uses the real-Process runner
/// below (which attaches a `readabilityHandler` to the stdout FileHandle).
///
/// Contract:
///   - Each yielded String is one chunk of stdout, in order.
///   - On exit 0: call `continuation.finish()`.
///   - On non-zero exit / signal / timeout: call `continuation.finish(throwing:)`
///     with an `LLMError.underlying` carrying stderr (or the timeout message).
///   - On `continuation.onTermination` (consumer cancellation): the runner
///     MUST terminate the spawned Process and detach the read handler.
public typealias CodexStreamingProcessRunner = @Sendable (CodexProcessInvocation) -> AsyncThrowingStream<String, Error>

/// Shells out to the `codex` CLI. Configurable bin + runner for tests.
///
/// Streaming: as of 2026-05-31 `stream(...)` is implemented directly (no
/// longer the `LLMAdapter` single-chunk default). The streaming runner
/// attaches a `readabilityHandler` to the spawned process's stdout pipe and
/// yields each chunk to the `AsyncThrowingStream` continuation as the CLI
/// writes it. Non-streaming `complete(...)` still uses the original
/// CodexProcessRunner contract — both code paths coexist.
///
/// Honest CLI-side caveat: some Codex CLI builds buffer their stdout when the
/// downstream FD is not a TTY (line-buffered or block-buffered libc default).
/// In that case the readabilityHandler will not see incremental chunks even
/// though the runner is reading correctly — stdout will arrive in one or two
/// large blobs near process exit. That's a CLI flush behavior, not a bug in
/// this code. Operator workarounds when this bites: run the CLI under
/// `stdbuf -oL <bin>` (coreutils) or `unbuffer <bin>` (expect package) to
/// force line-buffered stdout, `script -q /dev/null <bin>` to give it a fake
/// TTY, or — if you own the CLI source — call
/// `setvbuf(stdout, NULL, _IOLBF, 0)` at startup. The fallback path
/// (LLMAdapter default `stream` → `complete`) is still callable by adapters
/// that explicitly want the single-chunk path.
public final class CodexAdapter: LLMAdapter {
    public let providerId: String = "codex"
    private let codexBin: String
    private let timeout: TimeInterval
    private let runner: CodexProcessRunner
    private let streamingRunner: CodexStreamingProcessRunner
    private let processEnvironmentOverride: [String: String]?

    public init(
        codexBin: String = "codex",
        timeout: TimeInterval = 180,
        runner: @escaping CodexProcessRunner = CodexAdapter.defaultRunner,
        streamingRunner: @escaping CodexStreamingProcessRunner = CodexAdapter.defaultStreamingRunner,
        processEnvironmentOverride: [String: String]? = nil
    ) {
        self.codexBin = codexBin
        self.timeout = timeout
        self.runner = runner
        self.streamingRunner = streamingRunner
        self.processEnvironmentOverride = processEnvironmentOverride
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        var args = Self.arguments(model: model)
        if let sys = system, !sys.isEmpty {
            // codex CLI accepts --system on its prompt-mode invocation.
            args.append(contentsOf: ["--system", sys])
        }
        let terminator = CodexTerminator()
        let invocation = CodexProcessInvocation(
            executable: codexBin,
            arguments: args,
            stdin: prompt,
            timeout: timeout,
            terminator: terminator,
            environment: processEnvironmentOverride
        )
        let result: CodexProcessResult
        do {
            // withTaskCancellationHandler propagates a cancelled consumer Task
            // down into the spawned Process: when the consumer cancels (chat
            // turn aborted, view dismissed, stream consumer's Task.cancel()),
            // the registered terminator fires and kills the process instead of
            // letting it run silently to completion.
            result = try await withTaskCancellationHandler(
                operation: { try await runner(invocation) },
                onCancel: { terminator.fire() }
            )
        } catch is CancellationError {
            // Cancellation propagates as CancellationError so structured-
            // concurrency callers (e.g. SwiftNativeWorkshopRunner) can
            // distinguish cancellation from a real process failure.
            throw CancellationError()
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "codex: \(error)"))
        }
        // Cancellation may have landed during the runner await without the runner
        // throwing CancellationError directly — the terminator fires, the process
        // exits non-zero, and the runner returns a CodexProcessResult with that
        // non-zero exitCode. Surface cancellation as CancellationError BEFORE
        // misinterpreting the non-zero exit as a real LLMError.
        try Task.checkCancellation()
        if result.timedOut {
            throw LLMError.underlying(message: "codex: timed out after \(Int(timeout))s")
        }
        if result.exitCode != 0 {
            // A3.2: classify the CLI failure instead of a blanket terminal
            // .underlying — auth signatures → .authRejected, rate-limit
            // signatures → .transient, preserving a bounded stderr tail.
            throw Self.classifyCodexFailure(
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        // A3.3: exit 0 with ZERO content is an empty-and-silent turn, not a
        // legitimate reply — throw streamTruncated so the surface retries /
        // surfaces honestly instead of returning an empty string.
        if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.streamTruncated(
                message: "codex produced no output (exit 0, empty stdout)")
        }
        return result.stdout
    }

    /// A3.2: classify a non-zero Codex CLI exit from its stdout/stderr. The CLI
    /// has no structured status code, so we sniff its failure text for auth and
    /// rate-limit signatures. A bounded stderr tail is preserved in every case
    /// so the real cause survives to the user / logs.
    static func classifyCodexFailure(exitCode: Int32, stdout: String, stderr: String) -> LLMError {
        let hay = (stderr + "\n" + stdout).lowercased()
        let detail = boundedCodexTail(stderr.isEmpty ? stdout : stderr)
        let authSignatures = [
            "not logged in", "please log in", "log in with", "login required",
            "please run codex login", "codex login", "unauthorized", "401",
            "authentication", "auth error", "token expired", "expired token",
            "invalid api key", "invalid token", "no api key", "missing api key",
            "re-authenticate", "reauthenticate", "sign in", "forbidden", "403",
        ]
        if authSignatures.contains(where: { hay.contains($0) }) {
            return .authRejected(provider: "codex", detail: detail.isEmpty ? nil : detail)
        }
        let rateSignatures = [
            "rate limit", "rate_limit", "429", "too many requests", "overloaded",
            "temporarily unavailable", "status 503", "status 502", "status 504",
            "try again later",
        ]
        if rateSignatures.contains(where: { hay.contains($0) }) {
            return .transient(message: "codex: \(detail.isEmpty ? "rate limited" : detail)")
        }
        return .underlying(message: detail.isEmpty ? "codex exited \(exitCode)" : detail)
    }

    /// Bounded tail of CLI failure text (last `max` chars, trimmed). Keeps the
    /// tail because the actionable error line is usually at the END of a noisy
    /// CLI stderr dump.
    static func boundedCodexTail(_ s: String, max: Int = 600) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return "…" + String(t.suffix(max))
    }

    /// Streaming variant. Routes through `CodexStreamingProcessRunner` so
    /// codex/* models actually emit incremental stdout chunks instead of the
    /// single-chunk `LLMAdapter` default. Constructs the same invocation
    /// `complete()` would, hands it to the streaming runner, forwards each
    /// chunk to the consumer's continuation, and propagates cancellation down
    /// into the spawned process via the `terminator` hook (publisher = runner,
    /// fire = stream `onTermination`).
    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        var args = Self.arguments(model: model)
        if let sys = system, !sys.isEmpty {
            args.append(contentsOf: ["--system", sys])
        }
        let terminator = CodexTerminator()
        let invocation = CodexProcessInvocation(
            executable: codexBin,
            arguments: args,
            stdin: prompt,
            timeout: timeout,
            terminator: terminator,
            environment: processEnvironmentOverride
        )
        let upstream = streamingRunner(invocation)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var sawContent = false
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sawContent = true
                        }
                        continuation.yield(chunk)
                    }
                    // A3.3: a clean (exit-0) stream that yielded ZERO content is
                    // an empty-and-silent turn — throw streamTruncated instead
                    // of finishing clean and letting an empty reply through.
                    if sawContent {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: LLMError.streamTruncated(
                            message: "codex produced no output (clean exit, empty stream)"))
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
                }
            }
            continuation.onTermination = { _ in
                terminator.fire()
                task.cancel()
            }
        }
    }

    private static func arguments(model: String) -> [String] {
        var args: [String] = []
        if let effort = OpenAIExecutionControls.reasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort,
            transport: .codexCLI
        ) {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        if let tier = OpenAIExecutionControls.serviceTier(
            model: model,
            requested: LLMCallContext.serviceTier,
            transport: .codexCLI
        ) {
            args.append(contentsOf: ["-c", "service_tier=\"\(tier)\""])
        }
        args.append(contentsOf: ["-m", model])
        return args
    }

    /// Real-Process streaming runner. Spawns `codex` with the given args, pipes
    /// the prompt over stdin, drains stdout/stderr on nonblocking reader threads,
    /// and yields each decoded UTF-8 chunk to the continuation as it lands.
    ///
    /// Termination paths (all idempotent via the `finished` LockBox):
    ///   - Clean exit 0 → `continuation.finish()`.
    ///   - Non-zero exit → `continuation.finish(throwing: LLMError.underlying)`
    ///     carrying stderr (or "codex exited N" if stderr is empty).
    ///   - Timeout → terminate + `finish(throwing: .underlying("codex: timed out…"))`.
    ///   - Consumer cancellation (`onTermination`) → register terminator fires
    ///     `proc.terminate()`, the terminationHandler then finishes the stream.
    ///
    /// Reader hygiene: stdout/stderr avoid `FileHandle.readabilityHandler`.
    /// Foundation implements that API with dispatch sources, and fast-exit
    /// subprocess churn in the full SwiftPM suite can close descriptors while
    /// libdispatch still owns a source. The explicit readers have a bounded stop.
    public static let defaultStreamingRunner: CodexStreamingProcessRunner = { inv in
        AsyncThrowingStream { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [inv.executable] + inv.arguments
            if let environment = inv.environment { proc.environment = environment }
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = inPipe

            // Accumulate stderr in case the process exits non-zero — we want
            // the message in the thrown error, not just on the floor.
            let stderrBuf = LockBox(Data())
            let finished = LockBox(false)
            let terminating = LockBox(false)
            // Incremental UTF-8 decode across reads — a multibyte codepoint
            // (2-4 bytes) can be split across two pipe reads; naive per-read
            // decoding returns nil for the partial-bytes read and drops the
            // bytes silently. See `Utf8StreamDecoder` for details.
            let utf8Decoder = Utf8StreamDecoder()
            let stdoutReader = NonblockingPipeReader(
                fileDescriptor: outPipe.fileHandleForReading.fileDescriptor
            ) { data in
                if let s = utf8Decoder.append(data) {
                    continuation.yield(s)
                }
            }
            let stderrReader = NonblockingPipeReader(
                fileDescriptor: errPipe.fileHandleForReading.fileDescriptor
            ) { data in
                stderrBuf.mutate { $0.append(data) }
            }
            stdoutReader.start()
            stderrReader.start()

            @Sendable func finishStream(_ block: () -> Result<Void, Error>) {
                if finished.swap(true) { return }
                switch block() {
                case .success: continuation.finish()
                case .failure(let e): continuation.finish(throwing: e)
                }
            }

            // Late-bound timeout slot — the DispatchWorkItem is created after
            // proc.run() (it captures proc), but the terminationHandler must be
            // installed BEFORE run() to close the fast-exit race window where a
            // CLI exits before we get a chance to attach the handler. Handler
            // reads the slot lazily; nil is fine if proc died before the
            // timeoutWork was even created.
            let timeoutSlot = LockBox<DispatchWorkItem?>(nil)

            // Install terminationHandler BEFORE run() — a fast-exit CLI can
            // terminate between run() returning and a post-run assignment,
            // which would orphan the stream (handler never fires → consumer
            // hangs forever waiting on continuation.finish()).
            proc.terminationHandler = { p in
                _ = terminating.swap(true)
                timeoutSlot.get()?.cancel()
                // Let the readers drain whatever is immediately available after
                // process exit. They do not wait for EOF forever: a grandchild
                // could inherit the stdout/stderr write end.
                stdoutReader.stopAndWait()
                stderrReader.stopAndWait()
                let (tailStr, dropped) = utf8Decoder.drain()
                if let tailStr { continuation.yield(tailStr) }
                if dropped > 0 {
                    FileHandle.standardError.write(Data(
                        "[codex] dropping \(dropped) malformed UTF-8 trailing bytes at stream end\n".utf8
                    ))
                }
                try? outPipe.fileHandleForReading.close()
                try? errPipe.fileHandleForReading.close()
                if p.terminationStatus == 0 {
                    finishStream { .success(()) }
                } else {
                    // A3.2: classify auth / rate-limit signatures from the CLI
                    // failure text instead of a blanket terminal .underlying.
                    let errMsg = String(data: stderrBuf.get(), encoding: .utf8) ?? ""
                    finishStream {
                        .failure(CodexAdapter.classifyCodexFailure(
                            exitCode: p.terminationStatus, stdout: "", stderr: errMsg))
                    }
                }
                // Symmetric guard against the scheduler racing past our entry-flag flip
                // and storing a work item between our flag-set and our slot-read at the
                // top of the handler. Read-and-clear under the lock; cancel outside.
                let late = timeoutSlot.mutate { (slot: inout DispatchWorkItem?) -> DispatchWorkItem? in
                    let s = slot
                    slot = nil
                    return s
                }
                if late != nil {
                    late?.cancel()
                    #if DEBUG
                    CodexAdapterDebugCounters.timeoutCancelled.mutate { $0 += 1 }
                    #endif
                }
            }

            do {
                try proc.run()
                try? inPipe.fileHandleForReading.close()
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
            } catch {
                stdoutReader.stopAndWait()
                stderrReader.stopAndWait()
                try? inPipe.fileHandleForReading.close()
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                finishStream { .failure(LLMError.underlying(message: "codex: \(error)")) }
                return
            }

            // Cancellation hook — the user's consumer cancels, terminator fires,
            // proc.terminate() ships SIGTERM; terminationHandler then runs and
            // finishes the stream clean.
            inv.terminator.register { [weak proc] in
                if proc?.isRunning == true {
                    proc?.terminate()
                }
            }
            continuation.onTermination = { _ in
                inv.terminator.fire()
            }

            // Write prompt to stdin then close so the CLI sees EOF.
            if let data = inv.stdin.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()

            // Timeout enforcer — terminate + finish-throwing on overrun.
            // Published into timeoutSlot so the pre-run() terminationHandler
            // can cancel it on clean exit.
            //
            // Fast-exit guard: if the CLI already exited and the
            // terminationHandler ran the stream to clean finish before we got
            // here, skip scheduling entirely — otherwise we'd queue a no-op
            // DispatchWorkItem that retains proc/pipes/continuation for the
            // full inv.timeout window. Re-check after storing the slot in case
            // the handler raced us between the two checks.
            if (finished.get() || terminating.get()) { return }
            let timeoutWork = DispatchWorkItem {
                if proc.isRunning {
                    proc.terminate()
                    finishStream {
                        .failure(LLMError.underlying(
                            message: "codex: timed out after \(Int(inv.timeout))s"
                        ))
                    }
                }
            }
            if (finished.get() || terminating.get()) {
                timeoutWork.cancel()
                return
            }
            timeoutSlot.mutate { $0 = timeoutWork }
            if (finished.get() || terminating.get()) {
                timeoutSlot.mutate { $0 = nil }
                timeoutWork.cancel()
                // NOTE: do NOT bump timeoutCancelled here. This branch never
                // reached asyncAfter and never bumped timeoutScheduled, so
                // counting a cancel here would invert the scheduled==cancelled
                // invariant the test asserts. Only the end-of-handler slot
                // sweep (which is paired with a real asyncAfter) increments
                // timeoutCancelled.
                return
            }
            #if DEBUG
            CodexAdapterDebugCounters.timeoutScheduled.mutate { $0 += 1 }
            #endif
            // REMAINING RACE WINDOW (sub-millisecond, not closed by this fix):
            //   1. Scheduler thread passes the post-store guard above.
            //   2. terminationHandler's end-of-handler sweep cancels the slot's
            //      work item (timeoutWork) and bumps timeoutCancelled.
            //   3. Scheduler thread reaches the asyncAfter call below and
            //      queues an ALREADY-CANCELLED DispatchWorkItem.
            //
            // Impact: GCD retains the cancelled DispatchWorkItem (its closure
            // captures proc/pipes/continuation) until the inv.timeout deadline
            // expires. The closure body never runs (cancel is honored), so no
            // spurious SIGTERM is sent to the already-dead process. Memory
            // pressure is bounded by inv.timeout × concurrency.
            //
            // Why not fixed now: closing the window requires atomicizing the
            // entire (check-flags, store-slot, schedule-asyncAfter) sequence
            // under a single lock with a refactored timeout state struct
            // (likely a single LockBox<TimeoutState> that owns both the work
            // item and the scheduling decision). That refactor isn't blocking
            // production — the leak is bounded and the closure is inert.
            //
            // Tracked as a future cleanup.
            DispatchQueue.global().asyncAfter(deadline: .now() + inv.timeout, execute: timeoutWork)
        }
    }

    /// Real-Process runner. Spawns `codex` with the given args, pipes the
    /// prompt over stdin, captures stdout/stderr, enforces a timeout.
    public static let defaultRunner: CodexProcessRunner = { inv in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CodexProcessResult, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [inv.executable] + inv.arguments
            if let environment = inv.environment { proc.environment = environment }
            let outPipe = Pipe()
            let errPipe = Pipe()
            let inPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = inPipe

            let resumed = LockBox(false)
            @Sendable func finish(_ block: () -> Result<CodexProcessResult, Error>) {
                if resumed.swap(true) { return }
                switch block() {
                case .success(let r): cont.resume(returning: r)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            @Sendable func readAll(_ pipe: Pipe) -> Data {
                var collected = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    collected.append(chunk)
                }
                return collected
            }

            // Late-bound timeout slot — the DispatchWorkItem is created after
            // proc.run() (it captures proc), but the terminationHandler must be
            // installed BEFORE run() to close the fast-exit race window where a
            // CLI exits before we get a chance to attach the handler. Mirrors
            // the streamingRunner pattern.
            let timeoutSlot = LockBox<DispatchWorkItem?>(nil)

            // Install terminationHandler BEFORE run() — a fast-exit CLI can
            // terminate between run() returning and a post-run assignment,
            // which would orphan the continuation (handler never fires →
            // consumer hangs forever waiting on cont.resume).
            proc.terminationHandler = { p in
                timeoutSlot.get()?.cancel()
                let out = readAll(outPipe)
                let err = readAll(errPipe)
                finish {
                    .success(CodexProcessResult(
                        exitCode: p.terminationStatus,
                        stdout: String(data: out, encoding: .utf8) ?? "",
                        stderr: String(data: err, encoding: .utf8) ?? "",
                        timedOut: false
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                finish { .failure(error) }
                return
            }

            // Publish a cancellation hook so a cancelled consumer can kill the
            // process. Mirrors the timeout path; finish() is idempotent via the
            // `resumed` LockBox so a late terminate-on-cancel followed by a
            // normal terminationHandler can't double-resume.
            inv.terminator.register { [weak proc] in
                if proc?.isRunning == true {
                    proc?.terminate()
                }
            }

            // Write stdin then close so codex sees EOF.
            if let data = inv.stdin.data(using: .utf8) {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? inPipe.fileHandleForWriting.close()

            // Timeout enforcer — late-bound and published into timeoutSlot so
            // the pre-run() terminationHandler can cancel it on clean exit.
            // Fast-exit guard: skip scheduling if the handler already resumed.
            if resumed.get() { return }
            let timeoutWork = DispatchWorkItem {
                if proc.isRunning {
                    proc.terminate()
                    let out = readAll(outPipe)
                    let err = readAll(errPipe)
                    finish {
                        .success(CodexProcessResult(
                            exitCode: -1,
                            stdout: String(data: out, encoding: .utf8) ?? "",
                            stderr: String(data: err, encoding: .utf8) ?? "",
                            timedOut: true
                        ))
                    }
                }
            }
            if resumed.get() {
                timeoutWork.cancel()
                return
            }
            timeoutSlot.mutate { $0 = timeoutWork }
            if resumed.get() {
                timeoutSlot.mutate { $0 = nil }
                timeoutWork.cancel()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + inv.timeout, execute: timeoutWork)
        }
    }
}
