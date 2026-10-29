import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+MoonshotAdapter.swift` | `MoonshotTransport`: structured Chat Completions, vision/SSE and Kimi reasoning state across tool loops |

/// First-class Moonshot/Kimi adapter over the provider's OpenAI-compatible
/// Chat Completions surface. Unlike the generic API-key fallthrough, this
/// preserves structured tool calls, vision inputs, SSE deltas, and Kimi's
/// required reasoning state across K3/K2.7 tool loops.
public final class MoonshotTransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    public let providerId = "moonshot"

    public static let defaultEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    /// The default is the provider catalog's first row, or empty when the catalog is empty.
    public static var defaultModel: String {
        FirstPartyModelCatalog.models(forProviderID: "moonshot").first?.id ?? ""
    }

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    private let telemetry: LLMCallTraceRecorder
    private let reasoningLedger = ToolCallReplayLedger<String>()

    private var credentialRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    public init(
        session: URLSession = .shared,
        endpoint: URL = MoonshotTransport.defaultEndpoint,
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
        tools: [LLMToolSchema]?
    ) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: tools)
    }

    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        // The stream carries the reasoning ledger for tool calls, as a turn's does.
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
        let telemetry = self.telemetry
        let providerID = providerId
        let ledger = reasoningLedger
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let key = try self.apiKey()
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &request)
                    request.httpBody = try JSONSerialization.data(withJSONObject: await self.buildBody(
                        model: model, messages: messages, system: system, tools: tools, stream: true
                    ))

                    let started = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, request)
                    } catch {
                        throw mapTransportError(error, fallback: .transient(message: "connection failed: \(endpoint.host ?? "moonshot")"))
                    }
                    defer { bytes.task.cancel() }
                    try await ProviderWire.validateChatCompletions(bytes, response)
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot", retainReasoning: true)
                    try await decoder.consume(
                        SSEEventStream(bytes), continuation: continuation,
                        request: request, providerID: providerID, model: model, idPrefix: "moonshot_tool",
                        started: started, telemetry: telemetry
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildBody(
        model: String,
        messages: [LLMMessage],
        system: String?,
        tools: [LLMToolSchema]?,
        stream: Bool
    ) async throws -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if let system, !system.isEmpty { apiMessages.append(["role": "system", "content": system]) }
        for message in messages {
            apiMessages.append(contentsOf: await chatMessages(from: message))
        }
        var body: [String: Any] = ["model": model, "messages": apiMessages, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }
        try OpenAITransport.applyTools(to: &body, tools: tools)
        applyReasoningControls(to: &body, model: model)
        return body
    }

    private func chatMessages(from message: LLMMessage) async -> [[String: Any]] {
        let toolCallIDs = message.content.compactMap { block -> String? in
            if case .toolUse(let id, _, _) = block { return id }
            return nil
        }
        let reasoning = toolCallIDs.isEmpty
            ? nil
            : await reasoningLedger.payload(forAny: toolCallIDs)
        return chatCompletionsMessages(from: message, reasoning: reasoning)
    }

    /// The wire form is the model row's declaration; an id with no row sends none.
    private func applyReasoningControls(to body: inout [String: Any], model: String) {
        guard let row = FirstPartyModelCatalog.descriptor(for: model, providerID: "moonshot") else { return }
        let requested = LLMCallContext.reasoningEffort?.lowercased()
        switch row.reasoningWire {
        case .thinkingSwitch:
            body["thinking"] = ["type": requested == "none" ? "disabled" : "enabled"]
        case .effort:
            let effort = requested.flatMap { row.supportedReasoningEfforts.contains($0) ? $0 : nil }
                ?? row.defaultReasoningEffort
            if effort != "none" { body["reasoning_effort"] = effort }
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
