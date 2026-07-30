import Foundation
import NativeAgentCore
import PersistenceCore

/// OpenAI Chat Completions adapter. URLSession is injectable for tests.
public final class OpenAIAdapter: LLMAdapter {
    public let providerId: String = "openai"
    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    /// When non-nil, credential discovery is confined to this data root.
    /// Production callers may leave it nil to preserve dynamic default-root
    /// resolution; tests and secondary runtimes must inject their own root.
    private let dataRootOverride: URL?
    /// U1 step 1 — per-call llm.call telemetry writer (override is test-only).
    /// The SSE path records timing-only rows (durationMs + ttftMs, nil token
    /// fields): receiving usage on-stream would need a `stream_options`
    /// request change, which violates the step-1 zero-behavior-change
    /// constraint.
    private let telemetry: LLMCallTraceRecorder

    private var credentialRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    private var includesProcessEnvironmentCredentials: Bool {
        dataRootOverride == nil
            || credentialRoot.standardizedFileURL
                == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        apiKeyOverride: String? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.dataRootOverride = dataRootOverride
        // A custom provider root defines a secondary/test runtime boundary.
        // Telemetry belongs to that same body unless a still-more-specific
        // telemetry root is injected; otherwise a hermetic provider call can
        // silently append traces to User's live default root.
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: "OPENAI_API_KEY",
                    providerConfigFile: "openai.json",
                    dataRoot: credentialRoot,
                    includeEnvironment: includesProcessEnvironmentCredentials),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: "openai")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if let sys = system, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // Cancellation MUST propagate as CancellationError so the
            // SwiftNativeWorkshopRunner (and any other structured-concurrency
            // caller) can distinguish a cancelled request from a real network
            // failure. URLSession surfaces cancellation as
            // NSURLErrorDomain + NSURLErrorCancelled (R-M2: shared helper).
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try throwIfChatCompletionsError(status: status, data: data, mapping: Self.statusMapping, response: response)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse(status: status)
        }
        // U1 step 1: token/cache usage telemetry (non-fatal, numbers only).
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return content
    }

    // MARK: - Structured messages (native vision)

    /// Native-vision `completeMessages` override for the Chat Completions API.
    /// The api-key OpenAI path is a fallthrough in the user's OAuth setup, but we
    /// wire real vision here too so no provider/credential combo silently loses
    /// images.
    ///
    /// BYTE-IDENTITY: when no `.image` block is present we DELEGATE to the same
    /// flatten → `complete(prompt:)` the default produced, keeping the text-only
    /// body byte-identical. We only build a multi-part content body when an
    /// image is present.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let hasImage = messages.contains { m in
            m.content.contains { if case .image = $0 { return true }; return false }
        }
        guard hasImage else {
            // Text-only: reproduce the LLMAdapter default flatten EXACTLY.
            var parts: [String] = []
            for m in messages {
                let prefix = m.role == .user ? "USER:" : "ASSISTANT:"
                for block in m.content {
                    switch block {
                    case .text(let t):
                        parts.append("\(prefix) \(t)")
                    case .toolUse(_, let name, let inputJSON):
                        let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                        parts.append("\(prefix) [tool_use \(name) \(argsStr)]")
                    case .toolResult(_, let content, _):
                        parts.append("\(prefix) [tool_result] \(content)")
                    case .image:
                        break  // unreachable: hasImage == false here
                    }
                }
            }
            let combined = parts.joined(separator: "\n")
            return try await complete(prompt: combined, system: system, model: model)
        }

        guard let key = apiKeyOverride
                ?? LLMCredentialResolver.resolveAPIKey(
                    envVar: "OPENAI_API_KEY",
                    providerConfigFile: "openai.json",
                    dataRoot: credentialRoot,
                    includeEnvironment: includesProcessEnvironmentCredentials),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: "openai")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Chat Completions multi-part content: image_url parts (data-URL
        // object) FIRST, then a text part. text-only messages keep the plain
        // string content form so non-image turns in a mixed conversation are
        // unchanged.
        var apiMessages: [[String: Any]] = []
        if let sys = system, !sys.isEmpty {
            apiMessages.append(["role": "system", "content": sys])
        }
        for m in messages {
            let role = m.role == .user ? "user" : "assistant"
            let hasImg = m.content.contains { if case .image = $0 { return true }; return false }
            if hasImg {
                var contentParts: [[String: Any]] = []
                for block in m.content {
                    switch block {
                    case .image(let mediaType, let base64, _, _):
                        contentParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mediaType);base64,\(base64)"],
                        ])
                    case .text(let t):
                        contentParts.append(["type": "text", "text": t])
                    case .toolUse(_, let name, let inputJSON):
                        let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                        contentParts.append(["type": "text", "text": "[tool_use \(name) \(argsStr)]"])
                    case .toolResult(_, let content, _):
                        contentParts.append(["type": "text", "text": "[tool_result] \(content)"])
                    }
                }
                apiMessages.append(["role": role, "content": contentParts])
            } else {
                // Non-image message: flatten ALL blocks (text + tool blocks) to
                // a single string content. Mirrors the api-key Anthropic adapter
                // so a tool_use/tool_result message later in an image-bearing
                // conversation is NOT silently dropped.
                var parts: [String] = []
                for block in m.content {
                    switch block {
                    case .text(let t):
                        parts.append(t)
                    case .toolUse(_, let name, let inputJSON):
                        let argsStr = String(data: inputJSON, encoding: .utf8) ?? "{}"
                        parts.append("[tool_use \(name) \(argsStr)]")
                    case .toolResult(_, let content, _):
                        parts.append("[tool_result] \(content)")
                    case .image:
                        break  // unreachable: this is the no-image branch
                    }
                }
                apiMessages.append(["role": role, "content": parts.joined(separator: "\n")])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
        ]
        OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try throwIfChatCompletionsError(status: status, data: data, mapping: Self.statusMapping, response: response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse(status: status)
        }
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return content
    }

    // MARK: - Streaming (SSE)

    /// OpenAI Chat Completions in streaming mode. Parses SSE frames of shape:
    ///   data: {"choices":[{"delta":{"content":"..."}}]}
    ///   data: [DONE]
    /// Yields delta.content strings only. Skips empty deltas and role-only
    /// frames; ignores tool_calls (those route through ToolLoop).
    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let apiKeyOverride = self.apiKeyOverride
        let credentialRoot = self.credentialRoot
        let includesProcessEnvironmentCredentials = self.includesProcessEnvironmentCredentials
        let telemetry = self.telemetry
        let providerId = self.providerId
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let key = apiKeyOverride
                        ?? LLMCredentialResolver.resolveAPIKey(
                            envVar: "OPENAI_API_KEY",
                            providerConfigFile: "openai.json",
                            dataRoot: credentialRoot,
                            includeEnvironment: includesProcessEnvironmentCredentials),
                      !key.isEmpty else {
                    continuation.finish(throwing: LLMError.notConfigured(provider: "openai"))
                    return
                }

                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                applyStreamingLLMHeaders(to: &req)

                var messages: [[String: String]] = []
                if let sys = system, !sys.isEmpty {
                    messages.append(["role": "system", "content": sys])
                }
                messages.append(["role": "user", "content": prompt])
                var body: [String: Any] = [
                    "model": model,
                    "messages": messages,
                    "stream": true,
                    // B8: request usage on the final SSE frame so the streaming
                    // telemetry row carries token counts (Moonshot already does
                    // this; the api-key OpenAI path was the last usage gap).
                    "stream_options": ["include_usage": true],
                ]
                OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model)
                do {
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: LLMError.underlying(message: "encode: \(error)"))
                    return
                }

                let requestStartNs = DispatchTime.now().uptimeNanoseconds
                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: req)
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")")))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200..<300).contains(status) {
                    // 2026-07-21 audit: drain + preserve the provider error body
                    // and route through the SAME mapping as the non-streaming
                    // path (throwIfChatCompletionsError) — a streaming 5xx is
                    // .transient (retryable), not terminal .invalidResponse.
                    // 4KB drain mirrors the Anthropic stream's body preservation.
                    var errData = Data()
                    do {
                        for try await byte in bytes {
                            errData.append(byte)
                            if errData.count >= 4096 { break }
                        }
                    } catch {}
                    do {
                        try throwIfChatCompletionsError(status: status, data: errData, mapping: Self.statusMapping, response: response)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }

                do {
                    // U1 step 1 (review fix 2026-06-10) — streaming telemetry:
                    // TTFT stamped at the first yielded content delta.
                    var ttftMs: Int?
                    // C1: shared decoder owns framing semantics — [DONE]
                    // tracking, root error frames (B2: previously an error
                    // frame's missing `choices` was swallowed → wrong-cause
                    // streamTruncated), and usage capture (B8). This loop keeps
                    // only OpenAI's text-only yield policy.
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
                    var sawContent = false
                    for try await sse in SSEEventStream(bytes) {
                        try Task.checkCancellation()
                        let frame = try decoder.consume(payload: sse.data)
                        if frame.isDone { break }
                        if frame.reasoning != nil {
                            // Liveness (2026-07-21 audit; parity with the Moonshot
                            // event-stream keepAlive): reasoning_content frames are
                            // real model output but not reply text, and
                            // ProviderStreamGuard's idle clock only advances on a
                            // yield — a long reasoning phase would otherwise get a
                            // healthy stream killed at the 90s idle default. The
                            // String stream has no .keepAlive event, so yield an
                            // EMPTY string (content-invisible: `+= ""` is a no-op
                            // and consumers' `!delta.isEmpty` guards skip it).
                            continuation.yield("")
                        }
                        guard let content = frame.content else { continue }
                        if ttftMs == nil {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        sawContent = true
                        continuation.yield(content)
                    }
                    if !decoder.sawDone {
                        // EOF without `[DONE]` — truncated reply. Surface as
                        // streamTruncated so callers can distinguish from clean ends.
                        throw LLMError.streamTruncated(
                            message: "openai stream ended without [DONE]"
                        )
                    }
                    // A3.3: `[DONE]` but ZERO reply content AND zero tool calls
                    // is an empty-and-silent turn — throw streamTruncated instead
                    // of finishing clean and letting an empty reply through. A
                    // tool-only turn (content-free but with calls) is NOT empty.
                    if !sawContent && decoder.completedToolCalls(idPrefix: "openai").isEmpty {
                        throw LLMError.streamTruncated(
                            message: "openai stream produced no content ([DONE], empty)"
                        )
                    }
                    let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        provider: providerId,
                        model: model,
                        streaming: true,
                        usage: decoder.usage,
                        ttftMs: ttftMs,
                        durationMs: durationMs
                    )
                    continuation.finish()
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// R-M1: shared status→error mapping for the api-key OpenAI Chat Completions
    /// paths. 5xx is unified to `.transient` (was `.underlying`).
    /// 2026-07-21 audit: closures are empty-body-safe so an empty error body
    /// keeps a meaningful message (the streaming path now routes through this
    /// mapping too; its hand-check used to say "rate limited" unconditionally).
    private static let statusMapping = ChatCompletionsStatusMapping(
        provider: "openai",
        rateLimited: { OpenAIAdapter.errorBodyText($0, fallback: "rate limited") },
        serverError: { OpenAIAdapter.errorBodyText($0, fallback: "5xx") },
        otherwise: { status, _ in .invalidResponse(status: status) }
    )

    private static func errorBodyText(_ data: Data, fallback: String) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? fallback : text
    }
}
