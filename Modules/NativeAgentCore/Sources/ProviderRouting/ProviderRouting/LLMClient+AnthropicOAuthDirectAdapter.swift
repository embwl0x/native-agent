import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import MacNerves
import PersistenceCore
import SenseCore
// Blueprint: | `LLMClient+AnthropicOAuthDirectAdapter.swift` | Anthropic CLI headers, marker streams and credential storage |

// MARK: - AnthropicOAuthTransport
// The OAuth endpoint requires Claude Code identity headers. Path-scoped serialization and credential locking prevent duplicate single-use refreshes and
// coordinate with sign-out/settings.

public final class AnthropicOAuthTransport: HTTPProviderProfile {
    public static let toolWire = ProviderToolWire.textMarkers
    public let providerId: String = "anthropic_oauth_direct"

    public static let productionSession: URLSession = ProviderHTTP.makeSession()

    let session: URLSession
    private let endpoint: URL?
    private let refreshEndpoint: URL?
    /// An injected credential path confines alternate runtimes; production resolves the canonical layout.
    private let authPathOverride: URL?
    private let maxTokensOverride: Int?
    private let clientID: String
    public let telemetry: LLMCallTraceRecorder

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
        // What is left of a run's budget never exceeds the model's effective ceiling, nor this transport's own cap.
        if let allowance = FirstPartyExecutionControls.budgetedOutputTokens(
            model: model, providerID: providerId, call: call, transportCap: maxTokensOverride, dataRoot: catalogRoot) {
            return allowance
        }
        return try FirstPartyExecutionControls.anthropicMaxOutputTokens(
            model: model,
            requestedEffort: call.admission?.reasoningEffort,
            explicitOverride: maxTokensOverride, providerID: providerId, dataRoot: catalogRoot
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
    private static let claudeCLIVersion = "2.1.323"

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

    /// The subscription connection must never carry a native `tools` array (ProviderToolCapability); tools reach Claude here only as prompt text.
    private static func refuseNativeTools(_ tools: [LLMToolSchema]?) throws {
        guard let tools, !tools.isEmpty else { return }
        throw LLMError.providerError(message:
            "anthropic_oauth_direct never receives a native tools[] array (text tool lane only)")
    }

    /// Text-tool streams must refuse native schemas.
    var transport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare, diagnostic: { status, body, _ in
            let reason = ContextSecretContentPolicy.redactedFragment(String(decoding: body.prefix(600), as: UTF8.self))
            ModuleLog(subsystem: "NativeAgent", category: "Anthropic")("oauth HTTP \(status): \(reason)", level: .error)
        }, filter: { stream, input in
            input.system?.contains(Self.textToolProtocolHeader) == true ? Self.endingCallBlock(stream, turn: input.call.turn) : stream
        })
    }

    /// The app ends a text-lane reply. It reads the reply as it arrives and stops passing text on where its call block closes, or where a
    /// call written outside a block ends. A stop mark cannot do this: it is matched on bytes, so it also fires on the same letters inside
    /// a call's own content. Past the end the model is let finish, so the provider's own ending and the usage it carries still arrive;
    /// a model that keeps writing instead is let go.
    package static func endingCallBlock(
        _ source: AsyncThrowingStream<LLMMessageStreamEvent, Error>, turn: Turn?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                // Units written past the end, once the reply has ended.
                var past: Int?
                do {
                    for try await event in source {
                        guard case .textDelta(let delta) = event else { continuation.yield(event); continue }
                        if let written = past {
                            // A model that stops at its block's end says so within a few characters; one that goes on is writing again.
                            past = written + delta.utf16.count
                            if written + delta.utf16.count > 200 { break }
                            continue
                        }
                        text += delta
                        guard let end = ToolCallParser.replyEnd(in: text, appended: delta.count) else { continuation.yield(event); continue }
                        // Cut in the units the end is measured in: a combining mark after the end must not take the character before it.
                        let over = max(0, text.utf16.count - end)
                        let kept = delta.utf16.dropLast(over)
                        if !kept.isEmpty { continuation.yield(.textDelta(String(decoding: Array(kept), as: UTF16.self))) }
                        TurnTraceBus.fireFromContext(kind: "provider.callBlockEnded", payload: .object(["units": .int(Int64(end))]), turn: turn)
                        past = over
                        if over > 200 { break }
                    }
                    continuation.finish()
                } catch {
                    // The reply was whole before the stream failed.
                    if past == nil { continuation.finish(throwing: error) } else { continuation.finish() }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> AnthropicMessagesWire {
        try Self.refuseNativeTools(input.tools)
        let model = try Self.coerceToClaudeModel(input.model)
        let substitutedFrom = substitutionTrace(requested: input.model, coerced: model)
        let messages = input.messages
        let system = input.system
        let call = input.call
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
            stream: true, call: call, dataRoot: catalogRoot
        )
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        Self.dumpBodyIfEnabled(body, call: "streamMessages")

        return AnthropicMessagesWire(request: req, profile: self, model: model, call: call,
            payload: .markers(substitutedFrom: substitutedFrom, cacheMarkers: Self.cacheMarkers(in: body)))
    }

    // MARK: - Auth file resolution + token load

    /// The data root this sign-in's file lives in, where its model list lives too.
    var catalogRoot: URL {
        resolveAuthPath().deletingLastPathComponent().deletingLastPathComponent()
    }

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
        return try await OAuthTokenManager.resolve(.file(path), read: { try Data(contentsOf: path) }, current: { [self] data in
            let object = try ProviderStateValidation.credential(data: data)
            try requestAccount.check(object, provider: providerId)
            guard let (token, expiry) = Self.accessTokenAndExpiry(in: object) else { return nil }
            return expiry.map { $0.timeIntervalSinceNow <= OAuthGrantOperations.renewalMargin } == true ? nil : token
        }, renew: { [self] data in
            try await refreshTokens(at: path, baseline: data, object: ProviderStateValidation.credential(data: data), requestAccount: requestAccount)
        })
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

        let answer = try await OAuthTokenManager.exchange(provider: providerId, endpoint: refreshEndpoint, client: clientID,
            refresh: refreshToken, session: session, original: obj)
        let expiry = answer.expiresIn.map { NativeTimestampFormat.basicZulu(Date().addingTimeInterval($0)) }
        return try OAuthTokenManager.commit(path: path, baseline: baseline, provider: providerId,
            account: requestAccount, access: answer.accessToken, read: { try ProviderStateValidation.dataIfPresent(at: path) }) { current in
            var blob = try ProviderStateValidation.credential(data: current)
            blob["access_token"] = answer.accessToken
            if let refresh = answer.refreshToken { blob["refresh_token"] = refresh }
            blob.removeValue(forKey: "expires_in")
            blob["expires_at"] = expiry
            try saveAuthBlob(blob, to: path)
        }
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
