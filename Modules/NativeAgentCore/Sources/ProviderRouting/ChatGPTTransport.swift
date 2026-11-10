import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ChatGPTTransport.swift` | ChatGPT OAuth request/stream/error execution with conversation or stable workshop-surface cache routing |
// Browser sign-in and token refresh share endpoint-scoped credentials; path serialization prevents duplicate rotations. ChatTurnRuntime owns tool
// authority.

public final class ChatGPTTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// The backend rejects output-cap fields.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId: String = "openai_oauth_direct"

    public static let productionSession: URLSession = ProviderHTTP.makeSession()
    /// The backend requires the official Codex client identity for routing; a neutral originator receives overload failures.
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
    internal let session: URLSession
    private let endpoint: URL?
    internal let refreshEndpoint: URL?
    internal let authPathOverride: URL?
    internal let dataRootOverride: URL?
    internal let openAIPublicClientID: String
    private let telemetry: LLMCallTraceRecorder
    /// Refresh serialization is shared across instances by resolved credential path.
    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        refreshQueueRegistry.queue(for: path)
    }
    public init(
        session: URLSession = ChatGPTTransport.productionSession,
        endpoint: URL? = URL(string: "https://chatgpt.com/backend-api/codex/responses"),
        refreshEndpoint: URL? = URL(string: ProviderOAuthConfig.openai.tokenEndpoint),
        authPathOverride: URL? = nil,
        dataRootOverride: URL? = nil,
        openAIPublicClientID: String = ProviderOAuthConfig.openai.clientId,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.authPathOverride = authPathOverride
        self.dataRootOverride = dataRootOverride
        self.openAIPublicClientID = openAIPublicClientID
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }
    /// Cache routing follows conversation, the sessionless workshop surface, then the call's purpose, then turn; an unbound call has no cache key and never changes store:false.
    static func currentPromptCacheKey(call: LLMCall) -> String? {
        guard let raw = cacheScopeID(call: call) else { return nil }
        return "nativeagent-session-\(raw)"
    }
    /// Sessionless calls on the workshop surface share a cache scope so their common prefix reaches one node across runs; this grants no identity.
    private static func cacheScopeID(call: LLMCall) -> String? {
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
    /// Structured calls must stay paired with results or the model can repeat them indefinitely. Whole replies share SSE decoding, liveness and one
    /// receipt.
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let endpoint else {
                    continuation.finish(throwing: LLMError.providerError(message: "ChatGPT response endpoint is invalid; correct its provider configuration."))
                    return
                }
                // Validate inside the nonthrowing stream factory so an invalid model reaches the caller as a thrown finish.
                let coercedModel: String
                let substitutedFrom: String?
                do {
                    coercedModel = try coerceToGPTModel(model)
                    substitutedFrom = Self.substitutionTrace(
                        requested: model,
                        coerced: coercedModel
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                let requestAccount = OAuthRequestAccount()
                do {
                    try Task.checkCancellation()
                    let access: String
                    do {
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
                        supportedEfforts: accountRow.supportedReasoningEfforts,
                        supportsFast: accountRow.supportsFast, call: call
                    )
                    do {
                        req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [.sortedKeys])
                    } catch {
                        throw LLMError.underlying(message: "encode body: \(error)")
                    }
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
                    if status == 401 {
                        throw exhaustedCredentialError()
                    }
                    if !(200..<300).contains(status) {
                        let body = try await Self.boundedBodyString(from: bytes)
                        try throwIfChatCompletionsError(
                            status: status, data: Data(body.utf8), response: response)
                    }
                    try await Self.consumeResponsesStream(
                        bytes: bytes, request: req, model: coercedModel,
                        providerId: self.providerId, telemetry: self.telemetry,
                        requestStartNs: requestStartNs, substitutedFrom: substitutedFrom,
                        providerLabel: "openai oauth", errorPrefix: "chatgpt-backend",
                        networkError: { self.transientNetworkError($0, endpoint: endpoint, operation: "streamMessages") },
                        continuation: continuation, call: call
                    )
                    continuation.finish()
                    return
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        try await completeMessages(
            messages: [LLMMessage(role: .user, content: [.text(prompt)])],
            system: system, model: model, tools: tools, call: call
        )
    }
    internal func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        .transient(
            message: """
                \(providerId) \(operation) failed for \(endpoint.host ?? "chatgpt.com"): \
                \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))
                """)
    }
    private static func boundedBodyString(
        from bytes: ProviderHTTPBytes,
        maxBytes: Int = 4_096
    ) async throws -> String {
        // One lookahead byte preserves the existing truncation annotation.
        let collected = try await ProviderErrorBodyDrain.read(
            bytes, maxBytes: maxBytes + 1
        )
        var text = String(decoding: collected.prefix(maxBytes), as: UTF8.self)
        if collected.count > maxBytes { text += "\n...(truncated)" }
        return text
    }
    /// Top-level message and nested error envelopes are current backend forms; one decoder preserves their cause across all response paths.
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
    private func coerceToGPTModel(_ requested: String?) throws -> String {
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
        let normalized = SwiftNativeProviderRouting.normalizeModelIdStatic(
            stripped,
            fallback: ""
        )
        if accountModel(normalized) != nil {
            return normalized
        }
        throw LLMError.modelUnavailable(provider: "openai_oauth_direct", model: r)
    }
    /// Record ID normalization so substitution stays visible in telemetry.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
    }
}
