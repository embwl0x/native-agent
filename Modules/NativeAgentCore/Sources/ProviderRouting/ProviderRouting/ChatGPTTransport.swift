import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `ChatGPTTransport.swift` | ChatGPT OAuth request/stream/error execution with conversation or stable workshop-surface cache routing |
// Browser sign-in and token refresh share endpoint-scoped credentials; path serialization prevents duplicate rotations. ChatTurnRuntime owns tool
// authority.

public final class ChatGPTTransport: HTTPProviderProfile {
    public static let toolWire = ProviderToolWire.native
    /// The backend rejects output-cap fields.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId: String = "openai_oauth_direct"

    public static let productionSession: URLSession = ProviderHTTP.makeSession()
    /// The backend requires the official Codex client identity for routing; a neutral originator receives overload failures.
    public static let codexBackendOriginator = "codex_cli_rs"
    public static let codexClientVersion = "0.169.0"
    /// The model list's client version asks for rows above the checked wire version.
    static let codexModelListVersion = "99.0.0"
    public static var codexBackendUserAgent: String {
        let rawVersion =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "source"
        let safeVersion = rawVersion.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
        }
        let nativeAgentVersion = safeVersion.isEmpty ? "source" : safeVersion
        return "\(codexBackendOriginator)/\(codexClientVersion) NativeAgent/\(nativeAgentVersion)"
    }
    internal let session: URLSession
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")
    internal let refreshEndpoint = URL(string: ProviderOAuthConfig.openai.tokenEndpoint)
    internal let authPathOverride: URL?
    internal let dataRootOverride: URL?
    internal let openAIPublicClientID = ProviderOAuthConfig.openai.clientId
    public let telemetry: LLMCallTraceRecorder
    public init(
        session: URLSession = ChatGPTTransport.productionSession,
        authPathOverride: URL? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.authPathOverride = authPathOverride
        self.dataRootOverride = dataRootOverride
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }
    static func currentPromptCacheKey(call: LLMCall) -> String? {
        guard let raw = cacheScopeID(call: call) else { return nil }
        return call.memoryPolicyScope == nil ? "nativeagent-session-\(raw)" : raw
    }
    /// Sessionless calls on the workshop surface share a cache scope so their common prefix reaches one node across runs; this grants no identity.
    private static func cacheScopeID(call: LLMCall) -> String? {
        if let policy = call.memoryPolicyScope { return "nativeagent-policy-\(policy.rawValue)" }
        let workshopScope = WorkshopSurfaceVocabulary.isWorkshopSurface(call.surface)
            ? "nativeagent-workshop" : nil
        // Sessionless calls of one purpose send one prompt policy, so they share a scope and its unchanging text is cached across calls.
        for candidate in [call.session, workshopScope, call.purpose.isEmpty ? nil : "purpose-" + call.purpose, call.turn?.id] {
            if let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }
    /// Bound cache affinity admits only alphanumerics, dash, underscore and dot, capped at 128 characters.
    static func currentSessionRoutingID(call: LLMCall) -> String? {
        guard let raw = cacheScopeID(call: call) else { return nil }
        let safe = raw.unicodeScalars
            .filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "."
            }
            .map(Character.init)
        guard !safe.isEmpty else { return nil }
        return String(safe.prefix(128))
    }
    private func responsesRequest(endpoint: URL, accessToken: String, call: LLMCall) throws -> URLRequest {
        guard let accountID = try currentAccountID(accessToken: accessToken) else {
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
        // Keep header affinity aligned with the prompt-cache routing key.
        if let sessionRoutingID = Self.currentSessionRoutingID(call: call) {
            req.setValue(sessionRoutingID, forHTTPHeaderField: "session_id")
        }
        return req
    }
    public func codexAccessContext() async throws -> CodexOAuthAccessContext {
        let access = try await ensureFreshAccessToken()
        guard let accountID = try currentAccountID(accessToken: access) else {
            throw LLMError.notConfigured(provider: "openai_oauth_direct")
        }
        return CodexOAuthAccessContext(
            accessToken: access,
            accountID: accountID,
            authPath: resolveAuthPath()
        )
    }

    var transport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare, reject: { [self] status, _ in
            if status == 401 { throw exhaustedCredentialError() }
        })
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> ResponsesWire {
        let messages = input.messages
        let system = input.system
        let model = input.model
        let tools = input.tools
        let call = input.call
        guard let endpoint else {
            throw LLMError.providerError(message: "ChatGPT response endpoint is invalid; correct its provider configuration.")
        }
        let coercedModel = try coerceToGPTModel(model, preview: call.preview)
        let substitutedFrom = substitutionTrace(requested: model, coerced: coercedModel)
        let requestAccount = OAuthRequestAccount()
        let access: String
        do {
            try Task.checkCancellation()
            access = try await ensureFreshAccessToken(
                requestAccount: requestAccount
            )
        } catch is CancellationError { throw CancellationError() }
        catch let err as LLMError { throw err }
        catch let err as any ProviderFailureWrapping { throw err }
        catch {
            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                detail: "\(resolveAuthPath().path): \(ProviderFailure.diagnosticDescription(error))")
        }
        var req = try responsesRequest(endpoint: endpoint, accessToken: access, call: call)

        guard let accountRow = accountModel(coercedModel, preview: call.preview) else {
            throw LLMError.providerError(
                message: "The selected ChatGPT account's controls for \(coercedModel) are unavailable. Refresh its models in Providers.")
        }
        let bodyDict = try Self.buildResponsesBodyFromMessages(
            model: coercedModel, messages: messages, system: system, tools: tools,
            supportedEfforts: accountRow.supportedReasoningEfforts, ultraEffort: accountRow.ultraEffort,
            supportsFast: accountRow.supportsFast, call: call
        )
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [.sortedKeys])
        } catch {
            throw LLMError.underlying(message: "encode body: \(error)")
        }
        return ResponsesWire(request: req, model: coercedModel, profile: self, call: call, label: "openai oauth",
            errorPrefix: "chatgpt-backend", substitutedFrom: substitutedFrom)
    }

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
    /// HTTP 200 can carry a failed response; preserve auth, rate-limit and capacity evidence for typed recovery.
    static func classifiedBackendError(_ description: String) -> ProviderFailure.Diagnostic {
        .init(cause: ProviderFailure.wire(description), detail: description)
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
    /// Only the selected account's catalog can admit a normalized model ID.
    private func coerceToGPTModel(_ requested: String?, preview: Bool) throws -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespaces), !r.isEmpty else {
            throw LLMError.modelUnavailable(provider: "openai_oauth_direct", model: "")
        }
        let stripped: String = {
            if r.lowercased().hasPrefix("openai/") {
                return String(r.dropFirst("openai/".count))
            }
            return r
        }()
        // Empty normalization sentinel keeps invalid IDs from becoming a model pick.
        let normalized = SwiftNativeProviderRouting.normalizeModelIdStatic(stripped)
        if accountModel(normalized, preview: preview) != nil {
            return normalized
        }
        throw LLMError.modelUnavailable(provider: "openai_oauth_direct", model: r)
    }
}
