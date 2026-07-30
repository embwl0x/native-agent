import Foundation
import NativeAgentCore
import PersistenceCore

/// First-class Moonshot/Kimi adapter over the provider's OpenAI-compatible
/// Chat Completions surface. Unlike the generic API-key fallthrough, this
/// preserves structured tool calls, vision inputs, SSE deltas, and Kimi's
/// required reasoning state across K3/K2.7 tool loops.
public final class MoonshotAdapter: LLMAdapter {
    public let providerId = "moonshot"

    public static let defaultEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    public static let defaultModel = "kimi-k3"

    private let session: URLSession
    private let endpoint: URL
    private let apiKeyOverride: String?
    private let dataRootOverride: URL?
    private let telemetry: LLMCallTraceRecorder
    private let reasoningLedger = MoonshotReasoningLedger()

    private var credentialRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }
    private var includesEnvironment: Bool {
        dataRootOverride == nil
            || credentialRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL
    }

    public init(
        session: URLSession = .shared,
        endpoint: URL = MoonshotAdapter.defaultEndpoint,
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

    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        try await completeMessages(messages: [.user(prompt)], system: system, model: model, tools: nil)
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
        let key = try apiKey()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NativeAgent (Darwin)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: await buildBody(
            model: model, messages: messages, system: system, tools: tools, stream: false
        ))

        let started = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error, fallback: .transient(message: "connection failed: \(endpoint.host ?? "moonshot")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try Self.validate(status: status, data: data, response: response)
        let parsed = try Self.parseCompletion(data: data, status: status)
        if !parsed.toolCalls.isEmpty, !parsed.reasoning.isEmpty {
            await reasoningLedger.record(reasoning: parsed.reasoning, callIDs: parsed.toolCalls.map(\.id))
        }
        let duration = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromOpenAIChatCompletions(parsed.usage),
            ttftMs: nil,
            durationMs: duration
        )
        var pieces: [String] = parsed.text.isEmpty ? [] : [parsed.text]
        pieces.append(contentsOf: parsed.toolCalls.map { call in
            "<tool_use id=\"\(call.id)\" name=\"\(call.name)\">\(call.arguments)</tool_use>"
        })
        return pieces.joined(separator: "\n")
    }

    public func stream(prompt: String, system: String?, model: String) -> AsyncThrowingStream<String, Error> {
        streamMessages(messages: [.user(prompt)], system: system, model: model, tools: nil)
            .moonshotTextDeltas()
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
                    request.timeoutInterval = 300
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    applyStreamingLLMHeaders(to: &request)
                    request.httpBody = try JSONSerialization.data(withJSONObject: await self.buildBody(
                        model: model, messages: messages, system: system, tools: tools, stream: true
                    ))

                    let started = DispatchTime.now().uptimeNanoseconds
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw mapTransportError(error, fallback: .transient(message: "connection failed: \(endpoint.host ?? "moonshot")"))
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        // 2026-07-21 audit: route through the SAME mapping the
                        // non-streaming path uses (Self.validate →
                        // throwIfChatCompletionsError) so a streaming 5xx is
                        // .transient (retryable) — the hand-check threw terminal
                        // .invalidResponse, divergent from the deliberate unified
                        // 5xx→transient policy. Drain + preserve a bounded
                        // error-body chunk (the Anthropic stream's 4KB pattern)
                        // so the provider's real message survives.
                        var errData = Data()
                        do {
                            for try await byte in bytes {
                                errData.append(byte)
                                if errData.count >= 4096 { break }
                            }
                        } catch {}
                        try Self.validate(status: status, data: errData, response: response)
                        // validate() throws for every non-2xx; unreachable.
                        throw LLMError.invalidResponse(status: status)
                    }

                    var ttftMs: Int?
                    // C1: the SSE framing, [DONE] tracking, root error frames
                    // (M-F1), usage capture (M-F2), and tool-call accumulation
                    // now live in the shared decoder. This loop keeps only
                    // Moonshot's YIELD policy: a keepAlive per reasoning chunk
                    // and per tool-call delta (idle-clock liveness), ttft
                    // stamping on the first content delta, and the reasoning
                    // ledger.
                    var decoder = ChatCompletionsStreamDecoder(providerLabel: "Moonshot")
                    for try await event in SSEEventStream(bytes) {
                        try Task.checkCancellation()
                        let frame = try decoder.consume(payload: event.data)
                        if frame.isDone { break }
                        if frame.reasoning != nil {
                            continuation.yield(.keepAlive)
                        }
                        if let content = frame.content {
                            if ttftMs == nil {
                                ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
                            }
                            continuation.yield(.textDelta(content))
                        }
                        for _ in 0..<frame.toolCallDeltaCount {
                            continuation.yield(.keepAlive)
                        }
                    }
                    guard decoder.sawDone else {
                        throw LLMError.streamTruncated(message: "moonshot stream ended without [DONE]")
                    }
                    let completed = decoder.completedToolCalls(idPrefix: "moonshot_tool")
                    for call in completed {
                        continuation.yield(.toolCall(.init(
                            id: call.id,
                            name: call.name,
                            inputJSON: Data(call.arguments.utf8)
                        )))
                    }
                    if !completed.isEmpty, !decoder.reasoning.isEmpty {
                        await ledger.record(reasoning: decoder.reasoning, callIDs: completed.map(\.id))
                    }
                    let duration = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
                    await telemetry.record(
                        provider: providerID, model: model, streaming: true,
                        usage: decoder.usage, ttftMs: ttftMs, durationMs: duration
                    )
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
            apiMessages.append(contentsOf: try await chatMessages(from: message))
        }
        var body: [String: Any] = ["model": model, "messages": apiMessages, "stream": stream]
        if stream { body["stream_options"] = ["include_usage": true] }
        if let tools, !tools.isEmpty {
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
        applyReasoningControls(to: &body, model: model)
        return body
    }

    private func chatMessages(from message: LLMMessage) async throws -> [[String: Any]] {
        let role = message.role == .user ? "user" : "assistant"
        var textParts: [String] = []
        var contentParts: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var toolCallIDs: [String] = []
        var toolResults: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let text):
                textParts.append(text)
                contentParts.append(["type": "text", "text": text])
            case .image(let mediaType, let base64, _, _):
                contentParts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(base64)"],
                ])
            case .toolUse(let id, let name, let inputJSON):
                toolCallIDs.append(id)
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": String(data: inputJSON, encoding: .utf8) ?? "{}",
                    ],
                ])
            case .toolResult(let toolUseID, let content, _):
                toolResults.append(["role": "tool", "tool_call_id": toolUseID, "content": content])
            }
        }
        var output: [[String: Any]] = []
        if !toolCalls.isEmpty {
            var assistant: [String: Any] = [
                "role": "assistant",
                "content": textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n"),
                "tool_calls": toolCalls,
            ]
            if let preserved = await reasoningLedger.reasoning(forAny: toolCallIDs) {
                assistant["reasoning_content"] = preserved
            }
            output.append(assistant)
        } else if !contentParts.isEmpty {
            let hasImage = message.content.contains { if case .image = $0 { return true }; return false }
            output.append([
                "role": role,
                "content": hasImage ? contentParts : textParts.joined(separator: "\n"),
            ])
        }
        output.append(contentsOf: toolResults)
        return output
    }

    private func applyReasoningControls(to body: inout [String: Any], model: String) {
        let id = model.lowercased()
        if id == "kimi-k3" || id.hasPrefix("kimi-k2.7-code") {
            body["reasoning_effort"] = "max"
        } else if id == "kimi-k2.6" || id == "kimi-k2.5" {
            let effort = LLMCallContext.reasoningEffort?.lowercased()
            body["thinking"] = ["type": effort == "none" ? "disabled" : "enabled"]
        }
    }

    private func apiKey() throws -> String {
        guard let key = apiKeyOverride ?? LLMCredentialResolver.resolveAPIKey(
            envVar: "MOONSHOT_API_KEY",
            providerConfigFile: "moonshot.json",
            dataRoot: credentialRoot,
            includeEnvironment: includesEnvironment
        ), !key.isEmpty else {
            throw LLMError.notConfigured(provider: "moonshot")
        }
        return key
    }

    private static func parseCompletion(data: Data, status: Int) throws -> (
        text: String, reasoning: String, toolCalls: [MoonshotToolCall], usage: [String: Any]?
    ) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.invalidResponse(status: status)
        }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { index, raw -> MoonshotToolCall? in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String, !name.isEmpty else { return nil }
            return MoonshotToolCall(
                id: (raw["id"] as? String) ?? "moonshot_tool_\(index)_\(name)",
                name: name,
                arguments: (function["arguments"] as? String) ?? "{}"
            )
        }
        return (
            (message["content"] as? String) ?? "",
            (message["reasoning_content"] as? String) ?? "",
            calls,
            root["usage"] as? [String: Any]
        )
    }

    private static func validate(status: Int, data: Data, response: URLResponse? = nil) throws {
        try throwIfChatCompletionsError(
            status: status,
            data: data,
            mapping: ChatCompletionsStatusMapping(
                provider: "moonshot",
                rateLimited: { boundedBody($0) },
                serverError: { boundedBody($0) },
                otherwise: { status, data in
                    .providerError(message: "Moonshot HTTP \(status): \(boundedBody(data))")
                }
            ),
            response: response
        )
    }
}

private struct MoonshotToolCall: Sendable {
    let id: String
    let name: String
    let arguments: String
}

private actor MoonshotReasoningLedger {
    private var byCallID: [String: String] = [:]
    private var order: [String] = []
    private let limit = 512

    func record(reasoning: String, callIDs: [String]) {
        guard !reasoning.isEmpty else { return }
        for id in callIDs where !id.isEmpty {
            if byCallID[id] == nil { order.append(id) }
            byCallID[id] = reasoning
        }
        while order.count > limit {
            byCallID.removeValue(forKey: order.removeFirst())
        }
    }

    func reasoning(forAny callIDs: [String]) -> String? {
        callIDs.compactMap { byCallID[$0] }.first
    }
}

private extension AsyncThrowingStream where Element == LLMMessageStreamEvent, Failure == Error {
    func moonshotTextDeltas() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await event in self {
                        switch event {
                        case .textDelta(let text): continuation.yield(text)
                        case .toolCall, .keepAlive: continue
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
}
