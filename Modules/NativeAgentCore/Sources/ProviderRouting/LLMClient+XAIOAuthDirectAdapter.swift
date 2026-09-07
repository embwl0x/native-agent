import Foundation
import NativeAgentCore
import PersistenceCore

public let XAIOAuthDirectExhaustedMarker = "xai_oauth_direct_exhausted: re-sign-in required"

/// xAI Grok OAuth provider for NativeAgent-owned credentials.
///
/// This is independent from Agent's X/Twitter connector. It authenticates
/// against xAI and calls Grok models at https://api.x.ai/v1.
public final class XAIOAuthDirectAdapter: LLMAdapter {
    public let providerId: String = "xai_oauth_direct"

    public static let defaultEndpoint = URL(string: "https://api.x.ai/v1/chat/completions")!
    public static let defaultRefreshEndpoint = URL(string: "https://auth.x.ai/oauth/token")!
    public static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let defaultModel = "grok-4.5"
    static let tokenExpiryBufferSec: TimeInterval = 120

    private let session: URLSession
    private let endpoint: URL
    private let refreshEndpoint: URL
    private let tokenPathOverride: URL?
    private let telemetry: LLMCallTraceRecorder

    nonisolated(unsafe) private static var sharedRefreshActors: [String: AsyncSerialQueue] = [:]
    private static let sharedRefreshActorsLock = NSLock()

    public init(
        session: URLSession = .shared,
        endpoint: URL = XAIOAuthDirectAdapter.defaultEndpoint,
        refreshEndpoint: URL = XAIOAuthDirectAdapter.defaultRefreshEndpoint,
        tokenPathOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.tokenPathOverride = tokenPathOverride
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: telemetryDataRootOverride)
    }

    public static func tokenPath(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> URL {
        dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("xai_oauth_direct.json")
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        let messages = [LLMMessage.user(prompt)]
        return try await completeMessages(messages: messages, system: system, model: model, tools: nil)
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
        let effectiveModel = Self.normalizeModel(model)
        // User, 2026-09-06: the token the last attempt actually sent, handed to the
        // forced refresh so a rotation another caller already performed is taken
        // instead of burning a second single-use refresh_token — N simultaneous 401s
        // otherwise rotated N times and signed the user out.
        var lastSentAccessToken: String?
        for attempt in 0...1 {
            let access = try await ensureFreshAccessToken(
                forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
            lastSentAccessToken = access
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 240
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("NativeAgent (Darwin)", forHTTPHeaderField: "User-Agent")

            let body = try Self.buildChatCompletionsBody(
                model: effectiveModel,
                messages: messages,
                system: system,
                tools: tools,
                stream: false
            )
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let requestStartNs = DispatchTime.now().uptimeNanoseconds
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch {
                throw mapTransportError(error, fallback: transientNetworkError(error, operation: "completeMessages"))
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                if attempt == 0 { continue }
                throw LLMError.authRejected(
                    provider: "xai_oauth_direct",
                    detail: XAIOAuthDirectExhaustedMarker
                )
            }
            if status == 403 {
                throw LLMError.providerError(message: Self.tierDeniedMessage(data: data))
            }
            if status == 429 {
                throw LLMError.rateLimited(message: Self.boundedBodyString(data), retryAfterSeconds: parseRetryAfterSeconds(from: response))
            }
            if (500..<600).contains(status) {
                throw LLMError.transient(message: Self.boundedBodyString(data))
            }
            guard (200..<300).contains(status) else {
                throw LLMError.providerError(message: "xai_oauth_direct HTTP \(status): \(Self.boundedBodyString(data))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMError.invalidResponse(status: status)
            }
            let terminal = Result { try Self.parseChatCompletion(obj: obj, status: status) }
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: effectiveModel,
                streaming: false,
                usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
                ttftMs: nil,
                durationMs: durationMs,
                status: try terminal.chatCompletionsTerminalStatus()
            )
            return try terminal.get().text
        }
        throw LLMError.authRejected(
                    provider: "xai_oauth_direct",
                    detail: XAIOAuthDirectExhaustedMarker
                )
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        streamMessages(messages: [.user(prompt)], system: system, model: model, tools: nil)
            .textDeltas(omittingEmpty: true)
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
                    // User, 2026-09-06: see the sibling note in
                    // completeMessages — the stale token keeps N simultaneous
                    // 401s from rotating the single-use refresh_token N times.
                    var lastSentAccessToken: String?
                    for attempt in 0...1 {
                        let access = try await self.ensureFreshAccessToken(
                            forceRefresh: attempt == 1, staleToken: lastSentAccessToken)
                        lastSentAccessToken = access
                        var req = URLRequest(url: endpoint)
                        req.httpMethod = "POST"
                        req.timeoutInterval = 240
                        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                        applyStreamingLLMHeaders(to: &req)
                        let body = try Self.buildChatCompletionsBody(
                            model: effectiveModel,
                            messages: messages,
                            system: system,
                            tools: tools,
                            stream: true
                        )
                        req.httpBody = try JSONSerialization.data(withJSONObject: body)

                        let requestStartNs = DispatchTime.now().uptimeNanoseconds
                        let bytes: URLSession.AsyncBytes
                        let response: URLResponse
                        do {
                            (bytes, response) = try await session.bytes(for: req)
                        } catch {
                            throw mapTransportError(error, fallback: self.transientNetworkError(error, operation: "streamMessages"))
                        }
                        defer { bytes.task.cancel() }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 401, attempt == 0 { continue }
                        if status == 401 { throw LLMError.authRejected(
                    provider: "xai_oauth_direct",
                    detail: XAIOAuthDirectExhaustedMarker
                ) }
                        if status == 403 { throw LLMError.providerError(message: "xAI OAuth account is not authorized for this Grok API surface. Switch to xAI API-key provider if needed.") }
                        if status == 429 { throw LLMError.rateLimited(message: "xAI rate limited", retryAfterSeconds: parseRetryAfterSeconds(from: response)) }
                        if !(200..<300).contains(status) {
                            // 2026-07-21 audit: drain + preserve the (redacted)
                            // provider error body and map 5xx → .transient — the
                            // non-streaming path's deliberate retryable policy.
                            // The guard previously discarded the body and threw
                            // terminal .invalidResponse. 4KB drain mirrors the
                            // Anthropic stream's error-body preservation.
                            let errData = try await ProviderErrorBodyDrain.read(
                                bytes, maxBytes: 4096, timeout: 2.0
                            )
                            if (500..<600).contains(status) {
                                throw LLMError.transient(message: Self.boundedBodyString(errData))
                            }
                            throw LLMError.providerError(
                                message: "xai_oauth_direct HTTP \(status): \(Self.boundedBodyString(errData))"
                            )
                        }

                        var ttftMs: Int?
                        // C1: shared decoder owns framing — [DONE] tracking,
                        // root error frames (now surfaced as providerError
                        // instead of a masking streamTruncated), usage capture,
                        // and tool_call accumulation. This loop keeps only
                        // xAI's yield policy: ttft stamping and a keepAlive on a
                        // terminal finish_reason.
                        var decoder = ChatCompletionsStreamDecoder(providerLabel: "xAI")
                        var sawContent = false
                        for try await sse in SSEEventStream(bytes) {
                            try Task.checkCancellation()
                            let frame = try decoder.consume(payload: sse.data)
                            if frame.isDone { break }
                            // User, 2026-09-06: reasoning frames and tool-argument
                            // fragments are model output that yields no text, and
                            // this loop signalled liveness only on content and a
                            // terminal finish_reason — so ProviderStreamGuard's
                            // idle clock saw nothing and cut a stream that was
                            // thinking or assembling arguments. Parity with the
                            // Moonshot and OpenRouter loops on the same decoder.
                            if frame.reasoning != nil { continuation.yield(.keepAlive) }
                            for _ in 0..<frame.toolCallDeltaCount { continuation.yield(.keepAlive) }
                            if let content = frame.content {
                                sawContent = true
                                if ttftMs == nil {
                                    ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                                }
                                continuation.yield(.textDelta(content))
                            }
                            if let finish = frame.finishReason,
                               finish == "tool_calls" || finish == "stop" {
                                continuation.yield(.keepAlive)
                            }
                        }
                        // User, 2026-09-06: `[DONE]` with no content and no tool
                        // calls was accepted as success — the same empty-and-
                        // silent turn OpenAI and OpenRouter reject.
                        let terminal = Result {
                            try decoder.finalizedToolCalls(
                                idPrefix: "xai_tool", providerID: "xai_oauth_direct", sawContent: sawContent
                            )
                        }
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await telemetry.record(
                            provider: providerId,
                            model: effectiveModel,
                            streaming: true,
                            usage: decoder.usage,
                            ttftMs: ttftMs,
                            durationMs: durationMs,
                            status: try terminal.chatCompletionsTerminalStatus()
                        )
                        let completedCalls = try terminal.get()
                        for call in completedCalls {
                            continuation.yield(.toolCall(LLMStreamToolCall(
                                id: call.id,
                                name: call.name,
                                inputJSON: Data(call.arguments.utf8)
                            )))
                        }
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
        var apiMessages: [[String: Any]] = []
        if let system, !system.isEmpty {
            apiMessages.append(["role": "system", "content": system])
        }
        for message in messages {
            apiMessages.append(contentsOf: chatCompletionsMessages(from: message))
        }
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": stream,
        ]
        // R-L1: request usage on the final SSE frame so streaming telemetry
        // carries token counts (mirrors OpenAI/Moonshot). The stream loop
        // already records decoder.usage; without this the body never asked for
        // it, so xAI streaming token telemetry was always nil.
        if stream { body["stream_options"] = ["include_usage": true] }
        if let tools, !tools.isEmpty {
            body["tools"] = try tools.map { schema in
                let parameters = try JSONSerialization.jsonObject(with: schema.parametersJSON)
                return [
                    "type": "function",
                    "function": [
                        "name": schema.name,
                        "description": schema.description,
                        "parameters": parameters,
                    ],
                ]
            }
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        FirstPartyExecutionControls.applyXAIControls(to: &body, model: model)
        return body
    }


    private static func parseChatCompletion(obj: [String: Any], status: Int) throws -> (text: String, usage: [String: Any]?) {
        let message = try chatCompletionsMessage(obj, status: status)
        // User, 2026-09-06: all-or-nothing on the tool set, same as the streams
        // — the loop used to `continue` past an entry it could not execute and
        // emit its siblings, which is half a plan the model wrote as one
        // decision.
        let toolSet = finalizeChatCompletionsToolCalls(
            message["tool_calls"] as? [[String: Any]] ?? [],
            idPrefix: "xai_tool"
        )
        // User, 2026-09-06: an empty reply used to come back as "" and reach the
        // chat as a blank turn. The streaming lanes call that
        // `.streamTruncated`; this one does now too, and the ladder can retry.
        let reply = try chatCompletionsReply(
            content: (message["content"] as? String) ?? "",
            toolCalls: toolSet.calls, incompleteNote: toolSet.incompleteNote, provider: "xai_oauth_direct"
        )
        return (reply, obj["usage"] as? [String: Any])
    }

    // MARK: - Credentials

    private var tokenPath: URL {
        tokenPathOverride ?? Self.tokenPath()
    }

    private var refreshSerial: AsyncSerialQueue {
        Self.sharedRefreshActor(for: tokenPath)
    }

    private static func sharedRefreshActor(for path: URL) -> AsyncSerialQueue {
        sharedRefreshActorsLock.lock()
        defer { sharedRefreshActorsLock.unlock() }
        let key = path.standardizedFileURL.path
        if let actor = sharedRefreshActors[key] { return actor }
        let actor = AsyncSerialQueue()
        sharedRefreshActors[key] = actor
        return actor
    }

    /// True when a signed-in xAI OAuth credential is on disk at this adapter's
    /// own path (User, 2026-09-06 — see `OAuthCredentialPresence`).
    var hasStoredOAuthCredential: Bool {
        (try? Self.loadTokenState(path: tokenPath)) != nil
    }

    private func ensureFreshAccessToken(
        forceRefresh: Bool,
        staleToken: String? = nil
    ) async throws -> String {
        try await refreshSerial.run { [self] in
            let state = try Self.loadTokenState(path: self.tokenPath)
            let access = state.accessToken
            // User, 2026-09-06: a forced refresh used to rotate unconditionally,
            // so N simultaneous 401s each rotated in turn and every rotation
            // invalidated the single-use refresh_token the next waiter was
            // about to spend — a burst of parallel requests signed the user
            // out. A forced refresh whose on-disk token has already moved past
            // the one the failing request sent takes the new token instead.
            if forceRefresh, let staleToken, !staleToken.isEmpty, access != staleToken {
                return access
            }
            let shouldRefresh = forceRefresh || Self.accessTokenIsExpiring(state, skew: Self.tokenExpiryBufferSec)
            guard shouldRefresh else { return access }
            let refreshed = try await self.refreshTokens(state: state)
            return refreshed.accessToken
        }
    }

    private struct TokenState: @unchecked Sendable {
        var object: [String: Any]
        var accessToken: String
        var refreshToken: String
        var tokenEndpoint: URL
        /// User, 2026-09-06: the bytes this state was read from. Only their
        /// token-key digest (`CredentialFileLock.credentialGeneration`) is the
        /// generation the refresh write is allowed to replace — the rest of
        /// the file is provider settings that other writers own.
        var bytes: Data
    }

    private static func loadTokenState(path: URL) throws -> TokenState {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.notConfigured(provider: "xai_oauth_direct")
        }
        let access = ((obj["access_token"] as? String)
            ?? ((obj["tokens"] as? [String: Any])?["access_token"] as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = ((obj["refresh_token"] as? String)
            ?? ((obj["tokens"] as? [String: Any])?["refresh_token"] as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !refresh.isEmpty else {
            throw LLMError.notConfigured(provider: "xai_oauth_direct")
        }
        let endpointRaw = ((obj["discovery"] as? [String: Any])?["token_endpoint"] as? String)
            ?? (obj["token_endpoint"] as? String)
            ?? Self.defaultRefreshEndpoint.absoluteString
        guard let endpoint = URL(string: endpointRaw),
              Self.isTrustedXAIURL(endpoint) else {
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

    private func refreshTokens(state: TokenState) async throws -> TokenState {
        var req = URLRequest(url: state.tokenEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formEncode([
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": state.refreshToken,
        ]).data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw transientNetworkError(error, operation: "refresh")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            throw LLMError.providerError(message: Self.tierDeniedMessage(data: data))
        }
        // A3.5: classify refresh failures instead of blanket "revoked". A 401
        // means the refresh token itself was rejected → genuinely revoked
        // (reconnect). A 429/5xx is a provider-side hiccup → transient: keep the
        // session so a stranger isn't told to reconnect over a temporary blip.
        if status == 401 {
            throw LLMError.authRejected(
                provider: "xai_oauth_direct", detail: Self.boundedBodyString(data))
        }
        // User, 2026-09-06: preserve `Retry-After` on a refresh 429 the way the
        // chat call path does — see the Anthropic sibling.
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
            "last_refresh": isoNow(),
            "discovery": ["token_endpoint": state.tokenEndpoint.absoluteString],
        ]
        if let idToken = payload["id_token"] as? String {
            updates["id_token"] = idToken
        }
        if let expiresIn = payload["expires_in"] as? Int {
            updates["expires_in"] = expiresIn
            updates["expires_at"] = isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))
        } else if let expiresInDouble = payload["expires_in"] as? Double {
            updates["expires_in"] = expiresInDouble
            updates["expires_at"] = isoBasic(Date().addingTimeInterval(expiresInDouble))
        }
        // User, 2026-09-06: sign-out (which deletes this file) and a fresh
        // sign-in (which replaces it) do not go through the adapter's refresh
        // queue, so writing unconditionally resurrected a removed credential
        // or clobbered a newer one. The bytes read before the network call are
        // the generation; a refresh whose generation moved skips its write and
        // hands back whatever credential now owns the file.
        // User, 2026-09-06: the comparison and the write it guards now sit in
        // ONE critical section on the credential path's shared lock, which the
        // app's sign-in and sign-out take too — a compare followed by an
        // unguarded write still lost every sign-out that landed between them.
        // User, 2026-09-06: the generation is a digest of the TOKEN keys, not
        // the file's bytes. `configureProvider` writes `default_model` into
        // this same file, so saving provider settings during a refresh moved
        // the bytes and made the refresh discard the token it had just
        // rotated — burning the single-use refresh_token on disk. For the same
        // reason the refreshed fields are merged onto what is on disk NOW, so
        // a concurrent settings save survives the refresh's write.
        let generation = CredentialFileLock.credentialGeneration(ofFileContents: state.bytes)
        return try CredentialFileLock.withLock(tokenPath) {
            guard CredentialFileLock.credentialGeneration(ofFileAt: tokenPath) == generation else {
                return try Self.loadTokenState(path: tokenPath)
            }
            var object = (try? Data(contentsOf: tokenPath))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? state.object
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
        let host = endpoint.host ?? "api.x.ai"
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut:
                return .transient(message: "xai_oauth_direct \(operation) timed out: \(host)")
            case .notConnectedToInternet:
                return .transient(message: "xai_oauth_direct \(operation) not connected to internet")
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
                return .transient(message: "xai_oauth_direct \(operation) network error for \(host): \(nsError.code)")
            default:
                break
            }
        }
        return .transient(message: "xai_oauth_direct \(operation) network error for \(host): \(error)")
    }

    /// User, 2026-09-06: consult the PERSISTED `expires_at` as well as the JWT
    /// `exp`. xAI also issues opaque access tokens, and for those `jwtExpiry`
    /// returns nil — the token was then treated as never expiring, so the
    /// adapter never refreshed proactively and every turn paid a 401 round
    /// trip (and a turn that had already spent its one retry just failed).
    /// The earlier of the two wins when both are present, so an out-of-band
    /// rotation cannot leave a token being served past its real expiry.
    private static func accessTokenIsExpiring(_ state: TokenState, skew: TimeInterval) -> Bool {
        let jwt = jwtExpiry(state.accessToken)
        let persisted = persistedExpiry(state.object)
        let effective: Date? = {
            switch (jwt, persisted) {
            case let (.some(a), .some(b)): return min(a, b)
            case let (.some(a), .none):    return a
            case let (.none, .some(b)):    return b
            case (.none, .none):           return nil
            }
        }()
        guard let effective else { return false }
        return effective.timeIntervalSinceNow <= skew
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

    private static func tierDeniedMessage(data: Data) -> String {
        "xAI OAuth account is not authorized for this Grok API surface. xAI may require a different SuperGrok/X Premium+ tier. Response: \(boundedBodyString(data))"
    }

    private static func redactedErrorBody(_ raw: String) -> String {
        var out = raw
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
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}


private func formEncode(_ params: [String: String]) -> String {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    return params.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
}

private func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var body = String(parts[1])
    while body.count % 4 != 0 { body.append("=") }
    body = body.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: body),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let exp = obj["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
    if let exp = obj["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
    return nil
}

/// The `expires_at` this adapter itself persisted on the last refresh, in
/// either the top-level or the PKCE-nested shape. `parseExpiresAt` accepts ISO
/// basic, full ISO (with or without fractional seconds) and unix stamps; it
/// lives on the Anthropic adapter but is a plain date parser with nothing
/// provider-specific in it (User, 2026-09-06).
private func persistedExpiry(_ obj: [String: Any]) -> Date? {
    let raw = obj["expires_at"]
        ?? (obj["tokens"] as? [String: Any])?["expires_at"]
    guard let raw else { return nil }
    return AnthropicOAuthDirectAdapter.parseExpiresAt(raw)
}

private func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

private func isoBasic(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
}
