import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+AnthropicOAuthDirectAdapter.swift` | `AnthropicOAuthTransport`, `requestOutputTokens`: OAuth refresh and indexed blocks |

// MARK: - AnthropicOAuthTransport
// The OAuth endpoint requires Claude Code identity headers. Path-scoped serialization and credential locking prevent duplicate single-use refreshes and
// coordinate with sign-out/settings.

public final class AnthropicOAuthTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.textMarkers
    public let providerId: String = "anthropic_oauth_direct"

    public static let productionSession: URLSession = ProviderHTTP.makeSession()

    private let session: URLSession
    private let endpoint: URL?
    private let refreshEndpoint: URL?
    /// An injected credential path confines alternate runtimes; production resolves the canonical layout.
    private let authPathOverride: URL?
    private let maxTokensOverride: Int?
    private let clientID: String
    private let telemetry: LLMCallTraceRecorder

    public init(
        session: URLSession = AnthropicOAuthTransport.productionSession,
        endpoint: URL? = URL(string: "https://api.anthropic.com/v1/messages"),
        refreshEndpoint: URL? = URL(string: ProviderOAuthConfig.anthropic.tokenEndpoint),
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

    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        if let limit = call.turn?.tokenBudget?.available { return limit }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: call.admission?.reasoningEffort,
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
    // Explicit protocol identity for this adapter; never inferred from another application's installed version or a directory read.
    private static let claudeCLIVersion = "2.1.280"

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
        status: Int, bytes: ProviderHTTPBytes, response: URLResponse
    ) async throws {
        if !(200..<300).contains(status) {
            let body = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096)
            // The person sees one generic line; the provider's own reason stays findable.
            let reason = String(data: body.prefix(600), encoding: .utf8) ?? ""
            ModuleLog(subsystem: "NativeAgent", category: "Anthropic")("oauth HTTP \(status): \(reason)", level: .error)
            try throwIfChatCompletionsError(status: status, data: body, response: response)
        }
    }

    /// Inspector thinking is opt-in, secret-redacted and bounded; signatures never surface. Publish without awaiting the bus so display backpressure cannot
    /// stall provider liveness.
    static func fireThinkingDeltaEvent(_ text: String, redacted: Bool, call: LLMCall) {
        guard call.inspectorThinkingSummarized else { return }
        guard call.turn != nil else { return }
        let safe = redacted ? text : TurnTraceRedactor.redactText(text)
        TurnTraceBus.fireFromContext(
            kind: "thinking.delta",
            payload: .object([
                "text": .string(safe),
                "redacted": .bool(redacted),
            ]), turn: call.turn
        )
    }

    private func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        .transient(message: """
            \(providerId) \(operation) failed for \(endpoint.host ?? "api.anthropic.com"): \
            \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))
            """)
    }

    // MARK: - Shared refresh-actor registry
    // Share the refresh queue by credential path across instances so concurrent adapters cannot spend one refresh token twice.

    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        refreshQueueRegistry.queue(for: path)
    }

    // MARK: - Model admission

    /// Admit only Claude IDs, stripping the optional Anthropic namespace; foreign IDs require repair.
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

    /// Record actual ID rewrites in substitutedFrom so substitutions remain visible.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
    }

    /// The subscription connection must never carry a native `tools` array (ProviderToolCapability); tools reach Claude here only as prompt text.
    private static func refuseNativeTools(_ tools: [LLMToolSchema]?) throws {
        guard let tools, !tools.isEmpty else { return }
        throw LLMError.providerError(message:
            "anthropic_oauth_direct never receives a native tools[] array (text tool lane only)")
    }

    // MARK: - LLMTransport conformance

    /// Structured conversation blocks keep prior calls paired with results so the tool loop can converge.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }

    public func complete(
        prompt: String, system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: call)
    }

    /// Text-tool streams must refuse native schemas.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.refuseNativeTools(tools)
                    // Reject invalid models before any stream output.
                    let coercedModel = try Self.coerceToClaudeModel(model)
                    try await self.runStreamMessages(
                        messages: messages,
                        system: system,
                        model: coercedModel,
                        substitutedFrom: Self.substitutionTrace(
                            requested: model,
                            coerced: coercedModel
                        ),
                        continuation: continuation, call: call
                    )
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        substitutedFrom: String?,
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation, call: LLMCall
    ) async throws {
        guard let endpoint else {
            throw LLMError.providerError(message: "Anthropic response endpoint is invalid; correct its provider configuration.")
        }
        let requestAccount = OAuthRequestAccount()
        try Task.checkCancellation()
        let accessToken = try await ensureFreshAccessToken(
            requestAccount: requestAccount)

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
            maxTokens: try requestOutputTokens(model: model, call: call),
            stream: true, call: call
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        Self.dumpBodyIfEnabled(body, call: "streamMessages")

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let bytes: ProviderHTTPBytes
        let response: URLResponse
        do {
            (bytes, response) = try await ProviderWire.open(session, req, call: call)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: endpoint, operation: "streamMessages"))
        }
        defer { bytes.cancel() }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        try await Self.validateStreamResponse(status: status, bytes: bytes, response: response)

        let cacheMarkers = Self.cacheMarkers(in: body)
        var usage = LLMUsage()
        var ttftMs: Int?
        var yieldedSemanticOutput = false
        var lastStopReason: String?
        var contentBlocks: [Int: String] = [:]
        // Connect and mid-stream transport errors share a mapping; parser errors and cancellation pass through.
        do {
            // SSEEventStream owns framing; protocol semantics stay here.
            for try await sse in SSEEventStream(bytes, lifetime: call.lifetime) {
                if try await AnthropicTransport.consumeStreamEvent(
                    sse, usage: &usage, stopReason: &lastStopReason, blocks: &contentBlocks,
                    ttftMs: &ttftMs, semanticOutput: &yieldedSemanticOutput,
                    requestStartNs: requestStartNs, requestBody: req.httpBody, provider: providerId,
                    model: model, telemetry: telemetry,
                    malformedFrame: "Anthropic OAuth: malformed streamMessages frame",
                    continuation: continuation, substitutedFrom: substitutedFrom,
                    cacheMarkers: cacheMarkers, inspectThinking: { text, redacted in
                        Self.fireThinkingDeltaEvent(text, redacted: redacted, call: call)
                    },
                    call: call, payload: { _, _, _ in false }
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

    // MARK: - Auth file resolution + token load

    func resolveAuthPath() -> URL {
        if let override = authPathOverride { return override }
        return PersistenceCore.defaultDataRoot()
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
    }

    /// Readiness and execution share the renewal margin.
    func ensureFreshAccessToken(
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        let path = resolveAuthPath()
        let data = try Data(contentsOf: path)
        let object = try ProviderStateValidation.credential(data: data)
        try requestAccount.check(object, provider: "anthropic_oauth_direct")
        if let (token, exp) = Self.accessTokenAndExpiry(in: object) {
            if let exp = exp {
                if exp.timeIntervalSinceNow > OAuthGrantOperations.renewalMargin {
                    return token
                }
            } else {
                // No stated expiry: use this access token until rejected.
                return token
            }
        }
        let actor = Self.sharedRefreshActor(for: path)
        return try await actor.run { [self] in
            let data = try Data(contentsOf: path)
            let object = try ProviderStateValidation.credential(data: data)
            try requestAccount.check(object, provider: "anthropic_oauth_direct")
            if let (token, exp) = Self.accessTokenAndExpiry(in: object) {
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

    /// Readiness uses the adapter's own credential rules: a readable access token and, near expiry, a usable refresh grant. Presence of unrelated token
    /// fields cannot prove dispatch readiness.
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

    /// Refresh failures retain this selected route's failure; persisted rotations are atomic and private.
    @discardableResult
    private func refreshTokens(
        at path: URL, baseline: Data, object obj: [String: Any], requestAccount: OAuthRequestAccount
    ) async throws -> String {
        guard let refreshEndpoint else {
            throw LLMError.providerError(message: "Anthropic refresh endpoint is invalid; correct its provider configuration.")
        }
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
            (rdata, response) = try await OAuthGrantOperations.post(refreshEndpoint, body, json: true, session: session)
        } catch {
            throw mapTransportError(error, fallback: transientNetworkError(error, endpoint: refreshEndpoint, operation: "refresh"))
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
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

        // Refresh preserves account metadata while replacing token fields and the new token's expiry.
        let rotatedExpiresAt = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }

        // Under the shared path lock, compare token-key generations and merge onto current settings. Superseded refreshes skip the write and return a
        // current credential only for the same account.
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
