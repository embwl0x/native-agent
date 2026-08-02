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
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    /// F-B2 (2026-08-02): the api-key OpenAI lane used to inherit the protocol's
    /// default tools-aware `complete`, which DROPS `tools` on the floor — the
    /// request body carried only model+messages, no `.toolCall` was ever
    /// emitted, and the agent silently believed it had zero tools. The Moonshot
    /// and xAI adapters speak the identical Chat-Completions wire; this brings
    /// OpenAI to parity (tools / tool_choice / parallel_tool_calls out,
    /// tool_calls parsed back in on BOTH the streaming and non-streaming paths).
    ///
    /// BYTE-IDENTITY: `tools == nil || tools!.isEmpty` produces the exact body
    /// this method sent before the change.
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
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
        try Self.applyTools(to: &body, tools: tools)
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

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let parsed = try Self.parseCompletion(obj, status: status)
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
        return parsed
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
        // F-B2: tool_use / tool_result blocks now demand the STRUCTURED body
        // (assistant.tool_calls + role:"tool" messages). Flattening them into
        // "[tool_use …]" text is what made the api-key OpenAI lane unable to
        // run a second tool-loop turn. A plain text-only conversation still
        // takes the byte-identical flatten path below.
        let hasToolBlocks = messages.contains { m in
            m.content.contains {
                switch $0 {
                case .toolUse, .toolResult: return true
                default: return false
                }
            }
        }
        guard hasImage || hasToolBlocks else {
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
            return try await complete(prompt: combined, system: system, model: model, tools: tools)
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

        var body: [String: Any] = [
            "model": model,
            "messages": Self.chatMessages(messages: messages, system: system),
        ]
        try Self.applyTools(to: &body, tools: tools)
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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let parsed = try Self.parseCompletion(obj, status: status)
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return parsed
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

    // MARK: - Structured streaming (tool calls)

    /// F-B2 (2026-08-02): the api-key OpenAI lane had NO `streamMessages`
    /// override, so it fell through to the protocol default — one
    /// `completeMessages` round-trip yielded as a single `.textDelta`, and a
    /// `.toolCall` event was structurally impossible. Every tool the chat spine
    /// offered vanished on this provider with no error and no log. This mirrors
    /// `MoonshotAdapter.streamMessages` on the identical Chat-Completions wire.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let apiKeyOverride = self.apiKeyOverride
        let credentialRoot = self.credentialRoot
        let includesProcessEnvironmentCredentials = self.includesProcessEnvironmentCredentials
        let telemetry = self.telemetry
        let providerId = self.providerId
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
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
                    applyStreamingLLMHeaders(to: &req)
                    var body: [String: Any] = [
                        "model": model,
                        "messages": Self.chatMessages(messages: messages, system: system),
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    try Self.applyTools(to: &body, tools: tools)
                    OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: req)
                    } catch {
                        throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var errData = Data()
                        do {
                            for try await byte in bytes {
                                errData.append(byte)
                                if errData.count >= 4096 { break }
                            }
                        } catch {}
                        try throwIfChatCompletionsError(
                            status: status, data: errData,
                            mapping: Self.statusMapping, response: response
                        )
                        throw LLMError.invalidResponse(status: status)
                    }

                    var ttftMs: Int?
                    var sawContent = false
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
                    for try await sse in SSEEventStream(bytes) {
                        try Task.checkCancellation()
                        let frame = try decoder.consume(payload: sse.data)
                        if frame.isDone { break }
                        // Liveness: reasoning frames and tool-argument deltas are
                        // real model output but not reply text — keep the idle
                        // clock in ProviderStreamGuard advancing during a long
                        // thinking phase or a big argument accumulation.
                        if frame.reasoning != nil { continuation.yield(.keepAlive) }
                        if let content = frame.content {
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                            }
                            sawContent = true
                            continuation.yield(.textDelta(content))
                        }
                        for _ in 0..<frame.toolCallDeltaCount { continuation.yield(.keepAlive) }
                    }
                    guard decoder.sawDone else {
                        throw LLMError.streamTruncated(message: "openai stream ended without [DONE]")
                    }
                    let completed = decoder.completedToolCalls(idPrefix: "openai")
                    // A3.3 parity: `[DONE]` with zero content AND zero tool calls
                    // is an empty-and-silent turn. A tool-only turn is NOT empty.
                    if !sawContent && completed.isEmpty {
                        throw LLMError.streamTruncated(
                            message: "openai stream produced no content ([DONE], empty)"
                        )
                    }
                    for call in completed {
                        continuation.yield(.toolCall(.init(
                            id: call.id,
                            name: call.name,
                            inputJSON: Data(call.arguments.utf8)
                        )))
                    }
                    let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        provider: providerId, model: model, streaming: true,
                        usage: decoder.usage, ttftMs: ttftMs, durationMs: durationMs
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

    // MARK: - Shared body / response helpers

    /// Emit `tools` / `tool_choice` / `parallel_tool_calls` exactly the way the
    /// Moonshot and xAI adapters do on this same wire. No-op (byte-identical
    /// body) when there are no tools.
    static func applyTools(to body: inout [String: Any], tools: [LLMToolSchema]?) throws {
        guard let tools, !tools.isEmpty else { return }
        body["tools"] = try tools.map { schema in
            [
                "type": "function",
                "function": [
                    "name": schema.name,
                    "description": schema.description,
                    "parameters": try JSONSerialization.jsonObject(with: schema.parametersJSON),
                ],
            ]
        }
        body["tool_choice"] = "auto"
        body["parallel_tool_calls"] = true
    }

    /// Structured Chat-Completions message array: images as `image_url` parts,
    /// assistant tool calls as `tool_calls`, tool results as `role:"tool"` rows.
    static func chatMessages(messages: [LLMMessage], system: String?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let system, !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for message in messages {
            let role = message.role == .user ? "user" : "assistant"
            var textParts: [String] = []
            var contentParts: [[String: Any]] = []
            var toolCalls: [[String: Any]] = []
            var toolResults: [[String: Any]] = []
            var hasImage = false
            for block in message.content {
                switch block {
                case .text(let text):
                    textParts.append(text)
                    contentParts.append(["type": "text", "text": text])
                case .image(let mediaType, let base64, _, _):
                    hasImage = true
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(base64)"],
                    ])
                case .toolUse(let id, let name, let inputJSON):
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": String(data: inputJSON, encoding: .utf8) ?? "{}",
                        ],
                    ])
                case .toolResult(let toolUseID, let content, _):
                    toolResults.append([
                        "role": "tool", "tool_call_id": toolUseID, "content": content,
                    ])
                }
            }
            if !toolCalls.isEmpty {
                out.append([
                    "role": "assistant",
                    "content": textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n"),
                    "tool_calls": toolCalls,
                ])
            } else if !contentParts.isEmpty {
                out.append([
                    "role": role,
                    "content": hasImage ? contentParts : textParts.joined(separator: "\n"),
                ])
            }
            out.append(contentsOf: toolResults)
        }
        return out
    }

    /// Non-streaming reply → text plus `<tool_use …>` markers, the same shape
    /// the Anthropic / Moonshot / xAI adapters return for the tool loop.
    /// A tool-ONLY reply carries `content: null` — that used to fail the
    /// `content as? String` guard and throw `.invalidResponse`.
    static func parseCompletion(_ obj: [String: Any], status: Int) throws -> String {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let content = (message["content"] as? String) ?? ""
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
        let markers: [String] = rawCalls.enumerated().compactMap { index, raw in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty else { return nil }
            let id = (raw["id"] as? String) ?? "openai_tool_\(index)_\(name)"
            let args = (function["arguments"] as? String) ?? "{}"
            return "<tool_use id=\"\(id)\" name=\"\(name)\">\(args)</tool_use>"
        }
        if content.isEmpty && markers.isEmpty {
            // Neither text nor a tool call: the reply is genuinely unusable.
            // Keep the pre-change failure mode for that case.
            if message["content"] is String { return "" }
            throw LLMError.invalidResponse(status: status)
        }
        var pieces: [String] = content.isEmpty ? [] : [content]
        pieces.append(contentsOf: markers)
        return pieces.joined(separator: "\n")
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
