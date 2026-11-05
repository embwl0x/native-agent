import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenRouterAdapter.swift` | `OpenRouterTransport`: gateway-owned model transport |

/// Namespaced IDs are gateway targets on OpenRouter's own authenticated route; they must not dispatch to first-party adapters.
public final class OpenRouterTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// This transport sends no output-cap field.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId: String = "openrouter"
    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
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

    /// A 404 is already the answer for this call; the catalog learns it on its own task, so the failure never waits on a discovery request.
    private static func refreshCatalog(dataRoot: URL, session: URLSession) {
        Task.detached { _ = await OpenRouterModelCatalog.models(dataRoot: dataRoot, session: session, refresh: true) }
    }

    /// Send the exact admitted effort from this route's current catalog.
    static func applyReasoningControls(to body: inout [String: Any], model: String, dataRoot: URL, call: LLMCall) throws {
        let catalog = try SwiftNativeProviderRouting(dataRoot: dataRoot).checkedCatalogModels(for: "openrouter", preview: call.preview)
        guard let row = catalog.first(where: { $0.id == model }) else {
            throw ProviderRoutingError.configurationFailed("OpenRouter has no current controls for \(model). Refresh its model catalog in Providers.")
        }
        if row.supported_reasoning_efforts == [],
           call.admission?.reasoningEffort == nil || call.admission?.reasoningEffort == "" || call.admission?.reasoningEffort == "default" { return }
        guard let requested = call.admission?.reasoningEffort ?? row.default_reasoning_effort else {
            throw ProviderRoutingError.configurationFailed(
                "OpenRouter's default Think control for \(model) is unknown. Refresh its model catalog in Providers.")
        }
        let effort = try SwiftNativeProviderRouting.normalizeReasoningEffortStatic(
            requested, model: model, providerID: "openrouter",
            supportedReasoningEfforts: row.supported_reasoning_efforts)
        guard effort != "default" else { return }
        body["reasoning"] = effort == "none" ? ["enabled": false] : ["effort": effort]
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
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }

    /// Preserve images and assistant-tool/result turns on OpenRouter's OpenAI-compatible wire. The stream owns the 404 catalog refresh, as a turn's does.
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
                        "messages": try OpenAITransport.chatMessages(messages: messages, system: system),
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    try Self.applyReasoningControls(to: &body, model: model, dataRoot: dataRoot, call: call)
                    try OpenAITransport.applyTools(to: &body, tools: tools)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, req, call: call)
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
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenRouter", diagnosticDataRoot: telemetry.diagnosticDataRoot(call: call),
                        call: call)
                    try await decoder.consume(
                        SSEEventStream(bytes, lifetime: call.lifetime), continuation: continuation,
                        request: req, providerID: providerId, model: model, idPrefix: "openrouter",
                        started: startedNs, telemetry: telemetry, call: call
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
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }



}
