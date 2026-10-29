import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenAIAdapter.swift` | `OpenAITransport`: API-key Responses/Chat Completions selection, message/tool encoding and bounded completion/stream transport |

/// OpenAI API-key adapter: GPT-6 uses Responses; older models use Chat Completions.
public final class OpenAITransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String = "openai"

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

    /// api.openai.com, or the loopback stub a stream-guard proof runs against
    /// (`script/manual-fixtures/sse_pings_only.py`) when
    /// NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT names one. Only a loopback host is
    /// honored, so the key never leaves for anywhere but OpenAI or this Mac.
    public static var defaultEndpoint: URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT"],
           let url = URL(string: raw), ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            return url
        }
        return URL(string: "https://api.openai.com/v1/chat/completions")!
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL = OpenAITransport.defaultEndpoint,
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

    /// Streaming and non-streaming completions serialize tools and parse returned tool calls.
    /// Nil or empty tools leave the plain completion body unchanged.
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: [.user(prompt)], system: system, model: model, tools: tools))
    }

    // MARK: - Structured messages (native vision)

    /// On the `openai` Chat Completions wire, images and tool blocks stay structured.
    /// Text-only conversations retain role-prefixed compatibility flattening
    /// so their prompt shape and wire body stay unchanged.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        let hasImage = messages.contains { m in
            m.content.contains { if case .image = $0 { return true }; return false }
        }
        // Tool-use and tool-result blocks require structured assistant.tool_calls and role:"tool" messages.
        let hasToolBlocks = messages.contains { m in
            m.content.contains {
                switch $0 {
                case .toolUse, .toolResult: return true
                default: return false
                }
            }
        }
        guard hasImage || hasToolBlocks || OpenAIExecutionControls.usesResponses(model: model) else {
            // Text-only: the role-prefixed flatten (llmCompatibilityPrompt), unchanged.
            let flattened = try llmCompatibilityPrompt(messages: messages) { role in
                role == .user ? "USER:" : "ASSISTANT:"
            }
            let combined = flattened.text
            return try await complete(prompt: combined, system: system, model: model, tools: tools)
        }

        return try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: messages, system: system, model: model, tools: tools))
    }

    // MARK: - Structured streaming (tool calls)

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        if OpenAIExecutionControls.usesResponses(model: model) {
            return streamResponses(messages: messages, system: system, model: model, tools: tools)
        }
        let session = self.session
        let endpoint = self.endpoint
        let apiKeyOverride = self.apiKeyOverride
        let credentialRoot = self.credentialRoot
        let telemetry = self.telemetry
        let providerId = self.providerId
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = try apiKeyOverride
                            ?? LLMCredentialResolver.checkedAPIKey(
                                providerConfigFile: "openai.json",
                                dataRoot: credentialRoot),
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
                    if let limit = LLMCallContext.turnTokenBudget?.available {
                        body["max_completion_tokens"] = limit
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, req)
                    } catch {
                        throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
                    }
                    defer { bytes.task.cancel() }
                    try await ProviderWire.validateChatCompletions(bytes, response)
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI")
                    try await decoder.consume(
                        SSEEventStream(bytes), continuation: continuation,
                        request: req, providerID: providerId, model: model, idPrefix: "openai",
                        started: requestStartNs, telemetry: telemetry
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

    // MARK: - Public Responses API

    private func responsesRequest(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) throws -> URLRequest {
        guard let key = try apiKeyOverride
                ?? LLMCredentialResolver.checkedAPIKey(
                    providerConfigFile: "openai.json", dataRoot: credentialRoot),
              !key.isEmpty else {
            throw LLMError.notConfigured(provider: "openai")
        }
        // Keep custom endpoint origins and base paths, replacing only the API resource.
        let responsesEndpoint = endpoint.lastPathComponent == "completions"
            && endpoint.deletingLastPathComponent().lastPathComponent == "chat"
            ? endpoint.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("responses")
            : endpoint
        var req = URLRequest(url: responsesEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        applyStreamingLLMHeaders(to: &req)
        var body = try ChatGPTTransport.buildResponsesBodyFromMessages(
            model: model, messages: messages, system: system, tools: tools, transport: .publicAPI
        )
        body["prompt_cache_options"] = ["ttl": "30m"]
        if let limit = LLMCallContext.turnTokenBudget?.available {
            body["max_output_tokens"] = limit
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private func streamResponses(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    var req = try responsesRequest(messages: messages, system: system, model: model, tools: tools)
                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let (bytes, response) = try await ProviderWire.open(session, req)
                    defer { bytes.task.cancel() }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        let data = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
                        try throwIfChatCompletionsError(status: status, data: data, response: response)
                        throw LLMError.invalidResponse(status: status)
                    }
                    try await ChatGPTTransport.consumeResponsesStream(
                        bytes: bytes, request: req, model: model,
                        providerId: providerId, telemetry: telemetry, requestStartNs: requestStartNs,
                        providerLabel: "openai", errorPrefix: "openai",
                        transport: .publicAPI,
                        networkError: { _ in .underlying(message: "connection refused: \(req.url?.host ?? "openai")") },
                        continuation: continuation
                    )
                    continuation.finish()
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
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


}
