import Foundation
import NativeAgentCore

// MARK: - Native tool-use lane for the Anthropic-wire api-key adapter
//
// docs/build_plans/kimi-native-tools.md, P1. Gated on
// NativeToolCapability.providerSupportsNativeTools(providerId) — today that is
// kimi-code ONLY. Every other provider on this adapter (the Anthropic api-key
// path) keeps the historical behavior: tool blocks flatten to text and no
// `tools` array is ever emitted.
//
// WIRE CONTRACT (live-probed 2026-07-20 against api.kimi.com/coding with the
// real key — these shapes are ground truth, not documentation):
//   A. request  → {"tools":[{"name","description","input_schema"}], ...}
//      response → content:[thinking(+signature), tool_use{id:"tool_…",name,input}],
//                 stop_reason:"tool_use", HTTP 200.
//   B. roundtrip → assistant [tool_use] + user [tool_result{tool_use_id,content}]
//      → 200, model continues. Thinking REPLAY NOT REQUIRED (probe B omitted
//      it and was accepted) — so we DROP thinking blocks on replay.
//   C. parallel  → several tool_use blocks in ONE response; all must dispatch.
//
// CONTRACT NOTE 1 (the load-bearing one): stop_reason "tool_use" with ZERO
// text blocks is the HAPPY PATH here. `emptyTextResponseError` was built for
// the text-compat lane, where a textless 200 really is a dead turn; on this
// lane a textless 200 that carries tool_use blocks is a perfectly good
// response. The guard therefore fires only when there is NEITHER text NOR a
// tool_use block.

/// What a native-tools request actually returned. Deliberately a separate
/// return type rather than an overload of the String-returning
/// `completeMessages`: every existing caller of that protocol method wants a
/// reply string, and widening it would either lose tool calls silently or
/// force an out-of-band side channel. Callers that can act on tool calls opt
/// in by calling `completeMessagesWithTools` explicitly.
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

extension AnthropicAdapter {
    /// True when THIS adapter instance may ship native tools AND the caller
    /// opted in by passing a (possibly empty) tools array.
    ///
    /// NON-NIL, NOT NON-EMPTY — and that distinction is load-bearing. The chat
    /// loop passes `ctx.toolSchemas`, which is lazy-filtered per iteration to
    /// `alwaysOnCore ∪ sessionActive`; a session that has loaded nothing can
    /// legitimately produce an EMPTY list. If empty meant "not native", the
    /// adapter would silently fall back to the flatten path and stringify the
    /// conversation's tool_use/tool_result BLOCKS into prose — the loop would
    /// think it was on the native lane while the wire said otherwise, and the
    /// model would never see its own tool results. `nil` (what every non-native
    /// caller passes) remains the byte-identical legacy path.
    func usesNativeToolLane(_ tools: [LLMToolSchema]?) -> Bool {
        guard NativeToolCapability.providerSupportsNativeTools(providerId) else { return false }
        return tools != nil
    }

    // MARK: - Request encoding

    /// Anthropic `tools` array. `input_schema` is the tool's JSON-Schema object
    /// decoded from its canonical bytes; a schema that won't decode falls back
    /// to a permissive object rather than dropping the tool (a missing tool is
    /// invisible to the model; a loose schema is merely lenient).
    static func nativeToolsArray(_ tools: [LLMToolSchema]) -> [[String: Any]] {
        tools.map { schema in
            let inputSchema: [String: Any] = (try? JSONSerialization.jsonObject(
                with: schema.parametersJSON
            )) as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
            return [
                "name": schema.name,
                "description": schema.description,
                "input_schema": inputSchema,
            ]
        }
    }

    /// Encode the conversation with NATIVE tool blocks (P0 shapes A/B):
    ///   assistant → {"type":"tool_use","id","name","input"}
    ///   user      → {"type":"tool_result","tool_use_id","content"[,"is_error"]}
    ///
    /// A message whose blocks all vanish is DROPPED rather than sent empty —
    /// the Messages API rejects an empty content array, and the only way to
    /// produce one here is a message that held nothing but unsupported blocks.
    static func nativeAnthropicMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text(let t):
                    // Skip empty text blocks: the API rejects them, and the
                    // tool loop legitimately produces one when an iteration's
                    // assistant reply was pure tool_use with no prose.
                    guard !t.isEmpty else { continue }
                    blocks.append(["type": "text", "text": t])
                case .image(let mediaType, let base64, _, _):
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64,
                        ],
                    ])
                case .toolUse(let id, let name, let inputJSON):
                    let input: Any = (try? JSONSerialization.jsonObject(with: inputJSON))
                        ?? [String: Any]()
                    blocks.append([
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": input,
                    ])
                case .toolResult(let toolUseId, let content, let isError):
                    var b: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                    if isError { b["is_error"] = true }
                    blocks.append(b)
                }
            }
            guard !blocks.isEmpty else { continue }
            out.append([
                "role": m.role == .user ? "user" : "assistant",
                "content": blocks,
            ])
        }
        return out
    }

    // MARK: - Response parsing

    /// Every `tool_use` block in wire order. `thinking` blocks are skipped here
    /// exactly as `joinedTextBlocks` skips them (P0 note 2: we also drop them
    /// on replay, proven acceptable by probe B).
    static func nativeToolCalls(_ content: [[String: Any]]) -> [LLMStreamToolCall] {
        content.compactMap { block -> LLMStreamToolCall? in
            guard (block["type"] as? String) == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else { return nil }
            let input = block["input"] as? [String: Any] ?? [:]
            let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
            return LLMStreamToolCall(id: id, name: name, inputJSON: data)
        }
    }

    // MARK: - The native call

    /// Non-streaming native-tools request. Returns BOTH text and tool_use
    /// blocks so the caller never has to re-parse prose to find a tool call.
    ///
    /// Error handling is deliberately identical to `completeMessages` — same
    /// status ladder, same provider-message preservation — with ONE difference:
    /// the textless-200 guard is skipped when tool_use blocks are present
    /// (contract note 1).
    public func completeMessagesWithTools(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]
    ) async throws -> AnthropicNativeToolResult {
        let key = try resolvedCredentialKey()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": requestMaxTokens(model: model),
            "messages": Self.nativeAnthropicMessages(messages),
        ]
        // Omit the key entirely rather than sending `"tools": []` — an empty
        // array is a meaningless declaration, and some providers treat its
        // presence as "tool mode". The native BLOCK ENCODING above still
        // applies, which is the part that must not regress (see
        // usesNativeToolLane).
        if !tools.isEmpty {
            body["tools"] = Self.nativeToolsArray(tools)
        }
        if let systemBlocks = Self.makeSystemBlocks(system) {
            body["system"] = systemBlocks
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: model)
        applyThinkingControls(to: &body)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(
                message: "connection refused: \(endpoint.host ?? "anthropic")"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A3.1: key present here → 401 is a positive credential rejection.
        if status == 401 {
            throw LLMError.authRejected(provider: providerId, detail: providerErrorDetail(data))
        }
        if status == 429 {
            throw LLMError.rateLimited(
                message: String(data: data, encoding: .utf8) ?? "rate limited",
                retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if (500..<600).contains(status) {
            throw LLMError.underlying(message: String(data: data, encoding: .utf8) ?? "5xx")
        }
        guard (200..<300).contains(status) else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String, !message.isEmpty {
                throw LLMError.providerError(
                    message: "\(providerId): \(String(message.prefix(300))) (HTTP \(status))")
            }
            throw LLMError.invalidResponse(status: status)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw malformedSuccessBodyError(data)
        }

        let toolCalls = Self.nativeToolCalls(content)
        let text = Self.joinedTextBlocks(content)
        // CONTRACT NOTE 1: a textless 200 carrying tool_use blocks is the
        // HAPPY PATH on this lane (stop_reason "tool_use"). Only a response
        // with neither text nor tool calls is the empty-reply class.
        if text.isEmpty && toolCalls.isEmpty {
            throw emptyTextResponseError(obj, content: content)
        }

        let durationMs = Int((DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
        await telemetry.record(
            provider: providerId,
            model: model,
            streaming: false,
            usage: LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]),
            ttftMs: nil,
            durationMs: durationMs
        )
        return AnthropicNativeToolResult(
            text: text,
            toolCalls: toolCalls,
            stopReason: obj["stop_reason"] as? String
        )
    }

    // MARK: - Streaming

    /// STREAMING CHOICE (P1 decision, documented in the worker report):
    /// the native lane falls back to the NON-STREAMING
    /// `completeMessagesWithTools` call and emits its result as one text delta
    /// plus one `.toolCall` event per block, rather than parsing the SSE
    /// `content_block_start` + `input_json_delta` accumulation of P0 shape D.
    ///
    /// Why the simpler one is the correct one here:
    ///   * kimi-code ALREADY rides the non-streaming path in production — this
    ///     adapter never overrode `streamMessages`, so it inherited the
    ///     LLMAdapter default, which is exactly this shape. The native lane
    ///     therefore changes NO timing characteristic of the K3 surface.
    ///   * the tool loop consumes a one-chunk result correctly today.
    ///   * a real SSE tool parse adds partial-JSON accumulation state (the
    ///     single richest source of state-lifecycle bugs in this repo) to buy
    ///     latency this surface does not currently have anyway.
    /// Upgrading to shape D later is additive and does not change this
    /// function's contract with the loop.
    ///
    /// The non-native branch reproduces the inherited LLMAdapter default
    /// EXACTLY (completeMessages → one textDelta when non-empty → finish), so
    /// every provider except kimi-code-with-tools sees no behavior change from
    /// this override existing.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // F1-H1 KEEPALIVE: this override is a SINGLE blocking
                // complete*(…) call that yields nothing until it returns — no
                // per-token stream. ProviderStreamGuard (idle default 90s, clock
                // started at admitProducer) therefore kills any healthy turn
                // whose thinking exceeds ~90s. kimi-for-coding defaults to
                // reasoning_effort max with a 32k thinking budget, so heavy turns
                // routinely think silently past 90s and died as "idle" while the
                // surface retry ladders replayed into the same wall.
                //
                // While the blocking call is in flight, a heartbeat task yields
                // `.keepAlive` every ~30s — real guard-visible activity
                // (ProviderStreamGuard.markActivity resets its idle clock on ANY
                // yield) that consumers treat as a no-op (they IGNORE .keepAlive
                // so no empty/placeholder content leaks into the reply). Matches
                // the keepalive contract the OAuth/Moonshot SSE paths already use.
                //
                // Cancelled on ALL exits — success, throw, and onTermination —
                // via `defer`: onTermination cancels this task, the in-flight
                // cancellation-aware URLSession await throws, control reaches the
                // catch, the body unwinds, and defer fires. No leaked task.
                let heartbeatInterval = self.nativeToolKeepAliveInterval
                let heartbeat = Task {
                    let nanos = UInt64(max(0.001, heartbeatInterval) * 1_000_000_000)
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: nanos)
                        if Task.isCancelled { break }
                        continuation.yield(.keepAlive)
                    }
                }
                defer { heartbeat.cancel() }
                do {
                    guard usesNativeToolLane(tools), let tools else {
                        // Byte-identical to the LLMAdapter default.
                        let reply = try await completeMessages(
                            messages: messages, system: system, model: model, tools: tools
                        )
                        heartbeat.cancel()
                        if !reply.isEmpty { continuation.yield(.textDelta(reply)) }
                        continuation.finish()
                        return
                    }
                    let result = try await completeMessagesWithTools(
                        messages: messages, system: system, model: model, tools: tools
                    )
                    heartbeat.cancel()
                    if !result.text.isEmpty { continuation.yield(.textDelta(result.text)) }
                    for call in result.toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.finish()
                } catch {
                    heartbeat.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
