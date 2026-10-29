import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+XAIOAuthDirectAdapter.swift` | `XAIOAuthTransport`: app-owned OAuth token lifecycle and Grok completion/stream transport with shared refresh serialization |

public let XAIOAuthDirectExhaustedMarker = "xai_oauth_direct_exhausted: re-sign-in required"

/// xAI Grok OAuth provider for NativeAgent-owned credentials.
///
/// It authenticates against xAI and calls Grok models at https://api.x.ai/v1.
public final class XAIOAuthTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String = "xai_oauth_direct"

    public static let defaultEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")!
    public static let defaultRefreshEndpoint = URL(string: ProviderOAuthConfig.xaiTokenEndpoint)!
    public static let clientID = ProviderOAuthConfig.xaiClientID
    /// The default is the provider catalog's first row.
    public static var defaultModel: String {
        FirstPartyModelCatalog.models(forProviderID: "xai_oauth_direct").first?.id ?? ""
    }

    private let session: URLSession
    private let endpoint: URL
    private let tokenPathOverride: URL?
    private let telemetry: LLMCallTraceRecorder

    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    public init(
        session: URLSession = .shared,
        endpoint: URL = XAIOAuthTransport.defaultEndpoint,
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
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let messages = [LLMMessage.user(prompt)]
        return try await completeMessages(messages: messages, system: system, model: model, tools: tools)
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // The stream owns the account-bound refresh and the one 401 retry, as a turn's does.
        try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: messages, system: system, model: model, tools: tools))
    }



    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let providerId = self.providerId
        let telemetry = self.telemetry
        let effectiveModel = Self.normalizeModel(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Forced refresh reuses a concurrent rotation instead of spending the refresh token twice.
                    let requestAccount = OAuthRequestAccount()
                    var lastSentAccessToken: String?
                    for attempt in 0...1 {
                        let access = try await self.ensureFreshAccessToken(
                            forceRefresh: attempt == 1, staleToken: lastSentAccessToken, requestAccount: requestAccount)
                        lastSentAccessToken = access
                        var req = URLRequest(url: endpoint)
                        req.httpMethod = "POST"
                        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                        applyStreamingLLMHeaders(to: &req)
                        let body = try Self.buildChatCompletionsBody(
                            model: effectiveModel,
                            messages: messages,
                            system: system,
                            tools: tools,
                            stream: true
                        )
                        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                        let requestStartNs = DispatchTime.now().uptimeNanoseconds
                        let bytes: URLSession.AsyncBytes
                        let response: URLResponse
                        do {
                            (bytes, response) = try await ProviderWire.open(session, req)
                        } catch {
                            throw mapTransportError(error, fallback: self.transientNetworkError(error, operation: "streamMessages"))
                        }
                        defer { bytes.task.cancel() }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401, attempt == 0 { continue }
                        if status == 401 {
                            throw LLMError.authRejected(provider: "xai_oauth_direct", detail: XAIOAuthDirectExhaustedMarker)
                        }
                        try await ProviderWire.validateChatCompletions(bytes, response)
                        var decoder = ChatCompletionsStreamDecoder(providerLabel: "xAI")
                        try await decoder.consume(
                            SSEEventStream(bytes), continuation: continuation,
                            request: req, providerID: providerId, model: effectiveModel, idPrefix: "xai_tool",
                            started: requestStartNs, telemetry: telemetry
                        )
                        continuation.finish()
                        return
                    }
                    throw LLMError.authRejected(
                    provider: "xai_oauth_direct",
                    detail: XAIOAuthDirectExhaustedMarker
                )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request body

    static func buildChatCompletionsBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        stream: Bool
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": OpenAITransport.chatMessages(messages: messages, system: system),
            "stream": stream,
        ]
        // Streaming requests ask for token usage on the final SSE frame.
        if stream { body["stream_options"] = ["include_usage": true] }
        try OpenAITransport.applyTools(to: &body, tools: tools)
        FirstPartyExecutionControls.applyXAIControls(to: &body, model: model)
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
        forceRefresh: Bool,
        staleToken: String? = nil,
        requestAccount: OAuthRequestAccount = OAuthRequestAccount()
    ) async throws -> String {
        _ = try Self.loadTokenState(path: tokenPath, requestAccount: requestAccount, rejectedToken: staleToken)
        return try await refreshSerial.run { [self] in
            let state = try Self.loadTokenState(path: self.tokenPath, requestAccount: requestAccount)
            let access = state.accessToken
            // A forced refresh reuses the on-disk token when another waiter has already rotated it.
            if forceRefresh, let staleToken, !staleToken.isEmpty, access != staleToken {
                return access
            }
            let shouldRefresh = forceRefresh || Self.accessTokenIsExpiring(state, skew: OAuthGrantOperations.renewalMargin)
            guard shouldRefresh else { return access }
            let refreshed = try await self.refreshTokens(state: state, requestAccount: requestAccount)
            return refreshed.accessToken
        }
    }

    private struct TokenState: @unchecked Sendable {
        var object: [String: Any]
        var accessToken: String
        var refreshToken: String
        var tokenEndpoint: URL
        /// Hydrated credential bytes whose token-key digest gates refresh writes.
        var bytes: Data
    }

    private static func loadTokenState(
        path: URL, requestAccount: OAuthRequestAccount? = nil, rejectedToken: String? = nil
    ) throws -> TokenState {
        let obj = try XAIOAuthCredentialStore.read(at: path)
        guard !obj.isEmpty else {
            throw LLMError.notConfigured(provider: "xai_oauth_direct")
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try requestAccount?.check(obj, provider: "xai_oauth_direct", rejectedToken: rejectedToken)
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
            object: obj,
            accessToken: access,
            refreshToken: refresh,
            tokenEndpoint: endpoint,
            bytes: data
        )
    }

    private func refreshTokens(state: TokenState, requestAccount: OAuthRequestAccount) async throws -> TokenState {
        try OAuthRefreshBinding.requireRefresh(state.object, provider: "xai_oauth_direct")
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            throw LLMError.failure(.http(status: status, detail: ProviderFailure.wireDetail(data)))
        }
        // Only token rejection requires reconnecting; temporary refresh failures preserve the session.
        let refreshError = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == 401 || (status == 400 && refreshError?["error"] as? String == "invalid_grant") {
            throw LLMError.authRejected(
                provider: "xai_oauth_direct", detail: Self.boundedBodyString(data))
        }
        // Refresh 429 preserves Retry-After.
        if status == 429 {
            throw LLMError.rateLimited(
                message: "xai_oauth_direct refresh HTTP 429 (temporary): \(Self.boundedBodyString(data))",
                retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if (500..<600).contains(status) {
            throw LLMError.transient(
                message: "xai_oauth_direct refresh HTTP \(status) (temporary): \(Self.boundedBodyString(data))")
        }
        guard (200..<300).contains(status) else {
            throw LLMError.underlying(message: "xai_oauth_direct refresh HTTP \(status): \(Self.boundedBodyString(data))")
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = payload["access_token"] as? String,
              !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.invalidResponse(status: status)
        }
        var updates: [String: Any] = [
            "auth_mode": "oauth_pkce",
            "client_id": Self.clientID,
            "access_token": access,
            "refresh_token": (payload["refresh_token"] as? String) ?? state.refreshToken,
            "token_type": (payload["token_type"] as? String) ?? "Bearer",
            "last_refresh": NativeTimestampFormat.plainZulu(Date()),
            "discovery": ["token_endpoint": state.tokenEndpoint.absoluteString],
        ]
        try OAuthRefreshBinding.requireSameAccount(payload, original: state.object, provider: "xai_oauth_direct")
        if let idToken = payload["id_token"] as? String {
            updates["id_token"] = idToken
        }
        if let expiresIn = payload["expires_in"] as? Int {
            updates["expires_in"] = expiresIn
            updates["expires_at"] = NativeTimestampFormat.basicZulu(Date().addingTimeInterval(TimeInterval(expiresIn)))
        } else if let expiresInDouble = payload["expires_in"] as? Double {
            updates["expires_in"] = expiresInDouble
            updates["expires_at"] = NativeTimestampFormat.basicZulu(Date().addingTimeInterval(expiresInDouble))
        }
        // Under the shared path lock, compare token-key generations and merge onto current settings.
        // Superseded refreshes skip the write and return a current credential only for the same account.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: state.bytes)
        return try CredentialFileLock.withLock(tokenPath) {
            let current = try XAIOAuthCredentialStore.read(at: tokenPath)
            let currentData = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            guard CredentialFileLock.credentialGeneration(ofFileContents: currentData) == generation else {
                return try Self.loadTokenState(path: tokenPath, requestAccount: requestAccount)
            }
            var object = current
            if object["access_token"] == nil && object["refresh_token"] == nil {
                for (key, value) in OAuthRefreshBinding.tokenSet(object, provider: "xai_oauth_direct") { object[key] = value }
                object.removeValue(forKey: "tokens")
            }
            for (key, value) in updates { object[key] = value }
            try Self.writeJSONObject(object, to: tokenPath)
            return try Self.loadTokenState(path: tokenPath)
        }
    }

    // MARK: - Helpers

    private static func normalizeModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private func transientNetworkError(_ error: Error, operation: String) -> LLMError {
        .transient(message: "\(providerId) \(operation) failed for \(endpoint.host ?? "api.x.ai"): \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))")
    }

    /// Expiry is the earlier of persisted expires_at and JWT exp, including opaque-token support.
    private static func accessTokenIsExpiring(_ state: TokenState, skew: TimeInterval) -> Bool {
        guard let effective = effectiveExpiry(state.accessToken, object: state.object) else { return false }
        return effective.timeIntervalSinceNow <= skew
    }

    private static func effectiveExpiry(_ access: String, object: [String: Any]) -> Date? {
        [jwtExpiry(access), persistedExpiry(object)].compactMap { $0 }.min()
    }

    private static func tokenEndpoint(in object: [String: Any]) -> URL? {
        let raw = ((object["discovery"] as? [String: Any])?["token_endpoint"] as? String)
            ?? (object["token_endpoint"] as? String) ?? defaultRefreshEndpoint.absoluteString
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

    private static func boundedBodyString(_ data: Data, limit: Int = 1200) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let clean = redactedErrorBody(raw)
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)) + "... [truncated]"
    }

    private static func redactedErrorBody(_ raw: String) -> String {
        var out = OAuthGrantOperations.redact(raw, bearerReplacement: "Bearer ***")
        if let re = try? NSRegularExpression(
            pattern: #"(?i)"(access_token|refresh_token|id_token|authorization|api_key|token)"\s*:\s*"[^"]+""#
        ) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "\"$1\":\"***\"")
        }
        if let re = try? NSRegularExpression(pattern: #"(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*"#) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "Bearer ***")
        }
        return out
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

/// The `expires_at` this adapter itself persisted on the last refresh, in
/// either the top-level or the PKCE-nested shape. `parseExpiresAt` accepts ISO
/// basic, full ISO (with or without fractional seconds) and unix stamps; it
/// is shared with the other OAuth adapters.
private func persistedExpiry(_ obj: [String: Any]) -> Date? {
    let raw = obj["expires_at"]
        ?? (obj["tokens"] as? [String: Any])?["expires_at"]
    guard let raw else { return nil }
    return parseExpiresAt(raw)
}
