import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+XAIOAuthDirectAdapter.swift` | xAI request profile, Keychain renewal and account checks |

public let XAIOAuthDirectExhaustedMarker = "xai_oauth_direct_exhausted: re-sign-in required"

/// App-owned xAI credentials authenticate the first-party model route.
public final class XAIOAuthTransport: HTTPProviderProfile {
    public static let toolWire = ProviderToolWire.native
    /// While a run's budget is bound, one request's allowance (`budgetedOutputTokens`) goes in xAI's `max_completion_tokens`; else no cap.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        FirstPartyExecutionControls.budgetedOutputTokens(model: try Self.normalizeModel(model), providerID: providerId, call: call,
            dataRoot: tokenPath.deletingLastPathComponent().deletingLastPathComponent()) ?? 0
    }

    public let providerId: String = "xai_oauth_direct"

    public static let defaultEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")
    public static let clientID = ProviderOAuthConfig.xaiClientID
    let session = ProviderHTTP.session
    private let endpoint = XAIOAuthTransport.defaultEndpoint
    private let tokenPathOverride: URL?
    public let telemetry: LLMCallTraceRecorder

    public init(
        tokenPathOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.tokenPathOverride = tokenPathOverride
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    public static func tokenPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("xai_oauth_direct.json")
    }

    var transport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare, reject: { status, _ in
            if status == 401 { throw LLMError.authRejected(provider: "xai_oauth_direct", detail: XAIOAuthDirectExhaustedMarker) }
        })
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> ChatCompletionsWire {
        let messages = input.messages
        let system = input.system
        let model = input.model
        let tools = input.tools
        let call = input.call
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
            call: call,
            dataRoot: self.tokenPath.deletingLastPathComponent().deletingLastPathComponent()
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return ChatCompletionsWire(request: req, label: "xAI", model: effectiveModel, profile: self, call: call)
    }

    // MARK: - Request body

    static func buildChatCompletionsBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        call: LLMCall,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": try OpenAITransport.chatMessages(messages: messages, system: system),
            "stream": true,
        ]
        // Streaming requests ask for token usage on the final SSE frame.
        body["stream_options"] = ["include_usage": true]
        try OpenAITransport.applyTools(to: &body, tools: tools)
        try FirstPartyExecutionControls.applyXAIControls(to: &body, model: model, call: call, dataRoot: dataRoot)
        if let allowance = FirstPartyExecutionControls.budgetedOutputTokens(model: model, providerID: "xai_oauth_direct", call: call, dataRoot: dataRoot) {
            body["max_completion_tokens"] = allowance
        }
        return body
    }


    // MARK: - Credentials

    private var tokenPath: URL {
        tokenPathOverride ?? Self.tokenPath()
    }

    func ensureFreshAccessToken(requestAccount: OAuthRequestAccount = OAuthRequestAccount()) async throws -> String {
        let path = tokenPath
        return try await OAuthTokenManager.resolve(.file(path), read: {
            try Self.loadTokenState(path: path, requestAccount: requestAccount)
        }, current: { state in
            let expiry = Self.effectiveExpiry(state.accessToken, saved: state.savedExpiry)
            return expiry.map { $0.timeIntervalSinceNow <= OAuthGrantOperations.renewalMargin } == true ? nil : state.accessToken
        }, renew: { [self] state in try await refreshTokens(state: state, requestAccount: requestAccount) })
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

    private func refreshTokens(state: TokenState, requestAccount: OAuthRequestAccount) async throws -> String {
        let original = try ProviderStateValidation.credential(data: state.bytes)
        let answer = try await OAuthTokenManager.exchange(provider: providerId, endpoint: state.tokenEndpoint, client: Self.clientID,
            refresh: state.refreshToken, session: session, original: original)
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
        if let idToken = payload["id_token"] as? String {
            updates["id_token"] = idToken
        }
        return try OAuthTokenManager.commit(path: tokenPath, baseline: state.bytes, provider: providerId,
            account: requestAccount, access: answer.accessToken, read: {
                try Self.loadTokenState(path: tokenPath, requestAccount: requestAccount).bytes
            }) { current in
                var object = try ProviderStateValidation.credential(data: current)
                object.removeValue(forKey: "expires_at")
                object.removeValue(forKey: "expires_in")
                for (key, value) in updates { object[key] = value }
                try XAIOAuthCredentialStore.write(object, to: tokenPath)
            }
    }

    // MARK: - Helpers

    private static func normalizeModel(_ model: String) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.modelUnavailable(provider: "xai_oauth_direct", model: model) }
        return trimmed
    }

    private static func effectiveExpiry(_ access: String, saved: Date?) -> Date? {
        [jwtExpiry(access), saved].compactMap { $0 }.min()
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
        let expiry = effectiveExpiry(access ?? "", saved: persistedExpiry(object))
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
