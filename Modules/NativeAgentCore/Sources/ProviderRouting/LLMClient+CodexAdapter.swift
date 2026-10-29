import Foundation
import Synchronization
@preconcurrency import Dispatch
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+CodexAdapter.swift` | `CodexProcess`: streaming and buffered Codex runners; pins the shared credential resolver's path for account controls, child-home binding and preparation; never lets the CLI select another credential; NativeAgentCore's ProcessPipeDrain owns shared nonblocking pipe capture without an executor dependency |

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

private final class CodexProcessShutdown: @unchecked Sendable {
    private let process: Process
    private let launchTree: ProcessTreeSnapshot
    private let lock = NSLock()
    private var requested = false
    private let stopped = DispatchGroup()

    init(_ process: Process) {
        self.process = process
        ProcessTreeReaper.ensureChildLeadsOwnProcessGroup(process.processIdentifier)
        launchTree = ProcessTreeReaper.snapshot(rootPID: process.processIdentifier)
    }

    func requestStop() {
        let admitted = lock.withLock {
            guard !requested, process.isRunning else { return false }
            requested = true
            stopped.enter()
            return true
        }
        guard admitted else { return }
        let tree = ProcessTreeReaper.snapshot(
            rootPID: process.processIdentifier, retaining: launchTree
        )
        ProcessTreeReaper.signal(tree, signal: SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [stopped] in
            defer { stopped.leave() }
            ProcessTreeReaper.quiesceAndKill(tree)
            // The runner's termination handler owns root exit observation and
            // joins this escalation before draining and returning the result.
        }
    }

    /// Called on the process exit queue, never the cooperative executor.
    func waitForStop() { stopped.wait() }
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
/// `CodexProcess.complete()` wraps the runner call in
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

    /// Spawn once, drain both pipes, and join shutdown before reporting exit.
    fileprivate func run(
        stdout: @escaping @Sendable (Data) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        exited: @escaping @Sendable (Int32, Bool, Bool) -> Void
    ) throws {
        let proc = Process()
        var environment = environment ?? ProcessInfo.processInfo.environment
        environment["PATH"] = CodexExecutable.augmentedPath(environment["PATH"])
        proc.executableURL = try CodexExecutable.resolveCodexExecutable(
            environment: environment, program: executable)
        proc.arguments = arguments
        proc.environment = environment
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe
        let stdoutReader: ProcessPipeDrain
        let stderrReader: ProcessPipeDrain
        do {
            stdoutReader = try ProcessPipeDrain(handle: outPipe.fileHandleForReading, onData: stdout)
            do {
                stderrReader = try ProcessPipeDrain(handle: errPipe.fileHandleForReading, onData: stderr)
            } catch {
                stdoutReader.stopAndWait()
                throw error
            }
        } catch {
            for pipe in [outPipe, errPipe, inPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        let terminating = Mutex(false)
        let timedOut = Mutex(false)
        let cancelled = Mutex(false)
        let timeoutSlot = Mutex<DispatchWorkItem?>(nil)
        let shutdownSlot = Mutex<CodexProcessShutdown?>(nil)
        // Install before run so even an immediately exiting child settles.
        proc.terminationHandler = { p in
            terminating.withLock { $0 = true }
            timeoutSlot.withLock { $0 }?.cancel()
            shutdownSlot.withLock { $0 }?.waitForStop()
            stdoutReader.stopAndWait()
            stderrReader.stopAndWait()
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            exited(p.terminationStatus, timedOut.withLock { $0 }, cancelled.withLock { $0 })
            timeoutSlot.withLock { slot in defer { slot = nil }; return slot }?.cancel()
        }
        do {
            try proc.run()
        } catch {
            stdoutReader.stopAndWait()
            stderrReader.stopAndWait()
            for pipe in [outPipe, errPipe, inPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        let shutdown = CodexProcessShutdown(proc)
        shutdownSlot.withLock { $0 = shutdown }
        terminator.register {
            cancelled.withLock { $0 = true }
            shutdown.requestStop()
            timeoutSlot.withLock { $0 }?.cancel()
        }
        guard !terminating.withLock({ $0 }) else { return }
        if timeout > 0 {
            let work = DispatchWorkItem {
                if proc.isRunning {
                    timedOut.withLock { $0 = true }
                    shutdown.requestStop()
                }
            }
            timeoutSlot.withLock { $0 = work }
            if terminating.withLock({ $0 }) {
                timeoutSlot.withLock { slot in defer { slot = nil }; return slot }?.cancel()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }
        // Arm stop and deadline before a full stdin pipe can block its writer.
        let input = Data(stdin.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
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
/// Buffered and incremental callers share the invocation's process lifecycle.
/// Incremental delivery follows the CLI's own stdout flushing cadence.
public final class CodexProcess: LLMTransport {
    public static let toolWire = ProviderToolWire.unsupported
    /// The CLI prompt is text: images are flattened away (`messagesPrompt`).
    public static let carriesImages = false
    public let providerId: String = "codex"
    private let codexBin: String?
    private let timeout: TimeInterval
    private let runner: CodexProcessRunner
    private let streamingRunner: CodexStreamingProcessRunner
    private let processEnvironment: [String: String]
    private let dataRootOverride: URL?

    public init(
        codexBin: String? = nil,
        timeout: TimeInterval = 180,
        runner: @escaping CodexProcessRunner = CodexProcess.defaultRunner,
        streamingRunner: @escaping CodexStreamingProcessRunner = CodexProcess.defaultStreamingRunner,
        processEnvironmentOverride: [String: String]? = nil,
        dataRootOverride: URL? = nil
    ) {
        self.codexBin = codexBin
        self.timeout = timeout
        self.runner = runner
        self.streamingRunner = streamingRunner
        self.processEnvironment = processEnvironmentOverride ?? ProcessInfo.processInfo.environment
        self.dataRootOverride = dataRootOverride
    }

    /// NativeAgent tools never reach the CLI; its tool wire is unsupported.
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?) async throws -> String {
        let authPath = resolvedAuthPath()
        let args = arguments(model: model, authPath: authPath)
        let terminator = CodexTerminator()
        let invocation = CodexProcessInvocation(
            executable: try codexBin ?? CodexExecutable.resolveCodexExecutable(environment: processEnvironment).path,
            arguments: args,
            stdin: Self.composedPrompt(system: system, prompt: prompt),
            timeout: LLMCallContext.wallOwned || ProviderStreamContext.stallOnly ? 0 : timeout,
            terminator: terminator,
            environment: childEnvironment(authPath: authPath)
        )
        try await Self.prepareCodexHome(authPath)
        let result: CodexProcessResult
        do {
            // withTaskCancellationHandler propagates a cancelled consumer Task
            // down into the spawned Process: when the consumer cancels (chat
            // turn aborted, view dismissed, stream consumer's Task.cancel()),
            // the registered terminator fires and kills the process instead of
            // letting it run silently to completion.
            result = try await withTaskCancellationHandler(
                operation: { [runner] in
                    let outcome: Result<CodexProcessResult, Error> = await settle {
                        do { return .success(try await runner(invocation)) }
                        catch { return .failure(error) }
                    }
                    return try outcome.get()
                },
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
        if Task.isCancelled {
            // The runner has joined exit and both drains. Produced text is
            // returned to the cancelled owner for its stopped settlement.
            if !result.stdout.isEmpty { return result.stdout }
            throw CancellationError()
        }
        if result.timedOut {
            throw LLMError.underlying(message: "codex: timed out after \(Int(timeout))s")
        }
        if result.exitCode != 0 {
            // CLI failure classification preserves a bounded diagnostic tail.
            throw Self.classifyCodexFailure(
                exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        // Empty stdout is streamTruncated even when the CLI exits successfully.
        if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMError.streamTruncated(
                message: "codex produced no output (exit 0, empty stdout)")
        }
        return result.stdout
    }

    private func resolvedAuthPath() -> URL {
        ChatGPTTransport.preferredAuthPath(
            dataRoot: dataRootOverride,
            environment: processEnvironment
        )
    }

    private func childEnvironment(authPath: URL) -> [String: String] {
        var environment = processEnvironment
        environment["CODEX_HOME"] = ChatGPTTransport.codexHomeForChild(authPath: authPath).path
        if let dataRootOverride { environment["NATIVE_AGENT_DATA_ROOT"] = dataRootOverride.path }
        return environment
    }

    /// Preparation and execution share the credential pinned before dispatch.
    private static func prepareCodexHome(_ authPath: URL) async throws {
        try await ChatGPTTransport.prepareCodexChildHome(
            ChatGPTTransport.codexHomeForChild(authPath: authPath), authPath: authPath
        )
    }

    /// Nonzero CLI exits use stdout/stderr signatures and retain a bounded diagnostic tail.
    static func classifyCodexFailure(exitCode: Int32, stdout: String, stderr: String) -> LLMError {
        let hay = (stderr + "\n" + stdout).lowercased()
        let detail = boundedCodexTail(stderr.isEmpty ? stdout : stderr)
        // Classify anchored HTTP statuses and whole error phrases, never incidental digit substrings.
        if let status = ProviderFailure.httpStatusCode(inDescription: hay) {
            if status == 401 || status == 403 {
                return .authRejected(provider: "codex", detail: detail.isEmpty ? nil : detail)
            }
            if ProviderFailure.isRecoverableStatus(status) {
                return .transient(
                    message: "codex: \(detail.isEmpty ? "HTTP \(status)" : detail)")
            }
        }
        let authSignatures = [
            "not logged in", "please log in", "log in with", "login required",
            "please run codex login", "codex login", "unauthorized",
            "authentication", "auth error", "token expired", "expired token",
            "invalid api key", "invalid token", "no api key", "missing api key",
            "re-authenticate", "reauthenticate", "sign in", "forbidden",
        ]
        if authSignatures.contains(where: { containsWholePhrase($0, in: hay) }) {
            return .authRejected(provider: "codex", detail: detail.isEmpty ? nil : detail)
        }
        let rateSignatures = [
            "rate limit", "rate_limit", "too many requests", "overloaded",
            "temporarily unavailable", "try again later",
        ]
        if rateSignatures.contains(where: { containsWholePhrase($0, in: hay) }) {
            return .transient(message: "codex: \(detail.isEmpty ? "rate limited" : detail)")
        }
        return .underlying(message: detail.isEmpty ? "codex exited \(exitCode)" : detail)
    }

    /// Whole-phrase containment on an already-lowercased haystack: the phrase
    /// must sit on alphanumeric boundaries, so "sign in" cannot fire inside
    /// "design internals" and "auth error" cannot fire inside a longer word.
    static func containsWholePhrase(_ phrase: String, in haystack: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
        ) else {
            return haystack.contains(phrase)
        }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    /// Bounded tail of CLI failure text (last `max` chars, trimmed). Keeps the
    /// tail because the actionable error line is usually at the END of a noisy
    /// CLI stderr dump.
    static func boundedCodexTail(_ s: String, max: Int = 600) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return "…" + String(t.suffix(max))
    }

    /// Streams the same invocation as `complete()`, forwarding incremental
    /// stdout and propagating consumer cancellation through its terminator.
    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let authPath = resolvedAuthPath()
        let args = arguments(model: model, authPath: authPath)
        let terminator = CodexTerminator()
        return AsyncThrowingStream { continuation in
            let task = Task {
                await withTaskCancellationHandler {
                    var sawContent = false
                    do {
                        try Task.checkCancellation()
                        let invocation = CodexProcessInvocation(
                            executable: try codexBin ?? CodexExecutable.resolveCodexExecutable(environment: processEnvironment).path,
                            arguments: args,
                            stdin: Self.composedPrompt(system: system, prompt: prompt),
                            timeout: LLMCallContext.wallOwned || ProviderStreamContext.stallOnly ? 0 : timeout,
                            terminator: terminator,
                            environment: childEnvironment(authPath: authPath)
                        )
                        try await Self.prepareCodexHome(authPath)
                        let upstream = streamingRunner(invocation)
                        for try await chunk in upstream {
                            try Task.checkCancellation()
                            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                sawContent = true
                            }
                            continuation.yield(chunk)
                        }
                        // A clean exit without content is still an empty turn.
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
                } onCancel: {
                    terminator.fire()
                }
            }
            continuation.onTermination = { _ in
                terminator.fire()
                task.cancel()
            }
        }
    }

    // MARK: - Buffered text-only messages contract

    /// The conversation flattens into one role-prefixed prompt for the CLI's
    /// stdin (tool blocks rendered as inline annotations). The CLI cannot see
    /// images, so the model is told so and a trace row records the drop.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let combined = try await messagesPrompt(messages, model: model)
        return try await complete(prompt: combined, system: system, model: model, tools: tools)
    }

    private func messagesPrompt(_ messages: [LLMMessage], model: String) async throws -> String {
        let flattened = try llmCompatibilityPrompt(messages: messages) { role in
            role == .user ? "USER:" : "ASSISTANT:"
        }
        if flattened.imageCount > 0 {
            await Self.emitVisionUnsupportedTrace(provider: providerId, model: model, imageCount: flattened.imageCount)
        }
        return flattened.text
    }

    /// Delivery follows actual stdout for every deadline policy.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = try await messagesPrompt(messages, model: model)
                    for try await chunk in stream(prompt: prompt, system: system, model: model) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(chunk))
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tripwire row: an image attachment reached the CLI's flattened prompt
    /// and got dropped. Mirrors `memory.commit` trace shape
    /// (id/kind/title/status/payload/createdAt) and writes via the path-owned
    /// appender to `<dataRoot>/traces/events.jsonl`.
    private static func emitVisionUnsupportedTrace(
        provider: String,
        model: String,
        imageCount: Int
    ) async {
        let event = TurnTraceEvent(kind: "vision.attachment_unsupported",
            title: "vision_attachment_unsupported", status: "ok", payload: .object([
                "provider": .string(provider),
                "model": .string(model),
                "imageCount": .int(Int64(imageCount)),
            ]), createdAt: ISO8601DateFormatter().string(from: Date()))
        await TurnTracePersistLane(dataRootOverride: LLMCallContext.traceDataRootOverride).append(event)
    }

    /// Non-interactive exec accepts piped prompts from any app working directory and emits uncolored output.
    private func arguments(model: String, authPath: URL) -> [String] {
        // This transport is a model call. CLI tools would act outside the
        // NativeAgent dispatcher, so its declared no-tools contract applies
        // to the child too, independent of the person's CLI configuration.
        var args: [String] = [
            "exec", "--color", "never", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--sandbox", "read-only", "--enable", "skip_host_skill_discovery",
            "-c", "web_search=\"disabled\"", "-c", "tools.update_plan.enabled=false",
        ]
        for feature in [
            "shell_tool", "unified_exec", "multi_agent", "apps", "plugins", "hooks",
            "view_image", "image_generation", "in_app_browser", "computer_use",
            "in_app_local_automation", "skill_search", "skill_mcp_dependency_install",
            "tool_suggest", "request_permissions_tool", "enable_mcp_apps",
            "multi_agent_v2", "goals", "sleep_tool",
        ] {
            args.append(contentsOf: ["--disable", feature])
        }
        if ProviderStreamContext.stallOnly {
            args.append(contentsOf: ["-c", "model_reasoning_summary=\"auto\""])
        }
        let cacheURL = CodexAccountModelCatalog.cacheCandidate(
            environment: processEnvironment
        )
        let accountRow = CodexAccountModelCatalog.matchingModels(
            providerID: "codex",
            oauthAuthURL: authPath,
            fallbackCacheURL: cacheURL
        ).first { $0.id == model }
        if let effort = OpenAIExecutionControls.reasoningEffort(
            model: model,
            requested: LLMCallContext.reasoningEffort,
            transport: .codexCLI,
            supportedEfforts: accountRow?.supportedReasoningEfforts
        ) {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        if let tier = OpenAIExecutionControls.serviceTier(
            model: model,
            requested: LLMCallContext.serviceTier,
            transport: .codexCLI,
            supportsFast: accountRow?.supportsFast
        ) {
            args.append(contentsOf: ["-c", "service_tier=\"\(tier)\""])
        }
        args.append(contentsOf: ["-m", model])
        return args
    }

    /// The system prompt travels over stdin because the CLI has no --system flag.
    static func composedPrompt(system: String?, prompt: String) -> String {
        guard let system,
              !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return prompt }
        return system + "\n\n" + prompt
    }

    /// Incremental UTF-8 output over the invocation's process lifecycle.
    public static let defaultStreamingRunner: CodexStreamingProcessRunner = { inv in
        AsyncThrowingStream { continuation in
            let activity = ProviderStreamContext.activity
            let admitted = ProviderStreamContext.admitted
            let stderrBuf = Mutex(Data())
            let decoder = Utf8StreamDecoder()
            continuation.onTermination = { _ in
                inv.terminator.fire()
            }
            do {
                try inv.run(stdout: { data in
                    if !data.isEmpty { activity?(); admitted?() }
                    if let text = decoder.append(data) { continuation.yield(text) }
                }, stderr: { data in
                    if !data.isEmpty { activity?() }
                    stderrBuf.withLock { $0.append(data) }
                }, exited: { status, timedOut, cancelled in
                    let (tail, dropped) = decoder.drain()
                    if let tail { continuation.yield(tail) }
                    if dropped > 0 {
                        FileHandle.standardError.write(Data(
                            "[codex] dropping \(dropped) malformed UTF-8 trailing bytes at stream end\n".utf8
                        ))
                    }
                    if cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if timedOut {
                        continuation.finish(throwing: LLMError.underlying(message: "codex: timed out after \(inv.timeout)s"))
                    } else if status == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CodexProcess.classifyCodexFailure(
                            exitCode: status, stdout: "", stderr: String(data: stderrBuf.withLock { $0 }, encoding: .utf8) ?? ""))
                    }
                })
            } catch {
                continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
            }
        }
    }

    /// Buffered output over the same spawn, stop, deadline and drain operation.
    public static let defaultRunner: CodexProcessRunner = { inv in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexProcessResult, Error>) in
            let stdout = Mutex(Data()), stderr = Mutex(Data())
            do {
                try inv.run(stdout: { data in stdout.withLock { $0.append(data) } },
                            stderr: { data in stderr.withLock { $0.append(data) } },
                            exited: { status, timedOut, _ in
                    continuation.resume(returning: CodexProcessResult(
                        exitCode: status,
                        stdout: String(data: stdout.withLock { $0 }, encoding: .utf8) ?? "",
                        stderr: String(data: stderr.withLock { $0 }, encoding: .utf8) ?? "",
                        timedOut: timedOut
                    ))
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
