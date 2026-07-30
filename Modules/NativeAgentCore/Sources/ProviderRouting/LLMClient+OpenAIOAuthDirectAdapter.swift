import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - OpenAIOAuthDirectAdapter
//
// WAVE 27 (2026-06-01) — Swift mirror of `daemon/providers/openai_oauth_direct.py`.
//
// Why this adapter exists. Wave 26 closed the credential-path drift (the Swift
// resolver couldn't find OPENAI_API_KEY in `data/codex_home/auth.json`), but
// the wave-25 empirical re-run still produced `verdict=DEFER_RETIREMENT_STUB_
// FALLBACK` — because the user's production environment is OAuth-only. The
// OPENAI_API_KEY field is literally `null` in `auth.json`; the real
// credentials live in `auth.json::tokens.access_token` (a ChatGPT OAuth JWT,
// endpoint-scoped to `chatgpt.com`, NOT `api.openai.com`). The Python
// mission planner uses `openai_oauth_direct.py` which POSTs to
// `https://chatgpt.com/backend-api/codex/responses` with that JWT as Bearer.
// This Swift adapter mirrors that path.
//
// Endpoint + auth (mirrors `_DEFAULT_API_BASE + _RESPONSES_PATH` and
// `_build_responses_headers` in the Python source):
//   POST https://chatgpt.com/backend-api/codex/responses
//   Authorization:    Bearer <access_token JWT>
//   chatgpt-account-id: <chatgpt_account_id from JWT claim>
//   originator:       nativeagent
//   OpenAI-Beta:      responses=experimental
//   Accept:           text/event-stream
//   Content-Type:     application/json
//
// account_id resolution (mirrors `_account_id()` at L751-L764):
//   1. tokens.account_id (if persisted by an earlier sign-in)
//   2. Decode tokens.access_token JWT payload, read the
//      `https://api.openai.com/auth` claim (an object), then read its
//      `chatgpt_account_id` field. THIS IS THE EXACT CLAIM the Python source
//      reads — see `_JWT_AUTH_CLAIM` constant + `_account_id` fallback path.
//
// Refresh (mirrors `_refresh_with_refresh_token` at L533-L558):
//   POST https://auth.openai.com/oauth/token
//   Content-Type: application/x-www-form-urlencoded
//   body = grant_type=refresh_token
//         &refresh_token=<refresh_token>
//         &client_id=app_EMoamEEZ73f0CkXaXp7hrann
//   NO scope param, NO redirect_uri — matches pi-ai's exact body shape per
//   the Python source comment. Response payload: {access_token, refresh_token,
//   id_token} — merge into auth.json::tokens and write atomically with 0600.
//
// SSE stream protocol (mirrors `chat_stream` at L951-L1099):
//   - Frames are `data: <json>\n\n`.
//   - `response.output_text.delta` carries token-level text in `.delta`.
//   - `response.completed` / `response.done` carries `.response.usage` and
//     terminates the stream.
//   - `response.failed` / `error` carry an error envelope to throw on.
//   - On HTTP 401 with attempt==0, force refresh and retry once (mirrors the
//     2-attempt loop). On second 401 raise the exhaustion error — the same
//     "oauth_direct_exhausted" signal the Python provider raises.
//
// What this adapter intentionally does NOT do:
//   - Does NOT implement the browser sign-in UI. NativeAgent.app owns OAuth
//     initiation/callback handling and persists token files; this adapter only
//     consumes/refreshes already-persisted ChatGPT OAuth tokens.
//   - Does NOT own provider policy decisions. It only exposes text deltas and
//     function-call events; ChatOrchestration still owns tool permission,
//     dispatch, persistence, and loop budgets.

/// Distinct error sentinel for the OAuth-exhaustion case (Python's
/// `oauth_direct_exhausted` RuntimeError at L1108-L1113). Surfaced as
/// `LLMError.underlying(message:)` with this stable string so callers can
/// distinguish "tokens need re-sign-in" from a generic
/// notConfigured/missing-credentials state.
/// Routing implication: SwiftNativeLLMClient surfaces OAuth-direct errors
/// directly instead of silently swapping to an API-key adapter.
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
        let result = await me.value
        switch result {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}

public final class OpenAIOAuthDirectAdapter: LLMAdapter {
    public let providerId: String = "openai_oauth_direct"

    public static let productionSession: URLSession = makeProductionSession()

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

    // MARK: - Public API

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    /// Returns a fresh Codex/ChatGPT OAuth token plus account id for non-chat
    /// Codex backend calls, such as the image_generation Responses tool.
    public func codexAccessContext(forceRefresh: Bool = false) async throws -> CodexOAuthAccessContext {
        let access = try await ensureFreshAccessToken(forceRefresh: forceRefresh)
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
        let coercedModel = Self.coerceToGPTModel(model)
        for attempt in 0...1 {
            try Task.checkCancellation()
            let access: String
            do {
                access = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
            } catch is CancellationError { throw CancellationError() }
            catch let err as LLMError { throw err }
            catch { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
            guard let accountID = currentAccountID() else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            req.setValue("nativeagent", forHTTPHeaderField: "originator")
            req.setValue("NativeAgent (Darwin; arm64)", forHTTPHeaderField: "User-Agent")
            req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
                if attempt == 0 { continue }
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
                    durationMs: durationMs
                )
                return s
            case .providerError(let m): throw LLMError.providerError(message: m)
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
        let coercedModel = Self.coerceToGPTModel(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for attempt in 0...1 {
                    do {
                        try Task.checkCancellation()
                        let access: String
                        do {
                            access = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
                        } catch is CancellationError { throw CancellationError() }
                        catch let err as LLMError { throw err }
                        catch { throw LLMError.notConfigured(provider: "openai_oauth_direct") }
                        guard let accountID = currentAccountID() else {
                            throw LLMError.notConfigured(provider: "openai_oauth_direct")
                        }

                        var req = URLRequest(url: endpoint)
                        req.httpMethod = "POST"
                        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                        req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
                        req.setValue("nativeagent", forHTTPHeaderField: "originator")
                        req.setValue("NativeAgent (Darwin; arm64)", forHTTPHeaderField: "User-Agent")
                        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401 {
                            if attempt == 0 { continue }
                            throw LLMError.authRejected(
                    provider: "openai_oauth_direct",
                    detail: OpenAIOAuthDirectExhaustedMarker
                )
                        }
                        if status == 429 {
                            let body = await Self.boundedBodyString(from: bytes)
                            throw LLMError.rateLimited(message: body.isEmpty ? "rate limited" : body, retryAfterSeconds: parseRetryAfterSeconds(from: response))
                        }
                        if (500..<600).contains(status) {
                            let body = await Self.boundedBodyString(from: bytes)
                            throw LLMError.transient(message: body.isEmpty ? "5xx" : body)
                        }
                        guard (200..<300).contains(status) else {
                            let body = await Self.boundedBodyString(from: bytes)
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

                        func stampTTFT() {
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
                                return false
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
                            } else if etype == "response.failed" {
                                let errObj = ((event["response"] as? [String: Any])?["error"] as? [String: Any]) ?? [:]
                                let msg = (errObj["message"] as? String) ?? "response failed"
                                throw LLMError.providerError(message: "chatgpt-backend response failed: \(msg)")
                            } else if etype == "error" {
                                let msg = (event["message"] as? String) ?? "unknown"
                                throw LLMError.providerError(message: "chatgpt-backend error: \(msg)")
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
                        for id in pendingOrder {
                            if let pending = pendingByItemId[id] {
                                yieldToolCall(
                                    id: pending.callId.isEmpty ? id : pending.callId,
                                    name: pending.name,
                                    args: pending.args
                                )
                            }
                        }
                        // U1 step 1: one llm.call row per successful stream.
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await self.telemetry.record(
                            provider: self.providerId,
                            model: coercedModel,
                            streaming: true,
                            usage: capturedUsage,
                            ttftMs: ttftMs,
                            durationMs: durationMs
                        )
                        continuation.finish()
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
    /// `instructions` carries the system prompt (same shape as buildResponsesBody).
    // internal (was private) so ProviderRoutingTests can pin the request body
    // shape (native-image content array) without a live network call.
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
                let role = m.role == .user ? "user" : "assistant"
                var content: [[String: Any]] = []
                for block in m.content {
                    switch block {
                    case .image(let mediaType, let base64, _, _):
                        content.append([
                            "type": "input_image",
                            "image_url": "data:\(mediaType);base64,\(base64)",
                        ])
                    case .text(let t):
                        let typeKey = m.role == .user ? "input_text" : "output_text"
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
                    let role = m.role == .user ? "user" : "assistant"
                    let typeKey = m.role == .user ? "input_text" : "output_text"
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
        let coercedModel = Self.coerceToGPTModel(model)
        for attempt in 0...1 {
            try Task.checkCancellation()
            let access: String
            do {
                access = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LLMError {
                // notConfigured surfaces clean (no tokens, refresh failed
                // with no-creds path, etc).
                throw err
            } catch {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }
            guard let accountID = currentAccountID() else {
                throw LLMError.notConfigured(provider: "openai_oauth_direct")
            }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            req.setValue("nativeagent", forHTTPHeaderField: "originator")
            req.setValue("NativeAgent (Darwin; arm64)", forHTTPHeaderField: "User-Agent")
            req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
                    durationMs: durationMs
                )
                return s
            case .providerError(let m):
                throw LLMError.providerError(message: m)
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
    ) async -> String {
        var collected: [UInt8] = []
        collected.reserveCapacity(min(maxBytes, 512))
        var truncated = false
        do {
            for try await byte in bytes {
                if collected.count < maxBytes {
                    collected.append(byte)
                } else {
                    truncated = true
                    break
                }
            }
        } catch {
            if collected.isEmpty { return "" }
        }
        var text = String(decoding: collected, as: UTF8.self)
        if truncated { text += "\n...(truncated)" }
        return text
    }

    /// Coerce a model id to a GPT id for the chatgpt.com backend. Mirrors
    /// Python's `_coerce_to_gpt_model` at L171-L177 narrowed for Swift:
    /// strip the `openai/` namespace prefix; pass `gpt-*` through; otherwise
    /// return the default. The Python version also remaps Claude model ids
    /// to GPT defaults for defensive misrouting from the chat UI — we keep
    /// that behavior here so Anthropic ids that accidentally land on this
    /// adapter don't 404.
    static func coerceToGPTModel(_ requested: String?) -> String {
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
        let normalized = SwiftNativeProviderRouting.normalizeModelIdStatic(
            stripped,
            fallback: defaultGPT
        )
        if normalized.lowercased().hasPrefix("gpt-") {
            return normalized
        }
        // Defensive Claude-id remap (Python L136-L143). Opus tier maps to the
        // primary; sonnet/haiku tiers map to their respective sub-tier GPT
        // ids (those are distinct from the primary and stay as literals).
        let claudeToGPT: [String: String] = [
            "claude-fable-5":     nativeAgentPrimaryModel,
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
        return defaultGPT
    }

    // MARK: - SSE parser (responses-API)

    /// Result of SSE parsing: either accumulated text or a mid-stream
    /// provider error frame the caller should throw on.
    enum SSEParseResult {
        case text(String)
        case providerError(String)
    }

    /// Parse result + provider usage (U1 step 1). `usage` is non-nil when a
    /// `response.completed`/`response.done` frame carried a usage object.
    struct SSEParsed {
        let result: SSEParseResult
        let usage: LLMUsage?
    }

    /// Back-compat shim — existing callers/tests that only need the text.
    static func parseResponsesSSE(from data: Data) -> SSEParseResult {
        parseResponsesSSEDetailed(from: data).result
    }

    /// Parse a buffer of SSE bytes containing `response.output_text.delta`
    /// events and concatenate the `.delta` text fields in stream order.
    /// Mirrors the Python `chat_stream` accumulator at L1008-L1012 +
    /// `response.failed`/`error` handling at L1058-L1063. Ignores frames
    /// the adapter doesn't currently surface (reasoning, ping, etc). Also
    /// captures `response.usage` from the terminal `response.completed`
    /// frame (input/output tokens + input_tokens_details.cached_tokens).
    static func parseResponsesSSEDetailed(from data: Data) -> SSEParsed {
        var capturedUsage: LLMUsage?
        var deltas: [String] = []
        // HOTFIX 2026-06-03 tool-wire: accumulate function_call items so they
        // can be emitted as `<tool_use name="X">{args}</tool_use>` markers at
        // the end of the response, in stream order with text. Without this,
        // function_call events were being silently dropped at the catch-all
        // `else` below and ToolCallParser had nothing to parse.
        struct PendingCall { var name: String; var args: String }
        var pendingByItemId: [String: PendingCall] = [:]
        var pendingOrder: [String] = []
        var toolMarkers: [String] = []
        // Shared payload processor for in-loop frames AND the trailing
        // unterminated buffer (review nit 2026-06-10: the trailing drain
        // previously only handled text deltas, so a final response.completed
        // frame without a blank-line terminator dropped its usage object).
        // Returns true to stop parsing; a provider-error frame is surfaced
        // via `failure`.
        var failure: SSEParsed?
        func processPayload(_ payloadStr: String) -> Bool {
            if payloadStr == "[DONE]" { return true }
            guard let pdata = payloadStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any] else {
                return false
            }
            let etype = event["type"] as? String ?? ""
            if etype == "response.output_text.delta" {
                if let d = event["delta"] as? String, !d.isEmpty {
                    deltas.append(d)
                }
            } else if etype == "response.output_item.added" {
                // New output item — if it's a function_call, register it.
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    let name = (item["name"] as? String) ?? ""
                    let args = (item["arguments"] as? String) ?? ""
                    pendingByItemId[id] = PendingCall(name: name, args: args)
                    pendingOrder.append(id)
                }
            } else if etype == "response.function_call_arguments.delta" {
                // Streamed args chunks.
                if let id = event["item_id"] as? String,
                   let d = event["delta"] as? String,
                   pendingByItemId[id] != nil {
                    pendingByItemId[id]!.args.append(d)
                }
            } else if etype == "response.output_item.done" {
                // Finalize: emit <tool_use> marker now. Fold name/args
                // from item if present (some streams omit deltas).
                if let item = event["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call",
                   let id = item["id"] as? String {
                    var name = pendingByItemId[id]?.name ?? ""
                    var args = pendingByItemId[id]?.args ?? ""
                    if name.isEmpty, let n = item["name"] as? String { name = n }
                    if args.isEmpty, let a = item["arguments"] as? String { args = a }
                    let body = args.isEmpty ? "{}" : args
                    // Pull the provider-issued call_id (function_call
                    // items carry both an item id and a call_id; the
                    // call_id is what subsequent function_call_output
                    // items reference). Fall back to item.id when
                    // call_id is missing so the marker always carries
                    // *some* id.
                    let callId = (item["call_id"] as? String) ?? id
                    toolMarkers.append("<tool_use id=\"\(callId)\" name=\"\(name)\">\(body)</tool_use>")
                    pendingByItemId.removeValue(forKey: id)
                }
            } else if etype == "response.completed" || etype == "response.done" {
                // U1 step 1: usage rides on the terminal frame.
                let respObj = event["response"] as? [String: Any]
                if let usageObj = respObj?["usage"] as? [String: Any] {
                    capturedUsage = LLMUsage.fromOpenAIResponses(usageObj)
                }
                return true
            } else if etype == "response.failed" {
                // Mirrors Python L1058-L1061: extract response.error.message.
                let errObj = ((event["response"] as? [String: Any])?["error"] as? [String: Any]) ?? [:]
                let msg = (errObj["message"] as? String) ?? "response failed"
                failure = SSEParsed(
                    result: .providerError("chatgpt-backend response failed: \(msg)"),
                    usage: nil
                )
                return true
            } else if etype == "error" {
                let msg = (event["message"] as? String) ?? "unknown"
                failure = SSEParsed(
                    result: .providerError("chatgpt-backend error: \(msg)"),
                    usage: nil
                )
                return true
            }
            // Other event types (reasoning, ping) are ignored.
            return false
        }

        // R15: SSEEventParser owns framing, including the EOF flush of a
        // trailing unterminated event — so a trailing response.completed
        // keeps its usage and a trailing item.done still emits its marker
        // BEFORE the defensive pending flush below (no double-emit). The
        // old splitter treated a bare CR as its own terminator, which
        // flushed a phantom blank line inside CRLF streams and split
        // multi-line payloads (audit-#14 shape, buffered path) — fixed by
        // the shared parser.
        for sse in SSEEventParser.parse(data: data) {
            if processPayload(sse.data) {
                if let failure { return failure }
                break
            }
        }
        // Flush any pending calls that never got a `done` event (defensive).
        for id in pendingOrder {
            if let c = pendingByItemId[id] {
                let body = c.args.isEmpty ? "{}" : c.args
                // Defensive flush (no item.done was seen): pendingByItemId
                // is keyed by item_id; if we never got a call_id from a
                // matching `output_item.added` event, fall back to item_id
                // as the marker id so the round-trip still has SOMETHING
                // unique to echo back as the tool_result's tool_use_id.
                toolMarkers.append("<tool_use id=\"\(id)\" name=\"\(c.name)\">\(body)</tool_use>")
            }
        }
        // Combine text + tool markers. Order: text first, then tool markers
        // (since OpenAI Responses streams text deltas before function_call
        // items in our observed traces — putting markers after lets
        // ToolCallParser see them at the end of the response). Empty text +
        // tool markers is a tool-call-only response, which the parser handles.
        let textPart = deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if toolMarkers.isEmpty {
            return SSEParsed(result: .text(textPart), usage: capturedUsage)
        }
        if textPart.isEmpty {
            return SSEParsed(
                result: .text(toolMarkers.joined(separator: "\n")),
                usage: capturedUsage
            )
        }
        return SSEParsed(
            result: .text(textPart + "\n" + toolMarkers.joined(separator: "\n")),
            usage: capturedUsage
        )
    }

    /// Legacy text-only shim — used by tests that only care about the
    /// happy-path text accumulation.
    static func collectResponsesSSE(from data: Data) -> String {
        if case .text(let s) = parseResponsesSSE(from: data) { return s }
        return ""
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

    // MARK: - Token storage + JWT decode

    /// Resolve the auth.json path. Mirrors `_codex_auth_path` at L340-L353.
    /// IMPORTANT: cwd is unreliable when running inside the macOS app bundle
    /// (Sparkle / launchd execve sets cwd to "/" or the bundle's Resources).
    /// We check `data/codex_home/auth.json` under cwd ONLY for repo dev
    /// usage; production resolution falls through to the App Support path,
    /// which mirrors where the real daemon writes (gpt-5.5 review BLOCKING).
    ///   1. `authPathOverride` (test injection)
    ///   2. `CODEX_HOME` env var (explicit override)
    ///   3. `NATIVE_AGENT_DATA_ROOT` env var
    ///   4. cwd `data/codex_home/auth.json` IFF cwd looks like a repo
    ///      (i.e. the file actually exists with non-empty tokens) — this
    ///      prevents a cwd of "/" from claiming `/data/...`
    ///   5. `~/Library/Application Support/NativeAgent/codex_home/auth.json`
    ///      (canonical production path)
    ///   6. `~/.codex/auth.json` (shared Codex CLI auth, legacy/working path)
    func resolveAuthPath() -> URL {
        if let override = authPathOverride { return override }
        return Self.preferredAuthPath()
    }

    /// Candidate ChatGPT OAuth auth.json paths in the same order the runtime
    /// should trust them. This is public so the Mac app's provider picker and
    /// OAuth badge can use the exact same discovery as chat execution.
    public static func authPathCandidates(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportRoot: URL = libraryAppSupportFallback(),
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true
    ) -> [URL] {
        if !allowSharedFallbacks, let dataRoot {
            return [dataRoot.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")]
        }
        var candidates: [URL] = []
        var seen: Set<String> = []
        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized.path) else { return }
            seen.insert(standardized.path)
            candidates.append(standardized)
        }

        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            append(URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json"))
        }
        if let dataRoot = environment["NATIVE_AGENT_DATA_ROOT"], !dataRoot.isEmpty {
            append(URL(fileURLWithPath: (dataRoot as NSString).expandingTildeInPath)
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json"))
        }
        let cwd = URL(fileURLWithPath: currentDirectoryPath)
        let repoAuth = cwd
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        append(repoAuth)
        let appSupport = appSupportRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
        append(appSupport)
        append(userCodexHome.appendingPathComponent("auth.json"))
        if let dataRoot {
            append(dataRoot
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json"))
        }
        let defaultRoot = PersistenceCore.defaultDataRoot()
        append(defaultRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json"))
        return candidates
    }

    /// Preferred auth path for chat execution. Uses the first candidate with
    /// usable tokens; when none exist, returns the first writable candidate.
    public static func preferredAuthPath(
        dataRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        appSupportRoot: URL = libraryAppSupportFallback(),
        userCodexHome: URL = defaultUserCodexHome(),
        allowSharedFallbacks: Bool = true
    ) -> URL {
        if !allowSharedFallbacks, let dataRoot {
            return dataRoot.standardizedFileURL
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
                .appendingPathComponent("auth.json")
        }
        if let dataRoot = environment["NATIVE_AGENT_DATA_ROOT"], !dataRoot.isEmpty {
            return URL(fileURLWithPath: (dataRoot as NSString).expandingTildeInPath)
                .appendingPathComponent("codex_home", isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        let candidates = authPathCandidates(
            dataRoot: dataRoot,
            environment: environment,
            currentDirectoryPath: currentDirectoryPath,
            appSupportRoot: appSupportRoot,
            userCodexHome: userCodexHome,
            allowSharedFallbacks: allowSharedFallbacks
        )
        // Only honor the repo path when the FILE exists AND it carries real
        // tokens. Mere presence of `data/` (or worse, root-relative `/data/`)
        // shouldn't shadow the app-support candidate.
        for candidate in candidates where Self.hasUsableTokens(at: candidate) {
            return candidate
        }
        return appSupportRoot
            .appendingPathComponent("codex_home", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    /// True iff the file at `url` parses and has a non-empty
    /// tokens.access_token. Used by `resolveAuthPath` to decide between the
    /// repo dev path and the production AppSupport path.
    public static func hasUsableTokens(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else {
            return false
        }
        return true
    }

    public static func defaultUserCodexHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Load the auth blob from disk. Returns `nil` when the file is missing
    /// or unparseable — mirroring Python's `_load_codex_auth` which returns
    /// `{}` in both cases. We use `nil` here so the "needs OAuth" path is a
    /// clean `.notConfigured` throw at the caller.
    func loadAuthBlob() -> [String: Any]? {
        let path = resolveAuthPath()
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Save the auth blob atomically with 0600 permissions. Mirrors
    /// `_save_codex_auth` at L366-L372.
    func saveAuthBlob(_ blob: [String: Any]) throws {
        let path = resolveAuthPath()
        let data = try JSONSerialization.data(
            withJSONObject: blob,
            options: [.prettyPrinted, .sortedKeys]
        )
        try Self.writeAuthBytesAtomically(data, to: path)
    }

    /// Sendable-safe atomic writer used both by `saveAuthBlob` and the
    /// flock-guarded refresh path (so the closure captures only `Data`/`URL`).
    static func writeAuthBytesAtomically(_ data: Data, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Atomic write via a sibling tempfile + rename — same pattern as
        // Python's `atomic_write_text` (which the provider also uses).
        let tmp = parent.appendingPathComponent(
            ".\(path.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
        )
        try data.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try? FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Decode the (unverified) payload of a JWT. Mirrors `_jwt_payload`
    /// at L375-L385. We only use this to read claims for account_id + exp —
    /// the JWT is still server-side validated on every API call.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
        // base64url -> base64
        b64 = b64.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        let pad = b64.count % 4
        if pad != 0 { b64.append(String(repeating: "=", count: 4 - pad)) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Read a persisted `expires_at` from the auth blob. Looks at both
    /// the top level (where some flows write) and `tokens.expires_at`
    /// (where others write). Accepts ISO basic / ISO with fractional / or
    /// numeric (seconds-from-epoch). Returns nil if absent or unparseable.
    static func persistedExpiresAt(blob: [String: Any], tokens: [String: Any]) -> Int? {
        let raw: Any? = blob["expires_at"] ?? tokens["expires_at"]
        guard let raw = raw else { return nil }
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if let unix = TimeInterval(s) { return Int(unix) }
        let basic = DateFormatter()
        basic.calendar = Calendar(identifier: .iso8601)
        basic.locale = Locale(identifier: "en_US_POSIX")
        basic.timeZone = TimeZone(secondsFromGMT: 0)
        basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        if let d = basic.date(from: s) { return Int(d.timeIntervalSince1970) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
        return nil
    }

    /// Read `exp` claim from a JWT payload. Returns nil when missing.
    static func tokenExpiresAt(_ token: String) -> Int? {
        guard let payload = jwtPayload(token) else { return nil }
        if let exp = payload["exp"] as? Int { return exp }
        if let exp = payload["exp"] as? Double { return Int(exp) }
        return nil
    }

    /// Extract chatgpt_account_id from a JWT payload's
    /// `https://api.openai.com/auth` claim. Mirrors the lookup chain in
    /// `_account_id()` at L751-L764 + the persistence path at L678-L684.
    static func extractAccountIDFromJWT(_ token: String) -> String? {
        guard let payload = jwtPayload(token) else { return nil }
        guard let authClaim = payload["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return authClaim["chatgpt_account_id"] as? String
    }

    /// account_id resolution. Mirrors `_account_id()` exactly — checks the
    /// persisted `tokens.account_id` first, then falls back to extracting
    /// from the JWT.
    func currentAccountID() -> String? {
        guard let blob = loadAuthBlob() else { return nil }
        let tokens = (blob["tokens"] as? [String: Any]) ?? [:]
        if let acct = tokens["account_id"] as? String, !acct.isEmpty {
            return acct
        }
        if let access = tokens["access_token"] as? String, !access.isEmpty {
            return Self.extractAccountIDFromJWT(access)
        }
        return nil
    }

    // MARK: - Token refresh

    private static let tokenExpiryBufferSec: Int = 120

    /// Return a non-expired access token. Force-refresh when `forceRefresh`
    /// is true (used on retry after HTTP 401). Mirrors
    /// `_ensure_fresh_access_token` at L496-L531 — including the
    /// lock-protected re-read inside the critical section so a concurrent
    /// caller that already rotated the token doesn't trigger a second
    /// refresh that would burn the single-use refresh_token.
    func ensureFreshAccessToken(forceRefresh: Bool = false) async throws -> String {
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
        guard let blob = loadAuthBlob(),
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
            if status == 429 || (500..<600).contains(status) {
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
        do {
            let path = resolveAuthPath()
            // Serialize the blob to bytes outside the @Sendable closure so we
            // don't capture a non-Sendable [String: Any] across the boundary.
            let bytes = try JSONSerialization.data(
                withJSONObject: newBlob,
                options: [.prettyPrinted, .sortedKeys]
            )
            try await SwiftNativePersistenceCore().withFileLock(path) {
                try Self.writeAuthBytesAtomically(bytes, to: path)
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
        guard let newAccess = merged["access_token"] as? String, !newAccess.isEmpty else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return newAccess
    }
}
