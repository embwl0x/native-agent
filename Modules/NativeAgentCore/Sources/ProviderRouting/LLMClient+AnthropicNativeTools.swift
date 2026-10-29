import Foundation
import NativeAgentCore
// Provider streams share PersistenceCore's SSE framing.
import PersistenceCore
// Blueprint: | `LLMClient+AnthropicNativeTools.swift` | `AnthropicTransport`: buffered JSON and SSE both open through `ProviderWire`; native-tool stream decoding commits explicit object input at content-block close; empty-input candidates and later blocks wait in wire order for the terminal verdict; interruptions discard unconfirmed empty candidates and release explicit calls, retaining thinking replay; shared Anthropic event type, wire errors, usage and stop-reason accumulation |

// API-key transports carry native tools; OAuth transports use text markers.
// Omit tool_choice; strict tool definitions require first-party closed schemas.
// Dispatch every tool_use block and return its results in one user message.
// Tool inputs are parsed JSON; a textless response with tool calls is valid.

/// Exact provider thinking and signature replay, held together in memory for
/// the tool-calling turn; never rendered or persisted as conversation content.
struct AnthropicThinkingBlock: Sendable, Equatable {
    /// "thinking" or "redacted_thinking".
    let type: String
    /// The thinking text (`thinking` blocks). Empty for redacted blocks.
    let text: String
    /// The provider's attestation over `text` (`thinking` blocks).
    let signature: String?
    /// The opaque payload of a `redacted_thinking` block, replayed verbatim.
    let data: String?

    /// The exact block shape to put back on the wire.
    var wireBlock: [String: Any] {
        if type == "redacted_thinking" {
            return ["type": "redacted_thinking", "data": data ?? ""]
        }
        var block: [String: Any] = ["type": "thinking", "thinking": text]
        if let signature, !signature.isEmpty { block["signature"] = signature }
        return block
    }

    /// Parse a response content block; nil for anything that isn't thinking.
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
}

public struct AnthropicNativeToolResult: Sendable, Equatable {
    /// Joined text blocks. EMPTY is legal when `toolCalls` is non-empty.
    public let text: String
    /// Every `tool_use` block, in wire order (P0 shape C: all must dispatch).
    public let toolCalls: [LLMStreamToolCall]
    /// Raw provider `stop_reason` ("tool_use", "end_turn", "max_tokens", …).
    public let stopReason: String?

    public init(text: String, toolCalls: [LLMStreamToolCall], stopReason: String?) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
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
        runaway: inout RunawayOutputDetector, requestStartNs: UInt64,
        requestBody: Data?, provider: String, model: String, telemetry: LLMCallTraceRecorder,
        malformedFrame: String, continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation,
        substitutedFrom: String? = nil, cacheMarkers: [LLMCacheMarker]? = nil,
        inspectThinking: ((String, Bool) -> Void)? = nil,
        payload: (String, [String: Any], String?) async throws -> Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        if sse.data.isEmpty || sse.data == "[DONE]" { return false }
        guard let data = sse.data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if semanticOutput { throw LLMError.streamTruncated(message: malformedFrame) }
            return false
        }
        let type = object["type"] as? String ?? ""
        let event = type.isEmpty ? (sse.event ?? "") : type
        let closingTool = event == "content_block_stop" && blocks.values.first == "tool_use"
        try validateContentBlockEvent(object, event: event, blocks: &blocks)
        var boundary = false
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
                    semanticOutput = true
                    boundary = runaway.feed(text)
                    let kept = runaway.takeCommittedText()
                    if !kept.isEmpty { continuation.yield(.textDelta(kept)) }
                    else if inspectThinking != nil { continuation.yield(.keepAlive) }
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
        guard event == "message_stop" || boundary else { return false }
        if event == "message_stop", inspectThinking != nil {
            let tail = runaway.finish()
            if !tail.isEmpty { continuation.yield(.textDelta(tail)) }
        }
        let cutoff = !boundary && LLMToolBoundaryReason(stopReason: stopReason) == .outputLimit
        let emptyError = !boundary && !cutoff && !semanticOutput
            ? FirstPartyExecutionControls.anthropicEmptyStreamError(
                providerID: provider, stopReason: stopReason, expectedOutput: "answer text or tool call") : nil
        await telemetry.record(requestBody: requestBody, provider: provider, model: model,
            streaming: true, usage: usage.isEmpty ? nil : usage, ttftMs: ttftMs,
            durationMs: Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000),
            status: cutoff ? "incomplete" : emptyError == nil ? "ok" : "failed",
            substitutedFrom: substitutedFrom, cacheMarkers: cacheMarkers,
            stopReason: boundary ? "client_tool_boundary" : stopReason)
        if boundary {
            _ = try await payload("client_tool_boundary", object, stopReason)
        } else if cutoff {
            if inspectThinking != nil { AnthropicOAuthTransport.logCutoffShape(runaway.text) }
            RunawayOutputDetector.writeDiagnostic(runaway.text, reason: "output_limit")
        } else {
            if let emptyError { throw emptyError }
            if inspectThinking != nil { AnthropicOAuthTransport.logStopWithoutToolCall(stopReason, runaway.text) }
        }
        if let reason = cutoff ? LLMToolBoundaryReason.outputLimit : boundary ? runaway.toolBoundaryReason
            : LLMToolBoundaryReason(stopReason: stopReason) ?? (inspectThinking == nil ? nil : runaway.toolBoundaryReason) {
            continuation.yield(.toolBoundary(reason))
        }
        continuation.finish()
        return true
    }

    /// A non-nil tools array selects native block encoding, even when empty.
    /// Nil retains compatibility encoding; an empty array omits declarations
    /// while preserving tool-use/result blocks. Ordinary turns expose only `app`.
    func usesNativeToolLane(_ tools: [LLMToolSchema]?) -> Bool {
        tools != nil
    }

    // MARK: - Request encoding

    /// Anthropic `tools` array. `input_schema` is the tool's JSON-Schema object
    /// decoded from its canonical bytes; a schema that won't decode falls back
    /// to a permissive object rather than dropping the tool (a missing tool is
    /// invisible to the model; a loose schema is merely lenient).
    ///
    /// `strict` opts into PROVIDER-SIDE argument validation (Fable 5.1
    /// contract). It rides only where the tool's own schema already closed
    /// itself — at EVERY level (see `schemaIsRecursivelyClosed`). We
    /// deliberately never manufacture that closure: several tools here — the
    /// MCP schemaless passthrough shape above all — declare
    /// `additionalProperties: true` and genuinely accept extra keys, and
    /// forcing them shut would make the provider reject arguments the tool
    /// would have honored. Strictness is a property the schema earns, not one
    /// this encoder asserts.
    ///
    /// `cacheBreakpoint` stamps ONE ephemeral `cache_control` marker on the
    /// LAST tool definition — Anthropic prompt caching is a prefix match over
    /// tools → system → messages, so a breakpoint at the end of the tools
    /// block caches the whole declaration mass. Budget: this lane
    /// spends at most 1 here + at most 1 in `makeSystemBlocks`, well inside
    /// Anthropic's limit of 4 breakpoints per request.
    static func nativeToolsArray(
        _ tools: [LLMToolSchema],
        strict: Bool,
        cacheBreakpoint: Bool
    ) -> [[String: Any]] {
        var out: [[String: Any]] = tools.map { schema in
            var inputSchema: [String: Any] = (try? JSONSerialization.jsonObject(
                with: schema.parametersJSON
            )) as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            var tool: [String: Any] = [
                "name": schema.name,
                "description": schema.description,
            ]
            if strict, schemaIsRecursivelyClosed(inputSchema) {
                // The contract pairs `additionalProperties: false` with a
                // present `required` list. A closed schema that simply has no
                // mandatory arguments is legal — spell that as the empty list
                // rather than omitting the key and getting a 400.
                if inputSchema["required"] == nil {
                    inputSchema["required"] = [String]()
                }
                tool["strict"] = true
            }
            tool["input_schema"] = inputSchema
            return tool
        }
        if cacheBreakpoint, !out.isEmpty {
            out[out.count - 1]["cache_control"] = ["type": "ephemeral"]
        }
        return out
    }

    /// Is EVERY object schema reachable from this node explicitly closed?
    ///
    /// The root-only check this replaces was unsound: JSON Schema's default is
    /// OPEN, so a nested object that merely omits `additionalProperties`
    /// accepts extra keys — and claiming `strict: true` over it tells the
    /// provider to validate a contract the schema never made. Every object
    /// schema reachable through `properties`, `items`, `anyOf`/`oneOf`/`allOf`
    /// and `$defs`/`definitions` must carry `additionalProperties: false`
    /// itself; one open node anywhere in the tree omits `strict` for the whole
    /// tool (fail-open on the CLAIM, never on the schema).
    ///
    /// "Object schema" is read structurally: a declared `"type": "object"` OR
    /// any node that constrains named `properties`. Both accept extra keys by
    /// default, so both must close themselves.
    static func schemaIsRecursivelyClosed(_ node: Any) -> Bool {
        if let list = node as? [Any] {
            return list.allSatisfy { schemaIsRecursivelyClosed($0) }
        }
        guard let obj = node as? [String: Any] else {
            // Leaf (bool/string/number): carries no object schema to close.
            return true
        }
        let declaresObject = (obj["type"] as? String) == "object"
            || ((obj["type"] as? [Any])?.contains { ($0 as? String) == "object" } ?? false)
        if declaresObject || obj["properties"] is [String: Any] {
            guard (obj["additionalProperties"] as? Bool) == false else { return false }
        }
        // Named-subschema maps: the VALUES are schemas, the keys are names.
        for key in ["properties", "$defs", "definitions"] {
            guard let map = obj[key] as? [String: Any] else { continue }
            for (_, sub) in map where !schemaIsRecursivelyClosed(sub) { return false }
        }
        // Direct subschemas / subschema arrays.
        for key in ["items", "anyOf", "oneOf", "allOf"] {
            guard let sub = obj[key] else { continue }
            if !schemaIsRecursivelyClosed(sub) { return false }
        }
        return true
    }

    /// Anthropic's native content-block wire fields; message policy stays with its builder.
    static func anthropicBlock(_ block: LLMContentBlock) -> [String: Any] {
        switch block {
        case .text(let text): return ["type": "text", "text": text]
        case .image(let mediaType, let base64, _, _):
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
        case .toolUse(let id, let name, let inputJSON):
            let input: Any = (try? JSONSerialization.jsonObject(with: inputJSON)) ?? [String: Any]()
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let id, let content, let isError):
            var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
            if isError { result["is_error"] = true }
            return result
        }
    }

    /// Encode the conversation with NATIVE tool blocks (P0 shapes A/B):
    ///   assistant → {"type":"tool_use","id","name","input"}
    ///   user      → {"type":"tool_result","tool_use_id","content"[,"is_error"]}
    ///
    /// A message whose blocks all vanish is DROPPED rather than sent empty —
    /// the Messages API rejects an empty content array, and the only way to
    /// produce one here is a message that held nothing but unsupported blocks.
    ///
    /// THINKING REPLAY: `thinkingReplay` maps a tool_use id to the thinking /
    /// redacted_thinking blocks that arrived with it. An assistant message
    /// carrying tool_use blocks gets those blocks re-emitted FIRST, in their
    /// original order, ahead of its own text and tool_use blocks — the order
    /// the Messages API requires, and the shape claude-fable-5-1 (thinking
    /// always on) 400s without.
    static func nativeAnthropicMessages(
        _ messages: [LLMMessage],
        thinkingReplay: [String: [AnthropicThinkingBlock]] = [:]
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            if m.role == .assistant, !thinkingReplay.isEmpty {
                let ids = m.content.compactMap { block -> String? in
                    if case .toolUse(let id, _, _) = block { return id }
                    return nil
                }
                for id in ids {
                    guard let recorded = thinkingReplay[id] else { continue }
                    blocks.append(contentsOf: recorded.map(\.wireBlock))
                    break
                }
            }
            for block in m.content {
                // Native messages omit empty text while retaining replay order.
                if case .text(let text) = block, text.isEmpty { continue }
                blocks.append(Self.anthropicBlock(block))
            }
            guard !blocks.isEmpty else { continue }
            // Three-way role — see the api-key adapter's note. A `.system`
            // message stays a mid-conversation system message on the native
            // lane too.
            let entry: [String: Any] = [
                "role": AnthropicOAuthTransport.wireRole(m.role),
                "content": blocks,
            ]
            out.append(entry)
        }
        return out
    }

    /// ONE request body for both native-lane transports. The streaming and
    /// non-streaming calls differ by exactly one key (`stream`), so they share
    /// this builder: a tools-array or system-block difference between them
    /// would be invisible in tests that only exercise one of the two.
    ///
    /// NO `tool_choice` KEY IS EVER SET HERE. Forced tool choice
    /// (`{"type":"any"}` / `{"type":"tool"}`) returns 400 on Fable 5.1, and
    /// "auto" is the default — so the correct wire is the absent key, not an
    /// explicit auto. If a future caller wants to push the model toward a
    /// tool, that belongs in the prompt (and, for argument shape, in `strict`).
    func makeNativeToolsBody(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema],
        stream: Bool
    ) async -> [String: Any] {
        let replay = await thinkingReplayMap(for: messages)
        let encoded = messages.enumerated().compactMap { index, message -> (Int, [String: Any])? in
            Self.nativeAnthropicMessages([message], thinkingReplay: replay).first.map { (index, $0) }
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": requestMaxTokens(model: model),
            "messages": encoded.map { $0.1 },
        ]
        if stream { body["stream"] = true }
        // Omit the key entirely rather than sending `"tools": []` — an empty
        // array is a meaningless declaration, and some providers treat its
        // presence as "tool mode". The native BLOCK ENCODING still applies,
        // which is the part that must not regress (see usesNativeToolLane).
        if !tools.isEmpty {
            body["tools"] = Self.nativeToolsArray(
                tools,
                strict: firstPartyAnthropicToolContract,
                cacheBreakpoint: firstPartyAnthropicToolContract
            )
        }
        if let systemBlocks = Self.makeSystemBlocks(system) {
            body["system"] = systemBlocks
        }
        if firstPartyAnthropicToolContract {
            let usesPrefix = system.map { LLMCallContext.systemSegments?.reassembles(into: $0) == true } ?? false
            AnthropicOAuthTransport.cacheConversationPrefix(&body, sourceMessages: messages,
                wireSourceIndices: encoded.map { $0.0 }, usesPrefixShape: usesPrefix)
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
        applyThinkingControls(to: &body)
        return body
    }

    /// Thinking blocks to replay, keyed by tool_use id, for the assistant
    /// turns in this conversation.
    ///
    /// FIRST-PARTY ONLY. kimi-code's wire was probed WITHOUT thinking replay
    /// (P0 probe B) and accepted, so its request shape stays exactly as
    /// launched; the empty map makes `nativeAnthropicMessages` a no-op there.
    func thinkingReplayMap(
        for messages: [LLMMessage]
    ) async -> [String: [AnthropicThinkingBlock]] {
        guard firstPartyAnthropicToolContract else { return [:] }
        var map: [String: [AnthropicThinkingBlock]] = [:]
        for m in messages where m.role == .assistant {
            let ids = m.content.compactMap { block -> String? in
                if case .toolUse(let id, _, _) = block { return id }
                return nil
            }
            guard !ids.isEmpty,
                  let blocks = await thinkingLedger.payload(forAny: ids) else { continue }
            for id in ids { map[id] = blocks }
        }
        return map
    }

    // MARK: - Response parsing

    /// Every `tool_use` block in wire order. `thinking` blocks are skipped here
    /// exactly as `joinedTextBlocks` skips them — they are not tool calls and
    /// never reply text. They are NOT discarded, though: `nativeThinkingBlocks`
    /// captures them for the replay the next round requires.
    static func nativeToolCalls(_ content: [[String: Any]]) throws -> [LLMStreamToolCall] {
        try content.filter { ($0["type"] as? String) == "tool_use" }.map { block in
            guard let id = block["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = block["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let input = block["input"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: input) else {
                throw LLMError.failure(.malformedResponse)
            }
            return LLMStreamToolCall(id: id, name: name, inputJSON: data)
        }
    }

    /// Every `thinking` / `redacted_thinking` block in wire order — the exact
    /// sequence the next round has to replay ahead of the tool_result turn.
    static func nativeThinkingBlocks(_ content: [[String: Any]]) -> [AnthropicThinkingBlock] {
        content.compactMap { AnthropicThinkingBlock(responseBlock: $0) }
    }

    // MARK: - The native call

    /// Non-streaming native-tools request. Returns BOTH text and tool_use
    /// blocks so the caller never has to re-parse prose to find a tool call.
    ///
    /// A native tool call can satisfy a response without text.
    public func completeMessagesWithTools(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]
    ) async throws -> AnthropicNativeToolResult {
        let req = try request(body: await makeNativeToolsBody(
            messages: messages, system: system, model: model, tools: tools, stream: false
        ))

        return try await performCompletion(request: req, model: model, nativeTools: true)
    }

    // MARK: - Streaming

    /// Anthropic-compatible message routes expose real SSE progress, with or without tools.
    public func streamMessages(
        messages: [LLMMessage], system: String?, model: String, tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runNativeToolsStream(messages: messages, system: system,
                        model: model, tools: tools ?? [], continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error,
                        fallback: .underlying(message: "streamMessages: \(error)")))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - First-party SSE tool streaming (Fable 5.1 shape D)

    /// Streams the SAME body `completeMessagesWithTools` posts (+ `stream`),
    /// through the Anthropic SSE protocol, emitting:
    ///   * `.textDelta` per `text_delta` — live reply tokens;
    ///   * ONE `.toolCall` per completed `tool_use` block, its `input` assembled
    ///     from that block's `input_json_delta` fragments. PARALLEL tool use is
    ///     the default on this family, so several blocks may arrive in one
    ///     message: each opens at its own `content_block_start` and closes at
    ///     its own `content_block_stop`; empty input waits for a normal terminal.
    ///   * `.keepAlive` for thinking and tool-argument deltas — real model
    ///     output that carries no reply text. ProviderStreamGuard's idle clock
    ///     only advances on a yield, so without these a long thinking phase or
    ///     a large tool argument kills a healthy turn at the 90s idle default;
    ///     consumers ignore `.keepAlive`, so nothing leaks into the reply.
    ///
    /// The accumulator is intentionally scoped to the open block and cleared at
    /// `content_block_stop`, so a block's fragments can never bleed into the
    /// next block's input.
    private func runNativeToolsStream(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema],
        continuation: AsyncThrowingStream<LLMMessageStreamEvent, Error>.Continuation
    ) async throws {
        var req = try request(body: await makeNativeToolsBody(
            messages: messages, system: system, model: model, tools: tools, stream: true
        ))
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await ProviderWire.open(session, req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(
                message: "connection refused: \(endpoint.host ?? "anthropic")"))
        }
        defer { bytes.task.cancel() }

        // Status ladder identical to completeMessagesWithTools, with the body
        // drained (bounded) so a provider message survives into the error.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let errData = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
            try throwIfChatCompletionsError(status: status, data: errData, response: response)
        }

        var usage = LLMUsage()
        var ttftMs: Int?
        // CONTRACT NOTE 1 applies here too: a stream that produced a tool call
        // and no text is the HAPPY PATH, so the empty-response guard fires on
        // "neither text nor tool call", not on "no text".
        var yieldedSemanticOutput = false
        var lastStopReason: String?
        var contentBlocks: [Int: String] = [:]
        // The single in-flight tool_use block. `openToolName` is the presence
        // flag: a text or thinking block leaves it nil, so content_block_stop
        // for those blocks is a no-op.
        var openToolId: String?
        var openToolName: String?
        var openToolJSON = ""
        var pendingToolCalls: [LLMStreamToolCall] = []
        // Thinking-replay state. `openThinkingType` is the presence flag for
        // an in-flight thinking / redacted_thinking block; its text and
        // signature arrive as separate delta streams and are only valid
        // together, so both accumulate into the same block. Completed blocks
        // land in `thinkingBlocks` in wire order, and every tool_use id the
        // stream commits is banked against them when its input is confirmed.
        var openThinkingType: String?
        var openThinkingText = ""
        var openThinkingSignature = ""
        var openThinkingData: String?
        var thinkingBlocks: [AnthropicThinkingBlock] = []
        var runaway = RunawayOutputDetector()

        func commitToolCalls(terminal: Bool, stopReason: String?) async throws -> Bool {
            var committed = false
            while let call = pendingToolCalls.first {
                if call.inputJSON.isEmpty && !terminal { break }
                pendingToolCalls.removeFirst()
                if call.inputJSON.isEmpty,
                   !["end_turn", "tool_use", "stop_sequence", "pause_turn"].contains(stopReason ?? "") { continue }
                let json = call.inputJSON.isEmpty ? Data("{}".utf8) : call.inputJSON
                guard let input = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                else { throw LLMError.failure(.malformedResponse) }
                let calls = try Self.nativeToolCalls([
                    ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
                ])
                if !thinkingBlocks.isEmpty {
                    await thinkingLedger.record(thinkingBlocks, callIDs: calls.map(\.id))
                }
                committed = true
                for call in calls { continuation.yield(.toolCall(call)) }
            }
            return committed
        }

        do {
            for try await sse in SSEEventStream(bytes) {
                let finished = try await Self.consumeStreamEvent(
                    sse, usage: &usage, stopReason: &lastStopReason, blocks: &contentBlocks,
                    ttftMs: &ttftMs, semanticOutput: &yieldedSemanticOutput, runaway: &runaway,
                    requestStartNs: requestStartNs, requestBody: req.httpBody, provider: providerId,
                    model: model, telemetry: telemetry,
                    malformedFrame: "\(providerId): malformed native tools stream frame",
                    continuation: continuation
                ) { event, obj, stopReason in
                    switch event {
                    case "message_stop", "client_tool_boundary":
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
                            continuation.yield(.keepAlive)
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
