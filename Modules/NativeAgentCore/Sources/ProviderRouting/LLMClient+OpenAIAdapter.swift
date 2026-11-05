import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `LLMClient+OpenAIAdapter.swift` | `OpenAITransport`: checked API transport and message encoding |

/// GPT-6 requires Responses; other declared models use Chat Completions.
public final class OpenAITransport: LLMTransport {
    public static let toolWire = ProviderToolWire.native
    /// Both OpenAI wires send exactly the remaining per-turn cap, when bound.
    public func requestOutputTokens(model: String, call: LLMCall) throws -> Int {
        call.turn?.tokenBudget?.available ?? 0
    }

    public let providerId: String = "openai"

    private let session: URLSession
    private let endpoint: Result<URL, Error>
    private let apiKeyOverride: String?
    /// Injected roots confine credentials; secondary runtimes must supply their own root.
    private let dataRootOverride: URL?
    private let telemetry: LLMCallTraceRecorder

    private var credentialRoot: URL {
        dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    /// api.openai.com, or NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT when configured. A supplied override must be an absolute HTTP(S) loopback URL. Invalid
    /// configuration refuses the call before reading credentials.
    public static var defaultEndpoint: URL {
        get throws {
            guard let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT"] else {
                return URL(string: "https://api.openai.com/v1/chat/completions")!
            }
            guard let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  ["127.0.0.1", "localhost", "[::1]"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port == nil || (1...65535).contains(url.port!) else {
                throw ProviderFailure.Diagnostic(cause: .routingUnavailable,
                    detail: """
                        Invalid NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT: supply an absolute HTTP(S) loopback URL without credentials or fragment, or remove \
                        the override. No request was sent.
                        """)
            }
            return url
        }
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL? = nil,
        apiKeyOverride: String? = nil,
        dataRootOverride: URL? = nil,
        telemetryDataRootOverride: URL? = nil
    ) {
        self.session = session
        self.endpoint = Result { try endpoint ?? Self.defaultEndpoint }
        self.apiKeyOverride = apiKeyOverride
        self.dataRootOverride = dataRootOverride
        // Telemetry follows the credential body's root unless explicitly overridden, preventing secondary calls from writing to the user's live data.
        self.telemetry = LLMCallTraceRecorder(
            dataRootOverride: telemetryDataRootOverride ?? dataRootOverride
        )
    }

    /// Nil or empty tools must preserve the plain completion body.
    public func complete(
        prompt: String,
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) async throws -> String {
        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: [.user(prompt)], system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }

    // MARK: - Structured messages (native vision)

    /// Images and tool blocks require structured Chat Completions messages; text-only calls preserve their role-prefixed wire bytes.
    public func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
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
            let flattened = try llmCompatibilityPrompt(messages: messages) { role in
                role == .user ? "USER:" : "ASSISTANT:"
            }
            let combined = flattened.text
            return try await complete(prompt: combined, system: system, model: model, tools: tools, call: call)
        }

        return try await LLMMessageStreamEvent.reply(collecting:
            { held in self.streamMessages(messages: messages, system: system, model: model, tools: tools, call: held) }, using: telemetry, call: call)
    }

    // MARK: - Structured streaming (tool calls)

    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        if OpenAIExecutionControls.usesResponses(model: model) {
            return streamResponses(messages: messages, system: system, model: model, tools: tools, call: call)
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
                    try OpenAIExecutionControls.applyChatCompletionsControls(to: &body, model: model, call: call)
                    if call.turn?.tokenBudget != nil {
                        body["max_completion_tokens"] = try self.requestOutputTokens(model: model, call: call)
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await ProviderWire.open(session, req, call: call)
                    } catch {
                        throw mapTransportError(error, fallback: .underlying(message: "connection refused: \(endpoint.host ?? "openai")"))
                    }
                    defer { bytes.task.cancel() }
                    try await ProviderWire.validateChatCompletions(bytes, response)
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "OpenAI", diagnosticDataRoot: telemetry.diagnosticDataRoot(call: call),
                        call: call)
                    try await decoder.consume(
                        SSEEventStream(bytes, lifetime: call.lifetime), continuation: continuation,
                        request: req, providerID: providerId, model: model, idPrefix: "openai",
                        started: requestStartNs, telemetry: telemetry, call: call
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
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
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
        var body = try ChatGPTTransport.buildResponsesBodyFromMessages(
            model: model, messages: messages, system: system, tools: tools, transport: .publicAPI, call: call
        )
        body["prompt_cache_options"] = ["ttl": "30m"]
        if call.turn?.tokenBudget != nil {
            body["max_output_tokens"] = try requestOutputTokens(model: model, call: call)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private func streamResponses(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    var req = try responsesRequest(messages: messages, system: system, model: model, tools: tools, call: call)
                    let requestStartNs = DispatchTime.now().uptimeNanoseconds
                    let (bytes, response) = try await ProviderWire.open(session, req, call: call)
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
                        continuation: continuation, call: call
                    )
                    continuation.finish()
                } catch let err as LLMError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: mapTransportError(error, fallback: .underlying(message: "stream: \(error)")))
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
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
