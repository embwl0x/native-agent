import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+MoonshotAdapter.swift` | `MoonshotTransport`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |

/// Kimi tool loops require retained reasoning state alongside structured calls, images and SSE output.
public final class MoonshotTransport: HTTPProviderProfile {
    public static let toolWire = ProviderToolWire.native
    /// While a run's budget is bound, one request's allowance (`budgetedOutputTokens`) goes in Moonshot's `max_completion_tokens`; else no cap.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        FirstPartyExecutionControls.budgetedOutputTokens(model: model, providerID: providerId, call: call, dataRoot: credentialRoot) ?? 0
    }

    public let providerId = "moonshot"

    public static let defaultEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")

    let session: URLSession
    private let endpoint: URL?
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    public let telemetry: LLMCallTraceRecorder
    private let reasoningLedger = ToolCallReplayLedger<String>()

    private var credentialRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    public init(
        session: URLSession = ProviderHTTP.session,
        endpoint: URL? = MoonshotTransport.defaultEndpoint,
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

    var transport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare)
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> ChatCompletionsWire {
        let messages = input.messages
        let system = input.system
        let model = input.model
        let tools = input.tools
        let call = input.call
        guard let endpoint else { throw URLError(.badURL) }
        let key = try self.apiKey()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        applyStreamingLLMHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: await self.buildBody(
            model: model, messages: messages, system: system, tools: tools, stream: true, call: call
        ), options: [.sortedKeys])
        return ChatCompletionsWire(request: request, label: "Moonshot", model: model, profile: self, call: call, reasoning: reasoningLedger)
    }

    private func buildBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        stream: Bool, call: LLMCall
    ) async throws -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if let system, !system.isEmpty { apiMessages.append(["role": "system", "content": system]) }
        for message in messages {
            apiMessages.append(contentsOf: try await chatMessages(from: message))
        }
        var body: [String: Any] = ["model": model, "messages": apiMessages, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }
        try OpenAITransport.applyTools(to: &body, tools: tools)
        try applyReasoningControls(to: &body, model: model, call: call)
        // No allowance, no field: a cap of zero would refuse the request.
        if let allowance = FirstPartyExecutionControls.budgetedOutputTokens(model: model, providerID: providerId, call: call, dataRoot: credentialRoot) {
            body["max_completion_tokens"] = allowance
        }
        return body
    }

    private func chatMessages(from message: LLMMessage) async throws -> [[String: Any]] {
        let toolCallIDs = message.content.compactMap { block -> String? in
            if case .toolUse(let id, _, _) = block { return id }
            return nil
        }
        let reasoning = toolCallIDs.isEmpty
            ? nil
            : await reasoningLedger.payload(forAny: toolCallIDs)
        return try chatCompletionsMessages(from: message, reasoning: reasoning)
    }

    private func applyReasoningControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        guard let row = FirstPartyModelDiscovery.nearestSibling(of: model, route: providerId) else {
            if call.admission?.reasoningEffort != nil {
                throw LLMError.providerError(message: "Moonshot Think controls for \(model) are unknown. Choose a supported control in Providers.")
            }
            return
        }
        let requested = call.admission?.reasoningEffort?.lowercased()
        if let requested, !row.supportedReasoningEfforts.contains(requested) {
            throw LLMError.providerError(
                message: "Think level '\(requested)' is unsupported for \(model) on Moonshot. Choose a supported control in Providers.")
        }
        switch row.reasoningWire {
        case .thinkingSwitch:
            body["thinking"] = ["type": requested == "none" ? "disabled" : "enabled"]
        case .effort:
            let effort = requested ?? row.defaultReasoningEffort
            // "default" is the provider's own: never written. No effort-wire row offers "none".
            if effort != "none", effort != "default" { body["reasoning_effort"] = effort }
        }
    }

    private func apiKey() throws -> String {
        guard let key = try apiKeyOverride ?? LLMCredentialResolver.checkedAPIKey(
            providerConfigFile: "moonshot.json",
            dataRoot: credentialRoot
        ), !key.isEmpty else {
            throw LLMError.notConfigured(provider: "moonshot")
        }
        return key
    }

}
