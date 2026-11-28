import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenRouterAdapter.swift` | `OpenRouterTransport`: gateway-owned model transport |

/// Namespaced IDs are gateway targets on OpenRouter's own authenticated route; they must not dispatch to first-party adapters.
public final class OpenRouterTransport: HTTPProviderProfile {
    public static let toolWire = ProviderToolWire.native
    /// This transport sends no output-cap field.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId: String = "openrouter"
    let session = ProviderHTTP.session
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")
    private let dataRootOverride: URL?
    public let telemetry: LLMCallTraceRecorder

    func connectionError(_ error: Error, request: URLRequest) -> LLMError {
        .underlying(message: "connection refused: \(request.url?.host ?? "openrouter")")
    }

    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
        self.telemetry = LLMCallTraceRecorder(dataRootOverride: dataRootOverride)
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
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return try LLMCredentialResolver.checkedAPIKey(
            providerConfigFile: "openrouter.json",
            dataRoot: root
        )
    }

    var transport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare, diagnostic: { status, _, input in
            if status == 404, input.tools?.isEmpty != false {
                throw LLMError.modelUnavailable(provider: "openrouter", model: input.model)
            }
        })
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> ChatCompletionsWire {
        let messages = input.messages
        let system = input.system
        let model = input.model
        let tools = input.tools
        let call = input.call
        guard let endpoint else { throw URLError(.badURL) }
        guard let key = try resolveKey(), !key.isEmpty else {
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
        try Self.applyReasoningControls(to: &body, model: model, dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(), call: call)
        try OpenAITransport.applyTools(to: &body, tools: tools)
        if body["tools"] != nil { body["provider"] = ["require_parameters": true] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return ChatCompletionsWire(request: req, label: "OpenRouter", model: model, profile: self, call: call)
    }

}
