import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthTransport`: `ephemeralCacheControl`, `currentTurnUserIndex`, shared encoded conversation cache boundaries |

/// Anthropic OAuth wire layout and cache placement. Transport and token
/// ownership remain in the adapter; these helpers preserve model-visible bytes.
extension AnthropicOAuthTransport {
    /// First line of the text-lane tool protocol in the system prompt; its
    /// presence is what marks a request as a text-tool-lane chat call.
    public static let textToolProtocolHeader =
        "NativeAgent Swift tool protocol (text compatibility):"

    /// Anthropic's API gates OAuth-mode on this EXACT string being the first
    /// system block.
    private static let claudeCodeIdentity =
        "You are Claude Code, Anthropic's official CLI for Claude."

    // MARK: - Conversation cache compatibility
    //
    // Default requests cache append-only conversation prefixes. Text-compatible
    // turns retain previous and current request boundaries so reuse survives
    // a new turn; native-tool turns reserve a separate last-tool breakpoint.
    // makeMessagesRequestBody and makeSystemBlocks enforce the four-marker
    // budget for each layout, including the v2 prefix's shared identity prefix.

    // MARK: - Within-turn reuse
    //
    // Text-compatible turns have no provider tools array, but still replay an
    // append-only conversation. The caller binds this task-local while creating
    // and consuming the messages stream so its adapter task inherits the hint.
    // It enables conversation cache markers without changing tool authority.
    // Unbound callers retain the single-shot request layout.
    public enum MessagesCacheHint {
        @TaskLocal public static var withinTurnReuse: Bool = false
    }

    // MARK: - cache_control body helpers
    //
    // Anthropic prompt caching matches the system → messages prefix. A valid
    // segment split puts one system breakpoint at the stable end, covering the
    // identity too. Plain helper prompts retain their combined-system blocks.
    // Blocks below the model's minimum cacheable prefix silently don't
    // cache (no error) — verified via usage.cache_read_input_tokens.

    // Computed (not stored) — a stored static [String: Any] is rejected as a
    // non-Sendable mutable global under Swift 6 strict concurrency.
    static var ephemeralCacheControl: [String: Any] { ["type": "ephemeral"] }

    /// `cache_control` with an explicit TTL. `nil` ttl → the plain 5-minute
    /// ephemeral dict, BYTE-IDENTICAL to `ephemeralCacheControl` (the `ttl`
    /// key is absent, not `"5m"`, so no legacy body changes). `"1h"` is the
    /// GA extended TTL — no beta header required.
    static func ephemeralCacheControl(ttl: String?) -> [String: Any] {
        guard let ttl, !ttl.isEmpty else { return ephemeralCacheControl }
        return ["type": "ephemeral", "ttl": ttl]
    }

    /// The seeding owner binds the current user index for the whole loop.
    /// Calls without a seeded turn have no cross-turn boundary to mark.
    static func currentTurnUserIndex(_ messages: [LLMMessage]) -> Int? {
        if let bound = ConversationPrefixBoundary.currentUserIndex,
           messages.indices.contains(bound),
           messages[bound].role == .user {
            return bound
        }
        return nil
    }

    /// ONE extended-TTL decision for the WHOLE request.
    ///
    /// ORDERING RULE (Anthropic): entries with the longer TTL must appear
    /// BEFORE shorter ones — a 1h entry may not sit behind a 5m entry in the
    /// system → messages render order. Deciding the TTL once, here, and
    /// handing the same value to `makeSystemBlocks` and the previous-turn
    /// boundary is what makes that structural instead of a rule each call
    /// site has to remember. The current-turn boundary is always LAST and always 5m, which
    /// the rule permits.
    ///
    /// Returns nil (plain 5m ephemeral, no `ttl` key on the wire) unless the
    /// request has a valid segmented prefix.
    static func requestLongTTL(
        usesPrefixShape: Bool
    ) -> String? {
        // The stable prefix has a one-hour cache lifetime.
        guard usesPrefixShape else { return nil }
        return "1h"
    }

    /// Mark the current append-only request boundary and, when a previous
    /// boundary index is supplied, the preceding one. Both indices are
    /// explicit, using the seeded turn boundary where available. TTLs are
    /// explicit too — the previous boundary is the CROSS-TURN read (1h), the
    /// current boundary is re-read within this turn's own loop (5m — `nil`,
    /// i.e. no `ttl` key on the wire, byte-identical to the legacy marker).
    ///
    /// INVARIANT, enforced HERE because this is the one place message markers
    /// are written: a `system` message never receives cache_control. The
    /// reusable boundary is a user/assistant content block; changing context
    /// is sent and retained on its user turn.
    static func addConversationCacheControls(
        _ messages: inout [[String: Any]],
        previousBoundaryIndex: Int?,
        currentBoundaryIndex: Int?,
        previousBoundaryTTL: String? = nil,
        currentBoundaryTTL: String? = nil
    ) {
        func mark(_ index: Int, ttl: String?) {
            // The marker goes on the last block that carries something: never an empty text block.
            guard messages.indices.contains(index),
                  messages[index]["role"] as? String != "system",
                  var content = messages[index]["content"] as? [[String: Any]],
                  let at = content.lastIndex(where: { $0["type"] as? String != "text" || !(($0["text"] as? String) ?? "").isEmpty })
            else { return }
            content[at]["cache_control"] = ephemeralCacheControl(ttl: ttl)
            messages[index]["content"] = content
        }
        if let previousBoundaryIndex,
           previousBoundaryIndex != currentBoundaryIndex {
            mark(previousBoundaryIndex, ttl: previousBoundaryTTL)
        }
        if let currentBoundaryIndex {
            mark(currentBoundaryIndex, ttl: currentBoundaryTTL)
        }
    }

    /// Both Anthropic builders place markers on encoded entries, whose source
    /// indices survive native encoding's omission of empty messages. Tools and
    /// system consume their slots first; the current and previous boundaries
    /// share the remaining slots of Anthropic's four-marker request budget.
    static func cacheConversationPrefix(
        _ body: inout [String: Any], sourceMessages: [LLMMessage],
        wireSourceIndices: [Int], usesPrefixShape: Bool
    ) {
        guard usesPrefixShape || MessagesCacheHint.withinTurnReuse,
              var wire = body["messages"] as? [[String: Any]],
              wire.count == wireSourceIndices.count else { return }
        let markers = cacheMarkers(in: body)
        let slots = 4 - markers.count
        guard slots > 0 else { return }
        let eligible = wire.indices.filter {
            wire[$0]["role"] as? String != "system"
                && (wire[$0]["content"] as? [[String: Any]])?.isEmpty == false
        }
        guard let current = eligible.last else { return }
        let previous: Int?
        if let user = currentTurnUserIndex(sourceMessages) {
            previous = eligible.last { index in
                let source = wireSourceIndices[index]
                return sourceMessages.indices.contains(source) && source < user
                    && sourceMessages[source].role == .assistant
            }
        } else {
            previous = MessagesCacheHint.withinTurnReuse && wire.count >= 3
                ? eligible.last(where: { $0 <= wire.count - 3 }) : nil
        }
        // A longer-lived entry may not follow a shorter-lived tool/system
        // entry. Native API markers use 5m; OAuth's segmented prefix uses 1h.
        let previousTTL = usesPrefixShape && !markers.isEmpty && markers.allSatisfy { $0.ttl == "1h" }
            ? "1h" : nil
        addConversationCacheControls(&wire, previousBoundaryIndex: slots >= 2 ? previous : nil,
            currentBoundaryIndex: current, previousBoundaryTTL: previousTTL)
        body["messages"] = wire
    }

    /// NATIVE_AGENT_LLM_BODY_DUMP_DIR enables body dumps only in DEBUG builds, never Authorization headers.
    static func dumpBodyIfEnabled(_ body: [String: Any], call: String) {
        #if DEBUG
        guard let dir = ProcessInfo.processInfo.environment["NATIVE_AGENT_LLM_BODY_DUMP_DIR"],
              !dir.isEmpty else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        // UUID suffix: concurrent same-millisecond dumps must not overwrite
        // each other.
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("\(ts)-\(call)-\(UUID().uuidString.prefix(8)).json")
        if let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: [.atomic])
        }
        #endif
    }

    /// Request-scoped segments apply only when they reassemble byte-for-byte into `system`.
    /// Non-identity block texts concatenate to `system`, with separators on preceding blocks.
    /// The last stable block carries the single system breakpoint, after identity and before dynamic text.
    /// Long-TTL markers precede short-TTL markers; empty dynamic text emits no block.
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments? = LLMCallContext.systemSegments,
        longTTL: String? = nil
    ) -> [[String: Any]] {
        let usesPrefixShape = usesV2PrefixShape(system, segments: segments)
        var blocks: [[String: Any]] = [
            usesPrefixShape
                ? [
                    "type": "text",
                    "text": claudeCodeIdentity,
                ]
                : [
                    "type": "text",
                    "text": claudeCodeIdentity,
                    "cache_control": ephemeralCacheControl,
                ],
        ]
        guard let sys = system, !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return blocks
        }
        if usesPrefixShape, let seg = segments {
            let layout = seg.textBlockLayout
            blocks += layout.texts.enumerated().map { index, text in
                var block: [String: Any] = ["type": "text", "text": text]
                if index == layout.lastStableIndex {
                    block["cache_control"] = ephemeralCacheControl(ttl: longTTL)
                }
                return block
            }
            return blocks
        }
        blocks.append([
            "type": "text",
            "text": sys,
            "cache_control": ephemeralCacheControl,
        ])
        return blocks
    }

    /// Every `cache_control` marker present on a finished request body, in
    /// Anthropic's render order (tools → system → messages). Derived from the
    /// BODY, not from the placement code, so the telemetry row proves what
    /// actually shipped. Positions and TTLs only — no prompt bytes.
    static func cacheMarkers(in body: [String: Any]) -> [LLMCacheMarker] {
        func ttl(_ container: [String: Any]) -> String? {
            guard let cc = container["cache_control"] as? [String: Any] else { return nil }
            // The 5m default is the ABSENT `ttl` key on the wire.
            return (cc["ttl"] as? String) ?? "5m"
        }
        var out: [LLMCacheMarker] = []
        for (i, tool) in (body["tools"] as? [[String: Any]] ?? []).enumerated() {
            if let t = ttl(tool) { out.append(.init(position: "tools[\(i)]", ttl: t)) }
        }
        for (i, block) in (body["system"] as? [[String: Any]] ?? []).enumerated() {
            if let t = ttl(block) { out.append(.init(position: "system[\(i)]", ttl: t)) }
        }
        for (i, message) in (body["messages"] as? [[String: Any]] ?? []).enumerated() {
            for block in (message["content"] as? [[String: Any]] ?? []) {
                if let t = ttl(block) { out.append(.init(position: "messages[\(i)]", ttl: t)) }
            }
        }
        return out
    }

    /// Three-way wire role. `.system` is the MID-CONVERSATION system message
    /// (Anthropic accepts it inside `messages`); the turn-level system prompt
    /// still travels in the top-level `system` blocks.
    static func wireRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    /// Segmentation is safe only when it preserves the exact system string.
    /// Plain helper prompts keep their combined-system encoding.
    static func usesV2PrefixShape(
        _ system: String?,
        segments: SystemPromptSegments?
    ) -> Bool {
        guard let sys = system,
              !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let seg = segments,
              !seg.stable.isEmpty,
              seg.reassembles(into: sys)
        else { return false }
        return true
    }

    /// Text-tool chat requests stop at the outer call boundary, never at bare parallel-call markers.
    /// RunawayOutputDetector ends repeated bare blocks at the last complete call.
    static func applyTextLaneStops(to body: inout [String: Any], system: String?) {
        if system?.contains(textToolProtocolHeader) == true {
            body["stop_sequences"] = ["</function_calls>", "<function_results>", "\n<tool_result", "\nNativeAgent tool result #"]
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L01"), "site": .string("LLMClient+AnthropicOAuthRequestBody.swift:applyTextLaneStops")]))
        }
    }

    /// Completion and streaming share message retention, ordering and cache boundaries.
    static func makeMessagesRequestBody(
        messages: [LLMMessage],
        system: String?,
        coercedModel: String,
        maxTokens: Int,
        stream: Bool
    ) -> [String: Any] {
        let usesPrefixShape = Self.usesV2PrefixShape(
            system, segments: LLMCallContext.systemSegments
        )
        let longTTL = Self.requestLongTTL(
            usesPrefixShape: usesPrefixShape
        )
        let systemBlocks = Self.makeSystemBlocks(system, longTTL: longTTL)

        // Encode each LLMMessage as an Anthropic message with structured
        // content blocks. Text-only messages can use the short `content:
        // "..."` form, but anything with tool_use/tool_result MUST use
        // the array-of-blocks form.
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            // Empty text is never sent beside real content (a tool-only reply
            // leaves one); the API rejects it and a cache marker on it fails the turn.
            let kept = m.content.filter { if case .text(let text) = $0 { !text.isEmpty } else { true } }
            let blocks = (kept.isEmpty ? m.content : kept).map(AnthropicTransport.anthropicBlock)
            let entry: [String: Any] = [
                "role": Self.wireRole(m.role),
                "content": blocks,
            ]
            anthropicMessages.append(entry)
        }
        var body: [String: Any] = [
            "model": coercedModel,
            "max_tokens": maxTokens,
            "messages": anthropicMessages,
            "system": systemBlocks,
        ]
        Self.cacheConversationPrefix(&body, sourceMessages: messages,
            wireSourceIndices: Array(messages.indices), usesPrefixShape: usesPrefixShape)
        if stream {
            body["stream"] = true
        }
        Self.applyTextLaneStops(to: &body, system: system)
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel)
        return body
    }

}
