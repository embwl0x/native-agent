import Foundation
import NativeAgentCore
import PersistenceCore

/// Anthropic OAuth wire layout and cache placement. Transport and token
/// ownership remain in the adapter; these helpers preserve model-visible bytes.
extension AnthropicOAuthDirectAdapter {
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
    //
    // NATIVE_AGENT_GROWN_PROMPT_COMPAT=1 (or true/yes/on) restores dynamic-end
    // caching and disables conversation breakpoints. The task-local override
    // selects the same mode for a task tree. Both layouts preserve model-visible
    // content: only cache metadata changes.
    //
    // ChatOrchestration also gates IntraTurnToolResultClearing on this switch.
    // Clearing rewrites cached prefix bytes, so it runs only in compatibility
    // mode; the default layout retains those bytes for prefix reuse.
    public enum GrownPromptCompat {
        static let envVar = "NATIVE_AGENT_GROWN_PROMPT_COMPAT"

        /// Pure, injectable parser for the env flag.
        static func isForced(env: [String: String]) -> Bool {
            guard let raw = env[envVar]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !raw.isEmpty else { return false }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        static let forcedFromEnv = isForced(env: ProcessInfo.processInfo.environment)

        /// Test hook: binds over the env flag for a task tree. Production
        /// never binds it (nil → env flag decides).
        @TaskLocal public static var compatOverride: Bool?

        public static var effective: Bool { compatOverride ?? forcedFromEnv }
    }

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

    /// U1 item 9: TRUE when the auth file at `path` carries a usable access
    /// token (expiry ignored — the adapter refreshes inline on use). The
    /// text-compat loop preflights this before choosing the append-only
    /// messages transport: without OAuth credentials the messages path would
    /// fall through to the api-key adapter's NON-streaming streamMessages
    /// default (single-delta flatten) and kill live deltas, while the legacy
    /// prompt transport keeps real SSE through the api-key adapter's
    /// stream(). Fail-closed → caller keeps the legacy wire shape.
    public static func hasUsableOAuthCredentials(at path: URL) -> Bool {
        loadAccessTokenAndExpiry(from: path) != nil
    }

    // MARK: - cache_control body helpers (U1 step 3 + 2b/3b, 2026-06-10)
    //
    // Anthropic prompt caching is a PREFIX match over tools → system →
    // messages. Three ephemeral breakpoints (max 4 allowed):
    //   (a) the LAST tool definition  — caches the whole tools block
    //   (b) the claudeCodeIdentity system block — caches tools + identity
    //   (c) the END of the STABLE system mass:
    //       - with a stable/dynamic split bound via
    //         LLMCallContext.systemSegments (U1 2b/3b), the breakpoint sits
    //         on the stable block (persona+pins) and the dynamic block
    //         (recall+history) follows with NO breakpoint — so the per-turn
    //         churn stops invalidating the persona prefix and stops paying
    //         the 1.25x write premium uncached every turn;
    //       - without segments, the caller-supplied sys string is ONE block
    //         with the breakpoint (byte-identical to the pre-2b/3b shape).
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

    // MESSAGE-ORDER CONTRACT (live 400, 2026-09-01): a mid-conversation
    // system message must IMMEDIATELY FOLLOW a user turn and either end the
    // array or precede an assistant turn. The seeded v2 shape is therefore
    //     [ history… , assistant(N-1), user(N), system(volatile) ]
    // with the system message LAST, and within-turn rounds append AFTER it
    // (assistant tool_use, user tool_result, …). The three index helpers
    // below all read that shape; none of them may ever return a `.system`
    // index, because a system message must never carry cache_control.

    /// The CURRENT TURN's user message.
    ///
    /// AUTHORITATIVE SOURCE: `ConversationPrefixBoundary.currentUserIndex`,
    /// bound per turn by the seeding layer, which knows the answer exactly.
    /// Validated before use (in range, and actually a `.user` message) so a
    /// stale binding degrades to the fallback instead of mis-marking.
    ///
    /// FALLBACK — anchor on the TRAILING SYSTEM RUN, never on
    /// `lastIndex(.system)`. Replayed history carries ARCHIVED system blocks
    /// of its own, positioned after their own user messages. When the turn's
    /// volatile block is not delivered as a system message — it was empty, or
    /// the model has no mid-conversation system support — `lastIndex(.system)`
    /// selects one of those archived blocks, and the cross-turn 1h marker
    /// lands near the START of the conversation, caching almost nothing. That
    /// is a silent, expensive miss, so this reads only a system run that ENDS
    /// the array (the seeded shape) and otherwise answers nil: no cross-turn
    /// marker at all beats one in the wrong place.
    static func currentTurnUserIndex(_ messages: [LLMMessage]) -> Int? {
        if let bound = ConversationPrefixBoundary.currentUserIndex,
           messages.indices.contains(bound),
           messages[bound].role == .user {
            return bound
        }
        guard let last = messages.indices.last, messages[last].role == .system
        else { return nil }
        var runStart = last
        while runStart > 0, messages[runStart - 1].role == .system { runStart -= 1 }
        return messages[..<runStart].lastIndex { $0.role == .user }
    }

    /// Where the CURRENT (5m) boundary marker goes: the newest message that
    /// is NOT a system message. In the seeded shape that is exactly the
    /// current user message (the system message is last); once a within-turn
    /// round has appended past the trailing system it is the newest appended
    /// message, so the next round still reads the whole established prefix.
    static func currentBoundaryIndex(_ messages: [LLMMessage]) -> Int? {
        messages.lastIndex { $0.role != .system }
    }

    /// The v2 PREVIOUS-TURN boundary: the last ASSISTANT message strictly
    /// before the current turn's user message — the end of the transcript
    /// prefix this turn re-sends verbatim, so a marker there is the read the
    /// next turn is built on. Anchored on the current USER message, not on
    /// the system message and not on the current boundary: anchoring on
    /// either would let a within-turn round stamp THIS turn's own assistant
    /// tool_use with the cross-turn 1h TTL. Unlike the v1 `count - 3`
    /// arithmetic it stays correct however many messages the turn appended.
    static func previousTurnBoundaryIndex(_ messages: [LLMMessage]) -> Int? {
        guard let userIndex = currentTurnUserIndex(messages) else { return nil }
        return messages[..<userIndex].lastIndex { $0.role == .assistant }
    }

    /// Completed prior turns visible in this request, counted as assistant
    /// messages — which on v2 includes every assistant message the history
    /// projection REPLAYED, so a resumed session is credited with the turns
    /// it actually carries rather than restarting from zero. Gates the
    /// speculative 1h write: a one-shot (0 or 1 prior turns) would pay the
    /// 2x extended-TTL write premium with no expected reader (1h needs three
    /// reads to break even, against two for 5m).
    static func priorTurnCount(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.role == .assistant ? 1 : 0) }
    }

    /// ONE extended-TTL decision for the WHOLE request.
    ///
    /// ORDERING RULE (Anthropic): entries with the longer TTL must appear
    /// BEFORE shorter ones — a 1h entry may not sit behind a 5m entry in the
    /// tools → system → messages render order. The tools breakpoint is always
    /// FIRST, so it can never be shorter than the system or message markers;
    /// deciding the TTL once, here, and handing the same value to
    /// `makeToolList`, `makeSystemBlocks` and the previous-turn boundary is
    /// what makes that structural instead of a rule three call sites have to
    /// remember. The current-turn boundary is always LAST and always 5m, which
    /// the rule permits.
    ///
    /// Returns nil (plain 5m ephemeral, no `ttl` key on the wire) unless the
    /// request is a v2 prefix turn carrying at least two completed turns.
    static func requestLongTTL(
        usesPrefixShape: Bool,
        messages: [LLMMessage]
    ) -> String? {
        guard usesPrefixShape, priorTurnCount(messages) >= 2 else { return nil }
        return "1h"
    }

    /// Mark the current append-only request boundary and, when a previous
    /// boundary index is supplied, the preceding one. Both indices are
    /// explicit: v1 passes `count - 3` / `count - 1`; v2 passes
    /// `previousTurnBoundaryIndex` / `currentBoundaryIndex`. TTLs are
    /// explicit too — the previous boundary is the CROSS-TURN read (1h), the
    /// current boundary is re-read within this turn's own loop (5m — `nil`,
    /// i.e. no `ttl` key on the wire, byte-identical to the legacy marker).
    ///
    /// INVARIANT, enforced HERE because this is the one place message markers
    /// are written: a `system` message NEVER receives cache_control. The
    /// volatile mid-conversation system message is turn-scoped (it may even
    /// carry `clear_at`), so caching it is meaningless at best and pins
    /// disappearing bytes into the prefix at worst.
    static func addConversationCacheControls(
        _ messages: inout [[String: Any]],
        previousBoundaryIndex: Int?,
        currentBoundaryIndex: Int?,
        previousBoundaryTTL: String? = nil,
        currentBoundaryTTL: String? = nil
    ) {
        func mark(_ index: Int, ttl: String?) {
            guard messages.indices.contains(index),
                  messages[index]["role"] as? String != "system",
                  var content = messages[index]["content"] as? [[String: Any]],
                  var lastBlock = content.last else { return }
            lastBlock["cache_control"] = ephemeralCacheControl(ttl: ttl)
            content[content.count - 1] = lastBlock
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

    /// DEBUG-ONLY diagnostic: when NATIVE_AGENT_LLM_BODY_DUMP_DIR is set,
    /// write every outgoing request body to that directory so cache-breakpoint
    /// placement can be inspected offline (U1 finding #1 hunt, 2026-06-10).
    /// Bodies contain persona/conversation content, so this is compiled OUT
    /// of release builds entirely (#if DEBUG) — a stray env var in a
    /// production launch context can never activate it (gpt-5.5 review
    /// blocker, 2026-06-10). The Authorization header is never dumped.
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

    /// system blocks: identity (+ stable + dynamic | + combined sys).
    ///
    /// `segments` defaults to the request-scoped TaskLocal so every call
    /// path (complete / completeMessages / runStream — all run inside the
    /// task that inherited the loop's binding) picks the split up without
    /// signature churn at the call sites.
    ///
    /// SAFETY GUARD: the split is used ONLY when the segments reassemble
    /// byte-for-byte into `system` (INVARIANT: system == stable + "\n\n" +
    /// dynamic — see TurnContext.systemSegments). Any mismatch — stale
    /// binding, caller-mutated sys — falls back to the combined block, so
    /// model-visible content can never change.
    ///
    /// BYTE FAITHFULNESS (gpt-5.5 review blocker, 2026-06-10): the emitted
    /// stable+dynamic block TEXTS must concatenate byte-for-byte to the
    /// combined `system` string — the API does not guarantee any particular
    /// join between adjacent text blocks, so the "\n\n" separator is carried
    /// as a SUFFIX on the stable block's text (cache-safe: the suffix is
    /// exactly as stable as the block it rides on). The identity block is
    /// different: it has ALWAYS been its own block, never part of the `sys`
    /// string (pre-U1 shape was already [identity][sys]), so it carries no
    /// join contract with the blocks that follow it.
    ///
    /// `toolCapable` (U1 F1 lane (a), step-6 rider, 2026-06-10): on TOOL-
    /// CAPABLE requests with a stable/dynamic split, the dynamic block ALSO
    /// gets a breakpoint — within a multi-iteration tool turn the dynamic
    /// mass (recall+history, built once per turn) is byte-identical across
    /// iterations, so iteration 2..N read it from cache instead of re-paying
    /// ~2k input tokens per iteration (F1 live measurement). Breakpoint
    /// budget: last-tool + identity + stable-end + dynamic-end = 4 ≤ 4.
    /// On NON-tool turns there is exactly ONE call per turn and the dynamic
    /// block churns across turns — a breakpoint there would pay the 1.25x
    /// cache-write premium with ~zero read probability, hence the gate.
    /// (Unsegmented fallback: the combined sys block already carries the
    /// end-of-system breakpoint; nothing extra to add.)
    ///
    /// V2 PREFIX SHAPE (`ConversationPrefixShape.v2Prefix`, production default,
    /// engaged only when the segments are present and reassemble):
    ///   [identity — NO cache_control] [stable] [stableSuffix?] [dynamic?]
    /// The identity block is a strict PREFIX of the stable mass, so a
    /// breakpoint at the end of the stable mass already caches it; its own
    /// breakpoint bought nothing and spent one of the four slots. The freed
    /// slot funds the previous-turn conversation boundary marker. The LAST
    /// stable block (stableSuffix when present, else stable) carries the
    /// single system breakpoint, at the GA 1h TTL when `longTTL` says so —
    /// see `requestLongTTL`, which also keeps the tools breakpoint at the
    /// same TTL so the render order never puts 5m ahead of 1h. An empty `dynamic`
    /// emits no dynamic block at all.
    /// Byte faithfulness is unchanged: separators ride as SUFFIXES on the
    /// preceding block, so the emitted non-identity block texts concatenate to
    /// `sys` exactly.
    static func makeSystemBlocks(
        _ system: String?,
        segments: SystemPromptSegments? = LLMCallContext.systemSegments,
        toolCapable: Bool = false,
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
            // Separator suffixes: each emitted block carries the "\n\n" that
            // joins it to the NEXT emitted block, so the concatenation of the
            // block texts is `sys` byte-for-byte.
            let hasSuffix = !seg.stableSuffix.isEmpty
            let hasDynamic = !seg.dynamic.isEmpty
            let stableTTL: String? = longTTL
            var stableBlock: [String: Any] = [
                "type": "text",
                "text": seg.stable + ((hasSuffix || hasDynamic) ? "\n\n" : ""),
            ]
            if !hasSuffix {
                stableBlock["cache_control"] = ephemeralCacheControl(ttl: stableTTL)
            }
            blocks.append(stableBlock)
            if hasSuffix {
                blocks.append([
                    "type": "text",
                    "text": seg.stableSuffix + (hasDynamic ? "\n\n" : ""),
                    "cache_control": ephemeralCacheControl(ttl: stableTTL),
                ])
            }
            if hasDynamic {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                ])
            }
            return blocks
        }
        if let seg = segments,
           !seg.stable.isEmpty, !seg.dynamic.isEmpty, seg.stableSuffix.isEmpty,
           seg.reassembles(into: sys)
        {
            // Stable block carries the "\n\n" separator as its suffix so
            // stable-block-text + dynamic-block-text == `sys` byte-for-byte.
            blocks.append([
                "type": "text",
                "text": seg.stable + "\n\n",
                "cache_control": ephemeralCacheControl,
            ])
            // Dynamic tail: cache_control ONLY on tool-capable requests
            // (within-turn iteration reads; see toolCapable doc above).
            // Non-tool turns: NO breakpoint — recall+history churn per turn.
            if toolCapable {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                    "cache_control": ephemeralCacheControl,
                ])
            } else {
                blocks.append([
                    "type": "text",
                    "text": seg.dynamic,
                ])
            }
        } else {
            blocks.append([
                "type": "text",
                "text": sys,
                "cache_control": ephemeralCacheControl,
            ])
        }
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

    /// Which prefix shape this REQUEST actually emits.
    ///
    /// READS THE BOUND TASK-LOCAL ONLY — never `ConversationPrefixShape
    /// .effective`. The shape is decided ONCE per turn, at the history
    /// builder's seeding boundary, and bound around the whole call: a turn
    /// that seeded no replayed history seeds the v1 shape and binds
    /// `.v1Legacy`, and the adapter must then emit the v1 bytes exactly.
    /// If the adapter re-derived the shape from `.effective` it would answer
    /// `.v2Prefix` on that turn — dropping the identity breakpoint and adding
    /// a current-message breakpoint to a request the builder shaped as v1.
    /// Unbound (every non-chat caller: dream, REM, executions, tests) →
    /// `.v1Legacy`, i.e. byte-identical to the pre-v2 wire.
    ///
    /// v2 additionally needs the compat lever off AND segments that
    /// make it representable: a non-empty stable segment that reassembles
    /// byte-for-byte into the combined `system` string. Same safety guard as
    /// v1 — a stale or caller-mutated binding falls back to the legacy arm
    /// rather than changing model-visible content — but it tolerates an EMPTY
    /// `dynamic` (the cross-turn shape legitimately has none once history has
    /// moved into the message array).
    static func usesV2PrefixShape(
        _ system: String?,
        segments: SystemPromptSegments?
    ) -> Bool {
        guard ConversationPrefixShape.override == .v2Prefix,
              !GrownPromptCompat.effective,
              let sys = system,
              !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let seg = segments,
              !seg.stable.isEmpty,
              seg.reassembles(into: sys)
        else { return false }
        return true
    }

    /// Anthropic Messages-API tools list with a cache_control breakpoint on
    /// the LAST definition. Returns nil for nil/empty input so the no-tools
    /// request body stays byte-identical to the no-tools overload.
    /// `ttl` MUST match the request's system/message TTL decision — the
    /// tools block renders FIRST, and a 5m entry there would sit ahead of a
    /// 1h entry, which Anthropic rejects as an ordering violation. Defaults
    /// to nil (plain 5m) so every non-v2 caller is byte-identical.
    static func makeToolList(
        _ tools: [LLMToolSchema]?,
        ttl: String? = nil
    ) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return nil }
        var toolList: [[String: Any]] = []
        for t in tools {
            var entry: [String: Any] = [
                "name": t.name,
                "description": t.description,
            ]
            if let schema = try? JSONSerialization.jsonObject(with: t.parametersJSON) {
                entry["input_schema"] = schema
            } else {
                entry["input_schema"] = [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any]
            }
            toolList.append(entry)
        }
        toolList[toolList.count - 1]["cache_control"] = ephemeralCacheControl(ttl: ttl)
        return toolList
    }

    // MARK: - Shared messages-request body builder (U1 items 8 + 9)
    //
    // ONE encoder behind completeMessages AND the streaming runStreamMessages
    // so the wire shape (block encoding, breakpoint layout, lever behavior)
    // cannot drift between the non-streaming and SSE transports. The bodies
    // are test-pinned deep-equal modulo the `stream` key
    // (LLMCallTelemetryTests + AnthropicStreamMessagesSSETests).
    //
    // Reads three task-locals at call time (all inherited through the
    // adapter's inner Task per the LLMCallContext propagation contract):
    //   - LLMCallContext.systemSegments (via makeSystemBlocks' default arg)
    //   - GrownPromptCompat.compatOverride (rollback lever)
    //   - MessagesCacheHint.withinTurnReuse (item 9 — see enum doc above)
    static func makeMessagesRequestBody(
        messages: [LLMMessage],
        system: String?,
        coercedModel: String,
        maxTokens: Int,
        tools: [LLMToolSchema]?,
        stream: Bool
    ) -> [String: Any] {
        // U1 items 8 + 9 — conversation-cache INVARIANT: caching ships iff
        // the call is tool-capable OR withinTurnReuse-
        // hinted (and trailing-eligible, and not compat). Both grantors are
        // legitimate reuse signals: tools[] implies a multi-iteration
        // structured loop (item 8); the hint is the no-tools text-compat
        // loop's explicit "I re-send this conversation as a prefix next
        // iteration" signal (item 9 — see MessagesCacheHint). The current
        // message breakpoint replaces the lane-(a) dynamic-end breakpoint (its prefix
        // covers every system block, so the dynamic block is cached from
        // iteration 1's write on — and the 4-breakpoint budget has no room for
        // both; the `toolCapable && !useConversationCache` arg below is
        // what closes the budget at ≤ 4 across the whole hint × tools ×
        // segmented × compat matrix, test-pinned). The grown-prompt compat
        // lever restores the old layout. Non-tool un-hinted calls keep the
        // pre-item-8 body byte-identical (no trailing breakpoint, no
        // dynamic-end — single-shot turns have no within-turn reuse).
        let toolCapable = !(tools?.isEmpty ?? true)
        // V2: EVERY turn is a prefix-reuse turn — the transcript is re-sent
        // as a cached prefix across turns, not only inside one tool loop — so
        // the conversation breakpoints are unconditional (still subject to
        // trailing-eligibility and the compat lever). The v2 system-block
        // shape only engages when the segments actually reassemble; when it
        // does not, the identity block keeps its own breakpoint and there is
        // no free slot, so no previous-turn boundary is marked.
        let usesPrefixShape = Self.usesV2PrefixShape(
            system, segments: LLMCallContext.systemSegments
        )
        // Prove a conversation breakpoint CAN ship before
        // suppressing dynamic-end — an empty messages
        // array (or an empty last content) would otherwise lose BOTH
        // breakpoints silently. Eligibility on the source LLMMessages
        // mirrors the encoder exactly (every content block encodes to
        // one Anthropic block).
        // Eligibility is about the message the CURRENT marker would land on
        // — the newest NON-system message, not `messages.last` (which is the
        // volatile system message in the seeded v2 shape and can never be
        // marked). An empty content array there would silently lose both
        // markers.
        let boundaryIndex = Self.currentBoundaryIndex(messages)
        let trailingEligible = boundaryIndex.map { !messages[$0].content.isEmpty } ?? false
        let useConversationCache =
            (usesPrefixShape || toolCapable || MessagesCacheHint.withinTurnReuse)
            && trailingEligible
            && !Self.GrownPromptCompat.effective
        let longTTL = Self.requestLongTTL(
            usesPrefixShape: usesPrefixShape, messages: messages
        )
        let systemBlocks = Self.makeSystemBlocks(
            system,
            toolCapable: toolCapable && !useConversationCache,
            longTTL: longTTL
        )

        // Encode each LLMMessage as an Anthropic message with structured
        // content blocks. Text-only messages can use the short `content:
        // "..."` form, but anything with tool_use/tool_result MUST use
        // the array-of-blocks form.
        var anthropicMessages: [[String: Any]] = []
        for m in messages {
            var blocks: [[String: Any]] = []
            for block in m.content {
                switch block {
                case .text(let t):
                    blocks.append(["type": "text", "text": t])
                case .toolUse(let id, let name, let inputJSON):
                    let inputObj: Any = (try? JSONSerialization.jsonObject(with: inputJSON)) ?? [String: Any]()
                    blocks.append([
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": inputObj,
                    ])
                case .toolResult(let toolUseId, let content, let isError):
                    var entry: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                    if isError { entry["is_error"] = true }
                    blocks.append(entry)
                case .image(let mediaType, let base64, _, _):
                    // Native vision — Anthropic Messages API base64 image block.
                    // userWithImages emits image blocks FIRST, then the text
                    // block, so the canonical [image..., text] order is held by
                    // the content array's own order here.
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64,
                        ],
                    ])
                }
            }
            var entry: [String: Any] = [
                "role": Self.wireRole(m.role),
                "content": blocks,
            ]
            // Mid-conversation system message the provider drops as soon as
            // the next user message arrives. The `clear_at` key rides on the
            // MESSAGE, and its beta is added per-request in apiHeaders.
            if m.turnScopedClearAtNextUserMessage {
                entry["clear_at"] = "next_user_message"
            }
            anthropicMessages.append(entry)
        }
        if useConversationCache {
            // v2: the previous boundary is the last assistant message before
            // the volatile system message (funded by the identity block's
            // freed slot) and reads at the request's long TTL. v1: the historical
            // `count - 3` arithmetic, plain 5m, byte-identical.
            // The CURRENT marker index is the same rule on both arms: the
            // newest NON-system message. On v1 that is `count - 1` (v1 never
            // carries a mid-conversation system message), so the legacy body
            // stays byte-identical; the rule simply also holds the
            // never-mark-a-system-message invariant if one ever appears.
            let currentIndex = boundaryIndex
            let previousBoundaryIndex: Int?
            let previousBoundaryTTL: String?
            if usesPrefixShape {
                // Indices are computed on the SOURCE messages and applied to
                // `anthropicMessages`: this encoder is 1:1 (every LLMMessage
                // yields exactly one wire entry, empty content included), so
                // the two arrays share indices.
                previousBoundaryIndex = Self.previousTurnBoundaryIndex(messages)
                previousBoundaryTTL = longTTL
                // Budget: stable-end + previous + current + last tool = 4.
                // Nothing else can ship a marker on v2, so this is closed.
            } else {
                // The text lane has one free fourth slot. Structured tools
                // already spend it on the last tool definition.
                let retain = !toolCapable && MessagesCacheHint.withinTurnReuse
                previousBoundaryIndex =
                    (retain && anthropicMessages.count >= 3)
                    ? anthropicMessages.count - 3
                    : nil
                previousBoundaryTTL = nil
            }
            Self.addConversationCacheControls(
                &anthropicMessages,
                previousBoundaryIndex: previousBoundaryIndex,
                currentBoundaryIndex: currentIndex,
                previousBoundaryTTL: previousBoundaryTTL
            )
        }
        var body: [String: Any] = [
            "model": coercedModel,
            "max_tokens": maxTokens,
            "messages": anthropicMessages,
            "system": systemBlocks,
        ]
        if stream {
            body["stream"] = true
        }
        if let toolList = Self.makeToolList(tools, ttl: longTTL) {
            body["tools"] = toolList
        }
        // Turn Inspector W2 — GATED summarized-thinking lane. The `thinking`
        // param is part of the request BODY, so adding it CHANGES the bytes on
        // the wire (and the U1 cache prefix). It is therefore strictly gated on
        // the per-surface opt-in task-local `InspectorThinkingLane.summarized-
        // Thinking`, which is FALSE unless the Mac chat surface explicitly binds
        // it TRUE (read here at call time, same as the other body task-locals).
        // UNBOUND (the default everywhere) → the key is NOT added → the body is
        // BYTE-IDENTICAL to pre-W2. Display "summarized" yields SUMMARIZED
        // thinking blocks (Opus 4.7/4.8 omit raw CoT); the SSE parser renders
        // thinking_delta onto the bus and redacted_thinking as "[redacted]" —
        // blocks and signatures are NEVER mutated.
        if InspectorThinkingLane.summarizedThinking {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        }
        FirstPartyExecutionControls.applyAnthropicControls(to: &body, model: coercedModel)
        return body
    }

}
