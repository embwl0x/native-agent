import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+MoonshotAdapter.swift` | `MoonshotTransport`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |

/// Kimi tool loops require retained reasoning state alongside structured calls, images and SSE output.
public final class MoonshotTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// The transport declares no output-cap field.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int { 0 }

    public let providerId = "moonshot"

    public static let defaultEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")
    /// An empty catalog cannot supply a default model.
    public static var defaultModel: String {
        FirstPartyModelCatalog.models(forProviderID: "moonshot").first?.id ?? ""
    }

    private let session: URLSession
    private let endpoint: URL?
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    private let telemetry: LLMCallTraceRecorder
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

    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: call)
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        // The stream carries the reasoning ledger for tool calls, as a turn's does.
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
        let telemetry = self.telemetry
        let providerID = providerId
        let ledger = reasoningLedger
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let endpoint else { throw URLError(.badURL) }
                    let key = try self.apiKey()
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &request)
                    request.httpBody = try JSONSerialization.data(withJSONObject: await self.buildBody(
                        model: model, messages: messages, system: system, tools: tools, stream: true, call: call
                    ))

                    let started = DispatchTime.now().uptimeNanoseconds
                    let bytes: ProviderHTTPBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, request, call: call)
                    } catch {
                        throw mapTransportError(error, fallback: .transient(message: "connection failed: \(endpoint.host ?? "moonshot")"))
                    }
                    defer { bytes.cancel() }
                    try await ProviderWire.validateChatCompletions(bytes, response)
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot", retainReasoning: true)
                    try await decoder.consume(
                        SSEEventStream(bytes, lifetime: call.lifetime), continuation: continuation,
                        request: request, providerID: providerID, model: model, idPrefix: "moonshot_tool",
                        started: started, telemetry: telemetry, call: call
                    ) { calls, reasoning in
                        if !calls.isEmpty, !reasoning.isEmpty {
                            await ledger.record(reasoning, callIDs: calls.map(\.id))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
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

    /// The wire form is the model row's declaration; an id with no row sends none.
    private func applyReasoningControls(to body: inout [String: Any], model: String, call: LLMCall) throws {
        guard let row = FirstPartyModelCatalog.descriptor(for: model, providerID: "moonshot") else {
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
