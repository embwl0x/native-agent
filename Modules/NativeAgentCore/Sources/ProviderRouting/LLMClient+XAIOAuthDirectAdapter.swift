import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+XAIOAuthDirectAdapter.swift` | `XAIOAuthTransport`: path-serialized token refresh |

public let XAIOAuthDirectExhaustedMarker = "xai_oauth_direct_exhausted: re-sign-in required"

/// App-owned xAI credentials authenticate the first-party model route.
public final class XAIOAuthTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// This transport sends no output-cap field.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId: String = "xai_oauth_direct"

    public static let defaultEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")
    public static let clientID = ProviderOAuthConfig.xaiClientID
    private let session: URLSession
    private let endpoint: URL?
    private let tokenPathOverride: URL?
    private let telemetry: LLMCallTraceRecorder

    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    public init(
        session: URLSession = ProviderHTTP.session,
        endpoint: URL? = XAIOAuthTransport.defaultEndpoint,
        tokenPathOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.tokenPathOverride = tokenPathOverride
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    public static func tokenPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("xai_oauth_direct.json")
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        let messages = [LLMMessage.user(prompt)]
        return try await completeMessages(messages: messages, system: system, model: model, tools: tools, call: call)
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }



    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let providerId = self.providerId
        let telemetry = self.telemetry
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let endpoint else {
                        throw LLMError.providerError(message: "xAI response endpoint is invalid; correct its provider configuration.")
                    }
                    let effectiveModel = try Self.normalizeModel(model)
                    let requestAccount = OAuthRequestAccount()
                    let access = try await self.ensureFreshAccessToken(
                        requestAccount: requestAccount)
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &req)
                    let body = try Self.buildChatCompletionsBody(
                        model: effectiveModel,
                        messages: messages,
                        system: system,
                        tools: tools,
                        stream: true, call: call
                    )
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let bytes: ProviderHTTPBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, req, call: call)
                    } catch {
                        throw mapTransportError(error, fallback: self.transientNetworkError(error, operation: "streamMessages"))
                    }
                    defer { bytes.cancel() }
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    let status = http.statusCode
                    if status == 401 {
                        throw LLMError.authRejected(provider: "xai_oauth_direct", detail: XAIOAuthDirectExhaustedMarker)
                    }
                    try await ProviderWire.validateChatCompletions(bytes, response)
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "xAI")
                    try await decoder.consume(
                        SSEEventStream(bytes, lifetime: call.lifetime), continuation: continuation,
                        request: req, providerID: providerId, model: effectiveModel, idPrefix: "xai_tool",
                        started: requestStartNs, telemetry: telemetry, call: call
                    )
                    continuation.finish()
                    return
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request body

    static func buildChatCompletionsBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        stream: Bool, call: LLMCall
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": try OpenAITransport.chatMessages(messages: messages, system: system),
            "stream": stream,
        ]
        // Streaming requests ask for token usage on the final SSE frame.
        if stream { body["stream_options"] = ["include_usage": true] }
        try OpenAITransport.applyTools(to: &body, tools: tools)
        try FirstPartyExecutionControls.applyXAIControls(to: &body, model: model, call: call)
        return body
    }


    // MARK: - Credentials

    private var tokenPath: URL {
        tokenPathOverride ?? Self.tokenPath()
    }

    private var refreshSerial: AsyncSerialQueue {
        Self.sharedRefreshActor(for: tokenPath)
    }

    private static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        refreshQueueRegistry.queue(for: path)
    }

    func ensureFreshAccessToken(
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        _ = try Self.loadTokenState(path: tokenPath, requestAccount: requestAccount)
        return try await refreshSerial.run { [self] in
            let state = try Self.loadTokenState(path: self.tokenPath, requestAccount: requestAccount)
            let access = state.accessToken
            let shouldRefresh = Self.accessTokenIsExpiring(state, skew: OAuthGrantOperations.renewalMargin)
            guard shouldRefresh else { return access }
            let refreshed = try await self.refreshTokens(state: state, requestAccount: requestAccount)
            return refreshed.accessToken
        }
    }

    private struct TokenState: Sendable {
        var accessToken: String
        var refreshToken: String
        var tokenEndpoint: URL
        /// Hydrated credential bytes whose token-key digest gates refresh writes.
        var bytes: Data
        /// The saved expires_at, read once with the credential.
        var savedExpiry: Date?
    }

    private static func loadTokenState(
        path: URL, requestAccount: OAuthRequestAccount? = nil
    ) throws -> TokenState {
        let obj = try XAIOAuthCredentialStore.read(at: path)
        guard !obj.isEmpty else {
            throw LLMError.notConfigured(provider: "xai_oauth_direct")
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try requestAccount?.check(obj, provider: "xai_oauth_direct")
        let tokenSet = OAuthRefreshBinding.tokenSet(obj, provider: "xai_oauth_direct")
        let access = ((tokenSet["access_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = ((tokenSet["refresh_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !refresh.isEmpty else {
            throw LLMError.notConfigured(provider: "xai_oauth_direct")
        }
        guard let endpoint = tokenEndpoint(in: obj) else {
            throw LLMError.providerError(message: "xai_oauth_direct token endpoint is not on x.ai")
        }
        return TokenState(
            accessToken: access,
            refreshToken: refresh,
            tokenEndpoint: endpoint,
            bytes: data,
            savedExpiry: persistedExpiry(obj)
        )
    }

    private func refreshTokens(state: TokenState, requestAccount: OAuthRequestAccount) async throws -> TokenState {
        let original = try ProviderStateValidation.credential(data: state.bytes)
        try OAuthRefreshBinding.requireRefresh(original, provider: "xai_oauth_direct")
        let body = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": state.refreshToken,
        ]

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await OAuthGrantOperations.post(state.tokenEndpoint, body, session: session)
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw mapTransportError(error, fallback: transientNetworkError(error, operation: "refresh"))
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        if status == 403 {
            throw LLMError.failure(.http(status: status, detail: "xAI refused token renewal; review the account's access in Providers."))
        }
        // Only token rejection requires reconnecting; temporary refresh failures preserve the session.
        let invalidGrant: Bool
        if status == 400 {
            do {
                guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw OAuthGrantOperations.malformedTokenResponse()
                }
                invalidGrant = fields["error"] as? String == "invalid_grant"
            } catch {
                throw LLMError.failure(.http(status: status, detail: "xAI token endpoint returned an unreadable HTTP 400 error; review its account setup."))
            }
        } else { invalidGrant = false }
        if status == 401 || invalidGrant {
            throw LLMError.authRejected(
                provider: "xai_oauth_direct", detail: "xAI rejected token renewal. Reconnect the account in Providers.")
        }
        // Refresh 429 preserves Retry-After.
        if status == 429 {
            throw LLMError.rateLimited(
                message: "xai_oauth_direct refresh HTTP 429 (temporary)",
                retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if (500..<600).contains(status) {
            throw LLMError.transient(
                message: "xai_oauth_direct refresh HTTP \(status) (temporary)")
        }
        guard (200..<300).contains(status) else {
            throw LLMError.underlying(message: "xai_oauth_direct refresh HTTP \(status); review its account setup in Providers.")
        }
        let answer = try OAuthGrantOperations.validateTokenResponse(data, requiringRefreshToken: false)
        let payload = answer.fields
        var updates: [String: Any] = [
            "auth_mode": "oauth",
            "client_id": Self.clientID,
            "access_token": answer.accessToken,
            "last_refresh": NativeTimestampFormat.plainZulu(Date()),
            "discovery": ["token_endpoint": state.tokenEndpoint.absoluteString],
        ]
        if let supplied = payload["token_type"] {
            guard let tokenType = supplied as? String, !tokenType.isEmpty else { throw OAuthGrantOperations.malformedTokenResponse() }
            updates["token_type"] = tokenType
        }
        updates["expires_in"] = answer.expiresIn
        updates["expires_at"] = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }
        if let refresh = answer.refreshToken { updates["refresh_token"] = refresh }
        try OAuthRefreshBinding.requireSameAccount(payload, original: original, provider: "xai_oauth_direct")
        if let idToken = payload["id_token"] as? String {
            updates["id_token"] = idToken
        }
        // Under the shared path lock, compare token-key generations and merge onto current settings. Superseded refreshes skip the write and return a
        // current credential only for the same account.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: state.bytes)
        return try CredentialFileLock.withLock(tokenPath) {
            let current = try XAIOAuthCredentialStore.read(at: tokenPath)
            let currentData = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            guard CredentialFileLock.credentialGeneration(ofFileContents: currentData) == generation else {
                return try Self.loadTokenState(path: tokenPath, requestAccount: requestAccount)
            }
            var object = current
            object.removeValue(forKey: "expires_at")
            object.removeValue(forKey: "expires_in")
            for (key, value) in updates { object[key] = value }
            try Self.writeJSONObject(object, to: tokenPath)
            return try Self.loadTokenState(path: tokenPath)
        }
    }

    // MARK: - Helpers

    private static func normalizeModel(_ model: String) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.modelUnavailable(provider: "xai_oauth_direct", model: model) }
        return trimmed
    }

    private func transientNetworkError(_ error: Error, operation: String) -> LLMError {
        .transient(
            message: """
                \(providerId) \(operation) failed: \
                \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))
                """)
    }

    /// Expiry is the earlier of persisted expires_at and JWT exp, including opaque-token support.
    private static func accessTokenIsExpiring(_ state: TokenState, skew: TimeInterval) -> Bool {
        guard let effective = [jwtExpiry(state.accessToken), state.savedExpiry].compactMap({ $0 }).min() else { return false }
        return effective.timeIntervalSinceNow <= skew
    }

    private static func effectiveExpiry(_ access: String, object: [String: Any]) -> Date? {
        [jwtExpiry(access), persistedExpiry(object)].compactMap { $0 }.min()
    }

    private static func tokenEndpoint(in object: [String: Any]) -> URL? {
        guard let raw = (object["discovery"] as? [String: Any])?["token_endpoint"] as? String else { return nil }
        return URL(string: raw).flatMap { isTrustedXAIURL($0) ? $0 : nil }
    }

    public static func credentialStatus(_ auth: [String: Any]?) -> (usable: Bool, detail: String, health: OAuthCredentialHealth) {
        let object = auth ?? [:]
        let tokens = OAuthRefreshBinding.tokenSet(object, provider: "xai_oauth_direct")
        if OAuthRefreshBinding.hasInvalidExpiry(object, provider: "xai_oauth_direct") {
            return (false, "Saved expires_at is invalid — repair the credential or sign in again",
                OAuthCredentialHealth(configured: false, expiresAt: nil, canRefresh: false))
        }
        let access = OAuthRefreshBinding.string(tokens["access_token"])
        let refresh = OAuthRefreshBinding.string(tokens["refresh_token"])
        let expiry = effectiveExpiry(access ?? "", object: object)
        let canRefresh = refresh != nil && OAuthRefreshBinding.permitsRefresh(object, provider: "xai_oauth_direct")
        let needsRefresh = expiry.map { $0.timeIntervalSinceNow <= OAuthGrantOperations.renewalMargin } ?? false
        let usable = access != nil && refresh != nil && (!needsRefresh || canRefresh)
            && tokenEndpoint(in: object) != nil
        let detail = usable ? (needsRefresh ? "Signed in. Your session will renew on your next chat." : "Signed in")
            : object.isEmpty ? "Sign in to your xAI account in Providers." : "Reconnect your xAI account in Providers."
        return (usable, detail, OAuthCredentialHealth(configured: usable, expiresAt: expiry,
            canRefresh: canRefresh, requiresRefresh: needsRefresh))
    }

    public static func isTrustedXAIURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }

    private static func writeJSONObject(_ obj: [String: Any], to url: URL) throws {
        try XAIOAuthCredentialStore.write(obj, to: url)
    }
}


private func jwtExpiry(_ token: String) -> Date? {
    guard let obj = jwtPayload(token) else { return nil }
    if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
    if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
    return nil
}

/// Expiry parsing is shared across adapters and accepts the persisted ISO and Unix forms.
private func persistedExpiry(_ obj: [String: Any]) -> Date? {
    let raw = obj["expires_at"]
    guard let raw else { return nil }
    return parseExpiresAt(raw)
}
