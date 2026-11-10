import CryptoKit
import Foundation
import NativeAgentCore
// Use the shared SSE framer rather than interpreting transport lines here.
import PersistenceCore
// Blueprint: | `LLMClient+AnthropicNativeTools.swift` | `AnthropicTransport`, `ProviderWire`: ordered native calls and signed replay |

// API-key transports carry native tools; OAuth transports use text markers. Omit tool_choice; strict tool definitions require first-party closed schemas.
// Dispatch every tool_use block and return its results in one user message. Tool inputs are parsed JSON; a textless response with tool calls is valid.

/// Exact provider thinking and signature, held together in memory; never rendered or persisted as conversation content.
struct AnthropicThinkingBlock: Sendable, Equatable {
    let type: String
    /// Redacted blocks carry no readable thinking text.
    let text: String
    /// Keep the provider's signature paired with its thinking text.
    let signature: String?
    /// Redacted payloads must replay verbatim.
    let data: String?

    var wireBlock: [String: Any] {
        if type == "redacted_thinking" {
            return ["type": "redacted_thinking", "data": data ?? ""]
        }
        var block: [String: Any] = ["type": "thinking", "thinking": text]
        if let signature, !signature.isEmpty { block["signature"] = signature }
        return block
    }

    init?(responseBlock: [String: Any]) {
        guard let type = responseBlock["type"] as? String else { return nil }
        switch type {
        case "thinking":
            self.type = type
            self.text = responseBlock["thinking"] as? String ?? ""
            self.signature = responseBlock["signature"] as? String
            self.data = nil
        case "redacted_thinking":
            self.type = type
            self.text = ""
            self.signature = nil
            self.data = responseBlock["data"] as? String ?? ""
        default:
            return nil
        }
    }

    init(type: String, text: String, signature: String?, data: String?) {
        self.type = type
        self.text = text
        self.signature = signature
        self.data = data
    }
}

/// Thinking with the digest of the request that produced it: model, system, tools and every message. The provider accepts it back only in that conversation.
struct AnthropicThinkingRecord: Sendable {
    let blocks: [AnthropicThinkingBlock]
    let conversation: Data
}

/// Memory-only replay payloads keyed by every sibling tool-call ID, evicted in insertion order.
actor ToolCallReplayLedger<Payload: Sendable> {
    private var byToolUseID: [String: Payload] = [:]
    private var order: [String] = []
    private let limit = 512

    func record(_ payload: Payload, callIDs: [String]) {
        for id in callIDs where !id.isEmpty {
            if byToolUseID[id] == nil { order.append(id) }
            byToolUseID[id] = payload
        }
        while order.count > limit {
            byToolUseID.removeValue(forKey: order.removeFirst())
        }
    }

    func payload(forAny toolUseIDs: [String]) -> Payload? {
        for id in toolUseIDs {
            if let blocks = byToolUseID[id] { return blocks }
        }
        return nil
    }

    func forget(callIDs: [String]) {
        for id in callIDs { byToolUseID.removeValue(forKey: id) }
        order.removeAll { byToolUseID[$0] == nil }
    }
}



extension AnthropicTransport {
    /// A delta belongs to its indexed block, even when its own type claims otherwise.
    static func validateContentBlockEvent(
        _ object: [String: Any], event: String, blocks: inout [Int: String]
    ) throws {
        guard ["content_block_start", "content_block_delta", "content_block_stop"].contains(event) else { return }
        guard let index = object["index"] as? Int, index >= 0 else {
            throw LLMError.failure(.malformedResponse)
        }
        if event == "content_block_start" {
            guard blocks.isEmpty, let block = object["content_block"] as? [String: Any],
                  let type = block["type"] as? String else { throw LLMError.failure(.malformedResponse) }
            blocks[index] = type
        } else {
            guard let type = blocks[index] else { throw LLMError.failure(.malformedResponse) }
            if event == "content_block_stop" {
                blocks.removeValue(forKey: index)
            } else {
                guard let delta = object["delta"] as? [String: Any] else { throw LLMError.failure(.malformedResponse) }
                let expected: String?
                switch delta["type"] as? String {
                case "text_delta": expected = "text"
                case "thinking_delta", "signature_delta": expected = "thinking"
                case "input_json_delta": expected = "tool_use"
                default: expected = nil
                }
                if let expected, type != expected { throw LLMError.failure(.malformedResponse) }
            }
        }
    }

    static func consumeStreamEvent(
        _ sse: SSEEvent, usage: inout LLMUsage, stopReason: inout String?,
        blocks: inout [Int: String], ttftMs: inout Int?, semanticOutput: inout Bool,
        requestStartNs: UInt64,
        requestBody: Data?, provider: String, model: String, telemetry: LLMCallTraceRecorder,
        malformedFrame: String, continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation,
        substitutedFrom: String? = nil, cacheMarkers: [LLMCacheMarker]? = nil,
        inspectThinking: ((String, Bool) -> Void)? = nil,
        call: LLMCall, payload: (String, [String: Any], String?) async throws -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        if sse.data.isEmpty || sse.data == "[DONE]" { return false }
        let data = Data(sse.data.utf8)
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderFailure.Diagnostic(cause: .malformedResponse, detail: malformedFrame)
            }
            object = decoded
        } catch {
            throw ProviderFailure.Diagnostic(cause: .malformedResponse, detail: malformedFrame)
        }
        let type = object["type"] as? String ?? ""
        let event = type.isEmpty ? (sse.event ?? "") : type
        let closingTool = event == "content_block_stop" && blocks.values.first == "tool_use"
        try validateContentBlockEvent(object, event: event, blocks: &blocks)
        if event == "message_stop", !blocks.isEmpty { throw LLMError.failure(.malformedResponse) }
        var thinking: String?
        var redacted = false
        var output = false
        switch event {
        case "error":
            throw ProviderFailure.wireError(object["error"] as? [String: Any] ?? [:])
        case "message_start":
            let message = object["message"] as? [String: Any]
            usage.merge(LLMUsage.fromAnthropic(message?["usage"] as? [String: Any]))
        case "message_delta":
            usage.merge(LLMUsage.fromAnthropic(object["usage"] as? [String: Any]))
            if let delta = object["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                stopReason = stop
            }
        case "content_block_start":
            let block = object["content_block"] as? [String: Any]
            let type = block?["type"] as? String
            redacted = type == "redacted_thinking"
            if redacted { thinking = "[redacted]" }
            if inspectThinking == nil, type == "thinking" {
                thinking = (block?["thinking"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            output = thinking != nil || (inspectThinking == nil && type == "tool_use")
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    output = true
                    semanticOutput = semanticOutput || text.contains(where: { !$0.isWhitespace })
                    continuation.yield(.textDelta(text))
                }
            case "thinking_delta":
                thinking = (delta["thinking"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                output = thinking != nil
            case "input_json_delta": output = inspectThinking == nil
            default: break
            }
        case "content_block_stop": output = inspectThinking == nil && closingTool
        default: break
        }
        if output, ttftMs == nil {
            ttftMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        }
        if let thinking {
            inspectThinking?(thinking, redacted)
            continuation.yield(.keepAlive)
        }
        let produced = try await payload(event, object, stopReason)
        semanticOutput = semanticOutput || produced
        guard event == "message_stop" else { return false }
        let cutoff = LLMToolBoundaryReason(stopReason: stopReason) == .outputLimit
        let silentCompletion = call.allowsSilentCompletion && stopReason == "end_turn"
        let emptyError = !cutoff && !semanticOutput && !silentCompletion
            ? FirstPartyExecutionControls.anthropicEmptyStreamError(
                providerID: provider, stopReason: stopReason, expectedOutput: "answer text or tool call") : nil
        await telemetry.record(call: call, requestBody: requestBody, provider: provider, model: model,
            streaming: true, usage: usage.isEmpty ? nil : usage, ttftMs: ttftMs,
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
            status: cutoff ? "incomplete" : emptyError == nil ? "ok" : "failed",
            substitutedFrom: substitutedFrom, cacheMarkers: cacheMarkers,
            stopReason: stopReason)
        if let emptyError { throw emptyError }
        if let reason = LLMToolBoundaryReason(stopReason: stopReason) {
            continuation.yield(.toolBoundary(reason))
        }
        continuation.finish()
        return true
    }

    // MARK: - Request encoding

    /// Strict validation requires every object in the authored schema to close itself; forcing closure would reject valid extras. A last-tool cache marker
    /// covers the full tools prefix and leaves room within the four-marker request budget.
    static func nativeToolsArray(
        _ tools: [LLMToolSchema],
        strict: Bool,
        cacheBreakpoint: Bool
    ) throws -> [[String: Any]] {
        var out: [[String: Any]] = try tools.map { schema in
            _ = try schema.checkedParameters()
            var inputSchema = try checkedProviderJSONObject(schema.parametersJSON, owner: "Tool schema \(schema.name)")
            var tool: [String: Any] = [
                "name": schema.name,
                "description": schema.description,
            ]
            if strict, schemaIsRecursivelyClosed(inputSchema) {
                // Closed schemas need a required list even when empty, or the provider rejects the request.
                if inputSchema["required"] == nil {
                    inputSchema["required"] = [String]()
                }
                tool["strict"] = true
            }
            tool["input_schema"] = inputSchema
            return tool
        }
        if cacheBreakpoint, var last = out.popLast() {
            last["cache_control"] = AnthropicOAuthTransport.ephemeralCacheControl
            out.append(last)
        }
        return out
    }

    /// JSON Schema objects are open by default, including nodes with properties but no type. Every reachable object must explicitly close itself before
    /// strict can be claimed; one open node omits strict for the whole tool.
    static func schemaIsRecursivelyClosed(_ node: Any) -> Bool {
        if let list = node as? [Any] {
            return list.allSatisfy { schemaIsRecursivelyClosed($0) }
        }
        guard let obj = node as? [String: Any] else {
            // Scalar leaves carry no object schema to close.
            return true
        }
        let declaresObject = (obj["type"] as? String) == "object"
            || ((obj["type"] as? [Any])?.contains { ($0 as? String) == "object" } ?? false)
        if declaresObject || obj["properties"] is [String: Any] {
            guard (obj["additionalProperties"] as? Bool) == false else { return false }
        }
        // Map values are schemas; keys are declaration names.
        for key in ["properties", "$defs", "definitions"] {
            guard let map = obj[key] as? [String: Any] else { continue }
            for (_, sub) in map where !schemaIsRecursivelyClosed(sub) { return false }
        }
        for key in ["items", "anyOf", "oneOf", "allOf"] {
            guard let sub = obj[key] else { continue }
            if !schemaIsRecursivelyClosed(sub) { return false }
        }
        return true
    }

    /// Wire fields stay separate from message policy.
    static func anthropicBlock(_ block: LLMContentBlock) throws -> [String: Any] {
        switch block {
        case .text(let text): return ["type": "text", "text": text]
        case .image(let mediaType, let base64, _, _):
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
        case .toolUse(let id, let name, let inputJSON):
            let input = try checkedProviderJSONObject(inputJSON, owner: "Recorded tool call \(name) (\(id))")
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let id, let content, let isError):
            var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
            if isError { result["is_error"] = true }
            return result
        }
    }

    /// The API rejects empty content arrays.
    static func nativeAnthropicMessages(_ messages: [LLMMessage]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                // Native messages omit empty text while retaining replay order.
                if case .text(let text) = block, text.isEmpty { continue }
                blocks.append(try Self.anthropicBlock(block))
            }
            guard !blocks.isEmpty else { continue }
            // Mid-conversation system roles stay system on the native wire.
            let entry: [String: Any] = [
                "role": AnthropicOAuthTransport.wireRole(m.role),
                "content": blocks,
            ]
            out.append(entry)
        }
        return out
    }

    /// Omit tool_choice: auto is the default and forced tools are rejected by thinking-required models. Prompt guidance cannot alter schema authority.
    /// Signed thinking replays before its assistant message's text and calls, and only while the model, system, tools and every earlier message are the
    /// ones that produced it; seen anywhere else it is forgotten, so a block once left out never returns.
    func makeNativeToolsBody(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema],
        stream: Bool, call: LLMCall
    ) async throws -> (body: [String: Any], conversation: Data) {
        // Omit empty tool declarations because their presence can select tool mode; native call/result encoding still applies.
        let wireTools = tools.isEmpty ? [] : try Self.nativeToolsArray(
            tools,
            strict: firstPartyAnthropicToolContract,
            cacheBreakpoint: firstPartyAnthropicToolContract
        )
        let systemBlocks = Self.makeSystemBlocks(system, segments: call.systemSegments,
            cacheEligible: call.session != nil, cacheControl: systemCacheControl)
        // Cache markers are outside what thinking is bound to.
        var conversation = SHA256()
        conversation.update(data: try JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": (systemBlocks ?? []).compactMap { $0["text"] as? String },
            "tools": wireTools.map { $0.filter { $0.key != "cache_control" } },
        ] as [String: Any], options: [.sortedKeys]))
        var encoded: [(Int, [String: Any])] = []
        var forgotten = 0
        for (index, message) in messages.enumerated() {
            guard var wire = try Self.nativeAnthropicMessages([message]).first else { continue }
            let plain = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
            let ids = message.role == .assistant && replaysThinking ? message.content.compactMap { block -> String? in
                if case .toolUse(let id, _, _) = block { return id }
                return nil
            } : []
            if let record = await thinkingLedger.payload(forAny: ids) {
                if Data(conversation.finalize()) == record.conversation {
                    wire["content"] = record.blocks.map(\.wireBlock) + (wire["content"] as? [[String: Any]] ?? [])
                } else {
                    await thinkingLedger.forget(callIDs: ids)
                    forgotten += 1
                }
            }
            conversation.update(data: plain)
            encoded.append((index, wire))
        }
        if forgotten > 0 {
            nativeLog("%@", "\(providerId) thinking: \(forgotten) recorded round(s) left behind; the conversation before them changed (\(model))")
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": try requestOutputTokens(model: model, call: call),
            "messages": encoded.map { $0.1 },
        ]
        if stream { body["stream"] = true }
        if !wireTools.isEmpty { body["tools"] = wireTools }
        if let systemBlocks { body["system"] = systemBlocks }
        if firstPartyAnthropicToolContract {
            let usesPrefix = system.map { call.systemSegments?.reassembles(into: $0) == true } ?? false
            AnthropicOAuthTransport.cacheConversationPrefix(&body, sourceMessages: messages,
                wireSourceIndices: encoded.map { $0.0 }, usesPrefixShape: usesPrefix, call: call)
        }
        if firstPartyAnthropicToolContract { try FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model, call: call) }
        try applyThinkingControls(to: &body, model: model, call: call)
        return (body, Data(conversation.finalize()))
    }

    // MARK: - Response parsing

    /// Thinking is replay evidence, never a tool call or visible reply.
    static func nativeToolCalls(_ content: [[String: Any]]) throws -> [LLMStreamToolCall] {
        try content.filter { ($0["type"] as? String) == "tool_use" }.map { block in
            guard let id = block["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = block["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let input = block["input"] as? [String: Any] else {
                throw LLMError.failure(.malformedResponse)
            }
            let data = try JSONSerialization.data(withJSONObject: input)
            return LLMStreamToolCall(id: id, name: name, inputJSON: data)
        }
    }

    // MARK: - Streaming

    /// Anthropic-compatible message routes expose real SSE progress, with or without tools.
    public func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?, call: LLMCall
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runNativeToolsStream(messages: messages, system: system,
                        model: model, tools: tools ?? [], continuation: continuation, call: call)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error,
                        fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            call.replyWork?.own(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - First-party SSE tool streaming (Fable 5.1 shape D)

    /// Thinking and argument deltas renew liveness without entering reply text. Block-local accumulation prevents fragments from bleeding into sibling
    /// calls; empty inputs await the terminal verdict.
    private func runNativeToolsStream(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema],
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation, call: LLMCall
    ) async throws {
        let (body, conversation) = try await makeNativeToolsBody(
            messages: messages, system: system, model: model, tools: tools, stream: true, call: call
        )
        var req = try request(body: body)
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let bytes: ProviderHTTPBytes
        let response: URLResponse
        do {
            (bytes, response) = try await ProviderWire.open(session, req, call: call)
        } catch {
            throw mapTransportError(error, fallback: .underlying(
                message: "\(providerId) connection failed: \(ProviderFailure.diagnosticDescription(error))"))
        }
        defer { bytes.cancel() }

        // HTTP failures retain their typed cause, with the body drained (bounded) so a provider message survives into the error.
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = http.statusCode
        if !(200..<300).contains(status) {
            let errData = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096)
            try throwIfChatCompletionsError(status: status, data: errData, response: response)
        }

        var usage = LLMUsage()
        var ttftMs: Int?
        // A tool-only response is valid; only absence of both text and calls is empty.
        var yieldedSemanticOutput = false
        var lastStopReason: String?
        var contentBlocks: [Int: String] = [:]
        // The open tool name distinguishes a tool block from text/thinking so their stop events cannot close a call.
        var openToolId: String?
        var openToolName: String?
        var openToolJSON = ""
        var pendingToolCalls: [LLMStreamToolCall] = []
        // Thinking text and signatures are valid only together; accumulate them per block and bind completed replay to every confirmed sibling call.
        var openThinkingType: String?
        var openThinkingText = ""
        var openThinkingSignature = ""
        var openThinkingData: String?
        var thinkingBlocks: [AnthropicThinkingBlock] = []

        func commitToolCalls(terminal: Bool, stopReason: String?) async throws -> Bool {
            var committed = false
            while let call = pendingToolCalls.first {
                if call.inputJSON.isEmpty && !terminal { break }
                pendingToolCalls.removeFirst()
                if call.inputJSON.isEmpty,
                   !["end_turn", "tool_use", "stop_sequence", "pause_turn"].contains(stopReason ?? "") { continue }
                let json = call.inputJSON.isEmpty ? Data("{}".utf8) : call.inputJSON
                guard let input = try JSONSerialization.jsonObject(with: json) as? [String: Any]
                else { throw LLMError.failure(.malformedResponse) }
                let calls = try Self.nativeToolCalls([
                    ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
                ])
                if replaysThinking, !thinkingBlocks.isEmpty {
                    await thinkingLedger.record(
                        AnthropicThinkingRecord(blocks: thinkingBlocks, conversation: conversation), callIDs: calls.map(\.id))
                }
                committed = true
                for call in calls { continuation.yield(.toolCall(call)) }
            }
            return committed
        }

        do {
            for try await sse in SSEEventStream(bytes, lifetime: call.lifetime) {
                let finished = try await Self.consumeStreamEvent(
                    sse, usage: &usage, stopReason: &lastStopReason, blocks: &contentBlocks,
                    ttftMs: &ttftMs, semanticOutput: &yieldedSemanticOutput,
                    requestStartNs: requestStartNs, requestBody: req.httpBody, provider: providerId,
                    model: model, telemetry: telemetry,
                    malformedFrame: "\(providerId): malformed native tools stream frame",
                    continuation: continuation, call: call
                ) { event, obj, stopReason in
                    switch event {
                    case "message_stop":
                        return try await commitToolCalls(terminal: true, stopReason: stopReason)
                    case "content_block_start":
                        guard let block = obj["content_block"] as? [String: Any] else { return false }
                        let type = block["type"] as? String
                        if type == "thinking" || type == "redacted_thinking" {
                            openThinkingType = type
                            openThinkingText = block["thinking"] as? String ?? ""
                            openThinkingSignature = block["signature"] as? String ?? ""
                            openThinkingData = block["data"] as? String
                        } else if type == "tool_use" {
                            openToolId = block["id"] as? String ?? ""
                            openToolName = block["name"] as? String ?? ""
                            openToolJSON = ""
                        }
                    case "content_block_delta":
                        guard let delta = obj["delta"] as? [String: Any] else { return false }
                        switch delta["type"] as? String {
                        case "input_json_delta":
                            openToolJSON += delta["partial_json"] as? String ?? ""
                            // A named call's input says what is being written and how much.
                            let input = openToolName.map { LLMStreamCallInput(name: $0, input: openToolJSON.utf8) }
                            continuation.yield(input.map(LLMMessageStreamEvent.callInput) ?? .keepAlive)
                        case "thinking_delta":
                            openThinkingText += delta["thinking"] as? String ?? ""
                        case "signature_delta":
                            openThinkingSignature += delta["signature"] as? String ?? ""
                            continuation.yield(.keepAlive)
                        default: break
                        }
                    case "content_block_stop":
                        if let type = openThinkingType {
                            thinkingBlocks.append(AnthropicThinkingBlock(
                                type: type, text: openThinkingText,
                                signature: openThinkingSignature.isEmpty ? nil : openThinkingSignature,
                                data: openThinkingData))
                            openThinkingType = nil
                            openThinkingText = ""
                            openThinkingSignature = ""
                            openThinkingData = nil
                        } else if let name = openToolName {
                            // Empty candidates hold later calls in wire order until the terminal verdict.
                            let json = openToolJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                            pendingToolCalls.append(LLMStreamToolCall(
                                id: openToolId ?? "", name: name, inputJSON: Data(json.utf8)))
                            openToolId = nil
                            openToolName = nil
                            openToolJSON = ""
                            return try await commitToolCalls(terminal: false, stopReason: stopReason)
                        }
                    default: break
                    }
                    return false
                }
                if finished { return }
            }
            // EOF without message_stop is a truncation, not a clean end.
            throw LLMError.streamTruncated(
                message: "\(providerId): native tools stream ended without message_stop"
            )
        } catch {
            try Task.checkCancellation()
            if !(error is any ProviderFailureWrapping), ProviderFailure.classify(error) == .network {
                pendingToolCalls.removeAll { $0.inputJSON.isEmpty }
                _ = try await commitToolCalls(terminal: true, stopReason: lastStopReason)
            }
            if let err = error as? LLMError { throw err }
            throw mapTransportError(error, fallback: .underlying(message: "stream: \(error)"))
        }
    }
}
