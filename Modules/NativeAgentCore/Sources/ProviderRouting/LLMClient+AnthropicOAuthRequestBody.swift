import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
// Blueprint: | `LLMClient+AnthropicOAuthRequestBody.swift` | `AnthropicOAuthTransport`, `ephemeralCacheControl`, `currentTurnUserIndex` |

/// Anthropic OAuth wire layout and cache placement. Transport and token ownership remain in the adapter; these helpers preserve model-visible bytes.
extension AnthropicOAuthTransport {
    /// The protocol's first line identifies text-tool requests.
    public static let textToolProtocolHeader =
        "NativeAgent Swift tool protocol (text compatibility):"

    /// Anthropic's API gates OAuth-mode on this EXACT string being the first system block.
    private static let claudeCodeIdentity =
        "You are Claude Code, Anthropic's official CLI for Claude."

    // MARK: - Conversation cache compatibility
    // Append-only prefixes retain previous/current boundaries for cross-turn reuse; builders share the four-marker budget with identity, system and native
    // tools.

    // MARK: - cache_control body helpers
    // A stable-end system breakpoint caches the identity and system prefix; below the model's minimum size no cache entry is created.

    /// One-hour entries preserve reuse between turns and satisfy longer-before-shorter ordering. Compute the dictionary to avoid a non-Sendable stored
    /// global.
    static var ephemeralCacheControl: [String: Any] { ["type": "ephemeral", "ttl": "1h"] }

    /// The seeding owner binds the current user index for the whole loop. Calls without a seeded turn have no cross-turn boundary to mark.
    static func currentTurnUserIndex(_ messages: [LLMMessage], call: LLMCall) -> Int? {
        if let bound = call.currentUserIndex,
           messages.indices.contains(bound),
           messages[bound].role == .user {
            return bound
        }
        return nil
    }

    /// Current and previous user/assistant boundaries share one lifetime for cross-turn reuse. System messages never receive cache_control; changing
    /// context stays on its user turn.
    static func addConversationCacheControls(
        _ messages: inout [[String: Any]],
        previousBoundaryIndex: Int?,
        currentBoundaryIndex: Int?
    ) {
        func mark(_ index: Int) {
            // The marker goes on the last block that carries something: never an empty text block.
            guard messages.indices.contains(index),
                  messages[index]["role"] as? String != "system",
                  var content = messages[index]["content"] as? [[String: Any]],
                  let at = content.lastIndex(where: { $0["type"] as? String != "text" || !(($0["text"] as? String) ?? "").isEmpty })
            else { return }
            content[at]["cache_control"] = ephemeralCacheControl
            messages[index]["content"] = content
        }
        if let previousBoundaryIndex,
           previousBoundaryIndex != currentBoundaryIndex {
            mark(previousBoundaryIndex)
        }
        if let currentBoundaryIndex {
            mark(currentBoundaryIndex)
        }
    }

    /// Source indices survive omitted empty messages; current/previous boundaries share slots left by tools and system within the four-marker budget.
    static func cacheConversationPrefix(
        _ body: inout [String: Any], sourceMessages: [LLMMessage],
        wireSourceIndices: [Int], usesPrefixShape: Bool, call: LLMCall
    ) {
        guard usesPrefixShape || call.withinTurnReuse,
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
        if let user = currentTurnUserIndex(sourceMessages, call: call) {
            previous = eligible.last { index in
                let source = wireSourceIndices[index]
                return sourceMessages.indices.contains(source) && source < user
                    && sourceMessages[source].role == .assistant
            }
        } else {
            previous = call.withinTurnReuse && wire.count >= 3
                ? eligible.last(where: { $0 <= wire.count - 3 }) : nil
        }
        addConversationCacheControls(&wire, previousBoundaryIndex: slots >= 2 ? previous : nil,
            currentBoundaryIndex: current)
        body["messages"] = wire
    }

    /// NATIVE_AGENT_LLM_BODY_DUMP_DIR enables body dumps only in DEBUG builds, never Authorization headers.
    static func dumpBodyIfEnabled(_ body: [String: Any], call: String) {
        #if DEBUG
        guard let dir = ProcessInfo.processInfo.environment["NATIVE_AGENT_LLM_BODY_DUMP_DIR"],
              !dir.isEmpty else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        // UUID suffix: concurrent same-millisecond dumps must not overwrite each other.
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("\(ts)-\(call)-\(UUID().uuidString.prefix(8)).json")
        if let data = try? JSONSerialization.data(
            withJSONObject: body, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: [.atomic])
        }
        #endif
    }

    /// Segments must reassemble the exact system bytes. Cache the stable end after identity and before dynamic text; omit an empty dynamic block.
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments?
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
                    block["cache_control"] = ephemeralCacheControl
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

    /// Derive markers from the finished body so receipts prove what shipped; retain positions and TTLs, never prompt bytes.
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

    /// Mid-conversation system stays in messages; the turn-level prompt uses top-level system blocks.
    static func wireRole(_ role: LLMMessage.Role) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    /// Segmentation is safe only when it preserves the exact system string. Plain helper prompts keep their combined-system encoding.
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

    /// Text-tool chat requests stop at the outer call boundary, never at bare parallel-call markers. RunawayOutputDetector ends repeated bare blocks at the
    /// last complete call.
    static func applyTextLaneStops(to body: inout [String: Any], system: String?, call: LLMCall) {
        if system?.contains(textToolProtocolHeader) == true {
            body["stop_sequences"] = ["</function_calls>", "<function_results>", "\n<tool_result", "\nNativeAgent tool result #"]
            TurnTraceBus.fireFromContext(kind: "shim.fired", payload: .object(["id": .string("L01"), "site": .string(
                "LLMClient+AnthropicOAuthRequestBody.swift:applyTextLaneStops")]), turn: call.turn)
        }
    }

    /// Completions and streams share retention, ordering and cache boundaries.
    static func makeMessagesRequestBody(
        messages: [LLMMessage],
        system: String?,
        coercedModel: String,
        maxTokens: Int,
        stream: Bool, call: LLMCall
    ) throws -> [String: Any] {
        let usesPrefixShape = Self.usesV2PrefixShape(
            system, segments: call.systemSegments
        )
        let systemBlocks = Self.makeSystemBlocks(system, segments: call.systemSegments)

        // Tool calls/results require array content even when text-only messages can use a string.
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            // Empty text is never sent beside real content (a tool-only reply leaves one); the API rejects it and a cache marker on it fails the turn.
            let kept = m.content.filter { if case .text(let text) = $0 { !text.isEmpty } else { true } }
            let blocks = try (kept.isEmpty ? m.content : kept).map(AnthropicTransport.anthropicBlock)
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
            wireSourceIndices: Array(messages.indices), usesPrefixShape: usesPrefixShape, call: call)
        if stream {
            body["stream"] = true
        }
        Self.applyTextLaneStops(to: &body, system: system, call: call)
        try FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel, call: call)
        return body
    }

}
