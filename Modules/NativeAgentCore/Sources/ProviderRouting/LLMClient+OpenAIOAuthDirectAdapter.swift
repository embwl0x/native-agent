import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - OpenAIOAuthDirectAdapter
//
// Uses endpoint-scoped ChatGPT OAuth credentials with the Codex Responses
// backend. NativeAgent.app owns browser sign-in; this adapter consumes and
// refreshes the persisted tokens. Requests use the shared backend identity
// and the account ID from persisted tokens or the access-token JWT.
// Refreshes are serialized per credential path and persisted atomically.
// ChatOrchestration owns tool permission, dispatch, persistence, and budgets.

/// Stable exhaustion marker for credentials that require signing in again.
/// Routing surfaces this failure instead of switching to an API-key adapter.
public let OpenAIOAuthDirectExhaustedMarker = "openai_oauth_direct_exhausted: re-sign-in required"

public struct CodexOAuthAccessContext: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String
    public let authPath: URL

    public init(accessToken: String, accountID: String, authPath: URL) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.authPath = authPath
    }
}

/// Actor-backed serial queue. Backs OpenAIOAuthDirectAdapter's refresh
/// serialization (gpt-5.5 review BLOCKING: concurrent refreshes can rotate
/// a single-use refresh_token twice). Actor isolation gives us strict
/// serialization of `run` invocations — each call's body runs to completion
/// (including its awaits) before the next call's body starts, FIFO.
actor AsyncSerialQueue {
    private var tail: Task<Void, Never> = Task {}

    func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        // Capture the current tail, install ourselves as the new tail.
        let prev = tail
        // Create a task that waits for `prev` and then runs `body`.
        // The next caller will see this Task as their `prev`.
        let me = Task { () -> Result<T, Error> in
            await prev.value
            do {
                let v = try await body()
                return .success(v)
            } catch {
                return .failure(error)
            }
        }
        // Erase the typed result so the tail chain stays Task<Void, Never>.
        tail = Task { _ = await me.value }
        // User, 2026-09-06: `me` is UNSTRUCTURED, so it inherited nothing from
        // the caller — a turn cut by the per-call wall or a Stop left its
        // refresh running, holding the queue in front of the next turn's
        // token read. Forward the caller's cancellation to the queued work.
        let result = await withTaskCancellationHandler {
            await me.value
        } onCancel: {
            me.cancel()
        }
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}

public final class OpenAIOAuthDirectAdapter: LLMAdapter {
    public let providerId: String = "openai_oauth_direct"

    public static let productionSession: URLSession = makeProductionSession()
    /// ChatGPT's Codex backend uses the official Codex client identity as a
    /// routing contract, not merely analytics. A neutral NativeAgent
    /// originator currently receives repeatable `server_is_overloaded`
    /// failures for requests that succeed with this exact identity.
    public static let codexBackendOriginator = "codex_cli_rs"
    public static var codexBackendUserAgent: String {
        let rawVersion =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "source"
        let safeVersion = rawVersion.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
        }
        let nativeAgentVersion = safeVersion.isEmpty ? "source" : safeVersion
        return "codex_cli_rs/0.145.0 NativeAgent/\(nativeAgentVersion)"
    }

    private let session: URLSession
    private let endpoint: URL
    private let refreshEndpoint: URL
    private let authPathOverride: URL?
    private let openAIPublicClientID: String
    /// U1 step 1 — per-call llm.call telemetry writer (override is test-only).
    private let telemetry: LLMCallTraceRecorder
    /// Serializes concurrent refresh attempts ACROSS instances. Production
    /// constructs new OpenAIOAuthDirectAdapter values at multiple callsites
    /// (BackgroundLoopsAssembly, Workshop, ChatOrchestrationClient, etc.)
    /// — a per-instance lock would let two instances race a refresh and
    /// burn the single-use refresh_token. Key by resolved auth-file path so
    /// distinct codex_home roots (rare; only in tests) stay independent.
    private var refreshSerial: AsyncSerialQueue {
        Self.sharedRefreshActor(for: resolveAuthPath())
    }

    nonisolated(unsafe) private static var sharedRefreshActors: [String: AsyncSerialQueue] = [:]
    private static let sharedRefreshActorsLock = NSLock()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        sharedRefreshActorsLock.lock()
        defer { sharedRefreshActorsLock.unlock() }
        let key = path.standardizedFileURL.path
        if let existing = sharedRefreshActors[key] { return existing }
        let q = AsyncSerialQueue()
        sharedRefreshActors[key] = q
        return q
    }

    static func makeProductionSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutValue(
            environment["NATIVE_AGENT_OPENAI_OAUTH_REQUEST_TIMEOUT_SEC"],
            fallback: 240
        )
        cfg.timeoutIntervalForResource = timeoutValue(
            environment["NATIVE_AGENT_OPENAI_OAUTH_RESOURCE_TIMEOUT_SEC"],
            fallback: 600
        )
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }

    private static func timeoutValue(_ raw: String?, fallback: TimeInterval) -> TimeInterval {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = TimeInterval(trimmed), parsed > 0 else { return fallback }
        return parsed
    }

    public init(
        session: URLSession = OpenAIOAuthDirectAdapter.productionSession,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
        refreshEndpoint: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        authPathOverride: URL? = nil,
        openAIPublicClientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.authPathOverride = authPathOverride
        self.openAIPublicClientID = openAIPublicClientID
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    // MARK: - prompt_cache_key (U1 step 4, 2026-06-10)

    /// Stable per-session prompt-cache routing key for the Responses API.
    /// Derived from the task-local session id bound by the ChatOrchestration
    /// tool loop (LLMCallContext.sessionId). Returns nil when no session id
    /// reaches the adapter — in that case NO prompt_cache_key field is added
    /// and the request body is byte-identical to pre-U1 behavior.
    /// `store:false` is intentionally NOT flipped.
    static func currentPromptCacheKey() -> String? {
        guard let raw = LLMCallContext.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        return "nativeagent-session-\(raw)"
    }

    private func responsesRequest(accessToken: String) throws -> URLRequest {
        guard let accountID = currentAccountID() else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue(Self.codexBackendOriginator, forHTTPHeaderField: "originator")
        req.setValue(Self.codexBackendUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    // MARK: - Public API

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    /// Returns a fresh Codex/ChatGPT OAuth token plus account id for non-chat
    /// Codex backend calls, such as the image_generation Responses tool.
    /// `staleToken` is the access token the caller's FAILING request used, and
    /// it matters for the same reason it does in the chat loops (User,
    /// 2026-09-06): without it a forced refresh here rotates the single-use
    /// refresh_token again even when another caller already rotated it, and
    /// concurrent 401s sign the user out.
    public func codexAccessContext(
        forceRefresh: Bool = false,
        staleToken: String? = nil
    ) async throws -> CodexOAuthAccessContext {
        let access = try await ensureFreshAccessToken(
            forceRefresh: forceRefresh, staleToken: staleToken)
        guard let accountID = currentAccountID() else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return CodexOAuthAccessContext(
            accessToken: access,
            accountID: accountID,
            authPath: resolveAuthPath()
        )
    }

    /// Structured multi-turn variant. Encodes the LLMMessage array into
    /// Responses-API `input` items (message / function_call /
    /// function_call_output). Without these structured items the model can't
    /// see its own prior tool calls as PAIRED with their results — the loop
    /// re-emits the same tool call every iteration and never converges.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let coercedModel = try Self.coerceToGPTModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        var forceTokenRefresh = false
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let access: String
            do {
                access = try await ensureFreshAccessToken(
                    forceRefresh: forceTokenRefresh,
                    staleToken: lastSentAccessToken
                )
                forceTokenRefresh = false
                lastSentAccessToken = access
            } catch is CancellationError { throw CancellationError() }
            catch let err as LLMError { throw err }
            catch { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
            var req = try responsesRequest(accessToken: access)

            let bodyDict = buildResponsesBodyFromMessages(
                model: coercedModel, messages: messages, system: system, tools: tools
            )
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "completeMessages"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if attempt == 0 {
                    forceTokenRefresh = true
                    continue
                }
                throw LLMError.authRejected(
                    provider: "openai_oauth_direct",
                    detail: OpenAIOAuthDirectExhaustedMarker
                )
            }
            if status == 429 {
                throw LLMError.rateLimited(message: String(data: data, encoding: .utf8) ?? "rate limited", retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(message: String(data: data, encoding: .utf8) ?? "5xx")
            }
            guard (200..<300).contains(status) else {
                throw LLMError.providerError(
                    message: "chatgpt-backend HTTP \(status): \(Self.boundedBodyString(data))"
                )
            }
            let parsed = Self.parseResponsesSSEDetailed(from: data)
            // User, 2026-09-06: a buffered SSE body that ends without a
            // terminal event is a truncated response, not a complete one.
            // Returning its text flushed half-arrived function calls with
            // `{}` arguments and the tool loop dispatched them. Throw the
            // same error the streaming sibling throws so the reconnect
            // ladder retries the identical call.
            if !parsed.sawTerminal {
                throw LLMError.streamTruncated(
                    message: "openai oauth response ended without terminal event"
                )
            }
            switch parsed.result {
            case .text(let s):
                // U1 step 1: usage telemetry (whole SSE buffer arrived at
                // once here, so no meaningful TTFT on this path).
                let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                await telemetry.record(
                    provider: providerId,
                    model: coercedModel,
                    streaming: false,
                    usage: parsed.usage,
                    ttftMs: nil,
                    durationMs: durationMs,
                    substitutedFrom: substitutedFrom
                )
                // User, 2026-09-06: a `response.incomplete` reply is
                // legitimate but CUT. Carry the provider's own reason out with
                // the text so the caller (and the transcript) can see it.
                if let reason = parsed.incompleteReason {
                    let note = Self.incompleteNote(reason)
                    return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? note
                        : s + "\n\n" + note
                }
                return s
            case .providerError(let message):
                let error = Self.classifiedBackendError(message)
                if attempt == 0, Self.isSafePreOutputRetry(error) {
                    continue
                }
                throw error
            }
        }
        throw LLMError.notConfigured(provider: "openai_oauth_direct")
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Coerce INSIDE the stream task: this is a non-throwing
                // factory, so an unserviceable model id has to reach the
                // caller as a thrown continuation finish rather than as a
                // silently defaulted model (NORTHSTAR clause 2).
                let coercedModel: String
                let substitutedFrom: String?
                do {
                    coercedModel = try Self.coerceToGPTModel(model)
                    substitutedFrom = Self.substitutionTrace(
                        requested: model,
                        coerced: coercedModel
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                var forceTokenRefresh = false
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token.
        var lastSentAccessToken: String?
                for attempt in 0...1 {
                    var emittedProviderOutput = false
                    do {
                        try Task.checkCancellation()
                        let access: String
                        do {
                            access = try await ensureFreshAccessToken(
                                forceRefresh: forceTokenRefresh,
                                staleToken: lastSentAccessToken
                            )
                            forceTokenRefresh = false
                            lastSentAccessToken = access
                        } catch is CancellationError { throw CancellationError() }
                        catch let err as LLMError { throw err }
                        catch { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
                        var req = try responsesRequest(accessToken: access)

                        let bodyDict = buildResponsesBodyFromMessages(
                            model: coercedModel, messages: messages, system: system, tools: tools
                        )
                        do {
                            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
                        } catch {
                            throw LLMError.underlying(message: "encode body: \(error)")
                        }

                        let requestStartNs = DispatchTime.now().uptimeNanoseconds
                        let bytes: URLSession.AsyncBytes
                        let response: URLResponse
                        do {
                            (bytes, response) = try await session.bytes(for: req)
                        } catch {
                            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
                        }
                        defer { bytes.task.cancel() }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 {
                            if attempt == 0 {
                                forceTokenRefresh = true
                                continue
                            }
                            throw LLMError.authRejected(
                    provider: "openai_oauth_direct",
                    detail: OpenAIOAuthDirectExhaustedMarker
                )
                        }
                        if status == 429 {
                            let body = try await Self.boundedBodyString(from: bytes)
                            throw LLMError.rateLimited(message: body.isEmpty ? "rate limited" : body, retryAfterSeconds: parseRetryAfterSeconds(from: response))
                        }
                        if (500..<600).contains(status) {
                            let body = try await Self.boundedBodyString(from: bytes)
                            throw LLMError.transient(message: body.isEmpty ? "5xx" : body)
                        }
                        guard (200..<300).contains(status) else {
                            let body = try await Self.boundedBodyString(from: bytes)
                            throw LLMError.providerError(
                                message: "chatgpt-backend HTTP \(status): \(body.isEmpty ? "empty error body" : body)"
                            )
                        }

                        struct PendingCall {
                            var callId: String
                            var name: String
                            var args: String
                        }
                        var pendingByItemId: [String: PendingCall] = [:]
                        var pendingOrder: [String] = []
                        // U1 step 1 — streaming telemetry: TTFT stamped at
                        // the FIRST meaningful output frame — text delta,
                        // function_call output_item.added, or first argument
                        // delta, whichever arrives first. Stamping only at
                        // output_item.done (after the whole argument stream)
                        // read materially too high for tool-call-first
                        // responses (gpt-5.5 review blocker, 2026-06-10).
                        // Usage rides on the terminal response.completed.
                        var capturedUsage: LLMUsage?
                        var ttftMs: Int?
                        // User, 2026-09-06: set by a terminal
                        // `response.incomplete` frame — see the buffered
                        // sibling. Same omission, same misclassification.
                        var incompleteReason: String?

                        func stampTTFT() {
                            emittedProviderOutput = true
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                        }

                        func yieldToolCall(id: String, name: String, args: String) {
                            let body = args.isEmpty ? "{}" : args
                            stampTTFT()
                            continuation.yield(.toolCall(LLMStreamToolCall(
                                id: id,
                                name: name,
                                inputJSON: Data(body.utf8)
                            )))
                        }

                        func processPayload(_ payloadStr: String) throws -> Bool {
                            if payloadStr == "[DONE]" { return true }
                            guard let pdata = payloadStr.data(using: .utf8),
                                  let event = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                                // User, 2026-09-06: an unparseable frame used to
                                // vanish, so a corrupted transport mid-answer
                                // silently dropped a chunk of the reply (or of
                                // a function call's arguments) and the turn
                                // still finished "successfully". Once output
                                // has started, a frame we cannot read is a
                                // stream failure the ladder should re-ask on.
                                guard emittedProviderOutput else { return false }
                                throw LLMError.transient(
                                    message: "openai oauth: malformed stream frame after content")
                            }
                            let etype = event["type"] as? String ?? ""
                            if etype == "response.output_text.delta" {
                                if let delta = event["delta"] as? String, !delta.isEmpty {
                                    stampTTFT()
                                    continuation.yield(.textDelta(delta))
                                }
                            } else if etype == "response.output_item.added" {
                                if let item = event["item"] as? [String: Any],
                                   (item["type"] as? String) == "function_call",
                                   let id = item["id"] as? String {
                                    // First model-output frame for a
                                    // tool-call-first response — stamp TTFT
                                    // here, not at output_item.done.
                                    stampTTFT()
                                    let callId = (item["call_id"] as? String) ?? id
                                    let name = (item["name"] as? String) ?? ""
                                    let args = (item["arguments"] as? String) ?? ""
                                    pendingByItemId[id] = PendingCall(callId: callId, name: name, args: args)
                                    pendingOrder.append(id)
                                }
                            } else if etype == "response.function_call_arguments.delta" {
                                if let id = event["item_id"] as? String,
                                   let delta = event["delta"] as? String {
                                    // Argument deltas are model output even
                                    // when the item wasn't registered by a
                                    // recognized `added` frame — stamp
                                    // unconditionally.
                                    stampTTFT()
                                    if pendingByItemId[id] != nil {
                                        pendingByItemId[id]!.args.append(delta)
                                    }
                                }
                                // Liveness: tool-arg deltas are model output but are
                                // accumulated (not yielded as content), so emit
                                // `.keepAlive` to keep ProviderStreamGuard's idle
                                // clock alive through a long tool-argument stream —
                                // parity with the Anthropic input_json_delta path
                                // (pre-existing gap, gpt-5.5 review 2026-06-15).
                                continuation.yield(.keepAlive)
                            } else if etype == "response.output_item.done" {
                                if let item = event["item"] as? [String: Any],
                                   (item["type"] as? String) == "function_call",
                                   let id = item["id"] as? String {
                                    var pending = pendingByItemId[id] ?? PendingCall(callId: id, name: "", args: "")
                                    if let callId = item["call_id"] as? String { pending.callId = callId }
                                    if pending.name.isEmpty, let name = item["name"] as? String { pending.name = name }
                                    if pending.args.isEmpty, let args = item["arguments"] as? String { pending.args = args }
                                    yieldToolCall(id: pending.callId, name: pending.name, args: pending.args)
                                    pendingByItemId.removeValue(forKey: id)
                                }
                            } else if etype == "response.completed" || etype == "response.done" {
                                // U1 step 1: usage rides on the terminal frame.
                                let respObj = event["response"] as? [String: Any]
                                if let usageObj = respObj?["usage"] as? [String: Any] {
                                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                                }
                                return true
                            } else if etype == "response.incomplete" {
                                // Terminal: the model stopped at a limit, the
                                // transport did not drop. Without this the
                                // stream ended `shouldStop == false` and threw
                                // `.streamTruncated`, sending an output-limit
                                // completion into the reconnect ladder.
                                let respObj = event["response"] as? [String: Any]
                                if let usageObj = respObj?["usage"] as? [String: Any] {
                                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                                }
                                incompleteReason = Self.incompleteReasonText(from: event)
                                return true
                            } else if etype == "response.failed" {
                                let detail = Self.backendErrorDescription(
                                    from: event,
                                    fallback: "response failed"
                                )
                                throw Self.classifiedBackendError(
                                    "chatgpt-backend response failed: \(detail)"
                                )
                            } else if etype == "error" {
                                let detail = Self.backendErrorDescription(
                                    from: event,
                                    fallback: "unknown backend error"
                                )
                                throw Self.classifiedBackendError(
                                    "chatgpt-backend error: \(detail)"
                                )
                            } else if etype.hasPrefix("response.reasoning") {
                                // Liveness: extended-reasoning frames
                                // (response.reasoning_text.delta /
                                // reasoning_summary_text.delta / …) carry no
                                // user-visible content but ARE real model activity.
                                // Emit `.keepAlive` so a long reasoning phase
                                // doesn't trip the guard's idle timeout — parity
                                // with the Anthropic thinking_delta path. Reasoning
                                // is NOT surfaced as reply text (no content yield).
                                continuation.yield(.keepAlive)
                            }
                            return false
                        }

                        // R15: SSEEventStream owns framing (LF-only terminator
                        // with CR strip — audit #14 — multi-line `data:` joins,
                        // EOF flush of an unterminated trailing event);
                        // processPayload owns the Responses-API semantics.
                        //
                        // Mid-stream transport errors (resource timeout,
                        // connection lost, ...) thrown by the byte stream must
                        // route through the SAME transientNetworkError mapping
                        // the initial session.bytes(for:) connect uses —
                        // without this wrapper they fell through to the
                        // generic catch below and surfaced as raw URLErrors,
                        // so mid-stream URLError.timedOut never classified
                        // transient (Anthropic OAuth parity, gpt-5.5 review
                        // 2026-07-02). Intentional LLMErrors from
                        // processPayload (providerError, ...) and
                        // cancellation re-throw untouched.
                        var shouldStop = false
                        do {
                            for try await sse in SSEEventStream(bytes) {
                                try Task.checkCancellation()
                                shouldStop = try processPayload(sse.data)
                                if shouldStop { break }
                            }
                        } catch let err as LLMError {
                            throw err
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
                        }
                        guard shouldStop else {
                            // Byte stream ended WITHOUT a terminal event
                            // ([DONE]/response.completed): a proxy/LB closing
                            // the response mid-reply otherwise rendered the
                            // partial as complete and persisted it. Every
                            // other adapter throws streamTruncated here —
                            // match the contract (audit 2026-06-09).
                            continuation.finish(throwing: LLMError.streamTruncated(
                                message: "openai oauth stream ended without terminal event"
                            ))
                            return
                        }
                        // User, 2026-09-06: never on a `response.incomplete` —
                        // an un-`done` call there was cut mid-arguments, so
                        // yielding it would dispatch invented arguments.
                        if incompleteReason == nil {
                            for id in pendingOrder {
                                if let pending = pendingByItemId[id] {
                                    yieldToolCall(
                                        id: pending.callId.isEmpty ? id : pending.callId,
                                        name: pending.name,
                                        args: pending.args
                                    )
                                }
                            }
                        }
                        // The reply is legitimate but CUT: say so in the one
                        // channel this lane has (there is no finish-reason
                        // event on the stream contract).
                        if let reason = incompleteReason {
                            // Own line: the consumers concatenate deltas, and a
                            // note-only reply has its leading whitespace trimmed
                            // by the surface like any other reply.
                            continuation.yield(.textDelta(
                                "\n\n" + Self.incompleteNote(reason)
                            ))
                        }
                        // U1 step 1: one llm.call row per successful stream.
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await self.telemetry.record(
                            provider: self.providerId,
                            model: coercedModel,
                            streaming: true,
                            usage: capturedUsage,
                            ttftMs: ttftMs,
                            durationMs: durationMs,
                            substitutedFrom: substitutedFrom
                        )
                        continuation.finish()
                        return
                    } catch let error as LLMError {
                        // A capacity failure can arrive inside an HTTP 200
                        // stream before any model output. Replaying that
                        // provider request once is safe: no assistant delta or
                        // tool call has crossed the stream, so the tool loop
                        // has not dispatched an effect. Keep this independent
                        // from OAuth refresh so a capacity retry never rotates
                        // a healthy refresh token.
                        if attempt == 0,
                           !emittedProviderOutput,
                           Self.isSafePreOutputRetry(error) {
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: LLMError.notConfigured(provider: "openai_oauth_direct"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build the Responses-API request body from a structured message array.
    /// Each LLMMessage / content block maps to an `input` item:
    ///   - text user message       → {type:"message",role:"user",content:[{type:"input_text",text}]}
    ///   - text assistant message  → {type:"message",role:"assistant",content:[{type:"output_text",text}]}
    ///   - toolUse (assistant)     → {type:"function_call",name,arguments:<jsonString>,call_id}
    ///   - toolResult (user)       → {type:"function_call_output",call_id,output:<string>}
    ///   - text system message     → {type:"message",role:"developer",content:[{type:"input_text",text}]}
    /// `instructions` carries the system prompt (same shape as buildResponsesBody).
    ///
    /// MID-CONVERSATION SYSTEM (`LLMMessage.Role.system`): a Responses `input`
    /// message item takes role `user`, `assistant`, `system` or `developer`.
    /// `developer` is the Responses-era name for the instruction role that
    /// outranks user text and is the one OpenAI documents for
    /// mid-conversation instructions, so that is what we emit; its content
    /// parts are INPUT parts (`input_text`), same as a user message —
    /// `output_text` is assistant-only and is rejected on an input item.
    /// FALLBACK: flip `midConversationSystemRole` to "system" if an
    /// account/model ever rejects `developer`.
    // internal (was private) so ProviderRoutingTests can pin the request body
    // shape (native-image content array) without a live network call.
    /// One-line rollback: "developer" → "system" (both are accepted input
    /// message roles; see buildResponsesBodyFromMessages' doc).
    static let midConversationSystemRole = "developer"

    /// Three-way input-item role. `.system` becomes the mid-conversation
    /// instruction role; the turn-level system prompt still rides in
    /// `instructions`.
    static func responsesRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return midConversationSystemRole
        }
    }

    /// `output_text` is assistant-only; every INPUT item (user and the
    /// mid-conversation instruction role alike) carries `input_text`.
    static func responsesTextType(_ role: LLMMessage.Role) -> String {
        role == .assistant ? "output_text" : "input_text"
    }

    func buildResponsesBodyFromMessages(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        for m in messages {
            // Native vision: a user message carrying image blocks is encoded as
            // ONE Responses `message` item whose content array holds the
            // `input_image` items (data-URL string per the Responses API shape)
            // FIRST, then the trailing `input_text`. This coalescing only kicks
            // in when an .image block is present; a text-only message keeps the
            // exact per-block item shape below (byte-identical to pre-vision).
            let hasImage = m.content.contains { if case .image = $0 { return true }; return false }
            if hasImage {
                let role = Self.responsesRole(m.role)
                var content: [[String: Any]] = []
                for block in m.content {
                    switch block {
                    case .image(let mediaType, let base64, _, _):
                        content.append([
                            "type": "input_image",
                            "image_url": "data:\(mediaType);base64,\(base64)",
                        ])
                    case .text(let t):
                        let typeKey = Self.responsesTextType(m.role)
                        content.append([ "type": typeKey, "text": t ])
                    case .toolUse, .toolResult:
                        // Tool blocks never co-occur with images on a single
                        // user turn in this path; ignore defensively.
                        break
                    }
                }
                inputItems.append([
                    "type": "message",
                    "role": role,
                    "content": content,
                ])
                continue
            }
            for block in m.content {
                switch block {
                case .text(let t):
                    let role = Self.responsesRole(m.role)
                    let typeKey = Self.responsesTextType(m.role)
                    inputItems.append([
                        "type": "message",
                        "role": role,
                        "content": [[ "type": typeKey, "text": t ]],
                    ])
                case .toolUse(let id, let name, let inputJSON):
                    let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                    inputItems.append([
                        "type": "function_call",
                        "name": name,
                        "arguments": argsStr,
                        "call_id": id,
                    ])
                case .toolResult(let toolUseId, let content, _):
                    inputItems.append([
                        "type": "function_call_output",
                        "call_id": toolUseId,
                        "output": content,
                    ])
                case .image:
                    // Unreachable: handled by the hasImage branch above.
                    break
                }
            }
        }
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "input": inputItems,
            "text": ["verbosity": "medium"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "instructions": (system?.isEmpty == false ? system! : "You are a helpful assistant."),
        ]
        OpenAIExecutionControls.applyResponsesControls(
            to: &body,
            model: model,
            transport: .chatGPTOAuth
        )
        // U1 step 4: stable per-session prompt-cache routing. Absent when no
        // session id is bound (byte-identical body to pre-U1).
        if let cacheKey = Self.currentPromptCacheKey() {
            body["prompt_cache_key"] = cacheKey
        }
        if let tools, !tools.isEmpty {
            var toolList: [[String: Any]] = []
            for t in tools {
                var entry: [String: Any] = [
                    "type": "function",
                    "name": t.name,
                    "description": t.description,
                ]
                if let params = try? JSONSerialization.jsonObject(with: t.parametersJSON) {
                    entry["parameters"] = params
                } else {
                    entry["parameters"] = ["type": "object", "properties": [:] as [String: Any]] as [String: Any]
                }
                toolList.append(entry)
            }
            body["tools"] = toolList
        }
        return body
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // Two-attempt loop mirroring Python's `for attempt in (0, 1)` at L967.
        // Attempt 0 uses whatever token is fresh (refreshing first if expired).
        // On HTTP 401 with attempt==0 we DO NOT refresh inline here — we just
        // invalidate-and-loop. The next iteration's
        // `ensureFreshAccessToken(forceRefresh: true)` does the single refresh.
        // Earlier draft did BOTH (inline refresh + forceRefresh in the loop),
        // which burned the single-use refresh_token by rotating twice.
        // (gpt-5.5 review BLOCKING: "double-refreshes after a first 401".)
        //
        // Coerce non-`gpt-` model ids to the GPT-default. The chatgpt.com
        // backend routes by model id and rejects unknown ids — `openai/...`
        // namespace prefixes need stripping (gpt-5.5 review NON-BLOCKING).
        let coercedModel = try Self.coerceToGPTModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        var forceTokenRefresh = false
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let access: String
            do {
                access = try await ensureFreshAccessToken(
                    forceRefresh: forceTokenRefresh,
                    staleToken: lastSentAccessToken
                )
                forceTokenRefresh = false
                lastSentAccessToken = access
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LLMError {
                // notConfigured surfaces clean (no tokens, refresh failed
                // with no-creds path, etc).
                throw err
            } catch {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            var req = try responsesRequest(accessToken: access)

            let bodyDict = buildResponsesBody(
                model: coercedModel, prompt: prompt, system: system, tools: tools
            )
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                // Cancellation MUST propagate as CancellationError (R-M2). Without
                // this, a cancelled Workshop execution task can be misclassified as an
                // auth problem instead of a real cancellation. A network failure with
                // VALID tokens isn't a credentials issue; surface as .transient so
                // callers can retry.
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "complete"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 401 {
                if attempt == 0 {
                    // Do NOT refresh inline here. Just loop — the next
                    // iteration's `ensureFreshAccessToken(forceRefresh: true)`
                    // does the single refresh, exactly once per call.
                    forceTokenRefresh = true
                    continue
                }
                // Exhausted — Python raises a structured RuntimeError carrying
                // the "oauth_direct_exhausted" string. We surface as
                // .underlying with the same marker. Surface NOT as
                // notConfigured, which would mask the real "tokens revoked,
                // re-sign-in required" signal.
                throw LLMError.authRejected(
                    provider: "openai_oauth_direct",
                    detail: OpenAIOAuthDirectExhaustedMarker
                )
            }
            if status == 429 {
                let msg = String(data: data, encoding: .utf8) ?? "rate limited"
                throw LLMError.rateLimited(message: msg, retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                let body = String(data: data, encoding: .utf8) ?? "5xx"
                throw LLMError.transient(message: body)
            }
            guard (200..<300).contains(status) else {
                throw LLMError.providerError(
                    message: "chatgpt-backend HTTP \(status): \(Self.boundedBodyString(data))"
                )
            }

            // Parse the SSE bytes. Surface mid-stream `response.failed` /
            // `error` events as .providerError so a 200 with an error body
            // doesn't return empty text as success (gpt-5.5 review BLOCKING).
            let parsed = Self.parseResponsesSSEDetailed(from: data)
            // User, 2026-09-06: a buffered SSE body that ends without a
            // terminal event is a truncated response, not a complete one.
            // Returning its text flushed half-arrived function calls with
            // `{}` arguments and the tool loop dispatched them. Throw the
            // same error the streaming sibling throws so the reconnect
            // ladder retries the identical call.
            if !parsed.sawTerminal {
                throw LLMError.streamTruncated(
                    message: "openai oauth response ended without terminal event"
                )
            }
            switch parsed.result {
            case .text(let s):
                // U1 step 1: usage telemetry.
                let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                await telemetry.record(
                    provider: providerId,
                    model: coercedModel,
                    streaming: false,
                    usage: parsed.usage,
                    ttftMs: nil,
                    durationMs: durationMs,
                    substitutedFrom: substitutedFrom
                )
                // User, 2026-09-06: a `response.incomplete` reply is
                // legitimate but CUT. Carry the provider's own reason out with
                // the text so the caller (and the transcript) can see it.
                if let reason = parsed.incompleteReason {
                    let note = Self.incompleteNote(reason)
                    return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? note
                        : s + "\n\n" + note
                }
                return s
            case .providerError(let message):
                let error = Self.classifiedBackendError(message)
                if attempt == 0, Self.isSafePreOutputRetry(error) {
                    continue
                }
                throw error
            }
        }
        // Unreachable — the loop body always either returns or throws.
        throw LLMError.notConfigured(provider: "openai_oauth_direct")
    }

    private func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        let host = endpoint.host ?? "chatgpt.com"
        let nsError = error as NSError
        let timeout = Int(session.configuration.timeoutIntervalForRequest.rounded())
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut:
                return .transient(message: "openai_oauth_direct \(operation) timed out after \(timeout)s: \(host)")
            case .cannotConnectToHost:
                return .transient(message: "openai_oauth_direct \(operation) cannot connect to \(host) (code=\(nsError.code))")
            case .networkConnectionLost:
                return .transient(message: "openai_oauth_direct \(operation) network connection was lost: \(host) (code=\(nsError.code))")
            case .notConnectedToInternet:
                return .transient(message: "openai_oauth_direct \(operation) not connected to internet: \(host) (code=\(nsError.code))")
            case .cannotFindHost, .dnsLookupFailed:
                return .transient(message: "openai_oauth_direct \(operation) cannot resolve \(host) (code=\(nsError.code))")
            default:
                return .transient(message: "openai_oauth_direct \(operation) network error for \(host): \(error) (code=\(nsError.code))")
            }
        }
        return .transient(message: "openai_oauth_direct \(operation) network error for \(host): \(error)")
    }

    private static func boundedBodyString(_ data: Data, maxBytes: Int = 4_096) -> String {
        guard !data.isEmpty else { return "empty error body" }
        let prefix = data.prefix(maxBytes)
        let text = String(decoding: prefix, as: UTF8.self)
        if data.count > maxBytes {
            return text + "\n...(truncated \(data.count - maxBytes) bytes)"
        }
        return text
    }

    private static func boundedBodyString(
        from bytes: URLSession.AsyncBytes,
        maxBytes: Int = 4_096
    ) async throws -> String {
        // One lookahead byte preserves the existing truncation annotation.
        let collected = try await ProviderErrorBodyDrain.read(
            bytes, maxBytes: maxBytes + 1, timeout: 2.0
        )
        var text = String(decoding: collected.prefix(maxBytes), as: UTF8.self)
        if collected.count > maxBytes { text += "\n...(truncated)" }
        return text
    }

    /// ChatGPT currently emits both a legacy top-level `message` and a newer
    /// nested `error` object. `response.failed` places that same object under
    /// `response.error`. Keep one decoder for buffered, streaming, plain, and
    /// structured lanes so one backend envelope change cannot degrade only one
    /// chat surface to an unhelpful "unknown" error.
    static func backendErrorDescription(
        from event: [String: Any],
        fallback: String
    ) -> String {
        let nested = event["error"] as? [String: Any]
        let responseNested =
            ((event["response"] as? [String: Any])?["error"] as? [String: Any])
        let object = nested ?? responseNested
        let rawMessage = (object?["message"] as? String)
            ?? (event["message"] as? String)
            ?? fallback
        let rawCode = (object?["code"] as? String)
            ?? (object?["type"] as? String)
            ?? (event["code"] as? String)
        let message = boundedProviderErrorField(rawMessage, fallback: fallback)
        guard let rawCode else { return message }
        let code = boundedProviderErrorField(rawCode, fallback: "")
        return code.isEmpty ? message : "\(message) [code=\(code)]"
    }

    /// HTTP 200 does not mean the ChatGPT Responses stream succeeded. Preserve
    /// hard auth and rate-limit semantics while classifying explicit capacity
    /// and availability failures as transient so existing surface retry policy
    /// can handle them truthfully.
    static func classifiedBackendError(_ description: String) -> LLMError {
        let lower = description.lowercased()
        if lower.contains("rate_limit")
            || lower.contains("rate limit")
            || lower.contains("too many requests") {
            return .rateLimited(message: description, retryAfterSeconds: nil)
        }
        if lower.contains("invalid_api_key")
            || lower.contains("invalid authentication")
            || lower.contains("authentication_error")
            || lower.contains("unauthorized") {
            return .authRejected(provider: "openai_oauth_direct", detail: description)
        }
        if lower.contains("server_is_overloaded")
            || lower.contains("overloaded_error")
            || lower.contains("service_unavailable")
            || lower.contains("server_error")
            || lower.contains("currently overloaded")
            || lower.contains("temporarily unavailable")
            || lower.contains("try again later") {
            return .transient(message: description)
        }
        return .providerError(message: description)
    }

    static func isSafePreOutputRetry(_ error: LLMError) -> Bool {
        if case .transient = error { return true }
        return false
    }

    private static func boundedProviderErrorField(
        _ raw: String,
        fallback: String,
        maximumCharacters: Int = 1_024
    ) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? fallback : cleaned
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "…"
    }

    /// Coerce a model id to a GPT id for the chatgpt.com backend. Mirrors
    /// Python's `_coerce_to_gpt_model` at L171-L177 narrowed for Swift:
    /// strip the `openai/` namespace prefix; pass `gpt-*` through; otherwise
    /// throw. The Python version also remaps Claude model ids
    /// to GPT defaults for defensive misrouting from the chat UI — we keep
    /// that behavior here so Anthropic ids that accidentally land on this
    /// adapter don't 404.
    ///
    /// NORTHSTAR clause 2 (fail loud, no silent substitution): the enumerated
    /// rewrites above — empty request, `openai/` strip, the legacy `gpt-5.5`
    /// normalization, the 9-entry Claude→GPT table — all stay. What is GONE
    /// is the terminal catch-all: an id nothing recognized (`llama-3`,
    /// `deepseek-chat`, `o3`) used to come back as the primary GPT model, so
    /// User's pick was replaced and billed without a word. It now throws
    /// `modelUnavailable` naming the offending id.
    static func coerceToGPTModel(_ requested: String?) throws -> String {
        // Reference the canonical primary-model constant from
        // NativeAgentCore.Constants instead of repeating the primary-tier
        // literal here. The single-source-of-truth test
        // (`nativeAgentPrimaryModel_isSingleSourceOfTruth`) asserts exactly
        // ONE primary-tier literal occurrence across
        // Modules/NativeAgentCore/Sources — the canonical declaration in
        // Constants.swift. The 3 occurrences formerly here (defaultGPT + 2
        // Opus→GPT remaps) all semantically meant "the primary GPT model"
        // and are folded onto the constant.
        let defaultGPT = nativeAgentPrimaryModel
        guard let r = requested?.trimmingCharacters(in: .whitespaces), !r.isEmpty else {
            return defaultGPT
        }
        // Strip openai/ namespace.
        let stripped: String = {
            if r.lowercased().hasPrefix("openai/") {
                return String(r.dropFirst("openai/".count))
            }
            return r
        }()
        // Sentinel fallback, NOT defaultGPT: normalizeModelIdStatic returns
        // its fallback for a rejected id (illegal characters, >100 chars).
        // With defaultGPT as the fallback that rejection came back as a
        // `gpt-` id and sailed through the prefix check below — a second
        // silent substitution hiding behind the first. An empty sentinel
        // can't match any accept rule, so a rejected id reaches the throw.
        let normalized = SwiftNativeProviderRouting.normalizeModelIdStatic(
            stripped,
            fallback: ""
        )
        if normalized.lowercased().hasPrefix("gpt-") {
            return normalized
        }
        // Defensive Claude-id remap (Python L136-L143). Opus tier maps to the
        // primary; sonnet/haiku tiers map to their respective sub-tier GPT
        // ids (those are distinct from the primary and stay as literals).
        let claudeToGPT: [String: String] = [
            "claude-fable-5-1":   nativeAgentPrimaryModel,
            "claude-fable-5":     nativeAgentPrimaryModel,
            "claude-opus-5":      nativeAgentPrimaryModel,
            "claude-opus-4-8":    nativeAgentPrimaryModel,
            "claude-opus-4-7":   nativeAgentPrimaryModel,
            "claude-sonnet-5":    "gpt-5.4",
            "claude-sonnet-4-6": "gpt-5.4",
            "claude-haiku-4-6":  "gpt-5.4-mini",
            "claude-opus-4-5":   nativeAgentPrimaryModel,
            "claude-sonnet-4-5": "gpt-5.4",
            "claude-haiku-4-5":  "gpt-5.4-mini",
        ]
        if let mapped = claudeToGPT[stripped.lowercased()] {
            return mapped
        }
        throw LLMError.modelUnavailable(provider: "openai_oauth_direct", model: r)
    }

    /// The requested id when an enumerated remap actually rewrote it, else
    /// nil. Threaded onto the `llm.call` telemetry row as `substitutedFrom`
    /// so a surviving remap (Claude→GPT table, `openai/` strip, legacy
    /// `gpt-5.5` normalization) leaves a trace instead of being invisible.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
    }


    // MARK: - Body shape (responses-API)

    /// Build the responses-API request body. Mirrors `_build_responses_body`
    /// at L873-L909, narrowed to the prompt+system signature the
    /// LLMAdapter contract exposes. The responses endpoint REJECTS `messages`
    /// — it takes `instructions` (system role) + `input` (message items).
    private func buildResponsesBody(
        model: String,
        prompt: String,
        system: String?,
        tools: [LLMToolSchema]? = nil
    ) -> [String: Any] {
        let inputItems: [[String: Any]] = [
            [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": prompt]],
            ]
        ]
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "input": inputItems,
            "text": ["verbosity": "medium"],
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            // The endpoint returns 400 "Instructions are required" when this
            // field is missing — Python uses the same default literal.
            "instructions": (system?.isEmpty == false ? system! : "You are a helpful assistant."),
        ]
        OpenAIExecutionControls.applyResponsesControls(
            to: &body,
            model: model,
            transport: .chatGPTOAuth
        )
        // U1 step 4: stable per-session prompt-cache routing. Absent when no
        // session id is bound (byte-identical body to pre-U1).
        if let cacheKey = Self.currentPromptCacheKey() {
            body["prompt_cache_key"] = cacheKey
        }
        // Tools field: Responses-API shape is FLAT
        // ({"type":"function","name":...,"description":...,"parameters":...}),
        // NOT the Chat Completions wrap. Only add the key when non-empty so a
        // nil/empty tools arg produces byte-identical body to the no-tools
        // call.
        if let tools, !tools.isEmpty {
            var toolList: [[String: Any]] = []
            for t in tools {
                var entry: [String: Any] = [
                    "type": "function",
                    "name": t.name,
                    "description": t.description,
                ]
                if let params = try? JSONSerialization.jsonObject(with: t.parametersJSON) {
                    entry["parameters"] = params
                } else {
                    // Defensive: malformed schema bytes degrade to an empty
                    // object schema rather than throwing and silently killing
                    // the chat turn.
                    entry["parameters"] = ["type": "object", "properties": [:] as [String: Any]] as [String: Any]
                }
                toolList.append(entry)
            }
            body["tools"] = toolList
        }
        // Note: `max_output_tokens` is INTENTIONALLY omitted — the comment in
        // the Python source (L897-L900) calls out that the chatgpt.com
        // backend rejects it even though the public Responses API accepts it.
        return body
    }

    // MARK: - Credential path

    /// Explicit injection wins; otherwise use the shared credential discovery
    /// and CLI-adoption consent rules in OpenAIOAuthCredentials.
    func resolveAuthPath() -> URL {
        if let override = authPathOverride { return override }
        return Self.preferredAuthPath()
    }


    // MARK: - Token refresh

    private static let tokenExpiryBufferSec: Int = 120

    /// Return a non-expired access token. Force-refresh when `forceRefresh`
    /// is true (used on retry after HTTP 401). Mirrors
    /// `_ensure_fresh_access_token` at L496-L531 — including the
    /// lock-protected re-read inside the critical section so a concurrent
    /// caller that already rotated the token doesn't trigger a second
    /// refresh that would burn the single-use refresh_token.
    /// `staleToken` is the access token the caller's FAILING request used. On
    /// a forced refresh it lets a queued caller notice that someone ahead of it
    /// already rotated, instead of rotating again (User, 2026-09-06).
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil
    ) async throws -> String {
        // Fast path OUTSIDE the lock — check disk; return if still fresh.
        guard let blob0 = loadAuthBlob() else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        let tokens0 = (blob0["tokens"] as? [String: Any]) ?? [:]
        guard let access0 = tokens0["access_token"] as? String, !access0.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        if !forceRefresh {
            // Honor BOTH the JWT `exp` AND the persisted top-level
            // `expires_at` (if present) — pick the EARLIER of the two so an
            // out-of-band rotation (clock skew, manual sign-in) doesn't
            // serve a token past its real expiry. Mirrors how the daemon
            // tracks expiry independently of the JWT claim.
            let now = Int(Date().timeIntervalSince1970)
            let jwtExp = Self.tokenExpiresAt(access0)
            let persistedExp = Self.persistedExpiresAt(blob: blob0, tokens: tokens0)
            let effExp: Int? = {
                switch (jwtExp, persistedExp) {
                case (.some(let a), .some(let b)): return min(a, b)
                case (.some(let a), .none):        return a
                case (.none, .some(let b)):        return b
                case (.none, .none):               return nil
                }
            }()
            if let exp = effExp, exp - now > Self.tokenExpiryBufferSec {
                return access0
            }
            // missing-exp on both sides falls through to refresh (matches
            // Python's "refresh when uncertain" behavior).
        }
        // Slow path — serialize via the refresh queue so concurrent callers
        // share ONE refresh instead of double-rotating refresh_token.
        return try await refreshSerial.run {
            // Re-load INSIDE the critical section: another waiter may have
            // already refreshed while we were queued.
            guard let blob = self.loadAuthBlob() else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            let tokens = (blob["tokens"] as? [String: Any]) ?? [:]
            guard let access = tokens["access_token"] as? String, !access.isEmpty else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            // User, 2026-09-06: N concurrent 401s each forced their own
            // refresh, and every rotation invalidates the single-use
            // refresh_token the callers queued behind it are about to spend —
            // so a burst of parallel requests signed the user out. A forced
            // refresh whose token has already moved on since the failing
            // request read it takes the new token instead of rotating again.
            if forceRefresh, let staleToken, !staleToken.isEmpty, access != staleToken {
                return access
            }
            if !forceRefresh {
                let now = Int(Date().timeIntervalSince1970)
                let jwtExp = Self.tokenExpiresAt(access)
                let persistedExp = Self.persistedExpiresAt(blob: blob, tokens: tokens)
                let effExp: Int? = {
                    switch (jwtExp, persistedExp) {
                    case (.some(let a), .some(let b)): return min(a, b)
                    case (.some(let a), .none):        return a
                    case (.none, .some(let b)):        return b
                    case (.none, .none):               return nil
                    }
                }()
                if let exp = effExp, exp - now > Self.tokenExpiryBufferSec {
                    return access  // someone else already refreshed
                }
            }
            return try await self.refreshTokens()
        }
    }

    /// Refresh and persist tokens. Returns the new access token. Mirrors the
    /// lock-protected refresh block at L511-L531 + `_refresh_with_refresh_
    /// token` at L533-L558.
    @discardableResult
    func refreshTokens() async throws -> String {
        // User, 2026-09-06: resolve the path ONCE, before the network call. It
        // used to be resolved again at write time, and candidate resolution
        // probes the filesystem — a sign-out that deleted the app-owned file
        // mid-refresh moved the answer to the shared ~/.codex/auth.json, so
        // the write landed on the Codex CLI's own session file.
        let path = resolveAuthPath()
        // User, 2026-09-06: ONE read of ONE path. `loadAuthBlob()` re-resolved
        // the candidate list, so the refresh could read its refresh_token from
        // a different file than the one whose bytes it was about to compare
        // and write — and the parsed blob could disagree with the baseline it
        // was captured beside.
        let baseline = try? Data(contentsOf: path)
        guard let baseline,
              let blob = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any],
              let tokens = blob["tokens"] as? [String: Any],
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        // Build the form body — NO scope, NO redirect_uri (matches Python's
        // exact body shape at L536-L540).
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: openAIPublicClientID),
        ]
        let bodyString = components.percentEncodedQuery ?? ""
        let bodyData = bodyString.data(using: .utf8) ?? Data()

        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        // User, 2026-09-06: the refresh holds the serial queue, so it needs a
        // bound of its own rather than the session's chat-sized request
        // timeout — a hung token endpoint otherwise blocks every later turn's
        // token read for minutes.
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // A3.5: a 429/5xx during refresh is a provider-side hiccup, NOT a
            // dead token — surface transient so the session survives without a
            // needless "reconnect" prompt (the misreported-as-revoked bug).
            // User, 2026-09-06: preserve `Retry-After` on a refresh 429 the way
            // the chat call path does — see the Anthropic sibling.
            if status == 429 {
                throw LLMError.rateLimited(
                    message: "openai_oauth_direct refresh HTTP 429 (temporary)",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(
                    message: "openai_oauth_direct refresh HTTP \(status) (temporary)")
            }
            // A3.1/A3.5: 401/403/400(invalid_grant) = refresh token itself was
            // rejected → genuinely revoked. authRejected carries reconnect
            // guidance instead of the misleading "not configured".
            throw LLMError.authRejected(
                provider: "openai_oauth_direct", detail: providerErrorDetail(data))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.underlying(message: "refresh: unparseable response")
        }

        // Merge new tokens into existing — preserving account_id and any
        // other fields the refresh response doesn't return. Same merge
        // semantics as Python L526-L529.
        var newBlob = blob
        var merged = tokens
        for key in ["access_token", "refresh_token", "id_token"] {
            if let v = payload[key] as? String, !v.isEmpty {
                merged[key] = v
            }
        }
        // Re-extract account_id if the new access token has one and we
        // don't already have it persisted (fresh sign-in path).
        if let access = merged["access_token"] as? String,
           (merged["account_id"] as? String)?.isEmpty ?? true {
            if let acct = Self.extractAccountIDFromJWT(access) {
                merged["account_id"] = acct
            }
        }
        newBlob["tokens"] = merged
        newBlob["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        // Also write a top-level expires_at so the OAuth status UI (and the
        // ensureFreshAccessToken persisted-exp fast path) doesn't need to
        // decode the JWT just to know when the next refresh fires. Prefer
        // payload.expires_in (server-authoritative); fall back to the JWT.
        if let exp_in = payload["expires_in"] as? Int {
            let d = Date().addingTimeInterval(TimeInterval(exp_in))
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            newBlob["expires_at"] = f.string(from: d)
        } else if let access = merged["access_token"] as? String,
                  let exp = Self.tokenExpiresAt(access) {
            let d = Date(timeIntervalSince1970: TimeInterval(exp))
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            newBlob["expires_at"] = f.string(from: d)
        }
        // User, 2026-09-06: sign-out and a fresh sign-in write this file without
        // going through the adapter's refresh queue, so an in-flight refresh
        // could resurrect a deleted credential or overwrite a newer one with
        // the older account's tokens. The bytes captured before the network
        // call are the generation: if they moved, this refresh is stale, its
        // write is skipped, and the caller is served whatever credential now
        // owns the file.
        // User, 2026-09-06: the comparison and the write now sit in ONE
        // critical section on the credential path's shared lock — the app's
        // sign-in and sign-out take the same lock — because a compare followed
        // by an unguarded write still lost every sign-out that landed between
        // the two.
        enum RefreshWrite { case wrote, superseded(String), supersededAndGone }
        let outcome: RefreshWrite
        do {
            // Serialize the blob to bytes outside the closure so we don't
            // carry a non-Sendable [String: Any] across the boundary.
            let bytes = try JSONSerialization.data(
                withJSONObject: newBlob,
                options: [.prettyPrinted, .sortedKeys]
            )
            outcome = try CredentialFileLock.withLock(path) { () -> RefreshWrite in
                guard (try? Data(contentsOf: path)) == baseline else {
                    guard let current = Self.storedAccessToken(at: path) else {
                        return .supersededAndGone
                    }
                    return .superseded(current)
                }
                try Self.writeAuthBytesAtomically(bytes, to: path)
                return .wrote
            }
        } catch {
            // The refresh_token we just consumed was SINGLE-USE and the
            // server already rotated it — if the new blob doesn't reach
            // disk, the on-disk credential is burned and the next refresh
            // silently signs the user out (audit 2026-06-09). Fail loudly;
            // the empty catch here was a swallowed logout.
            FileHandle.standardError.write(Data(
                "OpenAIOAuthDirectAdapter: PERSIST FAILED after token rotation — on-disk refresh_token is now stale: \(error)\n".utf8
            ))
            throw LLMError.underlying(
                message: "openai oauth: token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required"
            )
        }
        switch outcome {
        case .superseded(let current):
            // Another writer owns the file now. Its credential is the live one.
            return current
        case .supersededAndGone:
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        case .wrote:
            break
        }
        guard let newAccess = merged["access_token"] as? String, !newAccess.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return newAccess
    }
}
