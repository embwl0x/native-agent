import Foundation
import Synchronization
@preconcurrency import Dispatch
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+CodexAdapter.swift` | `CodexProcess`: one process lifecycle; strict UTF-8 pipes |

/// One strict decoder for each Codex pipe, shared by both runners. Only an incomplete scalar waits for another read. Invalid bytes and their entire suffix
/// stay owned as raw evidence; valid text before them remains available.
final class CodexUTF8Output: @unchecked Sendable {
    struct Snapshot: Sendable {
        let text: String
        let undecodable: Data
    }
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var text = ""
    private var invalid = false

    func append(_ data: Data) -> String? {
        lock.withLock {
            pending.append(contentsOf: data)
            guard !invalid else { return nil }
            var cursor = 0
            while cursor < pending.count {
                let first = pending[cursor]
                let width: Int
                switch first {
                case 0...0x7F: width = 1
                case 0xC2...0xDF: width = 2
                case 0xE0...0xEF: width = 3
                case 0xF0...0xF4: width = 4
                default: invalid = true; width = 0
                }
                guard !invalid else { break }
                // Validate available continuation bytes even on a split scalar; overlong encodings, surrogates and > U+10FFFF are invalid now.
                for offset in 1..<width {
                    guard cursor + offset < pending.count else { break }
                    let byte = pending[cursor + offset]
                    let range: ClosedRange<UInt8>
                    if offset == 1, first == 0xE0 { range = 0xA0...0xBF }
                    else if offset == 1, first == 0xED { range = 0x80...0x9F }
                    else if offset == 1, first == 0xF0 { range = 0x90...0xBF }
                    else if offset == 1, first == 0xF4 { range = 0x80...0x8F }
                    else { range = 0x80...0xBF }
                    if !range.contains(byte) { invalid = true; break }
                }
                guard !invalid, cursor + width <= pending.count else { break }
                cursor += width
            }
            guard cursor > 0 else { return nil }
            // The scanner admitted only complete valid Unicode scalars.
            let delta = String(decoding: pending.prefix(cursor), as: UTF8.self)
            pending.removeFirst(cursor)
            text += delta
            return delta
        }
    }

    func finish() -> Snapshot {
        lock.withLock { Snapshot(text: text, undecodable: Data(pending)) }
    }
}

/// The process has settled; valid prefixes and exact undecodable pipe bytes stay on this error. Neither diagnostic prose nor logs publish raw bytes.
struct CodexOutputEncodingFailure: Error, Sendable, LocalizedError, ProviderFailureWrapping {
    let stdout: CodexUTF8Output.Snapshot
    let stderr: CodexUTF8Output.Snapshot
    var providerFailureCause: Error { ProviderFailure.Diagnostic(cause: .malformedResponse, detail: detail) }
    var providerWorkState: ProviderFailure.WorkState? { .outcomeUnknown }
    var errorDescription: String? { detail }
    private var detail: String {
        """
            Codex output was not valid UTF-8: stdout retained \(stdout.text.utf8.count) valid bytes and \(stdout.undecodable.count) undecodable bytes; \
            stderr retained \(stderr.text.utf8.count) valid bytes and \(stderr.undecodable.count) undecodable bytes. The reply is incomplete; inspect the \
            Codex output encoding before another call.
            """
    }
}

private final class CodexProcessShutdown: @unchecked Sendable {
    private let process: ManagedProcess
    private let launchTree: ProcessTreeSnapshot
    private let lock = NSLock()
    private var requested = false
    private let stopped = DispatchGroup()

    init(_ process: ManagedProcess) {
        self.process = process
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
            // The runner's termination handler owns root exit observation and joins this escalation before draining and returning the result.
        }
    }

    /// Called on the process exit queue, never the cooperative executor.
    func waitForStop() { stopped.wait() }
}

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

/// Cancellation is sticky: a fire before registration must terminate the child as soon as its handle arrives.
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
        // Honor cancellation that arrived before the process registered its terminator.
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

/// Register termination immediately after spawn so consumer cancellation cannot leave an unowned process running.
public struct CodexProcessInvocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var stdin: String
    public var timeout: TimeInterval
    public var terminator: CodexTerminator
    public var lifetime: ProviderRequestLifetime
    /// Optional full child-process environment. Rooted secondary runtimes use this to bind CODEX_HOME/NATIVE_AGENT_DATA_ROOT instead of silently reading
    /// the operator's personal Codex home.
    public var environment: [String: String]?
    public init(
        executable: String,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        terminator: CodexTerminator = CodexTerminator(),
        environment: [String: String]? = nil,
        lifetime: ProviderRequestLifetime = ProviderRequestLifetime()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.timeout = timeout
        self.terminator = terminator
        self.environment = environment
        self.lifetime = lifetime
    }

    /// Spawn once, drain both pipes, and join shutdown before reporting exit.
    fileprivate func run(
        stdout: @escaping @Sendable (Data) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        exited: @escaping @Sendable (Int32, Bool, Bool) -> Void
    ) throws {
        let proc = ManagedProcess()
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
            if let failure = p.terminationError { stderr(Data(("\n" + failure).utf8)) }
            exited(p.terminationStatus, timedOut.withLock { $0 }, cancelled.withLock { $0 } && p.terminationError == nil)
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

public typealias CodexProcessRunner = @Sendable (CodexProcessInvocation) async throws -> CodexProcessResult

/// Yield stdout in order, finish after exit/drain, and propagate failures. Consumer termination must stop the child and detach its read handler.
public typealias CodexStreamingProcessRunner = @Sendable (CodexProcessInvocation) -> AsyncThrowingStream<String, Error>

/// Buffered and incremental callers share one process lifecycle; delivery follows the CLI's stdout flushing.
public final class CodexProcess: LLMTransport {
    public static let toolWire = ProviderToolWire.unsupported
    /// The CLI prompt is text-only, so image loss must be reported.
    public static let carriesImages = false
    /// This transport has no output-cap field.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

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
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall) async throws -> String {
        let authPath = resolvedAuthPath()
        let args = try arguments(model: model, authPath: authPath, call: call)
        let terminator = CodexTerminator()
        let invocation = CodexProcessInvocation(
            executable: try codexBin ?? CodexExecutable.resolveCodexExecutable(environment: processEnvironment).path,
            arguments: args,
            stdin: Self.composedPrompt(system: system, prompt: prompt),
            timeout: call.wallOwned || call.lifetime.stallOnly ? 0 : timeout,
            terminator: terminator,
            environment: childEnvironment(authPath: authPath), lifetime: call.lifetime
        )
        try await Self.prepareCodexHome(authPath)
        let result: CodexProcessResult
        do {
            // Consumer cancellation must stop the spawned process rather than leave it running after its owner exits.
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
            // Keep cancellation typed so structured callers cannot mistake it for process failure.
            throw CancellationError()
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "codex: \(error)"))
        }
        // Cancellation can cause a nonzero exit without the runner throwing; check it before classifying a process failure.
        if Task.isCancelled {
            // The runner has joined exit and both drains. Produced text is returned to the cancelled owner for its stopped settlement.
            if !result.stdout.isEmpty { return result.stdout }
            throw CancellationError()
        }
        if result.timedOut {
            throw LLMError.underlying(message: "codex: timed out after \(Int(timeout))s")
        }
        if result.exitCode != 0 {
            // Keep bounded CLI failure evidence for diagnosis.
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

    /// Preparation and execution must use the same pinned credential.
    private static func prepareCodexHome(_ authPath: URL) async throws {
        try await ChatGPTTransport.prepareCodexChildHome(
            ChatGPTTransport.codexHomeForChild(authPath: authPath), authPath: authPath
        )
    }

    /// Classify nonzero exits from retained pipe evidence.
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

    /// Require whole phrase boundaries so sign-in errors cannot match incidental text inside longer words.
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

    /// Retain the bounded diagnostic tail because actionable CLI errors usually appear last.
    static func boundedCodexTail(_ s: String, max: Int = 600) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return "…" + String(t.suffix(max))
    }

    /// Streaming shares the complete invocation's cancellation owner.
    public func stream(
        prompt: String,
        system: String?,
        model: String, call: LLMCall
    ) -> AsyncThrowingStream<String, Error> {
        let authPath = resolvedAuthPath()
        let terminator = CodexTerminator()
        return AsyncThrowingStream { continuation in
            let task = Task {
                await withTaskCancellationHandler {
                    var sawContent = false
                    do {
                        try Task.checkCancellation()
                        let args = try arguments(model: model, authPath: authPath, call: call)
                        let invocation = CodexProcessInvocation(
                            executable: try codexBin ?? CodexExecutable.resolveCodexExecutable(environment: processEnvironment).path,
                            arguments: args,
                            stdin: Self.composedPrompt(system: system, prompt: prompt),
                            timeout: call.wallOwned || call.lifetime.stallOnly ? 0 : timeout,
                            terminator: terminator,
                            environment: childEnvironment(authPath: authPath), lifetime: call.lifetime
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
                    } catch let err as any ProviderFailureWrapping {
                        continuation.finish(throwing: err)
                    } catch let err as LLMError {
                        continuation.finish(throwing: err)
                    } catch {
                        continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
                    }
                } onCancel: {
                    terminator.fire()
                }
            }
            call.replyWork?.own(task, stop: { terminator.fire() })
            continuation.onTermination = { _ in
                terminator.fire()
                task.cancel()
            }
        }
    }

    // MARK: - Buffered text-only messages contract

    /// The CLI cannot see images; tell the model and record the drop while flattening tool blocks into the text prompt.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        let combined = try await messagesPrompt(messages, model: model, call: call)
        return try await complete(prompt: combined, system: system, model: model, tools: tools, call: call)
    }

    private func messagesPrompt(_ messages: [LLMMessage], model: String, call: LLMCall) async throws -> String {
        let flattened = try llmCompatibilityPrompt(messages: messages) { role in
            role == .user ? "USER:" : "ASSISTANT:"
        }
        if flattened.imageCount > 0 {
            await Self.emitVisionUnsupportedTrace(provider: providerId, model: model, imageCount: flattened.imageCount, call: call)
        }
        return flattened.text
    }

    /// Delivery follows actual stdout for every deadline policy.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = try await messagesPrompt(messages, model: model, call: call)
                    for try await chunk in stream(prompt: prompt, system: system, model: model, call: call) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(chunk))
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ProviderFailure.normalize(error))
                }
            }
            call.replyWork?.own(task, stop: {})
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Record dropped images in the path-owned trace so text-only transport loss remains visible.
    private static func emitVisionUnsupportedTrace(
        provider: String,
        model: String,
        imageCount: Int, call: LLMCall
    ) async {
        guard !call.preview else { return }
        let event = TurnTraceEvent(kind: "vision.attachment_unsupported",
            title: "vision_attachment_unsupported", status: "ok", payload: .object([
                "provider": .string(provider),
                "model": .string(model),
                "imageCount": .int(Int64(imageCount)),
            ]), createdAt: ISO8601DateFormatter().string(from: Date()),
            turnId: call.turn?.id, sessionId: call.session, surface: call.surface, turn: call.turn)
        await TurnTracePersistLane(dataRootOverride: call.traceDataRoot).append(event)
    }

    /// Piped non-interactive prompts must work from any app working directory.
    private func arguments(model: String, authPath: URL, call: LLMCall) throws -> [String] {
        // This transport is a model call. CLI tools would act outside the NativeAgent dispatcher, so its declared no-tools contract applies to the child
        // too, independent of the person's CLI configuration.
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
        if call.lifetime.stallOnly {
            args.append(contentsOf: ["-c", "model_reasoning_summary=\"auto\""])
        }
        if let effort = try OpenAIExecutionControls.reasoningEffort(
            model: model,
            requested: call.admission?.reasoningEffort,
            transport: .codexCLI,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            oauthAuthURL: authPath, preview: call.preview
        ) {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        if let tier = try OpenAIExecutionControls.serviceTier(
            model: model,
            requested: call.admission?.serviceTier,
            transport: .codexCLI,
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            oauthAuthURL: authPath, preview: call.preview
        ) {
            args.append(contentsOf: ["-c", "service_tier=\"\(tier)\""])
        }
        args.append(contentsOf: ["-m", model])
        return args
    }

    /// The CLI has no system flag, so send the system prompt over stdin.
    static func composedPrompt(system: String?, prompt: String) -> String {
        guard let system,
              !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return prompt }
        return system + "\n\n" + prompt
    }

    public static let defaultStreamingRunner: CodexStreamingProcessRunner = { inv in
        AsyncThrowingStream { continuation in
            let activity = inv.lifetime.activity
            let admitted = inv.lifetime.admitted
            let stdout = CodexUTF8Output(), stderr = CodexUTF8Output()
            continuation.onTermination = { _ in inv.terminator.fire() }
            do {
                try inv.run(stdout: { data in
                    if !data.isEmpty { activity?(); admitted?() }
                    if let text = stdout.append(data) { continuation.yield(text) }
                }, stderr: { data in
                    if !data.isEmpty { activity?() }
                    _ = stderr.append(data)
                }, exited: { status, timedOut, cancelled in
                    let out = stdout.finish(), err = stderr.finish()
                    if !out.undecodable.isEmpty || !err.undecodable.isEmpty {
                        continuation.finish(throwing: CodexOutputEncodingFailure(stdout: out, stderr: err))
                    } else if cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if timedOut {
                        continuation.finish(throwing: LLMError.underlying(message: "codex: timed out after \(inv.timeout)s"))
                    } else if status == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CodexProcess.classifyCodexFailure(
                            exitCode: status, stdout: out.text, stderr: err.text))
                    }
                })
            } catch {
                continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
            }
        }
    }

    public static let defaultRunner: CodexProcessRunner = { inv in
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexProcessResult, Error>) in
            let stdout = CodexUTF8Output(), stderr = CodexUTF8Output()
            do {
                try inv.run(stdout: { data in _ = stdout.append(data) },
                            stderr: { data in _ = stderr.append(data) },
                            exited: { status, timedOut, cancelled in
                    let out = stdout.finish(), err = stderr.finish()
                    if !out.undecodable.isEmpty || !err.undecodable.isEmpty {
                        continuation.resume(throwing: CodexOutputEncodingFailure(stdout: out, stderr: err))
                    } else if cancelled, out.text.isEmpty {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: CodexProcessResult(
                            exitCode: status, stdout: out.text, stderr: err.text, timedOut: timedOut))
                    }
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
