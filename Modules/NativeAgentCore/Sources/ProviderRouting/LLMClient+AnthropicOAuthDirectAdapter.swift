import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthTransport`: `requestOutputTokens`, explicit OAuth protocol client identity; indexed content-block validation shared by OAuth text and Anthropic native-tool streams, keeping text/thinking/signature/tool deltas on their own blocks |

// MARK: - AnthropicOAuthTransport
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

public final class AnthropicOAuthTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.textMarkers
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
    /// Per-call llm.call telemetry writer; the override selects a test data root.
    private let telemetry: LLMCallTraceRecorder

    public init(
        session: URLSession = AnthropicOAuthTransport.productionSession,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        refreshEndpoint: URL = URL(string: ProviderOAuthConfig.anthropic.tokenEndpoint)!,
        authPathOverride: URL? = nil,
        maxTokens: Int? = nil,
        clientID: String = ProviderOAuthConfig.anthropic.clientId,
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

    public func requestOutputTokens(model: String) throws -> Int {
        if let limit = LLMCallContext.turnTokenBudget?.available { return limit }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: LLMCallContext.reasoningEffort,
            explicitOverride: maxTokensOverride, providerID: providerId
        )
    }

    // MARK: - Constants

    private static let anthropicVersion = "2023-06-01"
    private static let oauthBetaFeatures = [
        "claude-code-20250219",
        "oauth-2025-04-20",
        "fine-grained-tool-streaming-2025-05-14",
    ]
    // Explicit protocol identity for this adapter; never inferred from another
    // application's installed version or a directory read.
    private static let claudeCLIVersion = "2.1.280"

    static func makeProductionSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        OAuthProductionSession.make(
            requestTimeout: environment["NATIVE_AGENT_ANTHROPIC_OAUTH_REQUEST_TIMEOUT_SEC"],
            resourceTimeout: environment["NATIVE_AGENT_ANTHROPIC_OAUTH_RESOURCE_TIMEOUT_SEC"]
        )
    }

    /// Shared OAuth headers; turn context needs no provider-specific beta.
    static func apiHeaders(accessToken: String) -> [String: String] {
        return [
            "Authorization":      "Bearer \(accessToken)",
            "anthropic-version":  anthropicVersion,
            "anthropic-beta":     oauthBetaFeatures.joined(separator: ","),
            "x-app":              "cli",
            "user-agent":         "claude-cli/\(claudeCLIVersion)",
            "anthropic-dangerous-direct-browser-access": "true",
            "Accept":             "application/json",
            "Content-Type":       "application/json",
        ]
    }

    /// Every HTTP failure retains bounded body evidence before classification.
    private static func validateStreamResponse(
        status: Int, bytes: URLSession.AsyncBytes, response: URLResponse
    ) async throws {
        if !(200..<300).contains(status) {
            let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
            // The person sees one generic line; the provider's own reason stays findable.
            let reason = String(data: body.prefix(600), encoding: .utf8) ?? ""
            ModuleLog(subsystem: "NativeAgent", category: "Anthropic")("oauth HTTP \(status): \(reason)", level: .error)
            try throwIfChatCompletionsError(status: status, data: body, response: response)
        }
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
    /// Inspector display remains opt-in; provider liveness is independent.
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
        .transient(message: "\(providerId) \(operation) failed for \(endpoint.host ?? "api.anthropic.com"): \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))")
    }

    // MARK: - Shared refresh-actor registry
    //
    // Production has 4+ callsites constructing fresh adapter instances. A
    // PER-INSTANCE actor would let two instances refresh in parallel and
    // rotate the single-use refresh_token twice — the second rotation
    // burns the credential. Share one AsyncSerialQueue per resolved auth
    // file path across the process.

    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        refreshQueueRegistry.queue(for: path)
    }

    // MARK: - Model admission

    /// Admit a `claude-` prefix, optionally preceded by `anthropic/` (case-insensitive).
    /// Strip only that namespace; missing or foreign IDs throw `modelUnavailable`.
    static func coerceToClaudeModel(_ requested: String?) throws -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            // An absent model is a routing fault; the picker owns the selection.
            throw LLMError.modelUnavailable(provider: "anthropic_oauth_direct", model: "")
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

    /// The subscription connection must never carry a native `tools` array
    /// (ProviderToolCapability); tools reach Claude here only as prompt text.
    private static func refuseNativeTools(_ tools: [LLMToolSchema]?) throws {
        guard let tools, !tools.isEmpty else { return }
        throw LLMError.providerError(message:
            "anthropic_oauth_direct never receives a native tools[] array (text tool lane only)")
    }

    // MARK: - LLMTransport conformance

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
        return try await LLMMessageStreamEvent.reply(collecting:
            self.streamMessages(messages: messages, system: system, model: model, tools: tools), using: telemetry)
    }

    public func complete(
        prompt: String, system: String?, model: String, tools: [LLMToolSchema]?
    ) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools)
    }

    /// Streams the messages-shaped text-tool body; native schemas are refused.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.refuseNativeTools(tools)
                    // Model validation errors finish the stream before any output.
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStreamMessages(
                        messages: messages,
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
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            ProviderReplyWork.current?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        // Forced refresh receives the sent token so concurrent rotations reuse the current credential.
        let requestAccount = OAuthRequestAccount()
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            try Task.checkCancellation()
            let accessToken = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken, requestAccount: requestAccount)
            lastSentAccessToken = accessToken

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            for (k, v) in Self.apiHeaders(
                accessToken: accessToken
            ) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

            let body = try Self.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: model,
                maxTokens: try requestOutputTokens(model: model),
                stream: true
            )
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            Self.dumpBodyIfEnabled(body, call: "streamMessages")

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await ProviderWire.open(session, req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
            }
            defer { bytes.task.cancel() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 { continue }
            try await Self.validateStreamResponse(status: status, bytes: bytes, response: response)

            let cacheMarkers = Self.cacheMarkers(in: body)
            var usage = LLMUsage()
            var ttftMs: Int?
            var yieldedSemanticOutput = false
            var lastStopReason: String?
            var contentBlocks: [Int: String] = [:]
            var runaway = RunawayOutputDetector(endsAtToolBoundary: body["stop_sequences"] != nil, diagnosticDataRoot: telemetry.diagnosticDataRoot)
            // Connect and mid-stream transport errors share a mapping; parser errors and cancellation pass through.
            do {
                // SSEEventStream owns framing; protocol semantics stay here.
                for try await sse in SSEEventStream(bytes) {
                    if try await AnthropicTransport.consumeStreamEvent(
                        sse, usage: &usage, stopReason: &lastStopReason, blocks: &contentBlocks,
                        ttftMs: &ttftMs, semanticOutput: &yieldedSemanticOutput, runaway: &runaway,
                        requestStartNs: requestStartNs, requestBody: req.httpBody, provider: providerId,
                        model: model, telemetry: telemetry,
                        malformedFrame: "Anthropic OAuth: malformed streamMessages frame",
                        continuation: continuation, substitutedFrom: substitutedFrom,
                        cacheMarkers: cacheMarkers, inspectThinking: Self.fireThinkingDeltaEvent,
                        payload: { _, _, _ in false }
                    ) { return }
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
    /// the shared renewal margin of now (or in the past), or if forceRefresh
    /// is set. Mirrors ChatGPTTransport.ensureFreshAccessToken.
    func ensureFreshAccessToken(
        forceRefresh: Bool = false,
        staleToken: String? = nil,
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        try OAuthProductionSession.validate(session)
        let path = resolveAuthPath()
        let data = try Data(contentsOf: path)
        let object = try ProviderStateValidation.credential(data: data)
        try requestAccount.check(object, provider: "anthropic_oauth_direct", rejectedToken: staleToken)
        // Fast path — no refresh needed.
        if !forceRefresh, let (token, exp) = Self.accessTokenAndExpiry(in: object) {
            if let exp = exp {
                if exp.timeIntervalSinceNow > OAuthGrantOperations.renewalMargin {
                    return token
                }
                // Else fall through to refresh.
            } else {
                // No stated expiry: use this access token until rejected.
                return token
            }
        }
        // Slow path — serialize.
        let actor = Self.sharedRefreshActor(for: path)
        return try await actor.run { [self] in
            let data = try Data(contentsOf: path)
            let object = try ProviderStateValidation.credential(data: data)
            try requestAccount.check(object, provider: "anthropic_oauth_direct")
            // A forced refresh reuses the on-disk token when another waiter has already rotated it.
            if forceRefresh, let staleToken, !staleToken.isEmpty,
               let (token, _) = Self.accessTokenAndExpiry(in: object),
               token != staleToken {
                return token
            }
            if !forceRefresh, let (token, exp) = Self.accessTokenAndExpiry(in: object) {
                if let exp = exp, exp.timeIntervalSinceNow > OAuthGrantOperations.renewalMargin {
                    return token
                }
                if exp == nil { return token }
            }
            return try await self.refreshTokens(at: path, baseline: data, object: object, requestAccount: requestAccount)
        }
    }

    private static func accessTokenAndExpiry(in obj: [String: Any]) -> (String, Date?)? {
        let tokens = OAuthRefreshBinding.tokenSet(obj, provider: "anthropic_oauth_direct")
        let access = tokens["access_token"] as? String
        guard let token = access, !token.isEmpty else { return nil }
        let expRaw: Any? = obj["expires_at"]
        let exp = expRaw.flatMap(parseExpiresAt)
        return (token, exp)
    }

    /// Can the credential in `auth` (this adapter's auth file, parsed) serve a
    /// call? Answered by the rules `ensureFreshAccessToken` itself applies: a
    /// token `loadAccessTokenAndExpiry` reads, used as-is when it carries no
    /// expiry or has more than the shared renewal margin left, and otherwise a
    /// `refresh_token` that `refreshTokens` can spend. Routing readiness and
    /// the Providers page ask this, so neither reports signed in for a file
    /// the adapter refuses — a bare `setup_token` key, for one (the app saves
    /// a setup token as `access_token`).
    public static func credentialStatus(_ auth: [String: Any]?) -> (usable: Bool, detail: String, health: OAuthCredentialHealth) {
        let object = auth ?? [:]
        let tokens = OAuthRefreshBinding.tokenSet(object, provider: "anthropic_oauth_direct")
        if OAuthRefreshBinding.hasInvalidExpiry(object, provider: "anthropic_oauth_direct") {
            return (false, "Saved expires_at is invalid — repair the credential or sign in again",
                OAuthCredentialHealth(configured: false, expiresAt: nil, canRefresh: false))
        }
        let canRefresh = OAuthRefreshBinding.string(tokens["refresh_token"]) != nil
            && OAuthRefreshBinding.permitsRefresh(object, provider: "anthropic_oauth_direct")
        let token = accessTokenAndExpiry(in: object)
        let expiry = token?.1
        let fresh = token != nil && (expiry.map { $0.timeIntervalSinceNow > OAuthGrantOperations.renewalMargin } ?? true)
        let usable = fresh || canRefresh
        let detail = auth == nil ? "anthropic_oauth_direct.json missing or malformed"
            : token == nil ? (canRefresh ? "No access_token - refresh on next chat" : "no access_token - sign in required")
            : fresh ? (expiry == nil ? "Signed in" : "Signed in (valid)")
            : canRefresh ? "Access expired - refresh on next chat" : "Access expired and no refresh_token - re-auth required"
        return (usable, detail, OAuthCredentialHealth(configured: usable, expiresAt: expiry,
            canRefresh: canRefresh, requiresRefresh: !fresh))
    }

    // MARK: - Token refresh

    /// POST to the OAuth refresh endpoint, persist the rotated tokens
    /// (atomically, 0600), return the new access token. Refresh failures are
    /// classified and thrown through this selected OAuth provider's route.
    @discardableResult
    private func refreshTokens(
        at path: URL, baseline: Data, object obj: [String: Any], requestAccount: OAuthRequestAccount
    ) async throws -> String {
        try ProviderStateValidation.credential(obj)
        let tokenSet = OAuthRefreshBinding.tokenSet(obj, provider: "anthropic_oauth_direct")
        let refresh = tokenSet["refresh_token"] as? String
        guard let refreshToken = refresh, !refreshToken.isEmpty else {
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        }

        try OAuthRefreshBinding.requireRefresh(obj, provider: "anthropic_oauth_direct")
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID,
        ]
        let (rdata, response): (Data, URLResponse)
        do {
            (rdata, response) = try await OAuthGrantOperations.post(refreshEndpoint, body, json: true, timeout: 30, session: session)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            // Refresh 429 preserves Retry-After; 5xx is transient and neither revokes the credential.
            if status == 429 {
                throw LLMError.rateLimited(
                    message: "anthropic_oauth_direct refresh HTTP 429 (temporary)",
                    retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(
                    message: "anthropic_oauth_direct refresh HTTP \(status) (temporary)")
            }
            // A rejected refresh token carries reconnect guidance and the provider's error detail.
            throw LLMError.authRejected(
                provider: "anthropic_oauth_direct", detail: providerErrorDetail(rdata))
        }
        let answer = try OAuthGrantOperations.validateTokenResponse(rdata, requiringRefreshToken: false)
        let payload = answer.fields
        try OAuthRefreshBinding.requireSameAccount(payload, original: obj, provider: "anthropic_oauth_direct")

        // Merge: keep client_id / scope / token_type / user_info; replace
        // access_token, a supplied refresh_token, and the new token's expiry.
        let rotatedExpiresAt = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }

        // Under the shared path lock, compare token-key generations and merge onto current settings.
        // Superseded refreshes skip the write and return a current credential only for the same account.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: baseline)
        enum RefreshWrite { case wrote, superseded(Data), supersededAndGone }
        let outcome: RefreshWrite
        do {
            outcome = try CredentialFileLock.withLock(path) { () -> RefreshWrite in
                guard let current = try ProviderStateValidation.dataIfPresent(at: path) else { return .supersededAndGone }
                guard CredentialFileLock.credentialGeneration(ofFileContents: current) == generation else {
                    return .superseded(current)
                }
                var blob = try ProviderStateValidation.credential(data: current)
                blob["access_token"] = answer.accessToken
                if let refresh = answer.refreshToken { blob["refresh_token"] = refresh }
                blob.removeValue(forKey: "expires_in")
                blob["expires_at"] = rotatedExpiresAt
                try saveAuthBlob(blob, to: path)
                return .wrote
            }
        } catch {
            // Persist failures stay visible because the server has already rotated the single-use token.
            FileHandle.standardError.write(Data(
                "AnthropicOAuthTransport: PERSIST FAILED after token rotation — on-disk refresh_token is now stale: \(error)\n".utf8
            ))
            throw LLMError.underlying(
                message: "anthropic oauth: token rotated but persist failed (\(error.localizedDescription)) — re-sign-in may be required"
            )
        }

        switch outcome {
        case .superseded(let current):
            let object = try ProviderStateValidation.credential(data: current)
            try requestAccount.check(object, provider: "anthropic_oauth_direct")
            guard let access = OAuthRefreshBinding.string(OAuthRefreshBinding.tokenSet(object, provider: "anthropic_oauth_direct")["access_token"]) else {
                throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
            }
            return access
        case .supersededAndGone:
            throw LLMError.notConfigured(provider: "anthropic_oauth_direct")
        case .wrote:
            break
        }

        return answer.accessToken
    }

    /// Private durable commit; the caller retains its credential lock.
    private func saveAuthBlob(_ blob: [String: Any], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: blob,
            options: [.prettyPrinted, .sortedKeys]
        )
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: path.resolvingSymlinksInPath())
    }
}

extension AnthropicOAuthTransport {
    /// A text-tool stop without a complete call logs only markup tag names, never chat text.
    static func logStopWithoutToolCall(_ stopReason: String?, _ text: String) {
        guard stopReason == "stop_sequence",
              !text.contains("</invoke>"), !text.contains("</tool_use>") else { return }
        logCutoffShape(text, event: "stop_sequence without tool call")
    }

    static func logCutoffShape(_ text: String, event: String = "max_tokens cutoff") {
        var counts: [String: Int] = [:]
        let pattern = try? NSRegularExpression(pattern: #"</?[a-z_][a-z0-9_:-]{0,30}(?=[\s>])"#)
        let range = NSRange(text.startIndex..., in: text)
        pattern?.enumerateMatches(in: text, range: range) { match, _, _ in
            if let match, let r = Range(match.range, in: text) { counts[String(text[r]), default: 0] += 1 }
        }
        let headerCount = text.components(separatedBy: "NativeAgent tool result").count - 1
        let shape = counts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        ModuleLog(subsystem: "NativeAgent", category: "Anthropic")("\(event) chars=\(text.count) resultHeaders=\(headerCount) tags=\(shape)", level: .error)
    }
}
