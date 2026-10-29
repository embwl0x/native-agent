import Foundation
import NativeAgentShared
import os
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `ChatGPTTransport.swift` | ChatGPT OAuth request/stream/error execution with conversation or stable Workshop cache routing |
// Uses endpoint-scoped ChatGPT OAuth credentials with the Codex Responses
// backend. NativeAgent.app owns browser sign-in; this adapter consumes and
// refreshes the persisted tokens. Requests use the shared backend identity
// and the account ID from persisted tokens or the access-token JWT.
// Refreshes are serialized per credential path and persisted atomically.
// ChatTurnRuntime owns tool permission, dispatch, and budgets.

public final class ChatGPTTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String = "openai_oauth_direct"

    public static let productionSession: URLSession = makeProductionSession()
    /// ChatGPT's Codex backend uses the official Codex client identity as a
    /// routing contract, not merely analytics. A neutral NativeAgent
    /// originator currently receives repeatable `server_is_overloaded`
    /// failures for requests that succeed with this exact identity.
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
    private let endpoint: URL
    internal let refreshEndpoint: URL
    internal let authPathOverride: URL?
    internal let dataRootOverride: URL?
    internal let openAIPublicClientID: String
    /// Per-call llm.call telemetry writer.
    private let telemetry: LLMCallTraceRecorder
    /// Refresh serialization is shared across instances by resolved credential path.
    private static let refreshQueueRegistry = OAuthRefreshQueueRegistry()

    static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        refreshQueueRegistry.queue(for: path)
    }
    static func makeProductionSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLSession {
        OAuthProductionSession.make(
            requestTimeout: environment["NATIVE_AGENT_OPENAI_OAUTH_REQUEST_TIMEOUT_SEC"],
            resourceTimeout: environment["NATIVE_AGENT_OPENAI_OAUTH_RESOURCE_TIMEOUT_SEC"]
        )
    }
    public init(
        session: URLSession = ChatGPTTransport.productionSession,
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!,
        refreshEndpoint: URL = URL(string: ProviderOAuthConfig.openai.tokenEndpoint)!,
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
    /// Responses prompt-cache routing key, shared with the session_id header.
    /// A conversation id wins, then the sessionless Workshop scope, then the
    /// turn id. With none of those bound no prompt_cache_key is added.
    /// `store:false` is intentionally NOT flipped.
    static func currentPromptCacheKey() -> String? {
        guard let raw = cacheScopeID() else { return nil }
        return "nativeagent-session-\(raw)"
    }
    /// Conversation identity owns routing when present. Workshop steps have
    /// no transcript session: route their common prefix to one stable scope
    /// across invocations, rather than a new cache node for every run UUID.
    /// This is only a cache hint; it creates no session or execution identity.
    /// Other ephemeral calls reuse their own turn's cache node.
    private static func cacheScopeID() -> String? {
        let workshopScope = WorkshopSurfaceVocabulary.isWorkshopSurface(LLMCallContext.surface ?? "")
            ? "nativeagent-workshop" : nil
        for candidate in [LLMCallContext.sessionId, workshopScope, TurnTraceContext.turnId] {
            if let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }
    /// session_id supplies backend cache-node affinity alongside prompt_cache_key.
    /// Admit only alphanumerics, dash, underscore and dot, at most 128 characters;
    /// no bound cache scope yields nil.
    static func currentSessionRoutingID() -> String? {
        guard let raw = cacheScopeID() else { return nil }
        let safe = raw.unicodeScalars
            .filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "."
            }
            .map(Character.init)
        guard !safe.isEmpty else { return nil }
        return String(safe.prefix(128))
    }
    private func responsesRequest(accessToken: String) throws -> URLRequest {
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
        // Sticky cache-node routing — see currentSessionRoutingID().
        if let sessionRoutingID = Self.currentSessionRoutingID() {
            req.setValue(sessionRoutingID, forHTTPHeaderField: "session_id")
        }
        return req
    }
    /// Returns a fresh Codex/ChatGPT OAuth token plus account id for non-chat
    /// Codex backend calls, such as the image_generation Responses tool.
    /// staleToken identifies the failing request so refresh can reuse a rotation
    /// already completed by another caller.
    public func codexAccessContext(
        forceRefresh: Bool = false,
        staleToken: String? = nil
    ) async throws -> CodexOAuthAccessContext {
        let access = try await ensureFreshAccessToken(
            forceRefresh: forceRefresh, staleToken: staleToken)
        guard let accountID = try currentAccountID(accessToken: access) else {
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
    ///
    /// Whole-reply callers (Telegram, the bridge, background work) ride the
    /// same SSE request and decoder as the chat surface, so the stream guard
    /// sees wire activity as it arrives and one llm.call row is written.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: messages, system: system, model: model, tools: tools)
        )
    }
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Coerce INSIDE the stream task: this is a non-throwing
                // factory, so an unserviceable model id has to reach the
                // caller as a thrown continuation finish rather than as a
                // silently defaulted model (NORTHSTAR clause 2).
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
                var forceTokenRefresh = false
        // Retain the sent token to detect a rotation completed by another caller.
        let requestAccount = OAuthRequestAccount()
        var lastSentAccessToken: String?
                for attempt in 0...1 {
                    do {
                        try Task.checkCancellation()
                        let access: String
                        do {
                            access = try await ensureFreshAccessToken(
                                forceRefresh: forceTokenRefresh,
                                staleToken: lastSentAccessToken, requestAccount: requestAccount
                            )
                            forceTokenRefresh = false
                            lastSentAccessToken = access
                        } catch is CancellationError { throw CancellationError() }
                        catch let err as LLMError { throw err }
                        catch let err as any ProviderFailureWrapping { throw err }
                        catch {
                            throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                                detail: "\(resolveAuthPath().path): \(ProviderFailure.diagnosticDescription(error))")
                        }
                        var req = try responsesRequest(accessToken: access)

                        let accountRow = accountModel(coercedModel)
                        let bodyDict = try Self.buildResponsesBodyFromMessages(
                            model: coercedModel, messages: messages, system: system, tools: tools,
                            supportedEfforts: accountRow?.supportedReasoningEfforts,
                            supportsFast: accountRow?.supportsFast
                        )
                        do {
                            req.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [.sortedKeys])
                        } catch {
                            throw LLMError.underlying(message: "encode body: \(error)")
                        }
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
                        if status == 401 {
                            if attempt == 0 {
                                forceTokenRefresh = true
                                continue
                            }
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
                            continuation: continuation
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
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await completeMessages(
            messages: [LLMMessage(role: .user, content: [.text(prompt)])],
            system: system, model: model, tools: tools
        )
    }
    internal func transientNetworkError(_ error: Error, endpoint: URL, operation: String) -> LLMError {
        .transient(message: "\(providerId) \(operation) failed for \(endpoint.host ?? "chatgpt.com"): \(String(ProviderFailure.diagnosticDescription(error).prefix(400)))")
    }
    private static func boundedBodyString(
        from bytes: URLSession.AsyncBytes,
        maxBytes: Int = 4_096
    ) async throws -> String {
        // One lookahead byte preserves the existing truncation annotation.
        let collected = try await ProviderErrorBodyDrain.read(
            bytes, maxBytes: maxBytes + 1, timeout: 2.0
        )
        var text = String(decoding: collected.prefix(maxBytes), as: UTF8.self)
        if collected.count > maxBytes { text += "\n...(truncated)" }
        return text
    }
    /// ChatGPT currently emits both a legacy top-level `message` and a newer
    /// nested `error` object. `response.failed` places that same object under
    /// `response.error`. Keep one decoder for buffered, streaming, plain, and
    /// structured lanes so one backend envelope change cannot degrade only one
    /// chat surface to an unhelpful "unknown" error.
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
    /// HTTP 200 does not mean the ChatGPT Responses stream succeeded. Preserve
    /// hard auth and rate-limit semantics while classifying explicit capacity
    /// and availability failures as transient so existing surface retry policy
    /// can handle them truthfully.
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
    /// Strip the openai/ namespace and normalize syntax, then admit only a model
    /// in the selected account catalog. Missing or unavailable picks are refused.
    private func coerceToGPTModel(_ requested: String?) throws -> String {
        guard let r = requested?.trimmingCharacters(in: .whitespaces), !r.isEmpty else {
            throw LLMError.modelUnavailable(provider: "openai_oauth_direct", model: "")
        }
        // Strip openai/ namespace.
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
    /// Record a changed requested ID as llm.call's substitutedFrom; unchanged is nil.
    static func substitutionTrace(requested: String?, coerced: String) -> String? {
        guard let r = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return nil
        }
        return r == coerced ? nil : r
    }
}
