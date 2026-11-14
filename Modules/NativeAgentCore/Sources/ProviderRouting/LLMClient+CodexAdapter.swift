import Foundation
import Darwin
import Synchronization
@preconcurrency import Dispatch
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+CodexAdapter.swift` | `CodexProcess`: one process lifecycle; strict UTF-8 pipes |

/// One strict decoder for each Codex pipe. Only an incomplete scalar waits for another read. Invalid bytes and their entire suffix
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

/// Valid prefixes and exact undecodable pipe bytes stay on this error. Neither diagnostic prose nor logs publish raw bytes.
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

/// Dispatch owns a cancellable stdin write; a full pipe never blocks process settlement.
private final class CodexProcessInput: Sendable {
    private struct State {
        var channel: DispatchIO?
        var cancelled = false
        var failure: String?
    }
    private let state = Mutex(State())
    private let finished = DispatchGroup()

    init(handle: FileHandle, data: Data, onFailure: @escaping @Sendable () -> Void) throws {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(descriptor)
            throw error
        }
        do { try handle.close() }
        catch { Darwin.close(descriptor); throw error }
        let queue = DispatchQueue(label: "NativeAgent.codex.stdin")
        finished.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { [self] error in
            let closed = Darwin.close(descriptor)
            let closeError = errno
            state.withLock {
                if error != 0, !$0.cancelled {
                    $0.failure = "Codex stdin cleanup failed: \(NSError(domain: NSPOSIXErrorDomain, code: Int(error)).localizedDescription)"
                }
                if closed != 0 {
                    $0.failure = "Codex stdin close failed: \(NSError(domain: NSPOSIXErrorDomain, code: Int(closeError)).localizedDescription)"
                }
                $0.channel = nil
            }
            finished.leave()
        }
        state.withLock { $0.channel = channel }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { [self] done, _, error in
            if error != 0 {
                let failed = state.withLock {
                    guard !$0.cancelled else { return false }
                    $0.failure = "Could not deliver Codex stdin: \(NSError(domain: NSPOSIXErrorDomain, code: Int(error)).localizedDescription)"
                    return true
                }
                if failed { onFailure() }
            }
            if done { channel.close() }
        }
    }

    var captureFailure: String? { state.withLock { $0.failure } }
    func wait() { finished.wait() }
    func stop() {
        let channel = state.withLock { $0.cancelled = true; return $0.channel }
        channel?.close(flags: .stop)
    }
}

/// One invocation retains its process and pipes through exit and drain, independently of the caller's wait.
public struct CodexProcessInvocation: Sendable {
    public var executable: String
    public var arguments: [String]
    public var stdin: String
    public var lifetime: ProviderRequestLifetime
    public var call: LLMCall?
    /// Optional full child-process environment. Rooted secondary runtimes use this to bind CODEX_HOME/NATIVE_AGENT_DATA_ROOT instead of silently reading
    /// the operator's personal Codex home.
    public var environment: [String: String]?
    public init(
        executable: String,
        arguments: [String],
        stdin: String,
        environment: [String: String]? = nil,
        lifetime: ProviderRequestLifetime = ProviderRequestLifetime(),
        call: LLMCall? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.lifetime = lifetime
        self.call = call
    }

    /// Spawn once, drain both pipes, and join shutdown before reporting exit.
    fileprivate func run(
        stdout: @escaping @Sendable (Data) -> Void,
        stdoutClosed: @escaping @Sendable (ProcessPipeDrain.End) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        exited: @escaping @Sendable (Int32, String?) -> Void
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
            stdoutReader = try ProcessPipeDrain(handle: outPipe.fileHandleForReading, onData: stdout, onEnd: stdoutClosed)
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
        let input: CodexProcessInput
        do {
            input = try CodexProcessInput(handle: inPipe.fileHandleForWriting, data: Data(stdin.utf8)) {
                if proc.isRunning { ProcessTreeReaper.quiesceAndKill(proc.groupSnapshot) }
            }
        } catch {
            stdoutReader.stopAndWait()
            stderrReader.stopAndWait()
            throw error
        }
        // Install before run so even an immediately exiting child settles.
        proc.terminationHandler = { p in
            if p.terminationError != nil {
                input.stop()
                stdoutReader.stop()
                stderrReader.stop()
            }
            input.wait()
            stdoutReader.waitForEOF()
            stderrReader.waitForEOF()
            let failures = [p.terminationError, input.captureFailure, stdoutReader.captureFailure,
                            stderrReader.captureFailure].compactMap { $0 }
            let failure = failures.isEmpty ? nil : failures.joined(separator: "; ")
            exited(p.terminationStatus, failure)
        }
        do {
            try proc.run()
        } catch {
            input.stop()
            input.wait()
            stdoutReader.stopAndWait()
            stderrReader.stopAndWait()
            for pipe in [outPipe, errPipe, inPipe] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        if input.captureFailure != nil, proc.isRunning { ProcessTreeReaper.quiesceAndKill(proc.groupSnapshot) }
    }
}

/// Yield stdout in order; a silent answer requires EOF and successful process exit.
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
    private let streamingRunner: CodexStreamingProcessRunner
    private let processEnvironment: [String: String]
    private let dataRootOverride: URL?

    public init(
        codexBin: String? = nil,
        streamingRunner: @escaping CodexStreamingProcessRunner = CodexProcess.defaultStreamingRunner,
        processEnvironmentOverride: [String: String]? = nil,
        dataRootOverride: URL? = nil
    ) {
        self.codexBin = codexBin
        self.streamingRunner = streamingRunner
        self.processEnvironment = processEnvironmentOverride ?? ProcessInfo.processInfo.environment
        self.dataRootOverride = dataRootOverride
    }

    /// NativeAgent tools never reach the CLI; its tool wire is unsupported.
    public func complete(prompt: String, system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: call)
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

    /// Preparation and execution must use the same pinned credential. Returns the access token the child is handed.
    private static func prepareCodexHome(_ authPath: URL) async throws -> String? {
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

    /// Words settle at stdout EOF; a silent answer also waits for successful process exit.
    public func stream(
        prompt: String,
        system: String?,
        model: String, call: LLMCall
    ) -> AsyncThrowingStream<String, Error> {
        guard !Task.isCancelled, call.replyWork?.isStopped != true else {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        let authPath = resolvedAuthPath()
        let work = call.replyWork ?? ProviderReplyWork()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var sawContent = false
                var output = ""
                do {
                    try Task.checkCancellation()
                    if work.isStopped { throw CancellationError() }
                    let args = try arguments(model: model, authPath: authPath, call: call)
                    let invocation = CodexProcessInvocation(
                        executable: try codexBin ?? CodexExecutable.resolveCodexExecutable(environment: processEnvironment).path,
                        arguments: args,
                        stdin: Self.composedPrompt(system: system, prompt: prompt),
                        environment: childEnvironment(authPath: authPath), lifetime: call.lifetime, call: call
                    )
                    // The call's receipt binds to the token the child is handed; with none, the call proves nothing.
                    if let handed = try await Self.prepareCodexHome(authPath), !handed.isEmpty { call.sentCredential?.sending(token: handed) }
                    if work.isStopped { throw CancellationError() }
                    let upstream = streamingRunner(invocation)
                    for try await chunk in upstream {
                        output += chunk
                        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sawContent = true
                        }
                        continuation.yield(chunk)
                    }
                    guard sawContent || call.allowsSilentCompletion else {
                        throw ProviderFailure.Diagnostic(cause: .malformedResponse,
                            detail: "codex closed stdout without reply text")
                    }
                    await retainProducedReply(output, error: nil, call: call)
                    continuation.finish()
                } catch is CancellationError {
                    await retainProducedReply(output, error: CancellationError(), call: call)
                    continuation.finish(throwing: CancellationError())
                } catch let err as any ProviderFailureWrapping {
                    await retainProducedReply(output, error: err, call: call)
                    continuation.finish(throwing: err)
                } catch let err as LLMError {
                    await retainProducedReply(output, error: err, call: call)
                    continuation.finish(throwing: err)
                } catch {
                    await retainProducedReply(output, error: error, call: call)
                    continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
                }
            }
            work.own(task, stop: {})
            continuation.onTermination = { ending in
                if case .cancelled = ending { work.stop() }
            }
        }
    }

    /// The producer owns its output even after its caller stops waiting.
    @concurrent nonisolated private func retainProducedReply(_ output: String, error: Error?, call: LLMCall) async {
        guard !call.preview else { return }
        var payload: [String: JSONValue] = [
            "outputPreview": .string(TurnTraceRedactor.redactText(String(output.prefix(2_000)))),
            "outputBytes": .int(Int64(output.utf8.count)),
        ]
        if let error { payload["error"] = .string(ProviderFailure.diagnosticDescription(error)) }
        var retentionFailed = false
        if !output.isEmpty {
            switch ProviderOutputDiagnostics.writeDiagnostic(output, reason: "Codex output at stdout settlement", dataRoot: dataRootOverride, call: call) {
            case .success(let path):
                if let path { payload["outputPath"] = .string(path.path) }
                else { retentionFailed = true; payload["retentionError"] = .string("Codex output retention returned no path.") }
            case .failure(let cause):
                retentionFailed = true
                payload["retentionError"] = .string(ProviderFailure.diagnosticDescription(cause))
            }
        }
        let row = TurnTraceEvent(kind: "codex.reply.produced", title: "Codex produced reply",
            status: error == nil && !retentionFailed ? "ok" : "failed",
            payload: .object(payload), createdAt: ISO8601DateFormatter().string(from: Date()),
            turnId: call.turn?.id, sessionId: call.session, surface: call.surface, turn: call.turn)
        let root = call.traceDataRoot ?? dataRootOverride
        await settle { await TurnTracePersistLane(dataRootOverride: root).append(row) }
    }

    // MARK: - Text-only messages contract

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting: { held in
            self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held)
        }, using: LLMCallTraceRecorder(dataRootOverride: dataRootOverride), call: call)
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

    /// Delivery follows stdout; silence also requires the process's successful exit.
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
                    try Task.checkCancellation()
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
            continuation.onTermination = { ending in
                if case .cancelled = ending { task.cancel() }
            }
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
            do {
                try inv.run(stdout: { data in
                    if !data.isEmpty { activity?(); admitted?() }
                    if let text = stdout.append(data) { continuation.yield(text) }
                }, stdoutClosed: { ending in
                    let out = stdout.finish()
                    switch ending {
                    case .stopped: break
                    case .failed(let detail):
                        continuation.finish(throwing: LLMError.underlying(message: "Codex stdout capture failed: \(detail)"))
                    case .eof:
                        // An allowed silent answer needs the process's successful exit as well as EOF.
                        if !out.undecodable.isEmpty {
                            continuation.finish(throwing: CodexOutputEncodingFailure(stdout: out, stderr: stderr.finish()))
                        } else if out.text.contains(where: { !$0.isWhitespace }) || inv.call?.allowsSilentCompletion != true {
                            continuation.finish()
                        }
                    }
                }, stderr: { data in
                    if !data.isEmpty { activity?() }
                    _ = stderr.append(data)
                }, exited: { status, failure in
                    let out = stdout.finish(), err = stderr.finish()
                    let cause: Error?
                    if let failure {
                        cause = LLMError.underlying(message: "Codex process capture failed: \(failure)")
                    } else if !out.undecodable.isEmpty || !err.undecodable.isEmpty {
                        cause = CodexOutputEncodingFailure(stdout: out, stderr: err)
                    } else if status != 0 {
                        cause = CodexProcess.classifyCodexFailure(exitCode: status, stdout: out.text, stderr: err.text)
                    } else { cause = nil }
                    var payload: [String: JSONValue] = ["exitCode": .int(Int64(status)), "status": .string(cause == nil ? "completed" : "failed")]
                    if let cause { payload["cause"] = .string(ProviderFailure.diagnosticDescription(cause)) }
                    TurnTraceBus.fireFromContext(kind: "codex.process.exited", surface: inv.call?.surface,
                        payload: .object(payload), turn: inv.call?.turn)
                    if let cause { continuation.finish(throwing: cause) }
                    else { continuation.finish() }
                })
            } catch {
                continuation.finish(throwing: LLMError.underlying(message: "codex: \(error)"))
            }
        }
    }
}
