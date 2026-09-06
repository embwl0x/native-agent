import Foundation
import NativeAgentCore
// SSEEventStream (shared SSE framing — R15) lives in PersistenceCore, same as
// every other adapter's stream parser in this module.
import PersistenceCore

// MARK: - Native tool-use lane for the Anthropic-wire api-key adapter
//
// docs/build_plans/kimi-native-tools.md, P1; extended by
// docs/build_plans/fable51-sweep-2026-09-01.md item 34. Gated on
// NativeToolCapability.providerSupportsNativeTools(providerId) — kimi-code AND
// the Anthropic API-KEY provider id. The Claude OAUTH-direct adapter is a
// different type entirely (AnthropicOAuthDirectAdapter) and is unreachable
// from this file; the predicate additionally refuses its provider id so the
// two can never be confused at the routing seam.
//
// FABLE 5.1 CONTRACT (Anthropic docs, 2026-09-01) — what this lane must and
// must not put on the wire:
//   * `tool_choice` of type "any" or "tool" returns 400. This lane emits NO
//     tool_choice key at all, ever — auto is the default and the only shape
//     that is valid across the family. (Pinned by a test.)
//   * `strict: true` is a TOP-LEVEL field on a tool definition and requires a
//     closed schema. Emitted only for the first-party api-key adapter and only
//     for tools whose schema already declares `additionalProperties: false`.
//   * Parallel tool use is the default: one assistant message may carry
//     several tool_use blocks, and ALL of them must dispatch, with every
//     tool_result returned in ONE user message (nativeAnthropicMessages keeps
//     the blocks of a message together, so the loop's single user message
//     stays single).
//   * Tool inputs are JSON — parsed with JSONSerialization here and handed on
//     as bytes. Nothing on this lane string-matches a serialized input.
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
/// ONE `thinking` / `redacted_thinking` block, held exactly as the provider
/// sent it so it can be replayed byte-for-byte.
///
/// On claude-fable-5-1 extended thinking is ALWAYS on, and the Messages API
/// requires the assistant turn that made a tool call to carry its ORIGINAL
/// thinking blocks — signature included, in original order — when the paired
/// tool_result round comes back. Drop them and the next request 400s. The
/// signature is an opaque provider attestation over the thinking text: it is
/// only valid alongside the exact text it was issued for, so text and
/// signature travel together or not at all.
///
/// This is a WIRE artifact, not conversation content: it is never rendered to
/// the user and never persisted — it lives in the in-memory ledger below for
/// as long as the turn that produced it may still be replayed.
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

/// In-memory ledger of the thinking blocks that accompanied a tool-calling
/// assistant turn, keyed by the tool_use ids of that same turn.
///
/// WHY A LEDGER AND NOT A CONTENT BLOCK: the structured tool loop mints the
/// replayed assistant message from the parsed tool calls alone, so a thinking
/// block has no carrier in `LLMMessage` — and the tool_use ids ARE the join
/// key, unique per response and echoed back on the very message that needs
/// the replay. Same shape as `MoonshotReasoningLedger`, which solves the
/// identical "provider requires its reasoning state back" problem on the K3
/// wire.
///
/// Bounded (LRU-ish by insertion order) so a long-lived adapter can't grow
/// without limit, and never written to disk.
actor AnthropicThinkingLedger {
    private var byToolUseID: [String: [AnthropicThinkingBlock]] = [:]
    private var order: [String] = []
    private let limit = 512

    func record(_ blocks: [AnthropicThinkingBlock], toolUseIDs: [String]) {
        guard !blocks.isEmpty else { return }
        for id in toolUseIDs where !id.isEmpty {
            if byToolUseID[id] == nil { order.append(id) }
            byToolUseID[id] = blocks
        }
        while order.count > limit {
            byToolUseID.removeValue(forKey: order.removeFirst())
        }
    }

    /// The blocks recorded for whichever of these ids we know — parallel tool
    /// use puts SEVERAL ids on one response, all mapped to the same blocks.
    func blocks(forAny toolUseIDs: [String]) -> [AnthropicThinkingBlock]? {
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
    /// block caches the whole declaration mass. Exactly the placement the
    /// OAuth-direct adapter already uses (`makeToolList`). Budget: this lane
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
            // `defer_loading` (mid-conversation tool changes, beta
            // 2026-07-01): the tool is DECLARED here — so it rides the cached
            // prefix and can be referenced by name — but stays withheld from
            // the model until a `tool_addition` block offers it. Only the
            // always-on floor ships without the flag.
            if schema.deferLoading { tool["defer_loading"] = true }
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
            // Mid-conversation TOOL CHANGES (beta 2026-07-01). These are
            // content blocks of a `role: "system"` message that REFERENCE a
            // tool declared in the request's `tools` array rather than
            // defining one; the array itself never changes, so the cached
            // prefix survives. `LLMMessage`'s initializer already guarantees
            // these only ride a non-turn-scoped `.system` message (a
            // `clear_at` message is text-only and 400s with one).
            for change in m.toolChanges {
                blocks.append([
                    "type": change.kind == .addition ? "tool_addition" : "tool_removal",
                    "tool": ["type": "tool_reference", "name": change.name],
                ])
            }
            guard !blocks.isEmpty else { continue }
            // Three-way role — see the api-key adapter's note. A `.system`
            // message stays a mid-conversation system message on the native
            // lane too.
            var entry: [String: Any] = [
                "role": AnthropicOAuthDirectAdapter.wireRole(m.role),
                "content": blocks,
            ]
            if m.turnScopedClearAtNextUserMessage {
                entry["clear_at"] = "next_user_message"
            }
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
        var body: [String: Any] = [
            "model": model,
            "max_tokens": requestMaxTokens(model: model),
            "messages": Self.nativeAnthropicMessages(
                messages, thinkingReplay: await thinkingReplayMap(for: messages)
            ),
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
                  let blocks = await thinkingLedger.blocks(forAny: ids) else { continue }
            for id in ids { map[id] = blocks }
        }
        return map
    }

    // MARK: - Response parsing

    /// Every `tool_use` block in wire order. `thinking` blocks are skipped here
    /// exactly as `joinedTextBlocks` skips them — they are not tool calls and
    /// never reply text. They are NOT discarded, though: `nativeThinkingBlocks`
    /// captures them for the replay the next round requires.
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

    /// Every `thinking` / `redacted_thinking` block in wire order — the exact
    /// sequence the next round has to replay ahead of the tool_result turn.
    static func nativeThinkingBlocks(_ content: [[String: Any]]) -> [AnthropicThinkingBlock] {
        content.compactMap { AnthropicThinkingBlock(responseBlock: $0) }
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
        // clear_at AND tool_addition/tool_removal in the body each REQUIRE
        // their beta header (see the api-key messages lane) — present iff a
        // message in this request actually carries the feature.
        if let beta = AnthropicOAuthDirectAdapter.midConversationBetas(for: messages) {
            req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: await makeNativeToolsBody(
            messages: messages, system: system, model: model, tools: tools, stream: false
        ))

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
            // User, 2026-09-06: carry the status — see the api-key sibling.
            throw LLMError.underlying(
                message: "\(providerId) HTTP \(status): "
                    + (String(data: data, encoding: .utf8) ?? "5xx"))
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
        // Extended thinking is always on for claude-fable-5-1: bank this
        // response's thinking blocks against its own tool_use ids so the
        // assistant turn can replay them, signed and in order, when the
        // paired tool_result round comes back (the API 400s without).
        if !toolCalls.isEmpty {
            await thinkingLedger.record(
                Self.nativeThinkingBlocks(content), toolUseIDs: toolCalls.map(\.id)
            )
        }
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

    /// TWO native-lane transports, chosen by `firstPartyAnthropicToolContract`:
    ///
    ///   * FIRST-PARTY (api.anthropic.com, api-key): a REAL SSE parse —
    ///     `content_block_start` → `input_json_delta` accumulation →
    ///     `content_block_stop` → one `.toolCall`, with text deltas streaming
    ///     as they arrive. This matters because the api-key Claude path is a
    ///     CHAT surface: before this lane existed it rode the grown-prompt SSE
    ///     and streamed token by token, and moving it to a blocking call would
    ///     have traded marker-parsing for a frozen bubble. Same shape the
    ///     OAuth-direct adapter already runs, so the surface's live-delta
    ///     behavior is identical on both Claude transports.
    ///   * kimi-code: the original blocking `completeMessagesWithTools` + a
    ///     `.keepAlive` heartbeat. kimi-code launched on that shape (this
    ///     adapter used to inherit the LLMAdapter default, which is exactly
    ///     it), its SSE tool framing was never wire-probed, and the K3 surface
    ///     has no live-delta expectation to preserve. Unchanged, deliberately.
    ///
    /// The non-native branch reproduces the inherited LLMAdapter default
    /// EXACTLY (completeMessages → one textDelta when non-empty → finish), so
    /// every provider without tools sees no behavior change from this override
    /// existing.
    public func streamMessages(
        messages: [LLMMessage],
        system: String?,
        model: String,
        tools: [LLMToolSchema]?
    ) -> AsyncThrowingStream<LLMMessageStreamEvent, Error> {
        if firstPartyAnthropicToolContract, usesNativeToolLane(tools), let tools {
            return AsyncThrowingStream<LLMMessageStreamEvent, Error>(
                bufferingPolicy: .unbounded
            ) { continuation in
                let task = Task {
                    do {
                        try await self.runNativeToolsStream(
                            messages: messages,
                            system: system,
                            model: model,
                            tools: tools,
                            continuation: continuation
                        )
                    } catch let err as LLMError {
                        continuation.finish(throwing: err)
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: mapTransportError(
                            error,
                            fallback: .underlying(message: "streamMessages: \(error)")
                        ))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
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

    // MARK: - First-party SSE tool streaming (Fable 5.1 shape D)

    /// Streams the SAME body `completeMessagesWithTools` posts (+ `stream`),
    /// through the Anthropic SSE protocol, emitting:
    ///   * `.textDelta` per `text_delta` — live reply tokens;
    ///   * ONE `.toolCall` per completed `tool_use` block, its `input` assembled
    ///     from that block's `input_json_delta` fragments. PARALLEL tool use is
    ///     the default on this family, so several blocks may arrive in one
    ///     message: each opens at its own `content_block_start` and closes at
    ///     its own `content_block_stop`, and every one of them is yielded.
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
        let key = try resolvedCredentialKey()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if let beta = AnthropicOAuthDirectAdapter.midConversationBetas(for: messages) {
            req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: await makeNativeToolsBody(
            messages: messages, system: system, model: model, tools: tools, stream: true
        ))

        let requestStartNs = DispatchTime.now().uptimeNanoseconds
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw mapTransportError(error, fallback: .underlying(
                message: "connection refused: \(endpoint.host ?? "anthropic")"))
        }
        defer { bytes.task.cancel() }

        // Status ladder identical to completeMessagesWithTools, with the body
        // drained (bounded) so a provider message survives into the error.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            throw LLMError.rateLimited(
                message: "rate limited",
                retryAfterSeconds: parseRetryAfterSeconds(from: response))
        }
        if !(200..<300).contains(status) {
            let errData = try await ProviderErrorBodyDrain.read(bytes, maxBytes: 4096, timeout: 2.0)
            // A3.1: a key IS present here, so a 401 is a positive rejection.
            if status == 401 {
                throw LLMError.authRejected(provider: providerId, detail: providerErrorDetail(errData))
            }
            if (500..<600).contains(status) {
                // User, 2026-09-06: carry the status — see the api-key sibling.
                throw LLMError.underlying(
                    message: "\(providerId) HTTP \(status): "
                        + (String(data: errData, encoding: .utf8) ?? "5xx"))
            }
            if let obj = try? JSONSerialization.jsonObject(with: errData) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let message = err["message"] as? String, !message.isEmpty {
                throw LLMError.providerError(
                    message: "\(providerId): \(String(message.prefix(300))) (HTTP \(status))")
            }
            throw LLMError.invalidResponse(status: status)
        }

        var usage = LLMUsage()
        var ttftMs: Int?
        // CONTRACT NOTE 1 applies here too: a stream that produced a tool call
        // and no text is the HAPPY PATH, so the empty-response guard fires on
        // "neither text nor tool call", not on "no text".
        var yieldedSemanticOutput = false
        var lastStopReason: String?
        // The single in-flight tool_use block. `openToolName` is the presence
        // flag: a text or thinking block leaves it nil, so content_block_stop
        // for those blocks is a no-op.
        var openToolId: String?
        var openToolName: String?
        var openToolJSON = ""
        /// Completed tool_use blocks, held until `message_stop` so they can be
        /// validated against the assembled JSON and the response's stop_reason
        /// (User, 2026-09-06).
        var pendingToolCalls: [(id: String, name: String, json: String)] = []
        // Thinking-replay state. `openThinkingType` is the presence flag for
        // an in-flight thinking / redacted_thinking block; its text and
        // signature arrive as separate delta streams and are only valid
        // together, so both accumulate into the same block. Completed blocks
        // land in `thinkingBlocks` in wire order, and every tool_use id the
        // stream yields is banked against them at message_stop.
        var openThinkingType: String?
        var openThinkingText = ""
        var openThinkingSignature = ""
        var openThinkingData: String?
        var thinkingBlocks: [AnthropicThinkingBlock] = []
        var streamedToolUseIDs: [String] = []

        do {
            // R15: SSEEventStream owns framing; protocol semantics stay here.
            for try await sse in SSEEventStream(bytes) {
                try Task.checkCancellation()
                let payload = sse.data
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                // The data JSON's own `type` is authoritative per Anthropic's
                // streaming protocol; the `event:` name is the fallback for a
                // producer that sends data-only frames.
                let payloadType = obj["type"] as? String ?? ""
                let effectiveEvent = payloadType.isEmpty ? (sse.event ?? "") : payloadType

                switch effectiveEvent {
                case "error":
                    let errObj = obj["error"] as? [String: Any]
                    let message = (errObj?["message"] as? String)
                        ?? (errObj?["type"] as? String)
                        ?? "unknown error"
                    throw LLMError.providerError(message: "\(providerId): \(message)")
                case "message_start":
                    let msg = obj["message"] as? [String: Any]
                    usage.merge(LLMUsage.fromAnthropic(msg?["usage"] as? [String: Any]))
                case "message_delta":
                    usage.merge(LLMUsage.fromAnthropic(obj["usage"] as? [String: Any]))
                    if let delta = obj["delta"] as? [String: Any],
                       let stop = delta["stop_reason"] as? String {
                        lastStopReason = stop
                    }
                case "message_stop":
                    // User, 2026-09-06: release the buffered tool calls, dropping
                    // any whose arguments do not parse as a JSON object and ALL
                    // of them when the response was cut by `max_tokens` — a call
                    // the limit truncated carries arguments the model never
                    // finished choosing. A drop makes the reply INCOMPLETE, and
                    // this lane says so the way the OpenAI OAuth-direct lane
                    // does, in the only channel it has: a note in the text.
                    // User, 2026-09-06: all-or-nothing, as the max_tokens
                    // branch already was. Dropping only the malformed call and
                    // yielding its valid siblings executed a subset of a
                    // parallel response — half of a plan the model wrote as
                    // one decision, chosen by which block happened to survive.
                    let cutByTokenLimit = (lastStopReason == "max_tokens")
                    let decodedToolCalls = pendingToolCalls.map { call -> (id: String, name: String, bytes: Data?) in
                        let trimmed = call.json.trimmingCharacters(in: .whitespacesAndNewlines)
                        // An argument-free tool legally streams nothing, which
                        // is the empty object, not "".
                        let bytes = trimmed.isEmpty ? Data("{}".utf8) : Data(trimmed.utf8)
                        let parsesAsObject =
                            (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] != nil
                        return (call.id, call.name, parsesAsObject ? bytes : nil)
                    }
                    let unparsableToolCalls = decodedToolCalls.filter { $0.bytes == nil }.count
                    if cutByTokenLimit || unparsableToolCalls > 0 {
                        if !decodedToolCalls.isEmpty {
                            continuation.yield(.textDelta(
                                "\n\n" + OpenAIOAuthDirectAdapter.incompleteNote(
                                    cutByTokenLimit
                                        ? "max_tokens cut \(decodedToolCalls.count) tool call(s)"
                                        : "\(unparsableToolCalls) of \(decodedToolCalls.count) tool call(s) had unparsable arguments"
                                )
                            ))
                            yieldedSemanticOutput = true
                        }
                    } else {
                        for call in decodedToolCalls {
                            guard let bytes = call.bytes else { continue }
                            streamedToolUseIDs.append(call.id)
                            continuation.yield(.toolCall(LLMStreamToolCall(
                                id: call.id,
                                name: call.name,
                                inputJSON: bytes
                            )))
                            yieldedSemanticOutput = true
                        }
                    }
                    pendingToolCalls = []
                    // Bank this response's thinking against the tool ids it
                    // called with — the assistant turn replayed on the next
                    // round must carry them back, signed and in order.
                    if !streamedToolUseIDs.isEmpty {
                        await thinkingLedger.record(
                            thinkingBlocks, toolUseIDs: streamedToolUseIDs
                        )
                    }
                    let durationMs = Int(
                        (DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    await telemetry.record(
                        provider: providerId,
                        model: model,
                        streaming: true,
                        usage: usage.isEmpty ? nil : usage,
                        ttftMs: ttftMs,
                        durationMs: durationMs
                    )
                    if !yieldedSemanticOutput {
                        throw FirstPartyExecutionControls.anthropicEmptyStreamError(
                            providerID: providerId,
                            stopReason: lastStopReason,
                            expectedOutput: "answer text or tool call"
                        )
                    }
                    continuation.finish()
                    return
                case "content_block_start":
                    guard let blockObj = obj["content_block"] as? [String: Any] else { continue }
                    let blockType = blockObj["type"] as? String
                    if blockType == "thinking" || blockType == "redacted_thinking" {
                        // Open the block. A redacted block carries its whole
                        // opaque payload right here (no deltas follow); a
                        // plain thinking block fills in from thinking_delta +
                        // signature_delta before its content_block_stop.
                        openThinkingType = blockType
                        openThinkingText = blockObj["thinking"] as? String ?? ""
                        openThinkingSignature = blockObj["signature"] as? String ?? ""
                        openThinkingData = blockObj["data"] as? String
                        continue
                    }
                    guard blockType == "tool_use" else { continue }
                    // First model-output frame of a tool-call-first response.
                    if ttftMs == nil {
                        ttftMs = Int(
                            (DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    }
                    openToolId = (blockObj["id"] as? String) ?? ""
                    openToolName = (blockObj["name"] as? String) ?? ""
                    openToolJSON = ""
                case "content_block_delta":
                    guard let delta = obj["delta"] as? [String: Any] else { continue }
                    switch delta["type"] as? String {
                    case "text_delta":
                        guard let text = delta["text"] as? String, !text.isEmpty else { continue }
                        if ttftMs == nil {
                            ttftMs = Int(
                                (DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        yieldedSemanticOutput = true
                        continuation.yield(.textDelta(text))
                    case "input_json_delta":
                        if ttftMs == nil {
                            ttftMs = Int(
                                (DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                        }
                        openToolJSON += (delta["partial_json"] as? String) ?? ""
                        continuation.yield(.keepAlive)
                    case "thinking_delta":
                        // Real output, never reply content: liveness for the
                        // guard, and accumulation for the replay the next
                        // round needs. NOT yielded as text — thinking is not
                        // the assistant reply and is never shown to the user.
                        openThinkingText += (delta["thinking"] as? String) ?? ""
                        continuation.yield(.keepAlive)
                    case "signature_delta":
                        // The attestation over the thinking text above. Only
                        // valid alongside that exact text, so it rides on the
                        // same block; never surfaced anywhere.
                        openThinkingSignature += (delta["signature"] as? String) ?? ""
                        continuation.yield(.keepAlive)
                    default:
                        continue
                    }
                case "content_block_stop":
                    if let thinkingType = openThinkingType {
                        thinkingBlocks.append(AnthropicThinkingBlock(
                            type: thinkingType,
                            text: openThinkingText,
                            signature: openThinkingSignature.isEmpty ? nil : openThinkingSignature,
                            data: openThinkingData
                        ))
                        openThinkingType = nil
                        openThinkingText = ""
                        openThinkingSignature = ""
                        openThinkingData = nil
                        continue
                    }
                    guard let name = openToolName else { continue }
                    // User, 2026-09-06: the assembled argument bytes used to be
                    // yielded RIGHT HERE, unvalidated — so a block cut mid-JSON
                    // was dispatched with truncated arguments, and one cut
                    // before any argument text was dispatched as `{}`, i.e. the
                    // model's call with every argument invented. The block's
                    // `stop_reason` has not arrived yet at this point, so the
                    // calls are buffered and released at `message_stop`, where
                    // both the parse and the max_tokens verdict are known.
                    // Mirrors the OpenAI OAuth-direct `response.incomplete` rule.
                    if ttftMs == nil {
                        ttftMs = Int(
                            (DispatchTime.now().uptimeNanoseconds &- requestStartNs) / 1_000_000)
                    }
                    pendingToolCalls.append((
                        id: openToolId ?? "",
                        name: name,
                        json: openToolJSON
                    ))
                    openToolId = nil
                    openToolName = nil
                    openToolJSON = ""
                default:
                    // ping and everything else: safe to ignore.
                    continue
                }
            }
        } catch let err as LLMError {
            throw err
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw mapTransportError(error, fallback: .underlying(message: "stream: \(error)"))
        }
        // EOF without message_stop is a truncation, not a clean end.
        throw LLMError.streamTruncated(
            message: "\(providerId): native tools stream ended without message_stop"
        )
    }
}
