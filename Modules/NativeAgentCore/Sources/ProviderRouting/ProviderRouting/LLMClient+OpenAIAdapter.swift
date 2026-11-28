import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenAIAdapter.swift` | `OpenAITransport`: checked API transport and message encoding |

/// A declared model that serves only through Responses (GPT-6, the Pro rows) goes there; other declared models use Chat Completions.
public final class OpenAITransport: HTTPProviderProfile, LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// Both OpenAI wires send one request's allowance while a run's budget is bound (`budgetedOutputTokens`), else no cap.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        FirstPartyExecutionControls.budgetedOutputTokens(model: model, providerID: providerId, call: call, dataRoot: credentialRoot) ?? 0
    }

    /// "openai", or the local server this transport speaks to (its host's id), so its calls are recorded as that server's.
    public let providerId: String
    private let providerLabel: String

    let session = ProviderHTTP.session
    private let endpoint: Result<URL, Error>
    private let apiKeyOverride: String?
    /// Injected roots confine credentials; secondary runtimes must supply their own root.
    private let dataRootOverride: URL?
    public let telemetry: LLMCallTraceRecorder

    private var credentialRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    /// api.openai.com, or NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT when configured. A supplied override must be an absolute HTTP(S) loopback URL. Invalid
    /// configuration refuses the call before reading credentials.
    public static var defaultEndpoint: URL {
        get throws {
            guard let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT"] else {
                guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { throw URLError(.badURL) }
                return url
            }
            guard let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  ["127.0.0.1", "localhost", "[::1]"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port.map({ (1...65535).contains($0) }) != false else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: """
                        Invalid NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT: supply an absolute HTTP(S) loopback URL without credentials or fragment, or remove \
                        the override. No request was sent.
                        """)
            }
            return url
        }
    }

    func connectionError(_ error: Error, request: URLRequest) -> LLMError {
        .underlying(message: "connection refused: \(request.url?.host ?? "openai")")
    }

    public init(
        endpoint: URL? = nil,
        apiKeyOverride: String? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil,
        providerId: String = "openai",
        providerLabel: String = "OpenAI"
    ) {
        self.providerId = providerId
        self.providerLabel = providerLabel
        self.endpoint = Result { try endpoint ?? Self.defaultEndpoint }
        self.apiKeyOverride = apiKeyOverride
        self.dataRootOverride = dataRootOverride
        // Telemetry follows the credential body's root unless explicitly overridden, preventing secondary calls from writing to the user's live data.
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    // MARK: - Structured streaming (tool calls)

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        // OpenAI's own model catalog decides its Responses models; a local server speaks chat completions only.
        if providerId == "openai", OpenAIExecutionControls.usesResponses(model: model, dataRoot: credentialRoot) {
            return responsesTransport.streamMessages(messages: messages, system: system, model: model, tools: tools, call: call)
        }
        return chatTransport.streamMessages(messages: messages, system: system, model: model, tools: tools, call: call)
    }

    private var chatTransport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: prepare)
    }

    private func prepare(_ input: ProviderStreamInput) async throws -> ChatCompletionsWire {
        let messages = input.messages
        let system = input.system
        let model = input.model
        let tools = input.tools
        let call = input.call
        let endpoint = try endpoint.get()
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
            "messages": try Self.chatMessages(messages: messages, system: system),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        try Self.applyTools(to: &body, tools: tools)
        if providerId == "openai" {
            try OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model, call: call, dataRoot: credentialRoot)
        }
        if call.turn?.tokenBudget != nil {
            body["max_completion_tokens"] = try self.requestOutputTokens(model: model, call: call)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return ChatCompletionsWire(request: req, label: providerLabel, model: model, profile: self, call: call)
    }

    // MARK: - Public Responses API

    private func responsesRequest(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall
    ) throws -> URLRequest {
        let endpoint = try endpoint.get()
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
        // The route's effective row (listed by OpenAI for this key, else shipped) owns the public controls.
        let row = FirstPartyModelCatalog.descriptor(for: model, providerID: "openai", dataRoot: credentialRoot)
        var body = try ChatGPTTransport.buildResponsesBodyFromMessages(
            model: model, messages: messages, system: system, tools: tools, transport: .publicAPI,
            supportedEfforts: row?.supportedReasoningEfforts ?? [], supportsFast: row?.supportsFast ?? false, call: call
        )
        body["prompt_cache_options"] = ["ttl": "30m"]
        if call.turn?.tokenBudget != nil {
            body["max_output_tokens"] = try requestOutputTokens(model: model, call: call)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private var responsesTransport: any LLMTransport {
        HTTPStreamTransport(profile: self, prepare: { [self] input in
            let request = try responsesRequest(messages: input.messages, system: input.system, model: input.model, tools: input.tools, call: input.call)
            return ResponsesWire(request: request, model: input.model, profile: self, call: input.call, label: "openai", errorPrefix: "openai")
        })
    }

    // MARK: - Shared body / response helpers

    /// Shared Chat Completions tool fields must leave tool-free bodies byte-identical.
    static func applyTools(to body: inout [String: Any], tools: [LLMToolSchema]?) throws {
        guard let tools, !tools.isEmpty else { return }
        body["tools"] = try tools.map { schema in
            _ = try schema.checkedParameters()
            return [
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

    static func chatMessages(messages: [LLMMessage], system: String?) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let system, !system.isEmpty {
            out.append(["role": "system", "content": system])
        }
        for message in messages {
            out.append(contentsOf: try chatCompletionsMessages(from: message))
        }
        return out
    }


}
