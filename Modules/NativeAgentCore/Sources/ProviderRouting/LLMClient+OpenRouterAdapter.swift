import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenRouterAdapter.swift` | `OpenRouterTransport`: namespaced model routing, reasoning controls and authenticated OpenRouter completion/stream transport |

/// OpenRouter chat-completions adapter. OpenRouter speaks the OpenAI
/// chat-completions wire format at `https://openrouter.ai/api/v1/chat/completions`
/// and uses the Bearer api key saved in
/// `<dataRoot>/providers/openrouter.json::api_key`. Used by SwiftNativeLLMClient
/// for slash-namespaced model ids (`anthropic/claude-...`, `openai/...`,
/// `meta-llama/...`, etc.) — those are OpenRouter routing targets, not
/// first-party Anthropic / OpenAI calls.
public final class OpenRouterTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId: String = "openrouter"
    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    /// Record `llm.call` usage for accounting and the Turn Inspector.
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

    /// OpenRouter reasoning sends low/medium/high, maps xhigh/max/ultra to high, and disables on none.
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

    private func resolveKey() throws -> String? {
        if let k = apiKeyOverride, !k.isEmpty { return k }
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return try LLMCredentialResolver.checkedAPIKey(
            providerConfigFile: "openrouter.json",
            dataRoot: root
        )
    }

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: [.user(prompt)], system: system, model: model, tools: tools))
    }

    /// Preserve images and assistant-tool/result turns on OpenRouter's OpenAI-compatible wire.
    /// The stream owns the 404 catalog refresh, as a turn's does.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await LLMMessageStreamEvent.reply(collecting:
            streamMessages(messages: messages, system: system, model: model, tools: tools))
    }

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        let session = self.session
        let endpoint = self.endpoint
        let keyResolved = Result { try self.resolveKey() }
        let dataRoot = self.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let telemetry = self.telemetry
        let providerId = self.providerId
        return AsyncThrowingStream { continuation in
            let task = Task {
                let startedNs = DispatchTime.now().uptimeNanoseconds
                do {
                    guard let key = try keyResolved.get(), !key.isEmpty else {
                        throw LLMError.notConfigured(provider: "openrouter")
                    }
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &req)
                    var body: [String: Any] = [
                        "model": model,
                        "messages": OpenAITransport.chatMessages(messages: messages, system: system),
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    Self.applyReasoningControls(to: &body)
                    try OpenAITransport.applyTools(to: &body, tools: tools)
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
                    try await ProviderWire.validateChatCompletions(bytes, response) { status in
                        if status == 404 {
                            Self.refreshCatalog(dataRoot: dataRoot, session: session)
                            throw LLMError.modelUnavailable(provider: "openrouter", model: model)
                        }
                    }
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter")
                    try await decoder.consume(
                        SSEEventStream(bytes), continuation: continuation,
                        request: req, providerID: providerId, model: model, idPrefix: "openrouter",
                        started: startedNs, telemetry: telemetry
                    )
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



}
