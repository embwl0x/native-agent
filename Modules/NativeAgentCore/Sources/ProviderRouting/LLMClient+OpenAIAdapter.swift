import Foundation
import NativeAgentCore
import PersistenceCore

/// OpenAI Chat Completions adapter. URLSession is injectable for tests.
public final class OpenAIAdapter: LLMAdapter {
    public static let supportsTools = true
    public let providerId: String = "openai"
    /// Request timeout for the API-key lane. Same resolved value the OAuth
    /// direct adapters use (240s), so both lanes fail a stalled request the
    /// same way instead of inheriting whatever the injected session carries.
    static let requestTimeoutSeconds: TimeInterval = 240

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    /// When non-nil, credential discovery is confined to this data root.
    /// Production callers may leave it nil to preserve dynamic default-root
    /// resolution; tests and secondary runtimes must inject their own root.
    private let dataRootOverride: URL?
    /// Records per-call timing and provider-reported token/cache usage.
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
        // An injected session may carry URLSession's 60s default (or none at
        // all); match the OAuth lanes' resolved 240s so a stalled completion
        // fails instead of hanging the turn.
        req.timeoutInterval = Self.requestTimeoutSeconds

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
        if let limit = (LLMCallContext.turnTokenBudget?.available ?? LLMCallContext.botOutputTokenLimit) { body["max_completion_tokens"] = limit }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        return try await performCompletion(request: req, model: model)
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
            let flattened = llmCompatibilityPrompt(messages: messages) { role in
                role == .user ? "USER:" : "ASSISTANT:"
            }
            let combined = flattened.text
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
        // An injected session may carry URLSession's 60s default (or none at
        // all); match the OAuth lanes' resolved 240s so a stalled completion
        // fails instead of hanging the turn.
        req.timeoutInterval = Self.requestTimeoutSeconds

        var body: [String: Any] = [
            "model": model,
            "messages": Self.chatMessages(messages: messages, system: system),
        ]
        if let limit = (LLMCallContext.turnTokenBudget?.available ?? LLMCallContext.botOutputTokenLimit) { body["max_completion_tokens"] = limit }
        try Self.applyTools(to: &body, tools: tools)
        OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        return try await performCompletion(request: req, model: model)
    }


    /// Shared transport, response validation, parsing, and success telemetry.
    private func performCompletion(request req: URLRequest, model: String) async throws -> String {
        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try throwIfChatCompletionsError(status: status, data: data, response: response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let terminal = Result { try Self.parseCompletion(obj, status: status) }
        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            requestBody: req.httpBody,
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs,
            status: try terminal.chatCompletionsTerminalStatus()
        )
        return try terminal.get()
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
        streamMessages(messages: [.user(prompt)], system: system, model: model, tools: nil)
            .textDeltas(omittingEmpty: true)
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
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: req)
                    } catch {
                        throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
                    }
                    defer { bytes.task.cancel() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        // User, 2026-09-06: this drained the body with no
                        // deadline, so the status — including a 429 whose
                        // Retry-After was already in hand — was mapped only
                        // after the read finished. A provider that answers the
                        // headers and then stalls the body wedged the turn for
                        // as long as it cared to. `ProviderErrorBodyDrain`
                        // bounds the read (4 KiB / 2s) and keeps a user Stop
                        // as cancellation instead of a provider verdict; an
                        // empty body still maps the status correctly.
                        let errData = try await ProviderErrorBodyDrain.read(
                            bytes, maxBytes: 4096, timeout: 2.0
                        )
                        try throwIfChatCompletionsError(
                            status: status, data: errData,
                            response: response
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
                    let terminal = Result {
                        try decoder.finalizedToolCalls(
                            idPrefix: "openai", providerID: "openai", sawContent: sawContent
                        )
                    }
                    let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        requestBody: req.httpBody,
                        provider: providerId, model: model, streaming: true,
                        usage: decoder.usage, ttftMs: ttftMs, durationMs: durationMs,
                        status: try terminal.chatCompletionsTerminalStatus()
                    )
                    let completed = try terminal.get()
                    for call in completed {
                        continuation.yield(.toolCall(.init(
                            id: call.id,
                            name: call.name,
                            inputJSON: Data(call.arguments.utf8)
                        )))
                    }
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
            out.append(contentsOf: chatCompletionsMessages(from: message))
        }
        return out
    }

    /// Non-streaming reply → text plus `<tool_use …>` markers, the same shape
    /// the Anthropic / Moonshot / xAI adapters return for the tool loop.
    /// A tool-ONLY reply carries `content: null` — that used to fail the
    /// `content as? String` guard and throw `.invalidResponse`.
    static func parseCompletion(_ obj: [String: Any], status: Int) throws -> String {
        let message = try chatCompletionsMessage(obj, status: status)
        // User, 2026-09-06: all-or-nothing on the tool set, same as the streams
        // — a `compactMap` used to drop the entries it could not execute and
        // run their siblings, which is half a plan the model wrote as one
        // decision.
        let toolSet = finalizeChatCompletionsToolCalls(
            message["tool_calls"] as? [[String: Any]] ?? [],
            idPrefix: "openai"
        )
        // User, 2026-09-06: an empty `content` string used to be returned
        // AS an empty reply, so a silent no-reply reached the chat as a
        // blank turn. The streaming lanes call that `.streamTruncated`;
        // this one does now too, and the ladder can retry it.
        return try chatCompletionsReply(
            content: (message["content"] as? String) ?? "",
            toolCalls: toolSet.calls, incompleteNote: toolSet.incompleteNote, provider: "openai"
        )
    }

    /// R-M1: shared status→error mapping for the api-key OpenAI Chat Completions
    /// paths. 5xx is unified to `.transient` (was `.underlying`).
    /// 2026-07-21 audit: closures are empty-body-safe so an empty error body
    /// keeps a meaningful message (the streaming path now routes through this
    /// mapping too; its hand-check used to say "rate limited" unconditionally).
}
