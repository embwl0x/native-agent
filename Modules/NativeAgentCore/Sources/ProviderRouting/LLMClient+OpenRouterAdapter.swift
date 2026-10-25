import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenRouterAdapter.swift` | `OpenRouterAdapter`: namespaced model routing, reasoning controls and authenticated OpenRouter completion/stream transport |

/// OpenRouter chat-completions adapter. OpenRouter speaks the OpenAI
/// chat-completions wire format at `https://openrouter.ai/api/v1/chat/completions`
/// and uses the Bearer api key saved in
/// `<dataRoot>/providers/openrouter.json::api_key`. Used by SwiftNativeLLMClient
/// for slash-namespaced model ids (`anthropic/claude-...`, `openai/...`,
/// `meta-llama/...`, etc.) — those are OpenRouter routing targets, not
/// first-party Anthropic / OpenAI calls.
public final class OpenRouterAdapter: LLMAdapter {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String = "openrouter"
    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    /// User, 2026-09-06: OpenRouter was the only adapter with no `llm.call` row
    /// at all — it decoded usage and threw it away, so every OpenRouter turn
    /// was invisible to accounting and to the Turn Inspector.
    private let telemetry: LLMCallTraceRecorder

    public init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        apiKeyOverride: String? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = endpoint
        self.apiKeyOverride = apiKeyOverride
        self.dataRootOverride = dataRootOverride
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    /// A 404 is already the answer for this call; the catalog learns it on
    /// its own task, so the failure never waits on a discovery request.
    private static func refreshCatalog(dataRoot: URL, session: URLSession) {
        Task.detached { _ = await OpenRouterModelCatalog.models(dataRoot: dataRoot, session: session, refresh: true) }
    }

    /// User, 2026-09-06: the model picker advertises low/medium/high/xhigh for
    /// every OpenRouter row (the provider catalog) and the
    /// request never carried the choice, so picking an effort did nothing at
    /// all. OpenRouter's unified `reasoning` field is the wire form: `effort`
    /// takes low/medium/high (xhigh and the ceiling efforts map to high), and
    /// "none" turns reasoning off. Models with no reasoning mode ignore it.
    static func applyReasoningControls(to body: inout [String: Any]) {
        guard let raw = LLMCallContext.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty else { return }
        switch raw {
        case "none":
            body["reasoning"] = ["enabled": false]
        case "low", "medium", "high":
            body["reasoning"] = ["effort": raw]
        case "xhigh", "max", "ultra":
            body["reasoning"] = ["effort": "high"]
        default:
            return
        }
    }

    private func resolveKey() -> String? {
        if let k = apiKeyOverride, !k.isEmpty { return k }
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return LLMCredentialResolver.resolveAPIKey(
            providerConfigFile: "openrouter.json",
            dataRoot: root
        )
    }

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await complete(prompt: prompt, system: system, model: model, tools: nil)
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])
        return try await completeWire(messages: messages, model: model, tools: tools)
    }

    /// Preserve native image blocks and the assistant-tool/result transcript
    /// on OpenRouter's OpenAI-compatible wire instead of flattening it into a
    /// one-shot string (which silently dropped images and broke tool turn 2).
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await completeWire(
            messages: OpenAIAdapter.chatMessages(messages: messages, system: system),
            model: model,
            tools: tools
        )
    }

    private func completeWire(
        messages: [[String: Any]],
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        guard let key = resolveKey(), !key.isEmpty else {
            throw LLMError.notConfigured(provider: "openrouter")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["model": model, "messages": messages]
        try OpenAIAdapter.applyTools(to: &body, tools: tools)
        Self.applyReasoningControls(to: &body)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let startedNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            if ProviderStreamContext.stallOnly { req.timeoutInterval = .infinity }
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openrouter")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            Self.refreshCatalog(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(), session: session)
            throw LLMError.modelUnavailable(provider: "openrouter", model: model)
        }
        try throwIfChatCompletionsError(status: status, data: data, response: response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let terminal = Result { try OpenAIAdapter.parseCompletion(obj, status: status) }
        await telemetry.record(
            requestBody: req.httpBody,
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000),
            status: try terminal.chatCompletionsTerminalStatus()
        )
        return try terminal.get()
    }

    public func messagesStreamKind(tools: [LLMToolSchema]?) -> LLMMessagesStreamKind { .incremental }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let keyResolved = self.resolveKey()
        let dataRoot = self.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let telemetry = self.telemetry
        let providerId = self.providerId
        return AsyncThrowingStream { continuation in
            let task = Task {
                let startedNs = DispatchTime.now().uptimeNanoseconds
                var ttftMs: Int?
                do {
                    guard let key = keyResolved, !key.isEmpty else {
                        throw LLMError.notConfigured(provider: "openrouter")
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &req)
                    var body: [String: Any] = [
                        "model": model,
                        "messages": OpenAIAdapter.chatMessages(messages: messages, system: system),
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    Self.applyReasoningControls(to: &body)
                    try OpenAIAdapter.applyTools(to: &body, tools: tools)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, req)
                    } catch {
                        throw mapTransportError(error, fallback: .underlying(
                            message: "connection refused: \(endpoint.host ?? "openrouter")"
                        ))
                    }
                    defer { bytes.task.cancel() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        let errorBody = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
                        if status == 404 {
                            Self.refreshCatalog(dataRoot: dataRoot, session: session)
                            throw LLMError.modelUnavailable(provider: "openrouter", model: model)
                        }
                        try throwIfChatCompletionsError(
                            status: status, data: errorBody,
                            response: response
                        )
                        throw LLMError.invalidResponse(status: status)
                    }

                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter")
                    var sawContent = false
                    try await decoder.consume(SSEEventStream(bytes)) { frame in
                        if ttftMs == nil, frame.content != nil || frame.toolCallDeltaCount > 0 {
                            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000)
                        }
                        if frame.reasoning != nil { continuation.yield(.keepAlive) }
                        if let content = frame.content {
                            sawContent = true
                            continuation.yield(.textDelta(content))
                        }
                        for _ in 0..<frame.toolCallDeltaCount { continuation.yield(.keepAlive) }
                    }
                    let terminal = Result {
                        try decoder.finalizedToolCalls(
                            idPrefix: "openrouter", providerID: "openrouter", sawContent: sawContent
                        )
                    }
                    await telemetry.record(
                        requestBody: req.httpBody,
                        provider: providerId,
                        model: model,
                        streaming: true,
                        usage: decoder.usage,
                        ttftMs: ttftMs,
                        durationMs: Int((DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000),
                        status: decoder.toolBoundaryReason != nil ? "incomplete" : (try terminal.chatCompletionsTerminalStatus()),
                        stopReason: decoder.toolBoundaryReason?.rawValue,
                        errorDetail: decoder.errorDetail
                    )
                    let completed = try terminal.get()
                    for call in completed {
                        continuation.yield(.toolCall(.init(
                            id: call.id,
                            name: call.name,
                            inputJSON: Data(call.arguments.utf8)
                        )))
                    }
                    if let reason = decoder.toolBoundaryReason { continuation.yield(.toolBoundary(reason)) }
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: mapTransportError(
                        error, fallback: .underlying(message: "stream: \(error)")
                    ))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream(
        prompt: String,
        system: String?,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        streamMessages(messages: [.user(prompt)], system: system, model: model, tools: nil)
            .textDeltas(omittingEmpty: true)
    }

}
