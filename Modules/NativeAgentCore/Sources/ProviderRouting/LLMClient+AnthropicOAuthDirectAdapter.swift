import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - AnthropicOAuthDirectAdapter
//
// Anthropic Messages transport with bearer credentials from
// anthropic_oauth_direct.json. Requests use the Claude Code identity and
// version headers required by the OAuth endpoint.
//
// Tokens refresh within 120 seconds of expiry and rotated credentials are
// persisted. A path-keyed AsyncSerialQueue serializes refresh across adapter
// instances because a refresh token is single-use. The credential lock also
// coordinates refresh with settings saves and sign-out.
//
// Request encoding and cache-marker placement live in
// LLMClient+AnthropicOAuthRequestBody.swift.

public final class AnthropicOAuthDirectAdapter: LLMAdapter {
    public let providerId: String = "anthropic_oauth_direct"

    public static let productionSession: URLSession = makeProductionSession()

    private let session: URLSession
    private let endpoint: URL
    private let refreshEndpoint: URL
    /// Test-injection override for the auth.json path. Production callers
    /// leave this nil and the resolver below walks the canonical layout.
    private let authPathOverride: URL?
    private let maxTokensOverride: Int?
    private let clientID: String
    /// U1 step 1 — per-call llm.call telemetry writer. Additive; the
    /// override is test-only (points the trace feed at a tmp data root).
    private let telemetry: LLMCallTraceRecorder

    public init(
        session: URLSession = AnthropicOAuthDirectAdapter.productionSession,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        refreshEndpoint: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        authPathOverride: URL? = nil,
        maxTokens: Int? = nil,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.authPathOverride = authPathOverride
        self.maxTokensOverride = maxTokens
        self.clientID = clientID
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    func requestMaxTokens(model: String) -> Int {
        FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: LLMCallContext.reasoningEffort,
            explicitOverride: maxTokensOverride
        )
    }

    // MARK: - Constants

    private static let anthropicVersion = "2023-06-01"
    private static let oauthBetaFeatures = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
    ]
    /// Rides ONLY on requests that actually carry a `clear_at` message.
    static let midConversationSystemClearAtBeta =
        "mid-conversation-system-clear-at-2026-08-21"

    /// ONE beta-assembly rule for every Anthropic transport (OAuth headers
    /// below, and both api-key lanes, which otherwise send no
    /// `anthropic-beta` header at all): the clear_at beta is present IFF a
    /// message in THIS request carries the flag. A lane that emitted
    /// `clear_at` in the body without this header would 400.
    static func clearAtBeta(for messages: [LLMMessage]) -> String? {
        messages.contains { $0.turnScopedClearAtNextUserMessage }
            ? midConversationSystemClearAtBeta
            : nil
    }

    /// Rides ONLY on requests that actually carry a `tool_addition` /
    /// `tool_removal` block.
    static let midConversationToolChangesBeta =
        "mid-conversation-tool-changes-2026-07-01"

    /// Same rule as `clearAtBeta`, for the tool-change blocks: present IFF a
    /// message in THIS request carries one. A body with tool-change blocks and
    /// no header is a 400; a header with no blocks would opt every ordinary
    /// request into a beta it does not use.
    static func toolChangeBeta(for messages: [LLMMessage]) -> String? {
        messages.contains { !$0.toolChanges.isEmpty }
            ? midConversationToolChangesBeta
            : nil
    }

    /// The full comma-joined `anthropic-beta` value the MID-CONVERSATION
    /// features need for this request, or nil when it needs none. One
    /// assembly rule for every Anthropic transport: both api-key lanes send
    /// this header ONLY when it is non-nil, so a request that uses neither
    /// feature stays byte-identical to the pre-2026-09 wire.
    static func midConversationBetas(for messages: [LLMMessage]) -> String? {
        let betas = [clearAtBeta(for: messages), toolChangeBeta(for: messages)]
            .compactMap { $0 }
        return betas.isEmpty ? nil : betas.joined(separator: ",")
    }
    // Anthropic gates newer models (Fable 5.1: "version 2.1.251 or newer is
    // required", error_code claude_code_version_too_old) on this version. Keep it
    // at the Claude Code release actually installed on this Mac.
    private static let claudeCLIVersion = "2.1.257"
    private static let defaultClaudeModel = "claude-opus-4-8"
    /// Refresh proactively when the token has less than this many seconds
    /// of life left. Mirrors OpenAI adapter's 120s buffer.
    static let tokenExpiryBufferSec: TimeInterval = 120

    static func makeProductionSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeoutValue(
            environment["NATIVE_AGENT_ANTHROPIC_OAUTH_REQUEST_TIMEOUT_SEC"],
            fallback: 240
        )
        cfg.timeoutIntervalForResource = timeoutValue(
            environment["NATIVE_AGENT_ANTHROPIC_OAUTH_RESOURCE_TIMEOUT_SEC"],
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

    /// Per-request header assembly. The STATIC beta list is unchanged; the
    /// mid-conversation-system clear_at beta is added ONLY when a message in
    /// THIS request actually carries the flag, so every existing request stays
    /// byte-identical on the wire.
    ///
    /// `model` is accepted so the call site reads as a per-request tuple and a
    /// future model-conditional beta has a home. The capability gate itself
    /// (`supportsMidConversationSystemClearAt`) is enforced UPSTREAM, where the
    /// flag is set: an adapter that silently dropped the beta while the body
    /// still carried `clear_at` would turn a builder bug into a 400.
    static func apiHeaders(
        accessToken: String,
        model: String? = nil,
        messages: [LLMMessage] = []
    ) -> [String: String] {
        var betas = oauthBetaFeatures
        if let midConversation = midConversationBetas(for: messages) {
            betas.append(midConversation)
        }
        return [
            "Authorization":      "Bearer \(accessToken)",
            "anthropic-version":  anthropicVersion,
            "anthropic-beta":     betas.joined(separator: ","),
            "x-app":              "cli",
            "user-agent":         "claude-cli/\(claudeCLIVersion)",
            "anthropic-dangerous-direct-browser-access": "true",
            "Accept":             "application/json",
            "Content-Type":       "application/json",
        ]
    }

    private static func validateCompletionResponse(status: Int, data: Data, response: URLResponse) throws {
        try throwIfChatCompletionsError(
            status: status,
            data: data,
            mapping: ChatCompletionsStatusMapping(
                provider: "anthropic_oauth_direct",
                rateLimited: { String(data: $0, encoding: .utf8) ?? "rate limited" },
                serverError: { String(data: $0, encoding: .utf8) ?? "5xx" },
                otherwise: { httpError(status: $0, data: $1, context: "anthropic oauth") }
            ),
            response: response
        )
    }

    /// Streaming rejects rate limits before reading the body; other failures retain
    /// the bounded drain and OAuth-specific mapping rather than the buffered 5xx rule.
    private static func validateStreamResponse(
        status: Int, bytes: URLSession.AsyncBytes, response: URLResponse
    ) async throws {
        if status == 429 {
            throw LLMError.rateLimited(
                message: "rate limited",
                retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if !(200..<300).contains(status) {
            let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
            if status == 401 {
                throw LLMError.authRejected(
                    provider: "anthropic_oauth_direct", detail: providerErrorDetail(body))
            }
            throw Self.httpError(status: status, data: body, context: "anthropic oauth")
        }
    }

    private static func httpError(status: Int, data: Data, context: String) -> LLMError {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return .invalidResponse(status: status) }
        if let usageNotice = providerUsageNotice(raw) {
            return .providerError(message: usageNotice)
        }
        return .underlying(message: "\(context) status \(status): \(redactedErrorBody(raw))")
    }

    private static func providerUsageNotice(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("out of extra usage")
            || lower.contains("usage is exhausted")
            || lower.contains("usage exhausted")
            || lower.contains("quota exceeded")
        {
            return "Anthropic OAuth usage is exhausted. Add more at claude.ai/settings/usage or switch providers."
        }
        return nil
    }

    private static func redactedErrorBody(_ raw: String) -> String {
        var out = raw
        if let re = try? NSRegularExpression(
            pattern: #"(?i)"(access_token|refresh_token|setup_token|authorization|api_key|token)"\s*:\s*"[^"]+""#
        ) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "\"$1\":\"***\"")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*"#) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "Bearer ***")
        }
        if out.count > 1200 {
            return String(out.prefix(1200)) + "... [truncated]"
        }
        return out
    }

    /// Turn Inspector W2 — fire a `thinking.delta` event onto the in-process
    /// bus (fire-and-forget, drop-on-backpressure, NEVER awaited). Carries the
    /// SUMMARIZED thinking text, SECRET-REDACTED by the shared non-digest
    /// TurnTraceRedactor, then bounded by
    /// the event's own per-leaf cap. `redacted:true` marks a RedactedThinking
    /// block rendered honestly as "[redacted]" (never decoded). Skipped when no
    /// turn is bound. The bus reads surface/sessionId from the ambient
    /// LLMCallContext (bound upstream by the chat engine), so no surface param
    /// is threaded here. signature_delta frames are never surfaced.
    ///
    /// GATED on `InspectorThinkingLane.summarizedThinking` (gpt-5.5 W2 review):
    /// only a request that opted into the lane asked for thinking, so a frame
    /// arriving while the lane is OFF — provider quirk, stub, or future default
    /// change — must NOT put thinking text on the bus the user never opted into.
    static func fireThinkingDeltaEvent(_ text: String, redacted: Bool) {
        guard InspectorThinkingLane.summarizedThinking else { return }
        guard TurnTraceContext.turnId != nil else { return }
        let safe = redacted ? text : TurnTraceRedactor.redactText(text)
        TurnTraceBus.fireFromContext(
            kind: "thinking.delta",
            payload: .object([
                "text": .string(safe),
                "redacted": .bool(redacted),
            ])
        )
    }

    private func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        let host = endpoint.host ?? "api.anthropic.com"
        let nsError = error as NSError
        let timeout = Int(session.configuration.timeoutIntervalForRequest.rounded())
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut:
                return .transient(message: "anthropic_oauth_direct \(operation) timed out after \(timeout)s: \(host)")
            case .cannotConnectToHost:
                return .transient(message: "anthropic_oauth_direct \(operation) cannot connect to \(host) (code=\(nsError.code))")
            case .networkConnectionLost:
                return .transient(message: "anthropic_oauth_direct \(operation) network connection was lost: \(host) (code=\(nsError.code))")
            case .notConnectedToInternet:
                return .transient(message: "anthropic_oauth_direct \(operation) not connected to internet: \(host) (code=\(nsError.code))")
            case .cannotFindHost, .dnsLookupFailed:
                return .transient(message: "anthropic_oauth_direct \(operation) cannot resolve \(host) (code=\(nsError.code))")
            default:
                return .transient(message: "anthropic_oauth_direct \(operation) network error for \(host): \(error) (code=\(nsError.code))")
            }
        }
        return .transient(message: "anthropic_oauth_direct \(operation) network error for \(host): \(error)")
    }

    // MARK: - Shared refresh-actor registry
    //
    // Production has 4+ callsites constructing fresh adapter instances. A
    // PER-INSTANCE actor would let two instances refresh in parallel and
    // rotate the single-use refresh_token twice — the second rotation
    // burns the credential. Share one AsyncSerialQueue per resolved auth
    // file path across the process.

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

    // MARK: - Model coercion

    /// Coerce a requested model id onto the Claude wire id this adapter can
    /// actually serve.
    ///
    /// NORTHSTAR clause 2 (fail loud, no silent substitution): the ONLY
    /// rewrites are enumerated ones — an absent/empty request takes the
    /// adapter default, and an `anthropic/claude-*` namespaced id has its
    /// namespace stripped. Anything else (`llama-3`, `deepseek-chat`, `o3`,
    /// a bare `gpt-*` misrouted onto this adapter) used to fall through to
    /// `defaultClaudeModel`, so User's pick was silently replaced by
    /// claude-opus-4-8 and the call was billed against a model he never
    /// chose. It now throws `modelUnavailable` naming the offending id.
    static func coerceToClaudeModel(_ requested: String?) throws -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return defaultClaudeModel
        }
        let lower = r.lowercased()
        if lower.hasPrefix("claude-") { return r }
        if lower.hasPrefix("anthropic/") {
            let suffix = String(r.dropFirst("anthropic/".count))
            if suffix.lowercased().hasPrefix("claude-") { return suffix }
        }
        throw LLMError.modelUnavailable(provider: "anthropic_oauth_direct", model: r)
    }

    /// The requested id when an enumerated remap actually rewrote it, else
    /// nil. Threaded onto the `llm.call` telemetry row as `substitutedFrom`
    /// so a surviving remap leaves a trace instead of being invisible.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
    }

    // MARK: - LLMAdapter conformance

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    /// Structured multi-turn variant. Encodes the LLMMessage array into
    /// Anthropic Messages-API content blocks (text / tool_use / tool_result)
    /// so the model sees its prior tool calls AND their results in the
    /// canonical wire shape. Without this the tool loop never converges —
    /// see the conversation-shape comment on LLMMessage in LLMClient.swift.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let coercedModel = try Self.coerceToClaudeModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(
                    forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
                lastSentAccessToken = accessToken
            } catch is CancellationError { throw CancellationError() }
            catch let err as LLMError { throw err }
            catch { throw LLMError.notConfigured(provider: "anthropic_oauth_direct") }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(
                accessToken: accessToken, model: coercedModel, messages: messages
            ) {
                req.setValue(v, forHTTPHeaderField: k)
            }

            // Body shape (breakpoint layout, lever behavior, encoding) lives
            // in the shared builder — one encoder for the non-streaming and
            // SSE messages transports (U1 item 9).
            let body = Self.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: coercedModel,
                maxTokens: requestMaxTokens(model: coercedModel),
                tools: tools,
                stream: false
            )
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }
            Self.dumpBodyIfEnabled(body, call: "completeMessages")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "completeMessages"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            try Self.validateCompletionResponse(status: status, data: data, response: response)
            let (obj, pieces) = try completionPieces(data: data, status: status)
            // U1 step 1: capture provider usage (incl. cache counters) into
            // the llm.call trace feed. Non-fatal; numbers only. Recorded
            // AFTER the pieces validation so a 200 with unsupported/empty
            // content throws WITHOUT leaving a misleading "ok" row
            // (gpt-5.5 review blocker, 2026-06-10).
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: coercedModel,
                streaming: false,
                usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: durationMs,
                substitutedFrom: substitutedFrom,
                cacheMarkers: Self.cacheMarkers(in: body)
            )
            return pieces.joined(separator: "\n")
        }
        throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let coercedModel = try Self.coerceToClaudeModel(model)
        let substitutedFrom = Self.substitutionTrace(requested: model, coerced: coercedModel)
        // Two-attempt loop mirrors the OpenAI adapter: refresh inline on a
        // 401 once. Avoids the wave-27 double-rotate bug by NOT also
        // refreshing inline on the first 401 — just loops with
        // forceRefresh=true on the second pass.
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken: String
            do {
                accessToken = try await ensureFreshAccessToken(
                    forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
                lastSentAccessToken = accessToken
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as LLMError {
                throw err
            } catch {
                throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
            }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }

            // toolCapable mirrors makeToolList's non-empty rule so the
            // dynamic-end breakpoint appears exactly when a tools block does.
            let systemBlocks = Self.makeSystemBlocks(
                system, toolCapable: !(tools?.isEmpty ?? true)
            )
            var body: [String: Any] = [
                "model": coercedModel,
                "max_tokens": requestMaxTokens(model: coercedModel),
                "messages": [["role": "user", "content": prompt]],
                "system": systemBlocks,
            ]
            // Anthropic Messages-API tools field. Only add when non-empty so a
            // nil/empty tools arg produces a byte-identical request body to
            // the no-tools path.
            if let toolList = Self.makeToolList(tools) {
                body["tools"] = toolList
            }
            FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel)
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw LLMError.underlying(message: "encode body: \(error)")
            }
            Self.dumpBodyIfEnabled(body, call: "complete")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "complete"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            try Self.validateCompletionResponse(status: status, data: data, response: response)
            let (obj, pieces) = try completionPieces(data: data, status: status)
            // U1 step 1: token/cache usage telemetry. Recorded AFTER the
            // pieces validation so a 200 with unsupported/empty content
            // throws WITHOUT leaving a misleading "ok" row (gpt-5.5 review
            // blocker, 2026-06-10).
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: coercedModel,
                streaming: false,
                usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: durationMs,
                substitutedFrom: substitutedFrom,
                cacheMarkers: Self.cacheMarkers(in: body)
            )
            return pieces.joined(separator: "\n")
        }
        throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
    }

    /// Preserve response order and tool markers before recording successful usage.
    private func completionPieces(data: Data, status: Int) throws -> ([String: Any], [String]) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse(status: status)
        }
        // Walk content blocks: text → append; tool_use → emit
        // `<tool_use id="..." name="...">{json}</tool_use>` markers the
        // ToolCallParser understands. ID is now included so the tool
        // loop can pair the result back to the call.
        var pieces: [String] = []
        for block in content {
            guard let btype = block["type"] as? String else { continue }
            if btype == "text", let t = block["text"] as? String {
                pieces.append(t)
            } else if btype == "tool_use" {
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? ""
                let input = block["input"] ?? [String: Any]()
                let bodyData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? "{}"
                pieces.append("<tool_use id=\"\(id)\" name=\"\(name)\">\(bodyStr)</tool_use>")
            }
        }
        if pieces.isEmpty {
            throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                providerID: providerId,
                stopReason: obj["stop_reason"] as? String,
                expectedOutput: "answer text or tool call"
            )
        }
        return (obj, pieces)
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Coerce INSIDE the stream task: this is a non-throwing
                    // factory, so an unserviceable model id has to reach the
                    // caller as a thrown continuation finish rather than as a
                    // silently defaulted model (NORTHSTAR clause 2).
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStream(
                        prompt: prompt,
                        system: system,
                        model: coercedModel,
                        substitutedFrom: Self.substitutionTrace(
                            requested: model,
                            coerced: coercedModel
                        ),
                        continuation: continuation
                    )
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        prompt: String,
        system: String?,
        model: String,
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
            lastSentAccessToken = accessToken

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(accessToken: accessToken) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let systemBlocks = Self.makeSystemBlocks(system)
            var body: [String: Any] = [
                "model": model,
                "max_tokens": requestMaxTokens(model: model),
                "stream": true,
                "messages": [["role": "user", "content": prompt]],
                "system": systemBlocks,
            ]
            FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            Self.dumpBodyIfEnabled(body, call: "runStream")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "stream"))
            }
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            try await Self.validateStreamResponse(status: status, bytes: bytes, response: response)

            // U1 step 1 — streaming telemetry. Anthropic splits usage across
            // message_start (input + cache counters) and message_delta
            // (output_tokens); TTFT is stamped at the FIRST yielded text
            // delta; the row is recorded on message_stop.
            var usage = LLMUsage()
            var ttftMs: Int?
            var yieldedAnyText = false
            var lastStopReason: String?
            // R15: SSEEventStream owns framing; protocol semantics stay here.
            for try await sse in SSEEventStream(bytes) {
                try Task.checkCancellation()
                let payload = sse.data
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let payloadType = obj["type"] as? String ?? ""
                let eventName = sse.event ?? ""
                let effectiveEvent = eventName.isEmpty ? payloadType : eventName
                switch effectiveEvent {
                case "error":
                    let errObj = obj["error"] as? [String: Any]
                    let message = (errObj?["message"] as? String)
                        ?? (errObj?["type"] as? String)
                        ?? "unknown error"
                    throw LLMError.providerError(message: "Anthropic OAuth: \(message)")
                case "message_start":
                    let msg = obj["message"] as? [String: Any]
                    usage.merge(LLMUsage.fromAnthropic(msg?["usage"] as? [String: Any]))
                case "message_delta":
                    usage.merge(LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]))
                    if let delta = obj["delta"] as? [String: Any],
                       let stop = delta["stop_reason"] as? String {
                        lastStopReason = stop
                    }
                case "message_stop":
                    let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        provider: providerId,
                        model: model,
                        streaming: true,
                        usage: usage.isEmpty ? nil : usage,
                        ttftMs: ttftMs,
                        durationMs: durationMs,
                        substitutedFrom: substitutedFrom,
                        cacheMarkers: Self.cacheMarkers(in: body)
                    )
                    if !yieldedAnyText {
                        throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                            providerID: providerId,
                            stopReason: lastStopReason,
                            expectedOutput: "answer text"
                        )
                    }
                    continuation.finish()
                    return
                case "content_block_delta":
                    guard let delta = obj["delta"] as? [String: Any],
                          (delta["type"] as? String) == "text_delta",
                          let text = delta["text"] as? String,
                          !text.isEmpty
                    else { continue }
                    if ttftMs == nil {
                        ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    }
                    yieldedAnyText = true
                    continuation.yield(text)
                default:
                    continue
                }
            }
            throw LLMError.streamTruncated(
                message: "Anthropic OAuth stream ended without message_stop"
            )
        }
    }

    // MARK: - U1 item 9 — real SSE over messages-shaped bodies
    //
    // The LLMAdapter default `streamMessages` falls back to NON-streaming
    // completeMessages and yields the reply as one delta — on the Anthropic
    // text-compat chat path that would kill live deltas in the Mac UI. This
    // override streams the SAME wire body completeMessages sends (shared
    // builder above, + "stream": true) through the SAME SSE event protocol
    // runStream parses, extended with the structured tool_use block events
    // (content_block_start → input_json_delta accumulation →
    // content_block_stop → one .toolCall) so the structured streaming tool
    // loop gets live tool-call events too. Error mapping mirrors stream():
    // .notConfigured propagates BEFORE any yield so SwiftNativeLLMClient's
    // api-key fallback chain still engages.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Coerce INSIDE the stream task — see stream() above.
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStreamMessages(
                        messages: messages,
                        system: system,
                        model: coercedModel,
                        tools: tools,
                        substitutedFrom: Self.substitutionTrace(
                            requested: model,
                            coerced: coercedModel
                        ),
                        continuation: continuation
                    )
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?,
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        // User, 2026-09-06: the token the last attempt actually sent, handed to
        // the forced refresh so a rotation another caller already performed is
        // taken instead of burning a second single-use refresh_token — N
        // simultaneous 401s otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
            lastSentAccessToken = accessToken

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(
                accessToken: accessToken, model: model, messages: messages
            ) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let body = Self.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: model,
                maxTokens: requestMaxTokens(model: model),
                tools: tools,
                stream: true
            )
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            Self.dumpBodyIfEnabled(body, call: "streamMessages")

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
            if status == 401, attempt == 0 { continue }
            try await Self.validateStreamResponse(status: status, bytes: bytes, response: response)

            // Telemetry mirrors runStream: usage split across message_start
            // (input + cache counters) and message_delta (output_tokens);
            // row recorded on message_stop. TTFT stamps at the FIRST
            // MODEL-OUTPUT FRAME — first text delta, tool_use
            // content_block_start, or first input_json_delta, whichever
            // arrives first — matching the OpenAI OAuth structured parser's
            // convention exactly (it stamps at output_item.added /
            // function_call_arguments.delta, NOT at output_item.done).
            // Stamping only at content_block_stop (after the whole argument
            // stream) read materially too high for tool-call-first
            // responses (gpt-5.5 review NEEDS_FIX, 2026-06-11).
            var usage = LLMUsage()
            var ttftMs: Int?
            var yieldedSemanticOutput = false
            var lastStopReason: String?
            // In-flight tool_use block being assembled from
            // input_json_delta frames (fine-grained-tool-streaming beta is
            // already in the request headers).
            var openToolId: String?
            var openToolName: String?
            var openToolJSON = ""
            // Mid-stream transport errors (resource timeout, connection
            // lost, ...) thrown by the byte stream must route through the SAME
            // transientNetworkError mapping the initial session.bytes(for:)
            // connect uses — without this wrapper they fell through to
            // streamMessages' generic catch and surfaced as .underlying,
            // so mid-stream URLError.timedOut never classified transient
            // (gpt-5.5 review NEEDS_FIX, 2026-06-11). Intentional LLMErrors
            // from the parser (providerError, httpError, streamTruncated)
            // and cancellation re-throw untouched.
            do {
                // R15: SSEEventStream owns framing; protocol semantics stay here.
                for try await sse in SSEEventStream(bytes) {
                    try Task.checkCancellation()
                    let payload = sse.data
                    if payload.isEmpty || payload == "[DONE]" { continue }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let payloadType = obj["type"] as? String ?? ""
                    // The data JSON's own `type` is authoritative per Anthropic's
                    // streaming protocol; let it WIN over the `event:` name (a
                    // compliant producer MAY omit `event:` and send data-only
                    // frames). Fall back to the event name only when the payload
                    // omits a type (audit #15 — the decoder resets the name per
                    // event, so the old stale-sticky-name mis-route is gone).
                    let effectiveEvent = payloadType.isEmpty ? (sse.event ?? "") : payloadType
                    switch effectiveEvent {
                    case "error":
                        let errObj = obj["error"] as? [String: Any]
                        let message = (errObj?["message"] as? String)
                            ?? (errObj?["type"] as? String)
                            ?? "unknown error"
                        throw LLMError.providerError(message: "Anthropic OAuth: \(message)")
                    case "message_start":
                        let msg = obj["message"] as? [String: Any]
                        usage.merge(LLMUsage.fromAnthropic(msg?["usage"] as? [String: Any]))
                    case "message_delta":
                        usage.merge(LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]))
                        if let delta = obj["delta"] as? [String: Any],
                           let stop = delta["stop_reason"] as? String {
                            lastStopReason = stop
                        }
                    case "message_stop":
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await telemetry.record(
                            provider: providerId,
                            model: model,
                            streaming: true,
                            usage: usage.isEmpty ? nil : usage,
                            ttftMs: ttftMs,
                            durationMs: durationMs,
                            substitutedFrom: substitutedFrom,
                            cacheMarkers: Self.cacheMarkers(in: body)
                        )
                        if !yieldedSemanticOutput {
                            throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                                providerID: providerId,
                                stopReason: lastStopReason,
                                expectedOutput: "answer text or tool call"
                            )
                        }
                        continuation.finish()
                        return
                    case "content_block_start":
                        let blockObj = obj["content_block"] as? [String: Any]
                        // Turn Inspector W2 — thinking lane: a redacted thinking
                        // block is rendered HONESTLY as "[redacted]" onto the
                        // bus (never decoded, never mutated). Bus-only — it does
                        // NOT enter the text stream and does NOT change tool/text
                        // handling below.
                        if (blockObj?["type"] as? String) == "redacted_thinking" {
                            Self.fireThinkingDeltaEvent("[redacted]", redacted: true)
                            continue
                        }
                        guard let blockObj,
                              (blockObj["type"] as? String) == "tool_use"
                        else { continue }
                        // First model-output frame for a tool-call-first
                        // response — stamp TTFT here, not at content_block_stop
                        // (parity with the OpenAI parser's output_item.added
                        // stamp; gpt-5.5 review NEEDS_FIX, 2026-06-11).
                        if ttftMs == nil {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        openToolId = (blockObj["id"] as? String) ?? ""
                        openToolName = (blockObj["name"] as? String) ?? ""
                        openToolJSON = ""
                    case "content_block_delta":
                        guard let delta = obj["delta"] as? [String: Any] else { continue }
                        switch delta["type"] as? String {
                        case "text_delta":
                            guard let text = delta["text"] as? String, !text.isEmpty else { continue }
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                            yieldedSemanticOutput = true
                            continuation.yield(.textDelta(text))
                        case "thinking_delta":
                            // Turn Inspector W2 — summarized-thinking lane.
                            // Fire the thinking text onto the bus (redacted +
                            // bounded). Bus-only: it does NOT yield into the
                            // text stream (thinking is NOT the assistant reply)
                            // and does NOT stamp TTFT (TTFT marks the first
                            // user-visible reply token). signature_delta frames
                            // are intentionally IGNORED — signatures are never
                            // surfaced or mutated.
                            if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                                Self.fireThinkingDeltaEvent(thinking, redacted: false)
                            }
                            // Liveness (audit #4, 2026-06-14): thinking is real
                            // model output but NOT user-visible reply text, so it
                            // isn't yielded as content. Without a yield here,
                            // ProviderStreamGuard's idle clock (which wraps this
                            // adapter and only advances on yield) starves during a
                            // long reasoning phase and KILLS a perfectly healthy
                            // turn. Yield a `.keepAlive` to reset the guard's
                            // activity clock — a dedicated no-content signal that
                            // consumers IGNORE, so (unlike the prior
                            // `.textDelta("")`) no empty delta leaks into the
                            // assistant reply or any consumer's token handling.
                            continuation.yield(.keepAlive)
                            continue
                        case "input_json_delta":
                            // Argument deltas are model output even if the
                            // tool_use block_start frame wasn't recognized —
                            // stamp unconditionally (parity with the OpenAI
                            // parser's function_call_arguments.delta stamp).
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                            openToolJSON += (delta["partial_json"] as? String) ?? ""
                            // Liveness (audit #4): tool-argument deltas are model
                            // output but aren't yielded as content, so reset the
                            // guard's idle clock during a long tool-arg
                            // accumulation (same rationale as thinking_delta) via
                            // the no-content `.keepAlive` signal.
                            continuation.yield(.keepAlive)
                        default:
                            continue
                        }
                    case "content_block_stop":
                        guard let name = openToolName else { continue }
                        let trimmedJSON = openToolJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                        let inputJSON = trimmedJSON.isEmpty ? Data("{}".utf8) : Data(trimmedJSON.utf8)
                        // Idempotent last-resort stamp (mirrors the OpenAI
                        // parser's yieldToolCall stamp) — the block-start /
                        // first-argument-delta stamps above win in practice.
                        if ttftMs == nil {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        continuation.yield(.toolCall(LLMStreamToolCall(
                            id: openToolId ?? "",
                            name: name,
                            inputJSON: inputJSON
                        )))
                        yieldedSemanticOutput = true
                        openToolId = nil
                        openToolName = nil
                        openToolJSON = ""
                    default:
                        continue
                    }
                }
            } catch let err as LLMError {
                throw err
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
            }
            throw LLMError.streamTruncated(
                message: "Anthropic OAuth streamMessages ended without message_stop"
            )
        }
    }

    // MARK: - Auth file resolution + token load

    func resolveAuthPath() -> URL {
        if let override = authPathOverride { return override }
        return PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Return a fresh access token, refreshing through the shared serial
    /// actor if the on-disk `expires_at` is within
    /// `tokenExpiryBufferSec` of now (or in the past), or if forceRefresh
    /// is set. Mirrors OpenAIOAuthDirectAdapter.ensureFreshAccessToken.
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil
    ) async throws -> String {
        let path = resolveAuthPath()
        // Fast path — no refresh needed.
        if !forceRefresh, let (token, exp) = Self.loadAccessTokenAndExpiry(from: path) {
            if let exp = exp {
                if exp.timeIntervalSinceNow > Self.tokenExpiryBufferSec {
                    return token
                }
                // Else fall through to refresh.
            } else {
                // No expires_at on disk: long-lived setup_token shape.
                // Don't speculatively refresh — return as-is. The 401 retry
                // path handles a stale token.
                return token
            }
        }
        // Slow path — serialize.
        let actor = Self.sharedRefreshActor(for: path)
        return try await actor.run { [self] in
            // Re-read inside the critical section in case another waiter
            // already refreshed.
            // User, 2026-09-06: the reread was skipped entirely on a forced
            // refresh, so N simultaneous 401s each rotated in turn and every
            // rotation invalidated the single-use refresh_token the next
            // waiter was about to spend — a burst of parallel requests signed
            // the user out. A forced refresh whose on-disk token has already
            // moved past the one the failing request sent takes the new token.
            if forceRefresh, let staleToken, !staleToken.isEmpty,
               let (token, _) = Self.loadAccessTokenAndExpiry(from: path),
               token != staleToken {
                return token
            }
            if !forceRefresh, let (token, exp) = Self.loadAccessTokenAndExpiry(from: path) {
                if let exp = exp, exp.timeIntervalSinceNow > Self.tokenExpiryBufferSec {
                    return token
                }
                if exp == nil { return token }
            }
            return try await self.refreshTokens()
        }
    }

    /// True when a signed-in Anthropic OAuth credential is on disk at this
    /// adapter's own path (User, 2026-09-06 — see `OAuthCredentialPresence`).
    var hasStoredOAuthCredential: Bool {
        Self.loadAccessTokenAndExpiry(from: resolveAuthPath()) != nil
    }

    /// Read `(access_token, expires_at)` from the JSON. Returns nil if the
    /// file is missing/unparseable or has no token. `expires_at` is
    /// optional — long-lived setup_tokens omit it.
    static func loadAccessTokenAndExpiry(from path: URL) -> (String, Date?)? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let access: String? = (obj["access_token"] as? String)
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["access_token"] as? String }
        guard let token = access, !token.isEmpty else { return nil }
        let expRaw: Any? = obj["expires_at"]
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["expires_at"] }
        let exp = expRaw.flatMap(parseExpiresAt)
        return (token, exp)
    }

    /// Accept ISO basic ("2026-06-03T18:23:45Z"), full ISO with fractional
    /// seconds, or an integer/double unix timestamp.
    static func parseExpiresAt(_ raw: Any) -> Date? {
        if let s = raw as? String {
            let basic = DateFormatter()
            basic.calendar = Calendar(identifier: .iso8601)
            basic.locale = Locale(identifier: "en_US_POSIX")
            basic.timeZone = TimeZone(secondsFromGMT: 0)
            basic.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            if let d = basic.date(from: s) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            if let unix = TimeInterval(s) { return Date(timeIntervalSince1970: unix) }
            return nil
        }
        if let i = raw as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
        if let d = raw as? Double { return Date(timeIntervalSince1970: d) }
        return nil
    }

    /// Instance shim used by older call paths / tests.
    private func loadAccessToken() throws -> String {
        try Self.loadAccessToken(from: resolveAuthPath())
    }

    static func loadAccessToken(from path: URL) throws -> String {
        guard let (token, _) = loadAccessTokenAndExpiry(from: path) else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        return token
    }

    // MARK: - Token refresh

    /// POST to the OAuth refresh endpoint, persist the rotated tokens
    /// (atomically, 0600), return the new access token. On non-2xx the
    /// caller sees `.notConfigured` — the api-key adapter chain will then
    /// take over (and likely also throw, but with the right error shape).
    @discardableResult
    func refreshTokens() async throws -> String {
        let path = resolveAuthPath()
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        let refresh: String? = (obj["refresh_token"] as? String)
            ?? (obj["tokens"] as? [String: Any]).flatMap { $0["refresh_token"] as? String }
        guard let refreshToken = refresh, !refreshToken.isEmpty else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }

        let body: [String: Any] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]
        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        // User, 2026-09-06: the refresh holds the shared serial refresh actor,
        // so it needs a bound of its own rather than the session's chat-sized
        // request timeout — a hung token endpoint otherwise blocks every later
        // turn's token read for minutes.
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (rdata, response): (Data, URLResponse)
        do {
            (rdata, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // A3.5: a 429/5xx during refresh is a provider-side hiccup, NOT a
            // dead token — surface transient so the session survives without a
            // needless "reconnect" prompt (the misreported-as-revoked bug).
            // User, 2026-09-06: a refresh 429 folded into `.transient` threw
            // the provider's own `Retry-After` away, so the reconnect ladder
            // backed off on its own schedule and re-asked into the same limit.
            // The chat call path already carries the header through
            // `.rateLimited`; the refresh does now too.
            if status == 429 {
                throw LLMError.rateLimited(
                    message: "anthropic_oauth_direct refresh HTTP 429 (temporary)",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(
                    message: "anthropic_oauth_direct refresh HTTP \(status) (temporary)")
            }
            // A3.1/A3.5: 401/403/400(invalid_grant) = the refresh token itself
            // was rejected → the credential is genuinely revoked. authRejected
            // carries the reconnect guidance + provider body, instead of the
            // misleading "not configured" (a stranger's revoked token used to
            // read as if they'd never signed in).
            throw LLMError.authRejected(
                provider: "anthropic_oauth_direct", detail: providerErrorDetail(rdata))
        }
        guard let payload = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any] else {
            throw LLMError.underlying(message: "anthropic refresh: unparseable response")
        }

        // Merge: keep client_id / scope / token_type / user_info; replace
        // access_token, refresh_token (if rotated), recompute expires_at.
        let rotatedAccess = (payload["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rotatedRefresh = (payload["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // expires_in is seconds-from-now. Compute an absolute timestamp.
        let expiresIn: Int = {
            if let i = payload["expires_in"] as? Int { return i }
            if let d = payload["expires_in"] as? Double { return Int(d) }
            return 3600
        }()
        let exp = Date().addingTimeInterval(TimeInterval(expiresIn))
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let rotatedExpiresAt = f.string(from: exp)

        // User, 2026-09-06: sign-out (which deletes this file) and a fresh
        // sign-in (which replaces it) both land while a refresh is in flight,
        // and neither goes through the adapter's refresh queue. Writing the
        // merged blob unconditionally resurrected a credential the user had
        // just removed, or clobbered a newer one with the older account's
        // tokens. The bytes read before the network call are the generation:
        // if they moved, this refresh is stale and its write is skipped. The
        // access token it minted is still valid, so the in-flight call is
        // served from whatever credential now owns the file.
        // User, 2026-09-06: the comparison and the write it guards now sit in
        // ONE critical section on the credential path's shared lock, which the
        // app's sign-in and sign-out take too — a compare followed by an
        // unguarded write still lost every sign-out that landed between them.
        // User, 2026-09-06: the generation is a digest of the TOKEN keys, not
        // the file's bytes. `configureProvider` writes `default_model` into
        // this same file, so saving provider settings during a refresh moved
        // the bytes and made the refresh discard the token it had just
        // rotated — burning the single-use refresh_token on disk. For the same
        // reason the merge happens against what is on disk NOW, so a
        // concurrent settings save survives the refresh's write.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: data)
        enum RefreshWrite { case wrote, superseded(String), supersededAndGone }
        let outcome: RefreshWrite
        do {
            outcome = try CredentialFileLock.withLock(path) { () -> RefreshWrite in
                guard CredentialFileLock.credentialGeneration(ofFileAt: path) == generation else {
                    guard let (current, _) = Self.loadAccessTokenAndExpiry(from: path) else {
                        return .supersededAndGone
                    }
                    return .superseded(current)
                }
                var blob = (try? Data(contentsOf: path))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    ?? obj
                if let rotatedAccess { blob["access_token"] = rotatedAccess }
                if let rotatedRefresh { blob["refresh_token"] = rotatedRefresh }
                blob["expires_at"] = rotatedExpiresAt
                try saveAuthBlob(blob, to: path)
                return .wrote
            }
        } catch {
            // Single-use refresh_token already rotated server-side — a
            // swallowed persist failure burns the on-disk credential and
            // surfaces later as a mystery sign-out (audit 2026-06-09).
            FileHandle.standardError.write(Data(
                "AnthropicOAuthDirectAdapter: PERSIST FAILED after token rotation — on-disk refresh_token is now stale: \(error)\n".utf8
            ))
            throw LLMError.underlying(
                message: "anthropic oauth: token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required"
            )
        }

        switch outcome {
        case .superseded(let current):
            // Another writer owns the file now. Its credential is the live one.
            return current
        case .supersededAndGone:
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        case .wrote:
            break
        }

        guard let newAccess = rotatedAccess ?? (obj["access_token"] as? String),
              !newAccess.isEmpty else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }
        return newAccess
    }

    /// Atomic 0600 write. Same pattern as NativeOAuthFlow.writeJSONObject.
    private func saveAuthBlob(_ blob: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: blob,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = path.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: path)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path.path
        )
    }
}
