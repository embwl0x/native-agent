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

    public static func providerAliases() -> Set<String> {
        ["xai_oauth_direct", "xai-oauth", "grok-oauth", "x-ai-oauth", "xai-grok-oauth"]
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
        for attempt in 0...1 {
            let access = try await ensureFreshAccessToken(forceRefresh: attempt == 1)
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
            let parsed = try Self.parseChatCompletion(data: data, status: status)
            let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
            await telemetry.record(
                provider: providerId,
                model: effectiveModel,
                streaming: false,
                usage: LLMUsage.fromOpenAIChatCompletions(parsed.usage),
                ttftMs: nil,
                durationMs: durationMs
            )
            return parsed.text
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
            .compactTextDeltas()
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
                    for attempt in 0...1 {
                        let access = try await self.ensureFreshAccessToken(forceRefresh: attempt == 1)
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
                            var errData = Data()
                            do {
                                for try await byte in bytes {
                                    errData.append(byte)
                                    if errData.count >= 4096 { break }
                                }
                            } catch {}
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
                        for try await sse in SSEEventStream(bytes) {
                            try Task.checkCancellation()
                            let frame = try decoder.consume(payload: sse.data)
                            if frame.isDone { break }
                            if let content = frame.content {
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
                        if !decoder.sawDone {
                            throw LLMError.streamTruncated(message: "xai_oauth_direct stream ended without [DONE]")
                        }
                        for call in decoder.completedToolCalls(idPrefix: "xai_tool") {
                            continuation.yield(.toolCall(LLMStreamToolCall(
                                id: call.id,
                                name: call.name,
                                inputJSON: Data(call.arguments.utf8)
                            )))
                        }
                        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        await telemetry.record(
                            provider: providerId,
                            model: effectiveModel,
                            streaming: true,
                            usage: decoder.usage,
                            ttftMs: ttftMs,
                            durationMs: durationMs
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
        var apiMessages: [[String: Any]] = []
        if let system, !system.isEmpty {
            apiMessages.append(["role": "system", "content": system])
        }
        for message in messages {
            apiMessages.append(contentsOf: try chatMessages(from: message))
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

    private static func chatMessages(from message: LLMMessage) throws -> [[String: Any]] {
        let role = message.role == .user ? "user" : "assistant"
        var contentParts: [[String: Any]] = []
        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []
        var toolMessages: [[String: Any]] = []

        for block in message.content {
            switch block {
            case .text(let text):
                textParts.append(text)
                contentParts.append(["type": "text", "text": text])
            case .image(let mediaType, let base64, _, _):
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(base64)"],
                ])
            case .toolUse(let id, let name, let inputJSON):
                let args = String(data: inputJSON, encoding: .utf8) ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": args],
                ])
            case .toolResult(let toolUseId, let content, _):
                toolMessages.append([
                    "role": "tool",
                    "tool_call_id": toolUseId,
                    "content": content,
                ])
            }
        }

        var out: [[String: Any]] = []
        if !toolCalls.isEmpty {
            var assistant: [String: Any] = [
                "role": "assistant",
                "content": textParts.joined(separator: "\n"),
                "tool_calls": toolCalls,
            ]
            if textParts.isEmpty { assistant["content"] = NSNull() }
            out.append(assistant)
        } else if !contentParts.isEmpty {
            let hasImage = message.content.contains { if case .image = $0 { return true }; return false }
            out.append([
                "role": role,
                "content": hasImage ? contentParts : textParts.joined(separator: "\n"),
            ])
        }
        out.append(contentsOf: toolMessages)
        return out
    }

    private static func parseChatCompletion(data: Data, status: Int) throws -> (text: String, usage: [String: Any]?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        var pieces: [String] = []
        if let content = message["content"] as? String, !content.isEmpty {
            pieces.append(content)
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in calls.enumerated() {
                let id = (call["id"] as? String) ?? "xai_tool_\(index)"
                guard let function = call["function"] as? [String: Any] else { continue }
                let name = (function["name"] as? String) ?? ""
                let args = (function["arguments"] as? String) ?? "{}"
                if !name.isEmpty {
                    pieces.append("<tool_use id=\"\(id)\" name=\"\(name)\">\(args)</tool_use>")
                }
            }
        }
        return (pieces.joined(separator: "\n"), obj["usage"] as? [String: Any])
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

    private func ensureFreshAccessToken(forceRefresh: Bool) async throws -> String {
        try await refreshSerial.run { [self] in
            let state = try Self.loadTokenState(path: self.tokenPath)
            let access = state.accessToken
            let shouldRefresh = forceRefresh || Self.accessTokenIsExpiring(access, skew: Self.tokenExpiryBufferSec)
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
        return TokenState(object: obj, accessToken: access, refreshToken: refresh, tokenEndpoint: endpoint)
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
        if status == 429 || (500..<600).contains(status) {
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
        var object = state.object
        object["auth_mode"] = "oauth_pkce"
        object["client_id"] = Self.clientID
        object["access_token"] = access
        object["refresh_token"] = (payload["refresh_token"] as? String) ?? state.refreshToken
        object["id_token"] = (payload["id_token"] as? String) ?? object["id_token"]
        object["token_type"] = (payload["token_type"] as? String) ?? "Bearer"
        object["last_refresh"] = isoNow()
        if let expiresIn = payload["expires_in"] as? Int {
            object["expires_in"] = expiresIn
            object["expires_at"] = isoBasic(Date().addingTimeInterval(TimeInterval(expiresIn)))
        } else if let expiresInDouble = payload["expires_in"] as? Double {
            object["expires_in"] = expiresInDouble
            object["expires_at"] = isoBasic(Date().addingTimeInterval(expiresInDouble))
        }
        object["discovery"] = [
            "token_endpoint": state.tokenEndpoint.absoluteString,
        ]
        try Self.writeJSONObject(object, to: tokenPath)
        return try Self.loadTokenState(path: tokenPath)
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

    private static func accessTokenIsExpiring(_ token: String, skew: TimeInterval) -> Bool {
        guard let exp = jwtExpiry(token) else { return false }
        return exp.timeIntervalSinceNow <= skew
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

private extension AsyncThrowingStream where Element == LLMMessageStreamEvent, Failure == Error {
    func compactTextDeltas() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await event in self {
                        switch event {
                        case .textDelta(let text):
                            if !text.isEmpty { continuation.yield(text) }
                        case .toolCall, .keepAlive:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
