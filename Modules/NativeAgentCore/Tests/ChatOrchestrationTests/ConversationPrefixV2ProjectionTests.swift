import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
@testable import ProviderRouting

// MARK: - v2Prefix conversation shape: the cross-turn cached transcript
//
// Measured before this change (2026-09-01): 13 KB of history, the fluid packet,
// memory recall, the cognitive capsule, the clock line, the turn-plan hint and
// the session digest ALL rode the DYNAMIC system segment, and `messages` was a
// single user message. Every one of those churns per turn, so the provider's
// prefix cache had nothing to match: OpenAI reported 5-8% cache reads per day,
// Anthropic 48%.
//
// v2 moves the transcript INTO `messages` (a real, byte-stable prefix) and the
// per-turn volatile mass into ONE message that sits after it. These tests are
// the proof that the move is a RELOCATION and not a rewrite:
//   - the same rows, with the same caps, in the same order;
//   - nothing volatile leaking into anything a cache has to match;
//   - `.v1Legacy` still producing byte-identical output.
//
// Silent-failure class: every failure here is a wrong value with no error.
// A prefix that quietly re-churns still answers perfectly and costs full-price
// uncached input on every turn, which is exactly why it needs pinning rather
// than assuming.

// MARK: - Fixtures

private func msg(
    _ role: String,
    _ content: String,
    id: String,
    kind: String? = nil,
    toolName: String? = nil,
    ok: Bool? = nil
) -> ChatMessage {
    var metadata: [String: JSONValue] = [:]
    if let kind { metadata["kind"] = .string(kind) }
    if let toolName { metadata["toolName"] = .string(toolName) }
    if let ok { metadata["ok"] = .bool(ok) }
    var extras: [String: JSONValue] = ["id": .string(id)]
    if !metadata.isEmpty { extras["metadata"] = .object(metadata) }
    return ChatMessage(
        role: role,
        content: content,
        timestamp: "2026-09-01T12:00:00Z",
        extras: .object(extras)
    )
}

/// Six ordinary turns plus one tool row — enough to exercise pairing, merging,
/// and the assistant-leading trim without being a wall of text.
private func transcript() -> [ChatMessage] {
    [
        msg("user", "first question about the deploy", id: "u1"),
        msg("assistant", "first answer about the deploy", id: "a1"),
        msg("user", "second question", id: "u2"),
        msg("assistant", "second answer", id: "a2"),
        msg("tool", "returned 3 rows", id: "t1", kind: "tool_use", toolName: "db_query", ok: true),
        msg("user", "third question", id: "u3"),
        msg("assistant", "third answer", id: "a3"),
        msg("user", "fourth question", id: "u4"),
        msg("assistant", "fourth answer", id: "a4"),
    ]
}

private let surface = "chat"
private let historyLimit = 40

private func budget() -> ContextBudgetPolicy.Resolved {
    ContextBudgetPolicy.resolve(windowTokens: nil, surface: surface)
}

private func projection(
    _ messages: [ChatMessage] = transcript(),
    cursor: HistoryWindowCursor? = nil
) -> SessionHistoryMessageProjection.Result {
    SessionHistoryMessageProjection.project(
        messages: messages,
        historyLimit: historyLimit,
        surface: surface,
        windowTokens: nil,
        cursor: cursor
    )
}

private func text(_ message: LLMMessage) -> String {
    message.content.compactMap {
        if case .text(let t) = $0 { return t }
        return nil
    }.joined(separator: "\n")
}

private func allText(_ messages: [LLMMessage]) -> String {
    messages.map(text).joined(separator: "\n")
}

// MARK: - Projection replays exactly what v1 rendered

@Suite struct SessionHistoryMessageProjectionTests {
    /// The load-bearing equivalence: every row the v1 block rendered appears in
    /// the projection with the SAME capped body. If these ever diverge, the
    /// model silently sees a different conversation on v2 than on v1.
    @Test func projectedTextEqualsV1HistoryRowsVerbatimUnderTheSameCaps() throws {
        let v1 = try #require(SessionHistoryPromptRenderer.render(
            messages: transcript(),
            userMessage: "now",
            surface: surface,
            historyLimit: historyLimit
        ))
        let projected = allText(projection().messages)
        for row in transcript() {
            // The v1 line is "[role] <capped body>"; the projection carries the
            // same capped body with the role expressed as the message role.
            guard let renderable = SessionHistoryPromptRenderer.renderable(row) else { continue }
            let body = SessionHistoryPromptRenderer.projectedHistoryText(
                renderable, budget: budget()
            )
            #expect(v1.contains(body), "v1 lost: \(body)")
            #expect(projected.contains(body), "v2 lost: \(body)")
        }
    }

    /// A long body is capped identically on both arms — the projection reads
    /// the renderer's own `capForRole`, it does not carry a second table.
    @Test func longRowsAreCappedByTheSameTable() throws {
        let long = String(repeating: "x", count: 40_000)
        let rows = [
            msg("user", "opening", id: "u1"),
            msg("assistant", long, id: "a1"),
            msg("user", "closing", id: "u2"),
        ]
        let renderable = try #require(SessionHistoryPromptRenderer.renderable(rows[1]))
        let capped = SessionHistoryPromptRenderer.projectedHistoryText(
            renderable, budget: budget()
        )
        #expect(capped.count <= budget().assistantCap + 4)   // + the "..." marker
        let projected = projection(rows)
        #expect(allText(projected.messages).contains(capped))
    }

    @Test func messagesOpenOnUser_andNeverRepeatARole() {
        let messages = projection().messages
        #expect(!messages.isEmpty)
        #expect(messages.first?.role == .user)
        for pair in zip(messages, messages.dropFirst()) {
            #expect(pair.0.role != pair.1.role, "adjacent same-role rows must merge")
        }
    }

    /// An assistant-first transcript (the tail cut mid-turn) must not open the
    /// replayed prefix on an assistant message — the Anthropic wire rejects it
    /// and every other provider reads it as an opening that never happened.
    @Test func leadingAssistantRowsAreTrimmed() {
        let rows = [
            msg("assistant", "dangling answer", id: "a0"),
            msg("user", "the real opening", id: "u1"),
            msg("assistant", "reply", id: "a1"),
        ]
        let messages = projection(rows).messages
        #expect(messages.first?.role == .user)
        #expect(!allText(messages).contains("dangling answer"))
    }

    /// Text-compat transcripts retain LITERAL `<tool_use>` markers. Replaying
    /// one re-issues that call on the next provider read — a real action taken
    /// from a transcript, which is the worst failure this projection can have.
    @Test func replayedAssistantTextCarriesNoToolUseMarkers() {
        let rows = [
            msg("user", "search for it", id: "u1"),
            msg(
                "assistant",
                "on it <tool_use>{\"name\":\"web_search\",\"input\":{\"q\":\"x\"}}</tool_use>",
                id: "a1"
            ),
            msg("user", "thanks", id: "u2"),
        ]
        let replayed = allText(projection(rows).messages)
        #expect(!replayed.contains("<tool_use>"))
        #expect(!replayed.contains("</tool_use>"))
        #expect(replayed.contains("on it"))
    }

    /// Prior tool rounds have NO provider call ids. Inventing tool_use /
    /// tool_result pairs to carry them would be a fabricated pairing the
    /// provider either rejects or — worse — accepts.
    @Test func toolRowsRideAsTextOnTheAssistantTurn_neverAsToolBlocks() throws {
        let messages = projection().messages
        for message in messages {
            for block in message.content {
                switch block {
                case .toolUse, .toolResult:
                    Issue.record("projection invented a provider tool block")
                default: break
                }
            }
        }
        #expect(allText(messages).contains("[tool db_query"))
        // It is attached to the assistant side, not stood up as its own turn.
        let carrier = try #require(messages.first { text($0).contains("[tool db_query") })
        #expect(carrier.role == .assistant)
    }

    /// The compaction summary is the only surviving record of every elided
    /// turn. It leads the oldest replayed user message rather than becoming a
    /// synthetic turn of its own.
    @Test func compactionSummaryLeadsTheOldestReplayedUserMessage() throws {
        let rows = [
            msg("system", "earlier: we agreed on the rollout order",
                id: "c1", kind: "compaction_summary"),
            msg("user", "so what is next", id: "u1"),
            msg("assistant", "the rollout", id: "a1"),
        ]
        let messages = projection(rows).messages
        let first = try #require(messages.first)
        #expect(first.role == .user)
        #expect(text(first).hasPrefix("[session recollection] "))
        #expect(text(first).contains("rollout order"))
        #expect(text(first).contains("so what is next"))
    }

    @Test func emptyHistoryProjectsNothing() {
        #expect(projection([]).messages.isEmpty)
        #expect(SessionHistoryMessageProjection.project(
            messages: transcript(), historyLimit: 0, surface: surface
        ).messages.isEmpty)
    }
}

// MARK: - Volatile block containment

private func contextFixture(
    stable: String = "PERSONA stable bytes",
    stableSuffix: String = "",
    dynamic: String,
    history: [LLMMessage],
    model: String = "claude-opus-5",
    providerId: String? = "anthropic_oauth_direct"
) -> TurnContext {
    let segments = SystemPromptSegments(
        stable: stable, stableSuffix: stableSuffix, dynamic: dynamic
    )
    return TurnContext(
        surface: surface,
        personaDocs: [:],
        recalled: [],
        modelId: model,
        reasoningEffort: "medium",
        providerId: providerId,
        toolsAvailable: [],
        systemPrompt: segments.combined,
        userMessage: "the current question",
        systemSegments: segments,
        historyMessages: history
    )
}

private let clockLineTurnN = "Local time: Monday, August 31, 2026 at 5:59 PM PDT (America/Los_Angeles)."
private let clockLineTurnN1 = "Local time: Monday, August 31, 2026 at 6:00 PM PDT (America/Los_Angeles)."

@Suite struct ConversationPrefixSeedingTests {
    private func seedV2(
        dynamic: String,
        model: String = "claude-opus-5",
        providerId: String? = "anthropic_oauth_direct"
    ) -> ConversationPrefixSeeding.Seed {
        ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: dynamic,
                history: projection().messages,
                model: model,
                providerId: providerId
            ),
            shape: .v2Prefix
        )
    }

    /// THE containment invariant. Anything volatile that leaks into a message
    /// BEFORE the volatile block — or into the stable segments — is a byte a
    /// provider cache has to re-match every turn, which is the entire defect
    /// v2 exists to remove.
    @Test func volatileBlockIsAbsentFromEveryEarlierMessageAndFromStable() throws {
        let volatile = "PACKET\n\nRECALL\n\n\(clockLineTurnN)"
        let seed = seedV2(dynamic: volatile)
        let index = try #require(seed.volatileIndex)
        for earlier in seed.messages.prefix(index) {
            #expect(!text(earlier).contains("PACKET"))
            #expect(!text(earlier).contains("RECALL"))
            #expect(!text(earlier).contains(clockLineTurnN))
        }
        let segments = try #require(seed.context.systemSegments)
        #expect(segments.dynamic.isEmpty)
        #expect(!segments.stable.contains(clockLineTurnN))
        #expect(!segments.stableSuffix.contains(clockLineTurnN))
        #expect(seed.context.systemPrompt == segments.combined)
        // And it IS delivered — relocation, not deletion.
        #expect(text(seed.messages[index]) == volatile)
    }

    /// WIRE RULE (live 400 on 785d7c42, `messages.28`: "role 'system' must
    /// follow a 'user' message or an 'assistant' message ending in a server
    /// tool result"). A text-carrying system message must IMMEDIATELY FOLLOW a
    /// user turn and must either END the array or precede an assistant turn.
    /// So the order is history ‖ current user ‖ volatile system — the volatile
    /// block is LAST.
    @Test func theVolatileSystemMessageIsLastAndFollowsTheCurrentUserTurn() throws {
        let seed = seedV2(dynamic: "VOLATILE")
        let index = try #require(seed.volatileIndex)
        #expect(index == seed.messages.count - 1)
        #expect(seed.messages[index].role == .system)
        #expect(seed.messages[index - 1].role == .user)
        #expect(seed.currentUserIndex == index - 1)
        #expect(text(seed.messages[seed.currentUserIndex]) == "the current question")
        #expect(Array(seed.messages.prefix(seed.currentUserIndex))
                == seed.context.historyMessages)
    }

    /// The invariant behind the 400, stated directly: no message anywhere in a
    /// seeded array may be a user turn sitting directly after a system turn.
    @Test func noUserTurnEverFollowsASystemTurn() {
        for model in ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5"] {
            let seed = seedV2(dynamic: "VOLATILE", model: model)
            for pair in zip(seed.messages, seed.messages.dropFirst()) {
                #expect(!(pair.0.role == .system && pair.1.role == .user), "\(model)")
            }
        }
    }

    /// History that ends on a user turn (the previous assistant reply was a
    /// transient failure and the projection filtered it out) is the one place
    /// two consecutive user messages could appear. It merges instead.
    @Test func aTrailingHistoryUserTurnMergesWithTheCurrentOne() throws {
        let rows = [
            msg("user", "opening", id: "u1"),
            msg("assistant", "reply", id: "a1"),
            msg("user", "unanswered question", id: "u2"),
        ]
        let history = SessionHistoryMessageProjection.project(
            messages: rows, historyLimit: historyLimit, surface: surface
        ).messages
        #expect(history.last?.role == .user)
        let seed = ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE", history: history), shape: .v2Prefix
        )
        for pair in zip(seed.messages, seed.messages.dropFirst()) {
            #expect(pair.0.role != pair.1.role)
        }
        let merged = seed.messages[seed.currentUserIndex]
        #expect(merged.role == .user)
        #expect(text(merged).contains("unanswered question"))
        #expect(text(merged).contains("the current question"))
    }

    /// clear_at only means anything on a message that ends the array — which
    /// is now where it always sits.
    @Test func theClearAtMessageEndsTheArray() throws {
        let seed = seedV2(dynamic: "VOLATILE", model: "claude-fable-5-1")
        let last = try #require(seed.messages.last)
        #expect(last.role == .system)
        #expect(last.turnScopedClearAtNextUserMessage)
        #expect(seed.delivery == .systemClearAt)
    }

    /// Turn N+1's request body must contain ZERO occurrences of turn N's clock
    /// line. On v1 the previous turn's clock line lived in a system segment
    /// that was re-sent verbatim; the whole point of the volatile message is
    /// that only THIS turn's instant ships.
    @Test func turnNPlusOneCarriesNoTraceOfTurnNsClockLine() throws {
        let turnN = seedV2(dynamic: "PACKET\n\n\(clockLineTurnN)")
        // Turn N+1 replays turn N's rows and renders its own clock.
        let turnN1 = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: "PACKET\n\n\(clockLineTurnN1)",
                history: turnN.messages.filter { $0.role != .system }
            ),
            shape: .v2Prefix
        )
        let body = allText(turnN1.messages)
            + (turnN1.context.systemPrompt ?? "")
        #expect(body.components(separatedBy: clockLineTurnN).count - 1 == 0)
        #expect(body.contains(clockLineTurnN1))
    }

    /// The capsule is the most expensive per-turn artifact in the system.
    /// Whatever else moves, its BYTES must be the same on both arms.
    @Test func cognitiveCapsuleBytesAreIdenticalOnBothArms() throws {
        let capsule = """
        [CognitiveSubstrate]
        run_id: abc-123
        session_id: sess-1
        surface: chat
        felt: steady
        """
        let dynamic = "PACKET\n\n\(capsule)"
        let ctx = contextFixture(dynamic: dynamic, history: projection().messages)
        let v1 = ConversationPrefixSeeding.seed(ctx, shape: .v1Legacy)
        let v2 = ConversationPrefixSeeding.seed(ctx, shape: .v2Prefix)
        let v1Bytes = (v1.context.systemPrompt ?? "") + allText(v1.messages)
        let v2Bytes = (v2.context.systemPrompt ?? "") + allText(v2.messages)
        func capsuleSlice(_ text: String) -> String {
            guard let start = text.range(of: "[CognitiveSubstrate]") else { return "" }
            return String(text[start.lowerBound...])
        }
        #expect(!capsuleSlice(v1Bytes).isEmpty)
        #expect(capsuleSlice(v1Bytes) == capsuleSlice(v2Bytes))
        // And the capsule left the system prompt entirely on v2.
        #expect(!(v2.context.systemPrompt ?? "").contains("[CognitiveSubstrate]"))
    }

    // MARK: Delivery ladder

    @Test func fable51GetsClearAt_otherFirstPartyClaudeGetsPlainSystem() {
        #expect(ConversationPrefixSeeding.delivery(
            model: "claude-fable-5-1", providerId: "anthropic_oauth_direct"
        ) == .systemClearAt)
        for model in ["claude-fable-5", "claude-opus-5", "claude-opus-4-8"] {
            #expect(ConversationPrefixSeeding.delivery(
                model: model, providerId: "anthropic_oauth_direct"
            ) == .system, "\(model)")
        }
    }

    /// The rungs that must NOT get a `.system` message: their adapters have a
    /// two-way role model and would encode it as ASSISTANT prose — putting
    /// words in her own mouth, which is worse than losing the cache win.
    @Test func twoWayRoleProvidersFoldTheBlockIntoTheUserMessage() throws {
        for (model, provider) in [
            ("claude-sonnet-5", "anthropic_oauth_direct"),
            ("grok-4", "xai_oauth"),
            ("gpt-5.6-sol", "openai"),
            ("kimi-k2", "moonshot"),
            ("not-a-real-model", nil),
        ] as [(String, String?)] {
            #expect(
                ConversationPrefixSeeding.delivery(model: model, providerId: provider)
                    == .userLeadingBlock,
                "\(model)"
            )
        }
        let seed = seedV2(dynamic: "VOLATILE", model: "claude-sonnet-5", providerId: "anthropic_oauth_direct")
        #expect(seed.volatileIndex == nil)
        // Folded in, so the user turn is the last message and there is no
        // system message to place at all.
        let current = try #require(seed.messages.last)
        #expect(current.role == .user)
        #expect(seed.currentUserIndex == seed.messages.count - 1)
        // LEADING text block of the current user message.
        if case .text(let first)? = current.content.first {
            #expect(first == "VOLATILE")
        } else {
            Issue.record("volatile block is not the leading text block")
        }
        #expect(text(current).contains("the current question"))
    }

    @Test func openAIResponsesLaneGetsASystemMessage_theAdapterEmitsDeveloper() {
        #expect(ConversationPrefixSeeding.delivery(
            model: "gpt-5.6-sol", providerId: "openai_oauth_direct"
        ) == .system)
        #expect(ConversationPrefixSeeding.delivery(
            model: "gpt-5.6-sol", providerId: "codex"
        ) == .system)
    }

    // MARK: Kill switch

    /// `.v1Legacy` must produce EXACTLY what every lane produced before v2: one
    /// user message, context untouched, dynamic segment intact. This is the
    /// rollback arm, so it is pinned on a fixed fixture rather than trusted.
    @Test func v1LegacyIsByteIdenticalToThePreV2Shape() throws {
        let ctx = contextFixture(
            dynamic: "PACKET\n\nRECALL\n\n\(clockLineTurnN)",
            history: projection().messages
        )
        let seed = ConversationPrefixSeeding.seed(ctx, shape: .v1Legacy)
        #expect(seed.delivery == .none)
        #expect(seed.volatileIndex == nil)
        #expect(seed.messages.count == 1)
        #expect(seed.messages[0].role == .user)
        #expect(seed.currentUserIndex == 0)
        #expect(text(seed.messages[0]) == "the current question")
        #expect(seed.context.systemPrompt == ctx.systemPrompt)
        #expect(seed.context.systemSegments?.dynamic == ctx.systemSegments?.dynamic)
        #expect(seed.context.turnVolatileBlock == nil)
    }

    /// A turn with no replayed prefix has nothing to reuse across turns, so it
    /// stays on the v1 shape even under `.v2Prefix` — relocation without a
    /// cache to feed would be a model-visible move that buys nothing.
    @Test func aTurnWithNoHistoryStaysOnTheV1Shape() {
        let ctx = contextFixture(dynamic: "VOLATILE", history: [])
        let seed = ConversationPrefixSeeding.seed(ctx, shape: .v2Prefix)
        #expect(seed.messages.count == 1)
        #expect(seed.delivery == .none)
        #expect(seed.context.systemSegments?.dynamic == "VOLATILE")
    }

    /// Images stay on the CURRENT user message and are never replayed.
    @Test func imageBlocksRideOnlyTheCurrentUserMessage() throws {
        let image = LLMContentBlock.image(
            mediaType: "image/png", base64: "AAA", name: "shot.png", byteSize: 3
        )
        let segments = SystemPromptSegments(stable: "S", dynamic: "VOLATILE")
        let ctx = TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-opus-5", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "look",
            systemSegments: segments, imageBlocks: [image],
            historyMessages: projection().messages
        )
        let seed = ConversationPrefixSeeding.seed(ctx, shape: .v2Prefix)
        let current = try #require(seed.messages.last)
        #expect(current.content.contains(image))
        for earlier in seed.messages.dropLast() {
            #expect(!earlier.content.contains(image))
        }
    }
}

// MARK: - Within-turn appends never break the wire rule

@Suite struct SeededConversationAppendTests {
    private func seeded(model: String = "claude-opus-5") -> [LLMMessage] {
        ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE", history: projection().messages, model: model),
            shape: .v2Prefix
        ).messages
    }

    /// The empty-reply nudge is the path that produced the class of failure:
    /// an empty reply leaves NO assistant message, so the array still ends with
    /// the volatile system message and a bare user append lands directly after
    /// it — a 400, on the recovery path.
    @Test func anEmptyReplyNudgeNeverLandsAfterTheSystemMessage() throws {
        var conversation = seeded()
        #expect(conversation.last?.role == .system)
        ConversationPrefixSeeding.appendUserText("say something", to: &conversation)
        for pair in zip(conversation, conversation.dropFirst()) {
            #expect(!(pair.0.role == .system && pair.1.role == .user))
            #expect(pair.0.role != pair.1.role)
        }
        // It merged into the current user turn, which still sits in front of
        // the volatile block.
        #expect(conversation.last?.role == .system)
        let user = try #require(conversation.dropLast().last)
        #expect(user.role == .user)
        #expect(text(user).contains("the current question"))
        #expect(text(user).contains("say something"))
    }

    /// Both call-site names route to the one owner, so neither lane can drift.
    @Test func bothNudgeHelpersUseTheSameRule() {
        var viaStructured = seeded()
        var viaNative = seeded()
        SwiftNativeTurnEngine.appendStructuredUserNudge("nudge", to: &viaStructured)
        SwiftNativeChatOrchestrationClient.appendNativeUserText("nudge", to: &viaNative)
        #expect(viaStructured == viaNative)
    }

    /// A tool round appends assistant-then-user, which is legal after a system
    /// message and must keep working exactly as before.
    @Test func aToolRoundAppendsAssistantThenUserAndStaysLegal() {
        var conversation = seeded()
        conversation.append(.assistantText("calling a tool"))
        conversation.append(.user("[tool result]"))
        for pair in zip(conversation, conversation.dropFirst()) {
            #expect(!(pair.0.role == .system && pair.1.role == .user))
            #expect(pair.0.role != pair.1.role)
        }
        #expect(conversation[conversation.count - 2].role == .assistant)
    }

    /// With no trailing system message the helper is byte-identical to the
    /// merge-else-append it replaced, so `.v1Legacy` is untouched.
    @Test func withNoTrailingSystemMessageTheRuleIsTheOldOne() {
        var endsOnUser: [LLMMessage] = [.user("a"), .assistantText("b"), .user("c")]
        ConversationPrefixSeeding.appendUserText("d", to: &endsOnUser)
        #expect(endsOnUser.count == 3)
        #expect(text(endsOnUser[2]) == "c\nd")

        var endsOnAssistant: [LLMMessage] = [.user("a"), .assistantText("b")]
        ConversationPrefixSeeding.appendUserText("c", to: &endsOnAssistant)
        #expect(endsOnAssistant.count == 3)
        #expect(endsOnAssistant[2].role == .user)
    }
}

// MARK: - Prefix fingerprint stability

@Suite struct ConversationPrefixFingerprintTests {
    private func fingerprint(_ seed: ConversationPrefixSeeding.Seed) -> String {
        // "What the next turn can reuse": history through the previous
        // assistant. The current user turn is per-turn and excluded.
        let before = Array(seed.messages.prefix(seed.currentUserIndex))
        return ConversationPrefixSeeding.prefixFingerprint(
            stable: seed.context.systemSegments?.stable ?? "",
            stableSuffix: seed.context.systemSegments?.stableSuffix ?? "",
            toolSchemaFingerprint: "tools-v1",
            messagesBeforeVolatile: before
        )
    }

    /// The measurement that says whether any of this worked. Turn N and turn
    /// N+1 change the clock, the capsule, the packet and the recall — every
    /// per-turn input — and the cacheable prefix must not move by one byte.
    @Test func prefixFingerprintSurvivesEveryPerTurnInputChanging() {
        let history = projection().messages
        let turnN = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: """
                PACKET turn N atoms
                RECALL hit A
                [CognitiveSubstrate]
                felt: steady
                \(clockLineTurnN)
                """,
                history: history
            ),
            shape: .v2Prefix
        )
        let turnN1 = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: """
                PACKET turn N+1 atoms, completely different
                RECALL hit B and hit C
                [CognitiveSubstrate]
                felt: alert
                \(clockLineTurnN1)
                """,
                history: history
            ),
            shape: .v2Prefix
        )
        #expect(fingerprint(turnN) == fingerprint(turnN1))
        // Sanity: the volatile halves really did differ.
        #expect(turnN.context.turnVolatileBlock != turnN1.context.turnVolatileBlock)
    }

    /// …and it DOES move when something cacheable actually changes, or the
    /// instrument is measuring nothing.
    @Test func prefixFingerprintMovesWhenTheCacheablePrefixMoves() {
        let base = ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "V", history: projection().messages),
            shape: .v2Prefix
        )
        let personaChanged = ConversationPrefixSeeding.seed(
            contextFixture(
                stable: "PERSONA stable bytes, edited",
                dynamic: "V",
                history: projection().messages
            ),
            shape: .v2Prefix
        )
        #expect(fingerprint(base) != fingerprint(personaChanged))

        let historyGrew = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: "V",
                history: projection().messages + [.user("a new replayed turn")]
            ),
            shape: .v2Prefix
        )
        #expect(fingerprint(base) != fingerprint(historyGrew))

        let toolsChanged = ConversationPrefixSeeding.prefixFingerprint(
            stable: base.context.systemSegments?.stable ?? "",
            stableSuffix: "",
            toolSchemaFingerprint: "tools-v2",
            messagesBeforeVolatile: Array(base.messages.prefix(base.currentUserIndex))
        )
        #expect(fingerprint(base) != toolsChanged)

        // …and it does NOT move when only the current user message changes:
        // that turn's own words are not something the next turn reuses.
        let segments = SystemPromptSegments(stable: "PERSONA stable bytes", dynamic: "V")
        let otherQuestion = ConversationPrefixSeeding.seed(
            TurnContext(
                surface: surface, personaDocs: [:], recalled: [],
                modelId: "claude-opus-5", reasoningEffort: "medium",
                providerId: "anthropic_oauth_direct", toolsAvailable: [],
                systemPrompt: segments.combined,
                userMessage: "a completely different question",
                systemSegments: segments,
                historyMessages: projection().messages
            ),
            shape: .v2Prefix
        )
        #expect(fingerprint(base) == fingerprint(otherQuestion))
    }
}

// MARK: - Window cursor

private func windowRows(
    count: Int,
    length: Int,
    anchors: Int = SessionHistoryMessageProjection.anchorLimit
) -> [HistoryWindowRow] {
    (0..<count).map { index in
        HistoryWindowRow(
            identity: "id-\(index)",
            role: index % 2 == 0 ? "user" : "assistant",
            length: length,
            isAnchor: index < anchors,
            isCompactionSummary: false
        )
    }
}

@Suite struct HistoryWindowCursorRuleTests {
    /// No pressure, no movement. A window that re-trims every turn rewrites the
    /// prefix every turn, which is the churn this cursor exists to remove.
    @Test func underPressureThresholdTheHeadDoesNotMove() {
        let rows = windowRows(count: 20, length: 100)          // 2,020 chars
        // Ceiling 2,000 → 1.15x = 2,300, and 2,020 is under it.
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: nil, budgetChars: 2_000
        ) == nil)
    }

    /// Over the threshold it advances ONCE and overshoots to the 0.70 target,
    /// which is what buys the next several turns of stability.
    @Test func overPressureItAdvancesOnceAndOvershootsToTheTarget() throws {
        let rows = windowRows(count: 40, length: 100)          // 4,040 chars
        let boundary = try #require(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: nil, budgetChars: 2_000
        ))
        let cutIndex = try #require(rows.firstIndex { $0.identity == boundary })
        let remaining = rows[(cutIndex + 1)...].reduce(0) { $0 + $1.length + 1 }
        #expect(Double(remaining) <= 2_000 * 0.70)
        // Oldest-first: the boundary is in the OLD half, never the new.
        #expect(cutIndex < rows.count / 2 + rows.count / 4)
        // And a second call at the same size is now a no-op — the whole point.
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: boundary, budgetChars: 2_000
        ) == nil)
    }

    /// Amortized rate. The quiet stretch after an advance is
    /// `(trigger - target) * budget / charsPerTurn` = `0.45 * budget /
    /// charsPerTurn`, so the "at most once per N turns" guarantee is a
    /// RELATIONSHIP, not a constant: it holds for `charsPerTurn <= 0.45/N` of
    /// the history budget. At N = 8 that is `charsPerTurn <= 0.056 * budget`
    /// — comfortably true for ordinary chat turns against the 13k+ chat
    /// history budget, and pinned here on those proportions.
    @Test func theWindowStaysPutForAtLeastEightTurnsAfterAnAdvance() throws {
        let budgetChars = 2_000                 // stands in for historyChars
        let rowLength = 20                      // 2 rows/turn = 42 chars/turn,
        var rows = windowRows(count: 200, length: rowLength)   // ≈ 2% of budget
        var boundary = try #require(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: nil, budgetChars: budgetChars
        ))
        var turnsSinceAdvance = 0
        for turn in 0..<8 {
            rows.append(HistoryWindowRow(
                identity: "new-u\(turn)", role: "user", length: rowLength,
                isAnchor: false, isCompactionSummary: false
            ))
            rows.append(HistoryWindowRow(
                identity: "new-a\(turn)", role: "assistant", length: rowLength,
                isAnchor: false, isCompactionSummary: false
            ))
            turnsSinceAdvance += 1
            if let next = HistoryWindowCursorStore.nextBoundary(
                admitted: rows, currentBoundary: boundary, budgetChars: budgetChars
            ) {
                #expect(turnsSinceAdvance >= 8, "advanced after only \(turnsSinceAdvance) turns")
                boundary = next
                turnsSinceAdvance = 0
            }
        }
        #expect(turnsSinceAdvance == 8, "the head should not have moved at all here")
    }

    /// The cursor is now the ONLY thing bounding the replayed prefix, so it has
    /// to actually engage on a real transcript that outgrows the budget. (Under
    /// the old v1-fill admission this could never fire: the fill had already
    /// capped the set at `historyChars`, so the 1.15x trigger was unreachable.)
    @Test func aTranscriptPastTheCeilingDoesTriggerASlide() throws {
        let long = longSession(turns: 200)
        let admission = try #require(SessionHistoryMessageProjection.admission(
            messages: long, historyLimit: historyLimit, surface: surface
        ))
        #expect(Double(admission.usedChars)
                > Double(budget().historyChars) * 1.15)
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: admission.rows, currentBoundary: nil,
            budgetChars: budget().historyChars
        ) != nil)
    }

    /// v2 admission is the CONTIGUOUS range, not a newest-first fill: no row in
    /// the middle is silently dropped for size, and no per-turn `suffix(limit)`
    /// head slides underneath the cursor.
    @Test func v2AdmissionIsContiguousAndKeepsEveryRenderableRow() throws {
        let long = longSession(turns: 200)
        let admission = try #require(SessionHistoryMessageProjection.admission(
            messages: long, historyLimit: historyLimit, surface: surface
        ))
        let renderable = long.compactMap(SessionHistoryPromptRenderer.renderable)
        #expect(admission.rows.count == renderable.count)
        #expect(admission.rows.map(\.identity) == renderable.map(\.historyIdentity))
        // …and v1 is untouched: it still fills newest-first against the budget,
        // so it admits strictly fewer rows on the same transcript.
        let v1 = try #require(SessionHistoryPromptRenderer.render(
            messages: long, userMessage: "now", surface: surface,
            historyLimit: historyLimit
        ))
        #expect(v1.contains("[NOTICE: Earlier session details are elided."))
    }

    /// Anchors are the opening that makes everything after it legible. The
    /// window slides past them, never through them.
    @Test func anchorsAreNeverDropped() throws {
        let rows = windowRows(count: 40, length: 400)
        let boundary = try #require(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: nil, budgetChars: 2_000
        ))
        let projected = SessionHistoryMessageProjection.project(
            messages: transcript(),
            historyLimit: historyLimit,
            surface: surface,
            cursor: HistoryWindowCursor(
                sessionId: "s", dropBoundaryIdentity: "id\u{1F}a4"
            )
        )
        // The three anchors survive even though the boundary is newer than all
        // of them.
        #expect(projected.messages.first?.role == .user)
        #expect(allText(projected.messages).contains("first question about the deploy"))
        _ = boundary
    }

    /// Monotonic: a boundary can never move backwards, so a replayed row can
    /// never re-enter the prefix and re-churn it.
    @Test func theHeadNeverMovesBackwards() {
        let rows = windowRows(count: 40, length: 100)
        // Current boundary already newer than anything pressure would pick.
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: rows, currentBoundary: "id-35", budgetChars: 2_000
        ) == nil)
    }

    /// A boundary the transcript no longer contains (compaction rewrote it)
    /// drops nothing. Fail-open is a bigger prompt, never a lost row.
    @Test func anUnknownBoundaryDropsNothing() {
        let full = projection()
        let stale = projection(cursor: HistoryWindowCursor(
            sessionId: "s", dropBoundaryIdentity: "id\u{1F}rewritten-away"
        ))
        #expect(stale.messages == full.messages)
        #expect(stale.droppedRowCount == 0)
    }

    @Test func aKnownBoundaryDropsTheOldestNonAnchorRows() {
        let full = projection()
        let slid = projection(cursor: HistoryWindowCursor(
            sessionId: "s", dropBoundaryIdentity: "id\u{1F}a3"
        ))
        #expect(slid.droppedRowCount > 0)
        #expect(allText(slid.messages).count < allText(full.messages).count)
        // Anchors (the first three user/assistant rows) survive the slide.
        #expect(allText(slid.messages).contains("first question about the deploy"))
        // …and the dropped middle really is gone.
        #expect(!allText(slid.messages).contains("third answer"))
        #expect(slid.messages.first?.role == .user)
    }
}

// MARK: - Persisted cursor: one advance per turn, never mid-turn

@Suite struct HistoryWindowCursorStoreTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-window-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A tool loop calls the context builder once per iteration. The cursor
    /// must move at most once for the whole turn — a head that slides between
    /// iteration N and N+1 is a guaranteed within-turn cache kill.
    @Test func neverAdvancesTwiceWithinOneTurn() async {
        let store = HistoryWindowCursorStore(dataRoot: tempRoot())
        let rows = windowRows(count: 40, length: 100)
        let first = await store.advanceIfNeeded(
            sessionId: "sess-1", admitted: rows, budgetChars: 2_000, rowCap: 0,
            turnId: "turn-a", compactionRanThisTurn: false
        )
        #expect(first.didAdvance)
        let second = await store.advanceIfNeeded(
            sessionId: "sess-1", admitted: rows, budgetChars: 2_000, rowCap: 0,
            turnId: "turn-a", compactionRanThisTurn: false
        )
        #expect(!second.didAdvance)
        #expect(second.cursor.dropBoundaryIdentity == first.cursor.dropBoundaryIdentity)
        #expect(second.cursor.advanceCount == 1)
    }

    /// Compaction is the rare rewrite owner. Two rewrites of the same prefix in
    /// one turn pays the cache write premium twice for one turn's savings.
    @Test func neverAdvancesInATurnCompactionAlreadyRewrote() async {
        let store = HistoryWindowCursorStore(dataRoot: tempRoot())
        let rows = windowRows(count: 40, length: 100)
        let outcome = await store.advanceIfNeeded(
            sessionId: "sess-2", admitted: rows, budgetChars: 2_000, rowCap: 0,
            turnId: "turn-a", compactionRanThisTurn: true
        )
        #expect(!outcome.didAdvance)
        #expect(outcome.cursor.dropBoundaryIdentity == nil)
    }

    @Test func theCursorSurvivesAReload() async {
        let root = tempRoot()
        let rows = windowRows(count: 40, length: 100)
        let written = await HistoryWindowCursorStore(dataRoot: root).advanceIfNeeded(
            sessionId: "sess-3", admitted: rows, budgetChars: 2_000, rowCap: 0,
            turnId: "turn-a", compactionRanThisTurn: false
        )
        #expect(written.didAdvance)
        let reloaded = await HistoryWindowCursorStore(dataRoot: root).load(sessionId: "sess-3")
        #expect(reloaded.dropBoundaryIdentity == written.cursor.dropBoundaryIdentity)
        #expect(reloaded.advanceCount == 1)
        #expect(reloaded.lastAdvanceTurnId == "turn-a")
    }

    @Test func anUnsafeSessionIdIsRefusedWithoutTouchingDisk() async {
        let store = HistoryWindowCursorStore(dataRoot: tempRoot())
        let outcome = await store.advanceIfNeeded(
            sessionId: "../escape", admitted: windowRows(count: 40, length: 100),
            budgetChars: 2_000, rowCap: 0, turnId: "t", compactionRanThisTurn: false
        )
        #expect(!outcome.didAdvance)
    }

    /// THE WRITE IS THE DECISION. A swallowed save failure used to report
    /// `didAdvance: true` against a cursor that was never persisted: this turn
    /// dropped the oldest rows, the next turn reloaded the OLD boundary, and
    /// those rows re-entered the prefix — the exact churn the cursor exists to
    /// prevent, wearing the receipt of a healthy advance.
    @Test func aFailedWriteKeepsTheOldCursorAndReportsNoAdvance() async {
        let root = tempRoot()
        // Make the per-session file unwritable by putting a DIRECTORY where the
        // JSON has to go: the lock still succeeds, the write cannot.
        let dir = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
            .appendingPathComponent("sess-fail.json", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryWindowCursorStore(dataRoot: root)
        let outcome = await store.advanceIfNeeded(
            sessionId: "sess-fail", admitted: windowRows(count: 40, length: 100),
            budgetChars: 2_000, rowCap: 0, turnId: "turn-a", compactionRanThisTurn: false
        )
        // No advance claimed, and the cursor handed back is the OLD one — so
        // the projection this turn replays the same rows the next turn will.
        #expect(!outcome.didAdvance)
        #expect(outcome.cursor.dropBoundaryIdentity == nil)
        #expect(outcome.cursor.advanceCount == 0)
        // And it did not latch a turn id, so a later turn may still try.
        #expect(outcome.cursor.lastAdvanceTurnId == nil)
    }

    /// The successful path still latches, so the pair of tests brackets the
    /// authority question from both sides.
    @Test func aSuccessfulWriteIsWhatMakesTheAdvanceReal() async {
        let root = tempRoot()
        let store = HistoryWindowCursorStore(dataRoot: root)
        let outcome = await store.advanceIfNeeded(
            sessionId: "sess-ok", admitted: windowRows(count: 40, length: 100),
            budgetChars: 2_000, rowCap: 0, turnId: "turn-a", compactionRanThisTurn: false
        )
        #expect(outcome.didAdvance)
        let reloaded = await HistoryWindowCursorStore(dataRoot: root)
            .load(sessionId: "sess-ok")
        // The returned cursor and the persisted one agree — that is the whole
        // invariant the failure path was violating.
        #expect(reloaded.dropBoundaryIdentity == outcome.cursor.dropBoundaryIdentity)
        #expect(reloaded.advanceCount == outcome.cursor.advanceCount)
    }
}

// MARK: - Window receipt travels on the context

@Suite struct HistoryWindowReceiptPlumbingTests {
    private func ctx(_ receipt: HistoryWindowReceipt?) -> TurnContext {
        let segments = SystemPromptSegments(stable: "S", dynamic: "VOLATILE")
        return TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-opus-5", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "now",
            systemSegments: segments,
            historyMessages: projection().messages,
            historyWindowReceipt: receipt
        )
    }

    /// The seeding sites used to hard-code 0/false, so a turn that DID slide
    /// its window reported that it had not — a receipt disagreeing with the
    /// decision it describes is worse than no receipt.
    @Test func telemetryReportsTheWindowDecisionTheContextCarries() {
        let seed = ConversationPrefixSeeding.seed(
            ctx(HistoryWindowReceipt(advanceCount: 3, slid: true)), shape: .v2Prefix
        )
        let snapshot = ConversationPrefixSeeding.telemetry(
            seed, shape: .v2Prefix, toolSchemaFingerprint: "tools-v1"
        )
        #expect(snapshot.windowCursorAdvanceCount == 3)
        #expect(snapshot.windowSlid)
        #expect(snapshot.shapeVersion == ConversationPrefixShape.v2Prefix.rawValue)
    }

    /// No receipt (v1, or a caller with no history lane) reads as zero — an
    /// honest absence, not an invented advance.
    @Test func anAbsentReceiptReadsAsZero() {
        let seed = ConversationPrefixSeeding.seed(ctx(nil), shape: .v2Prefix)
        let snapshot = ConversationPrefixSeeding.telemetry(
            seed, shape: .v2Prefix, toolSchemaFingerprint: "tools-v1"
        )
        #expect(snapshot.windowCursorAdvanceCount == 0)
        #expect(!snapshot.windowSlid)
    }

    /// The receipt has to survive every mid-pipeline TurnContext rebuild, or
    /// the seeding site reads a default that the build never chose.
    @Test func theReceiptSurvivesTheRebuildsBetweenBuildAndSeeding() {
        let receipt = HistoryWindowReceipt(advanceCount: 2, slid: true)
        let built = ctx(receipt)
        #expect(built.splittingVolatileBlock().historyWindowReceipt == receipt)
        #expect(built.withToolSchemas([]).historyWindowReceipt == receipt)
        #expect(SwiftNativeTurnEngine.contextByAppendingRuntimeContext(
            built, runtimeContext: "runtime"
        ).historyWindowReceipt == receipt)
        #expect(SwiftNativeTurnEngine.contextByAppendingClockContext(
            built, now: Date()
        ).historyWindowReceipt == receipt)
        #expect(SwiftNativeTurnEngine.contextBySettingNaturalExpressionCue(
            built, cue: "cue"
        ).historyWindowReceipt == receipt)
    }
}

// MARK: - Renderer arm equivalence

@Suite struct RenderedHistoryArmTests {
    /// v2 renders the SAME derived blocks (evidence boundary, continuity state,
    /// middle sampling, reply-reference hint) and only drops the conversation
    /// rows — which moved into `messages`.
    @Test func v2DropsOnlyTheConversationRowsFromTheRenderedBlock() throws {
        let v1 = try #require(SessionHistoryPromptRenderer.renderDetailed(
            messages: transcript(), userMessage: "yes go ahead",
            surface: surface, historyLimit: historyLimit
        ).historyBlock)
        let v2 = try #require(SessionHistoryPromptRenderer.renderDetailed(
            messages: transcript(), userMessage: "yes go ahead",
            surface: surface, historyLimit: historyLimit,
            includeConversationHistory: false
        ).historyBlock)
        #expect(v1.contains("# Historical evidence boundary"))
        #expect(v2.contains("# Historical evidence boundary"))
        #expect(v1.contains("SESSION_CONTINUITY_STATE:"))
        #expect(v2.contains("SESSION_CONTINUITY_STATE:"))
        #expect(v1.contains("Conversation history:"))
        #expect(!v2.contains("Conversation history:"))
        #expect(v2.count < v1.count)
    }

    /// The default argument keeps every pre-existing caller byte-identical.
    @Test func theDefaultArmIsUnchanged() {
        let explicit = SessionHistoryPromptRenderer.renderDetailed(
            messages: transcript(), userMessage: "now",
            surface: surface, historyLimit: historyLimit,
            includeConversationHistory: true
        ).historyBlock
        let defaulted = SessionHistoryPromptRenderer.render(
            messages: transcript(), userMessage: "now",
            surface: surface, historyLimit: historyLimit
        )
        #expect(explicit == defaulted)
    }
}

// MARK: - Long-session prefix stability (the whole point)

/// `turns` complete user/assistant exchanges at a realistic size.
private func longSession(turns: Int, charsPerRow: Int = 300) -> [ChatMessage] {
    let body = String(repeating: "w ", count: charsPerRow / 2)
    return (0..<turns).flatMap { index in
        [
            msg("user", "q\(index) \(body)", id: "u\(index)"),
            msg("assistant", "a\(index) \(body)", id: "a\(index)"),
        ]
    }
}

@Suite struct LongSessionPrefixStabilityTests {
    private func fingerprint(_ messages: [LLMMessage]) -> String {
        ConversationPrefixSeeding.prefixFingerprint(
            stable: "PERSONA stable bytes",
            stableSuffix: "",
            toolSchemaFingerprint: "tools-v1",
            messagesBeforeVolatile: messages
        )
    }

    /// THE measurement this whole change exists for. A live session keeps
    /// adding turns; the replayed prefix must stay byte-identical for a long
    /// run and move ONLY when the cursor advances. Under the old per-turn
    /// budget fill this was impossible — the head slid every single turn.
    @Test func theReplayedPrefixHoldsForAtLeastEightTurnsAndMovesOnlyOnAnAdvance() throws {
        let budgetChars = budget().historyChars
        var session = longSession(turns: 40)
        var cursor = HistoryWindowCursor(sessionId: "s")

        func turn() -> (fingerprint: String, advanced: Bool) {
            let admission = SessionHistoryMessageProjection.admission(
                messages: session, historyLimit: historyLimit, surface: surface
            )!
            var advanced = false
            if let next = HistoryWindowCursorStore.nextBoundary(
                admitted: admission.rows,
                currentBoundary: cursor.dropBoundaryIdentity,
                budgetChars: budgetChars
            ) {
                cursor = HistoryWindowCursor(
                    sessionId: "s", dropBoundaryIdentity: next,
                    advanceCount: cursor.advanceCount + 1
                )
                advanced = true
            }
            let projected = SessionHistoryMessageProjection.project(
                admission, cursor: cursor
            )
            return (fingerprint(projected.messages), advanced)
        }

        // Turn 0 slides once (the fixture already exceeds the ceiling), then
        // the head must hold.
        var previous = turn()
        var heldTurns = 0
        var advances = 0
        for index in 40..<(40 + 12) {
            session.append(msg("user", "q\(index) \(String(repeating: "w ", count: 150))",
                               id: "u\(index)"))
            session.append(msg("assistant", "a\(index) \(String(repeating: "w ", count: 150))",
                                id: "a\(index)"))
            let current = turn()
            if current.advanced {
                #expect(heldTurns >= 8,
                        "prefix moved after only \(heldTurns) held turns")
                advances += 1
                heldTurns = 0
            } else {
                // Not advanced ⇒ the cacheable prefix did not move by one byte.
                #expect(current.fingerprint == previous.fingerprint)
                heldTurns += 1
            }
            previous = current
        }
        #expect(heldTurns + advances * 8 >= 8)
    }

    /// The head is the CURSOR, not the tail window: appending turns does not
    /// shift the oldest replayed row.
    @Test func appendingTurnsDoesNotMoveTheOldestReplayedRow() throws {
        var session = longSession(turns: 10)   // comfortably under the ceiling
        func oldest() throws -> String {
            let projected = SessionHistoryMessageProjection.project(
                messages: session, historyLimit: historyLimit, surface: surface
            )
            return text(try #require(projected.messages.first))
        }
        let before = try oldest()
        for index in 10..<20 {
            session.append(msg("user", "q\(index)", id: "u\(index)"))
            session.append(msg("assistant", "a\(index)", id: "a\(index)"))
        }
        #expect(try oldest() == before)
    }
}

// MARK: - context.snapshot must measure the volatile block, not the empty segment

/// Capture `context.snapshot` off a private bus, so this never touches the
/// shared one or the live traces file.
private func captureSnapshot(
    _ body: @escaping (TurnTraceBus, String) -> Void
) async -> [String: JSONValue] {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let sub = await bus.subscribe()
    let drain = Task { () -> [String: JSONValue] in
        for await event in sub.stream where event.kind == "context.snapshot" {
            if case .object(let payload) = event.payload { return payload }
        }
        return [:]
    }
    let turnId = "turn-\(UUID().uuidString)"
    TurnTraceContext.$bus.withValue(bus) {
        TurnTraceContext.$turnId.withValue(turnId) {
            body(bus, turnId)
        }
    }
    let stopper = Task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await bus.unsubscribe(sub.id)
    }
    let payload = await drain.value
    stopper.cancel()
    await bus.unsubscribe(sub.id)
    return payload
}

private let capsuleFixture = """
[CognitiveSubstrate]
run_id: run-1
session_id: sess-1
surface: chat
felt: steady, a little wry
"""

@Suite struct ContextSnapshotVolatileBlockTests {
    private func v2Context() -> TurnContext {
        // The v2 shape: stable segments only, everything per-turn lifted into
        // the volatile block.
        let stable = "PERSONA stable bytes"
        let segments = SystemPromptSegments(stable: stable, dynamic: "")
        return TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-fable-5-1", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "the current question",
            systemSegments: segments,
            historyMessages: projection().messages,
            turnVolatileBlock: "PACKET atoms\n\nRECALL hit\n\n\(capsuleFixture)\n\n\(clockLineTurnN)"
        )
    }

    /// Live turn c83a39b8 shipped 11,304 characters of packet + recall + capsule
    /// in the volatile block and the Inspector reported `dynamicBytes: 0`,
    /// `containsCognitiveSubstrate: false`, `cognitiveCapsuleBytes: 0`. It was
    /// scanning the system segments, which v2 deliberately empties — measuring
    /// the wrong string, not observing an empty one. This is the silent-failure
    /// shape the whole instrument exists to avoid.
    @Test func aV2TurnReportsItsCapsuleAndDynamicMassFromTheVolatileBlock() async {
        let context = v2Context()
        let payload = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: context, sessionId: "sess-1"
            )
        }
        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        if case .int(let capsuleBytes)? = payload["cognitiveCapsuleBytes"] {
            #expect(capsuleBytes > 0)
        } else {
            Issue.record("cognitiveCapsuleBytes missing")
        }
        if case .int(let dynamicChars)? = payload["dynamicChars"] {
            #expect(dynamicChars == Int64(context.turnVolatileBlock?.count ?? 0))
        } else {
            Issue.record("dynamicChars missing")
        }
        // The delivery and size receipts are on the snapshot too, so a reader
        // does not have to join it to an llm.call row to know the shape.
        #expect(payload["volatileBlockChars"]
                == .int(Int64(context.turnVolatileBlock?.count ?? 0)))
        #expect(payload["volatileDelivery"] == .string("systemClearAt"))
        #expect(payload["shapeVersion"] == .string(ConversationPrefixShape.v2Prefix.rawValue))
        #expect(payload["historyMessageCount"]
                == .int(Int64(context.historyMessages.count)))
    }

    /// THE TEXT LANE, exactly as `streamTurn` fires it (live 92023f8c).
    ///
    /// This lane seeds BEFORE the provider call, so the context reaching the
    /// snapshot is the already-split one: dynamic segment empty, per-turn mass
    /// in `turnVolatileBlock`. It also fires through a REBUILT `snapshotContext`
    /// with `systemPromptOverride` / `systemSegmentsOverride` from the
    /// tool-catalog layout — and that rebuild was dropping the volatile block,
    /// so the snapshot had nothing left to measure and reported
    /// `cognitiveCapsuleBytes: 0` on a turn carrying 20,068 characters.
    ///
    /// The failure mode is the dangerous one: no error, no empty field, just a
    /// zero that reads as "she had no capsule this turn".
    @Test func theTextLaneSnapshotReportsTheCapsuleFromTheSeededContext() async {
        let seeded = ConversationPrefixSeeding.seed(v2Context(), shape: .v2Prefix).context
        // What the text-compat layout hands the snapshot: catalog folded into
        // the stable mass, dynamic empty.
        let layoutSegments = SystemPromptSegments(
            stable: (seeded.systemSegments?.stable ?? "") + "\n\nTOOL CATALOG",
            stableSuffix: "Also loaded this session: x",
            dynamic: ""
        )
        let payload = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface,
                context: seeded,
                sessionId: "sess-1",
                systemPromptOverride: layoutSegments.combined,
                systemSegmentsOverride: layoutSegments
            )
        }
        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        if case .int(let capsuleBytes)? = payload["cognitiveCapsuleBytes"] {
            #expect(capsuleBytes > 0)
        } else {
            Issue.record("cognitiveCapsuleBytes missing")
        }
        #expect(payload["dynamicChars"] == .int(Int64(seeded.turnVolatileBlock?.count ?? 0)))
        #expect(payload["volatileBlockChars"]
                == .int(Int64(seeded.turnVolatileBlock?.count ?? 0)))
        #expect(payload["volatileDelivery"] == .string("systemClearAt"))
        // The stable mass reported is the LAYOUT's, not the pre-layout one —
        // the overrides still win for everything they cover.
        #expect(payload["stableChars"] == .int(Int64(layoutSegments.stable.count)))
    }

    /// The structured lane fires BEFORE seeding, so its context is unsplit and
    /// the capsule is still in `segments.dynamic`. Same answer, other source —
    /// that is what makes the derivation correct rather than lucky.
    @Test func theStructuredLaneSnapshotReportsTheCapsuleFromTheDynamicSegment() async {
        let preSplit = v2Context()
        let unsplitSegments = SystemPromptSegments(
            stable: "PERSONA stable bytes",
            dynamic: preSplit.turnVolatileBlock ?? ""
        )
        let context = TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-fable-5-1", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: unsplitSegments.combined, userMessage: "the current question",
            systemSegments: unsplitSegments,
            historyMessages: preSplit.historyMessages
        )
        let payload = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: context, sessionId: "sess-1"
            )
        }
        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        #expect(payload["dynamicChars"] == .int(Int64(unsplitSegments.dynamic.count)))
        // Pre-split: no volatile block yet, so no delivery is claimed.
        #expect(payload["volatileDelivery"] == nil)
    }

    /// The capsule span is `[CognitiveSubstrate] … [OrganismBehavior] …` and
    /// nothing else. It used to run to END OF STRING, which on v2 swallowed
    /// every volatile section that happened to follow it — live 92023f8c
    /// reported `cognitiveCapsuleBytes: 9,299` for a 9,299-character block.
    @Test func capsuleBytesCoverTheCapsuleSpanNotTheWholeVolatileBlock() async {
        let capsuleWithPosture = """
        \(capsuleFixture)

        [OrganismBehavior]
        posture: leaning in
        """
        // A volatile block with the capsule in the MIDDLE: packet before it,
        // history and clock after.
        let volatile = """
        PACKET atoms, several of them

        \(capsuleWithPosture)

        # Historical evidence boundary
        Session continuity and conversation rows below preserve what was known.

        \(clockLineTurnN)
        """
        let segments = SystemPromptSegments(stable: "PERSONA stable bytes", dynamic: "")
        let context = TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-fable-5-1", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "now",
            systemSegments: segments,
            historyMessages: projection().messages,
            turnVolatileBlock: volatile
        )
        let payload = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: context, sessionId: "sess-1"
            )
        }
        guard case .int(let capsuleBytes)? = payload["cognitiveCapsuleBytes"] else {
            Issue.record("cognitiveCapsuleBytes missing")
            return
        }
        #expect(capsuleBytes > 0)
        // The span stops at the next non-capsule section — it is NOT the block.
        #expect(capsuleBytes < Int64(volatile.utf8.count))
        // …and it DOES include the OrganismBehavior half, which is the capsule's
        // own second section rather than a neighbour.
        #expect(capsuleBytes >= Int64(capsuleWithPosture.utf8.count) - 8)
        // The rest of the block is still measured, by dynamicChars.
        #expect(payload["dynamicChars"] == .int(Int64(volatile.count)))
    }

    /// Both fields are stamped on EVERY turn. A reader that has to infer the
    /// shape from a missing key cannot tell "v1" from "the field was dropped
    /// somewhere in the rebuild chain" — which is exactly what hid the text
    /// lane's blindness for two rounds.
    @Test func shapeAndDeliveryAreAlwaysStamped() async {
        let v2 = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: v2Context(), sessionId: "sess-1"
            )
        }
        #expect(v2["shapeVersion"] == .string(ConversationPrefixShape.v2Prefix.rawValue))
        #expect(v2["volatileDelivery"] == .string("systemClearAt"))

        let segments = SystemPromptSegments(stable: "S", dynamic: "D")
        let v1Context = TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-opus-5", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "now",
            systemSegments: segments
        )
        let v1 = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: v1Context, sessionId: "sess-1"
            )
        }
        #expect(v1["shapeVersion"] != nil)
        #expect(v1["volatileDelivery"] == .string("none"))
    }

    /// v1 keeps reading the dynamic SEGMENT — the fix moves the source, it does
    /// not change what a v1 turn reports.
    @Test func aV1TurnStillMeasuresTheDynamicSegment() async {
        let segments = SystemPromptSegments(
            stable: "PERSONA stable bytes", dynamic: "PACKET\n\n\(capsuleFixture)"
        )
        let context = TurnContext(
            surface: surface, personaDocs: [:], recalled: [],
            modelId: "claude-opus-5", reasoningEffort: "medium",
            providerId: "anthropic_oauth_direct", toolsAvailable: [],
            systemPrompt: segments.combined, userMessage: "now",
            systemSegments: segments
        )
        let payload = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: context, sessionId: "sess-1"
            )
        }
        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        #expect(payload["dynamicChars"] == .int(Int64(segments.dynamic.count)))
        // No volatile block ⇒ no v2 receipts invented.
        #expect(payload["volatileDelivery"] == nil)
    }

    /// The memory-recall outcome is DERIVED, in a fixed order: an explicit
    /// outcome wins, then the legacy `recalled` lane, then the ContextFlow
    /// packet's own memory/correction atoms, and only then `unknown`.
    ///
    /// The bug this closes: a ContextFlow turn's legacy lane is empty BY DESIGN
    /// (memory rides the packet), so the old fallback jumped straight to
    /// `unknown` and said "we have no idea" about a turn whose provenance is
    /// fully known — the same measurement lie `memory.recallHits` was already
    /// fixed for on the stage trace.
    ///
    /// A `ContextPreparedTurn` is not constructible from here, so the packet
    /// rung is pinned on the stage trace instead (`buildTurnContext` stamps
    /// `.contextFlow` from the identical reduction). What IS pinned here: an
    /// explicit outcome passes through untouched, and a turn with neither
    /// source stays honestly `unknown` rather than inventing zero hits.
    @Test func theRecallOutcomeIsDerivedInOrderAndNeverInvented() async {
        let explicit = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: v2Context(), sessionId: "sess-1",
                memoryRecallOutcome: .contextFlow(hitCount: 12)
            )
        }
        guard case .object(let carried)? = explicit["memoryRecall"] else {
            Issue.record("memoryRecall missing")
            return
        }
        #expect(carried["outcome"] == .string("contextFlow"))
        #expect(carried["retrievedHitCount"] == .int(12))

        let bare = await captureSnapshot { _, _ in
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: surface, context: v2Context(), sessionId: "sess-1"
            )
        }
        guard case .object(let derived)? = bare["memoryRecall"] else {
            Issue.record("memoryRecall missing")
            return
        }
        // No packet and no legacy hits on this fixture: honest absence, not a
        // fabricated zero-hit success.
        #expect(derived["outcome"] == .string("unknown"))
    }
}


// MARK: - Cleared turn-scoped messages must STAY in the prefix

/// A transcript whose rows carry run ids, so an archived block can find the
/// user message it originally followed.
private func runIdTranscript() -> [ChatMessage] {
    func row(_ role: String, _ text: String, id: String, run: String) -> ChatMessage {
        ChatMessage(
            role: role, content: text, timestamp: "2026-09-02T12:00:00Z",
            extras: .object(["id": .string(id), "runId": .string(run)])
        )
    }
    return [
        row("user", "first question", id: "u1", run: "run-1"),
        row("assistant", "first answer", id: "a1", run: "run-1"),
        row("user", "second question", id: "u2", run: "run-2"),
        row("assistant", "second answer", id: "a2", run: "run-2"),
    ]
}

@Suite struct ArchivedVolatileReplayTests {
    private func project(
        _ archive: [String: [LLMMessage]],
        messages: [ChatMessage] = runIdTranscript()
    ) -> SessionHistoryMessageProjection.Result {
        SessionHistoryMessageProjection.project(
            messages: messages,
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: nil,
            cursor: nil,
            archivedTurnMessages: archive
        )
    }

    /// A turn-scoped volatile block, as the seed built it.
    private func volatile(_ text: String) -> [LLMMessage] {
        [.system(text, clearAtNextUserMessage: true)]
    }

    /// THE BUG. Turn N sent `… user(N) ‖ system(volatile N)`. Turn N+1 rebuilt
    /// its prefix from the transcript, which has no record of that system
    /// message, so the two requests agreed through `user(N)` and diverged at
    /// the very next element — and everything after it, the previous turn's
    /// tool rounds and reply included, was re-created at full price.
    ///
    /// A cleared turn-scoped message costs 0 input tokens but must STAY in
    /// `messages` byte-for-byte.
    @Test func anEarlierTurnsBlockIsReplayedInItsOriginalPosition() throws {
        let result = project(["run-1": volatile("VOLATILE TURN 1")])
        let roles = result.messages.map(\.role)
        // user(1) ‖ system(volatile 1) ‖ assistant(1) ‖ user(2) ‖ assistant(2)
        #expect(roles == [.user, .system, .assistant, .user, .assistant])
        #expect(text(result.messages[1]) == "VOLATILE TURN 1")
        #expect(result.messages[1].turnScopedClearAtNextUserMessage)
        // BYTE-FOR-BYTE: the archive is replayed verbatim, never re-rendered.
        #expect(result.messages[1].content.count == 1)
    }

    @Test func everyArchivedTurnIsReplayedAtItsOwnPosition() {
        let result = project(["run-1": volatile("V1"), "run-2": volatile("V2")])
        #expect(result.messages.map(\.role)
                == [.user, .system, .assistant, .user, .system, .assistant])
        #expect(text(result.messages[1]) == "V1")
        #expect(text(result.messages[4]) == "V2")
    }

    /// The wire rule governs a REPLAYED system message exactly as it governs
    /// the current one: it may precede an assistant turn or end the array,
    /// never precede a user turn.
    @Test func noReplayedBlockEverPrecedesAUserTurn() {
        // run-2's assistant reply was a transient failure and was filtered out
        // of the projection, so its position is not intact.
        let rows = Array(runIdTranscript().dropLast())
        let result = project(["run-1": volatile("V1"), "run-2": volatile("V2")], messages: rows)
        for pair in zip(result.messages, result.messages.dropFirst()) {
            #expect(!(pair.0.role == .system && pair.1.role == .user))
        }
        #expect(!allText(result.messages).contains("V2"))
        #expect(allText(result.messages).contains("V1"))
    }

    /// The tail block is dropped for the same reason: `seed` appends the
    /// CURRENT user message next, and a system message directly before it is
    /// the 400 the whole ordering exists to avoid.
    @Test func aTailBlockIsDroppedSoTheCurrentUserTurnCanFollow() throws {
        let rows = Array(runIdTranscript().dropLast())
        let history = project(["run-2": volatile("TAIL")], messages: rows).messages
        #expect(history.last?.role == .user)
        let seed = ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE NOW", history: history,
                           model: "claude-fable-5-1"),
            shape: .v2Prefix
        )
        for pair in zip(seed.messages, seed.messages.dropFirst()) {
            #expect(!(pair.0.role == .system && pair.1.role == .user))
            #expect(pair.0.role != pair.1.role)
        }
        #expect(seed.messages.last?.role == .system)
    }

    /// Replay is opt-in per provider. Empty archive ⇒ the exact pre-archive
    /// projection, so every non-clear_at lane is untouched.
    @Test func anEmptyArchiveLeavesTheProjectionUnchanged() {
        let withArchive = project([:])
        let plain = SessionHistoryMessageProjection.project(
            messages: runIdTranscript(), historyLimit: historyLimit, surface: surface
        )
        #expect(withArchive.messages == plain.messages)
        #expect(!withArchive.messages.contains { $0.role == .system })
    }

    /// A block whose turn is no longer in the window cannot be replayed into a
    /// position that does not exist — the prune set is exactly what was
    /// replayed.
    @Test func replayedRunIdsAreWhatThePruneKeeps() {
        let result = project(["run-1": volatile("V1")])
        #expect(result.replayedRunIds == ["run-1", "run-2"])
        let stale = project(["run-99": volatile("GONE")])
        #expect(!allText(stale.messages).contains("GONE"))
        #expect(!stale.replayedRunIds.contains("run-99"))
    }

    /// Turn N+1's prefix must reproduce turn N's request byte-for-byte through
    /// the previous reply — the measurement that says the cache can hit.
    @Test func turnNPlusOnesPrefixReproducesTurnNsRequest() throws {
        // Turn N: history is just turn 1, and turn 2's user message is current.
        let turnNHistory = SessionHistoryMessageProjection.project(
            messages: Array(runIdTranscript().prefix(2)),
            historyLimit: historyLimit, surface: surface
        ).messages
        let turnN = ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE TURN 2", history: turnNHistory,
                           model: "claude-fable-5-1"),
            shape: .v2Prefix
        )
        // Turn N+1: the transcript now has turn 2's reply, and turn 2's block
        // is in the archive.
        let turnN1History = SessionHistoryMessageProjection.project(
            messages: runIdTranscript(), historyLimit: historyLimit, surface: surface,
            windowTokens: nil, cursor: nil,
            archivedTurnMessages: ["run-2": [.system("VOLATILE TURN 2", clearAtNextUserMessage: true)]]
        ).messages
        let turnN1 = ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE TURN 3", history: turnN1History,
                           model: "claude-fable-5-1"),
            shape: .v2Prefix
        )
        // Turn N's full array is a strict PREFIX of turn N+1's — nothing before
        // turn 2's reply moved, so only the new messages are uncached.
        #expect(turnN1.messages.count > turnN.messages.count)
        #expect(Array(turnN1.messages.prefix(turnN.messages.count)) == turnN.messages)
    }
}

@Suite struct StructuredLaneToolChangeReplayTests {
    private let changes = LLMMessage.toolChanges([.addition("read_file")])

    /// The structured lane seeds `user(N) ‖ toolChanges(N) ‖ volatile(N)`, so
    /// the replay must reproduce BOTH, in that order, at that position.
    @Test func bothMessagesAreReplayedInSeededOrder() throws {
        let result = SessionHistoryMessageProjection.project(
            messages: runIdTranscript(),
            historyLimit: historyLimit,
            surface: surface,
            windowTokens: nil,
            cursor: nil,
            archivedTurnMessages: [
                "run-1": [changes, .system("VOLATILE 1", clearAtNextUserMessage: true)],
            ]
        )
        #expect(result.messages.map(\.role)
                == [.user, .system, .system, .assistant, .user, .assistant])
        #expect(result.messages[1].toolChanges == [.addition("read_file")])
        #expect(result.messages[1].content.isEmpty)
        #expect(text(result.messages[2]) == "VOLATILE 1")
        #expect(result.messages[2].turnScopedClearAtNextUserMessage)
    }

    /// Turn N's array is a strict PREFIX of turn N+1's on the structured lane
    /// too — the tool-change message included. Removing an already-sent
    /// mid-conversation system message invalidates the prefix from that point,
    /// so "strict prefix" is the whole measurement.
    @Test func turnNsArrayIsAStrictPrefixOfTurnNPlusOnes() throws {
        func history(
            _ rows: [ChatMessage], archive: [String: [LLMMessage]]
        ) -> [LLMMessage] {
            SessionHistoryMessageProjection.project(
                messages: rows, historyLimit: historyLimit, surface: surface,
                windowTokens: nil, cursor: nil, archivedTurnMessages: archive
            ).messages
        }
        // Turn N: history is turn 1 (whose own pair is archived), turn 2 current.
        let turn1Archive: [String: [LLMMessage]] = [
            "run-1": [changes, .system("VOLATILE 1", clearAtNextUserMessage: true)],
        ]
        let turnN = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: "VOLATILE 2",
                history: history(Array(runIdTranscript().prefix(2)), archive: turn1Archive),
                model: "claude-fable-5-1"
            ),
            shape: .v2Prefix,
            toolChanges: LLMMessage.toolChanges([.addition("git_log")])
        )
        // Turn N+1: turn 2's reply is now in the transcript and turn 2's own
        // pair has been archived.
        var turnN1Archive = turn1Archive
        turnN1Archive["run-2"] = Array(turnN.messages.dropFirst(turnN.currentUserIndex + 1))
        let turnN1 = ConversationPrefixSeeding.seed(
            contextFixture(
                dynamic: "VOLATILE 3",
                history: history(runIdTranscript(), archive: turnN1Archive),
                model: "claude-fable-5-1"
            ),
            shape: .v2Prefix,
            toolChanges: LLMMessage.toolChanges([.addition("git_diff")])
        )
        #expect(turnN1.messages.count > turnN.messages.count)
        #expect(Array(turnN1.messages.prefix(turnN.messages.count)) == turnN.messages)
    }

    /// Capability-gated, per KIND. A model with clear_at but no tool changes
    /// replays only the volatile block; replaying a tool-change message the
    /// previous request never sent would ADD one — the same divergence,
    /// mirrored.
    @Test func eachKindIsGatedByItsOwnCapability() {
        #expect(supportsMidConversationSystemClearAt(forModel: "claude-fable-5-1"))
        #expect(!supportsMidConversationToolChanges(forModel: "claude-sonnet-5"))
        // The filter itself is exercised at the build site; here we pin that
        // the two capability rows really are independent, which is what makes
        // per-kind filtering meaningful rather than decorative.
        #expect(supportsMidConversationToolChanges(forModel: "claude-fable-5-1")
                != supportsMidConversationToolChanges(forModel: "claude-sonnet-5"))
    }
}

@Suite struct TurnVolatileArchiveStoreTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("volatile-archive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aRecordedBlockSurvivesAReloadVerbatim() async {
        let root = tempRoot()
        let block = "PACKET\n\nRECALL\n\n[CognitiveSubstrate]\nrun_id: r\n"
        await TurnVolatileArchive(dataRoot: root).record(
            sessionId: "sess-1", runId: "run-1",
            messages: [.system(block, clearAtNextUserMessage: true)]
        )
        let reloaded = await TurnVolatileArchive(dataRoot: root).load(sessionId: "sess-1")
        let message = try? #require(reloaded["run-1"]?.first?.message)
        #expect(message == .system(block, clearAtNextUserMessage: true))
    }

    /// The structured lane's pair: a `tool_addition`/`tool_removal` message
    /// (NOT turn-scoped) followed by the turn-scoped block. Both must come back
    /// in the order they were sent — removing an already-sent tool-change
    /// message invalidates the prefix from that point just as surely as
    /// dropping the volatile block does.
    @Test func aToolChangeMessageAndVolatileBlockRoundTripInOrder() async throws {
        let archive = TurnVolatileArchive(dataRoot: tempRoot())
        let changes = LLMMessage.toolChanges([.addition("read_file"), .removal("web_search")])
        let block = LLMMessage.system("VOLATILE", clearAtNextUserMessage: true)
        await archive.record(sessionId: "s", runId: "run-1", messages: [changes, block])
        let loaded = try #require(await archive.load(sessionId: "s")["run-1"])
        #expect(loaded.count == 2)
        #expect(loaded.map(\.order) == [0, 1])
        #expect(loaded[0].message == changes)
        #expect(loaded[0].message.toolChanges == [
            .addition("read_file"), .removal("web_search"),
        ])
        #expect(loaded[1].message == block)
        // The pairing the API rejects is never reconstructed.
        #expect(!loaded[0].clearAtNextUserMessage)
        #expect(loaded[1].toolChanges.isEmpty)
    }

    @Test func recordingTheSameRunTwiceKeepsOneEntry() async {
        let archive = TurnVolatileArchive(dataRoot: tempRoot())
        await archive.record(
            sessionId: "s", runId: "run-1", messages: [.system("first", clearAtNextUserMessage: true)]
        )
        await archive.record(
            sessionId: "s", runId: "run-1", messages: [.system("second", clearAtNextUserMessage: true)]
        )
        let loaded = await archive.load(sessionId: "s")
        #expect(loaded.count == 1)
        #expect(loaded["run-1"]?.count == 1)
        #expect(loaded["run-1"]?.first?.text == "second")
    }

    /// When the window cursor drops a turn, its block goes with it — a block
    /// replayed at a position the prefix no longer contains corrupts it.
    @Test func pruningDropsBlocksOutsideTheReplayedWindow() async {
        let archive = TurnVolatileArchive(dataRoot: tempRoot())
        for index in 1...3 {
            await archive.record(
                sessionId: "s", runId: "run-\(index)",
                messages: [.system("V\(index)", clearAtNextUserMessage: true)]
            )
        }
        await archive.prune(sessionId: "s", keeping: ["run-2", "run-3"])
        let loaded = await archive.load(sessionId: "s")
        #expect(Set(loaded.keys) == ["run-2", "run-3"])
    }

    @Test func anUnsafeSessionIdWritesNothing() async {
        let root = tempRoot()
        let archive = TurnVolatileArchive(dataRoot: root)
        await archive.record(
            sessionId: "../escape", runId: "r",
            messages: [.system("x", clearAtNextUserMessage: true)]
        )
        #expect(await archive.load(sessionId: "../escape").isEmpty)
    }

    @Test func anEmptyBlockIsNeverRecorded() async {
        let archive = TurnVolatileArchive(dataRoot: tempRoot())
        await archive.record(
            sessionId: "s", runId: "run-1", messages: [.system("", clearAtNextUserMessage: true)]
        )
        #expect(await archive.load(sessionId: "s").isEmpty)
    }
}


// MARK: - The live defect: a growing transcript must not move the prefix head

@Suite struct GrowingTranscriptPrefixStabilityTests {
    /// A 150-row transcript, the shape of live session CD041E66.
    private func transcript(turns: Int) -> [ChatMessage] {
        let body = String(repeating: "w ", count: 60)
        return (0..<turns).flatMap { index in
            [
                ChatMessage(
                    role: "user", content: "q\(index) \(body)",
                    timestamp: "2026-09-02T10:00:00Z",
                    extras: .object(["id": .string("u\(index)"),
                                     "runId": .string("run-\(index)")])
                ),
                ChatMessage(
                    role: "assistant", content: "a\(index) \(body)",
                    timestamp: "2026-09-02T10:00:01Z",
                    extras: .object(["id": .string("a\(index)"),
                                     "runId": .string("run-\(index)")])
                ),
            ]
        }
    }

    /// THE LIVE DEFECT (6cc7d8de, session CD041E66). Every turn's first call
    /// read exactly 11,215 tokens — tools plus system, nothing else — and
    /// re-created ~10.5k. `historyMessageCount` went 62 → 60 → 64 → 67 while
    /// the transcript only ever grew, which is the signature of a head that
    /// moves per turn rather than a window that holds.
    ///
    /// Root cause, reproduced here: the reader hands the projection a
    /// tail-limited slice, so the admitted set was pre-trimmed to well under
    /// `historyChars`, the char-pressure trigger was unreachable, the cursor
    /// never advanced — and the head became whatever the reader's sliding tail
    /// started at. Bounding ROWS with the same hysteresis puts the head back
    /// under the cursor.
    @Test func sixConsecutiveTurnsShareTheSameReplayedHead() throws {
        // Production knob: v2 carries twice the v1 render window (cached
        // history is cheap, continuity is the point). Fires at 92 rows, trims
        // to 56; the reader width below is 2x the cap so the boundary always
        // sits well inside it.
        let rowCap = 80
        let budgetChars = budget().historyChars
        var cursor = HistoryWindowCursor(sessionId: "CD041E66")
        var advances = 0
        var heads: [String] = []

        // 75 turns = 150 rows, then six more turns on top.
        var rows = transcript(turns: 75)
        for turn in 0..<6 {
            // What the reader hands us: anchors + a 2x tail, which SLIDES.
            let anchors = Array(rows.prefix(3))
            let tail = Array(rows.suffix(rowCap * 2))
            let read = anchors + tail.filter { row in
                !anchors.contains { $0.timestamp == row.timestamp }
            }
            let admission = try #require(SessionHistoryMessageProjection.admission(
                messages: read, historyLimit: rowCap, surface: surface
            ))
            if let next = HistoryWindowCursorStore.nextBoundary(
                admitted: admission.rows,
                currentBoundary: cursor.dropBoundaryIdentity,
                budgetChars: budgetChars,
                rowCap: rowCap
            ) {
                advances += 1
                cursor = HistoryWindowCursor(
                    sessionId: "CD041E66", dropBoundaryIdentity: next,
                    advanceCount: cursor.advanceCount + 1
                )
            }
            let projected = SessionHistoryMessageProjection.project(
                admission, cursor: cursor
            )
            // Fingerprint over the first 20 messages: the part every later turn
            // has to reuse byte-for-byte.
            heads.append(ConversationPrefixSeeding.prefixFingerprint(
                stable: "PERSONA", stableSuffix: "",
                toolSchemaFingerprint: "tools",
                messagesBeforeVolatile: Array(projected.messages.prefix(20))
            ))
            // Next turn's rows.
            rows.append(contentsOf: transcript(turns: 1).map { row in
                ChatMessage(
                    role: row.role, content: "turn\(turn) " + row.content,
                    timestamp: row.timestamp,
                    extras: .object(["id": .string("\(row.role)-x\(turn)"),
                                     "runId": .string("run-x\(turn)")])
                )
            })
        }

        // ALL SIX identical: the head did not move once across six turns.
        #expect(Set(heads).count == 1, "prefix head moved across turns: \(Set(heads).count) distinct")
        #expect(advances <= 1, "advanced \(advances) times in six turns")
    }

    /// Char pressure alone cannot fire on a reader-trimmed slice — which is
    /// exactly why the cursor never advanced in production. The row bound is
    /// what makes the hysteresis reachable at all.
    @Test func rowPressureFiresWhereCharPressureCannot() throws {
        let read = Array(transcript(turns: 75).suffix(80))
        let admission = try #require(SessionHistoryMessageProjection.admission(
            messages: read, historyLimit: 40, surface: surface
        ))
        let budgetChars = budget().historyChars
        // The reader pre-trimmed it: nowhere near the character ceiling.
        #expect(Double(admission.usedChars) <= Double(budgetChars) * 1.15)
        // Char bound alone → no advance, forever. This is the production bug.
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: admission.rows, currentBoundary: nil,
            budgetChars: budgetChars, rowCap: 0
        ) == nil)
        // With the row bound it fires, once, and trims to the 0.70 target.
        let boundary = try #require(HistoryWindowCursorStore.nextBoundary(
            admitted: admission.rows, currentBoundary: nil,
            budgetChars: budgetChars, rowCap: 40
        ))
        let cutIndex = try #require(
            admission.rows.firstIndex { $0.identity == boundary }
        )
        let kept = admission.rows[(cutIndex + 1)...].count
            + admission.rows[..<(cutIndex + 1)].filter { $0.isAnchor }.count
        #expect(Double(kept) <= 40 * 0.70 + 3)
        // Immediately after, no further pressure — it holds.
        #expect(HistoryWindowCursorStore.nextBoundary(
            admitted: admission.rows, currentBoundary: boundary,
            budgetChars: budgetChars, rowCap: 40
        ) == nil)
    }
}

@Suite struct HistoryWindowCursorPersistenceTests {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Live CD041E66 had only the `.lock` sidecar and no `.json` at all,
    /// because the file was written ONLY on a successful advance. That made
    /// "no advance yet" and "the write path is broken" indistinguishable from
    /// outside — the one piece of state that pins the prefix head was
    /// invisible.
    @Test func theCursorFileExistsEvenWhenNothingAdvanced() async {
        let root = tempRoot()
        let store = HistoryWindowCursorStore(dataRoot: root)
        // Far under both bounds: no advance.
        let outcome = await store.advanceIfNeeded(
            sessionId: "CD041E66", admitted: windowRows(count: 4, length: 10),
            budgetChars: 100_000, rowCap: 400,
            turnId: "turn-a", compactionRanThisTurn: false
        )
        #expect(!outcome.didAdvance)
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
            .appendingPathComponent("CD041E66.json")
        #expect(FileManager.default.fileExists(atPath: path.path))
        let reloaded = await store.load(sessionId: "CD041E66")
        #expect(reloaded.advanceCount == 0)
        #expect(reloaded.dropBoundaryIdentity == nil)
    }

    /// A compaction turn also persists — it just does not move the head.
    @Test func aCompactionTurnPersistsWithoutAdvancing() async {
        let root = tempRoot()
        let store = HistoryWindowCursorStore(dataRoot: root)
        let outcome = await store.advanceIfNeeded(
            sessionId: "s", admitted: windowRows(count: 40, length: 100),
            budgetChars: 2_000, rowCap: 40,
            turnId: "turn-a", compactionRanThisTurn: true
        )
        #expect(!outcome.didAdvance)
        let reloaded = await store.load(sessionId: "s")
        #expect(reloaded.advanceCount == 0)
        #expect(reloaded.dropBoundaryIdentity == nil)
    }
}


// MARK: - The head must be a pure function of the cursor

@Suite struct ProjectionHeadDeterminismTests {
    private func transcript(rows: Int) -> [ChatMessage] {
        let body = String(repeating: "w ", count: 40)
        return (0..<rows).map { index in
            ChatMessage(
                role: index % 2 == 0 ? "user" : "assistant",
                content: "row\(index) \(body)",
                timestamp: "2026-09-02T11:00:00Z",
                extras: .object(["id": .string("m\(index)"),
                                 "runId": .string("run-\(index / 2)")])
            )
        }
    }

    private func digests(_ messages: [LLMMessage], _ k: Int = 6) -> [String] {
        messages.prefix(k).map(ConversationPrefixSeeding.messageDigest)
    }

    /// Live d83b71d3: the cursor reported stable (slid false, advanceCount 1)
    /// and the first call of every turn STILL read exactly 11,215 tokens —
    /// tools plus system and nothing else — because `messages[0..]` differed
    /// between requests. Sizes could not show it; two different first messages
    /// have the same length.
    ///
    /// The head is now a pure function of the persisted boundary, so the same
    /// transcript and the same cursor must yield the same head no matter what
    /// the current turn happens to be about.
    @Test func theSameTranscriptAndCursorYieldTheSameHead() throws {
        let rows = transcript(rows: 150)
        let cursor = HistoryWindowCursor(
            sessionId: "d83b71d3", dropBoundaryIdentity: "id\u{1F}m80"
        )
        func project() -> [LLMMessage] {
            SessionHistoryMessageProjection.project(
                messages: rows, historyLimit: 80, surface: surface,
                windowTokens: nil, cursor: cursor
            ).messages
        }
        let first = project()
        let second = project()
        #expect(digests(first) == digests(second))
        // The head is the row AFTER the boundary — nothing pinned in front.
        #expect(text(try #require(first.first)).contains("row81"))
    }

    /// Two consecutive turns differ only in what the user just said. The
    /// replayed head must be byte-identical across them — that is the whole
    /// cache precondition.
    @Test func differentCurrentMessagesLeaveTheHeadIdentical() throws {
        let rows = transcript(rows: 150)
        let cursor = HistoryWindowCursor(
            sessionId: "d83b71d3", dropBoundaryIdentity: "id\u{1F}m80"
        )
        let history = SessionHistoryMessageProjection.project(
            messages: rows, historyLimit: 80, surface: surface,
            windowTokens: nil, cursor: cursor
        ).messages
        func seed(_ question: String) -> ConversationPrefixSeeding.Seed {
            let segments = SystemPromptSegments(stable: "PERSONA", dynamic: "VOLATILE \(question)")
            return ConversationPrefixSeeding.seed(
                TurnContext(
                    surface: surface, personaDocs: [:], recalled: [],
                    modelId: "claude-fable-5-1", reasoningEffort: "medium",
                    providerId: "anthropic_oauth_direct", toolsAvailable: [],
                    systemPrompt: segments.combined, userMessage: question,
                    systemSegments: segments, historyMessages: history
                ),
                shape: .v2Prefix
            )
        }
        let turnA = seed("what did we decide about the rollout")
        let turnB = seed("never mind, show me the diff")
        #expect(digests(turnA.messages) == digests(turnB.messages))
        // …and the telemetry publishes those digests, so the same comparison
        // is available from the trace without re-deriving anything.
        let snapshot = ConversationPrefixSeeding.telemetry(
            turnA, shape: .v2Prefix, toolSchemaFingerprint: "tools"
        )
        #expect(snapshot.messageDigests == digests(turnA.messages))
        #expect(snapshot.messageCount == turnA.messages.count)
        #expect(snapshot.messageDigests.allSatisfy { $0.count == 12 })
    }

    /// A growing transcript with a FIXED cursor must not move the head — this
    /// is the anchors-plus-gap discontinuity the fix removes.
    @Test func aGrowingTranscriptWithAFixedCursorKeepsTheSameHead() throws {
        let cursor = HistoryWindowCursor(
            sessionId: "d83b71d3", dropBoundaryIdentity: "id\u{1F}m80"
        )
        var rows = transcript(rows: 150)
        var heads: [[String]] = []
        for _ in 0..<4 {
            heads.append(digests(SessionHistoryMessageProjection.project(
                messages: rows, historyLimit: 80, surface: surface,
                windowTokens: nil, cursor: cursor
            ).messages))
            let next = rows.count
            rows.append(contentsOf: [
                ChatMessage(role: "user", content: "new\(next)",
                            timestamp: "2026-09-02T11:30:00Z",
                            extras: .object(["id": .string("m\(next)"),
                                             "runId": .string("run-n\(next)")])),
                ChatMessage(role: "assistant", content: "reply\(next)",
                            timestamp: "2026-09-02T11:30:01Z",
                            extras: .object(["id": .string("m\(next + 1)"),
                                             "runId": .string("run-n\(next)")])),
            ])
        }
        #expect(Set(heads.map { $0.joined(separator: ",") }).count == 1)
    }

    /// The two per-row inputs that could vary invisibly: the caps and the
    /// recollection prefix. Both are pure functions of surface + model window
    /// and of a stored row, so neither moves between turns of one session.
    @Test func capsAndRecollectionDoNotVaryBetweenTurns() throws {
        let a = SessionHistoryPromptRenderer.budget(for: surface, windowTokens: nil)
        let b = SessionHistoryPromptRenderer.budget(for: surface, windowTokens: nil)
        #expect(a.userCap == b.userCap)
        #expect(a.assistantCap == b.assistantCap)
        #expect(a.historyChars == b.historyChars)

        let withSummary = [
            msg("system", "earlier: the rollout order", id: "c1", kind: "compaction_summary"),
            msg("user", "and then", id: "u1"),
            msg("assistant", "yes", id: "a1"),
        ]
        func head() -> String {
            text(SessionHistoryMessageProjection.project(
                messages: withSummary, historyLimit: 80, surface: surface
            ).messages[0])
        }
        #expect(head() == head())
        #expect(head().hasPrefix("[session recollection] "))
    }
}


// MARK: - The adapter's cross-turn seam comes from the seed, not from guessing

@Suite struct ConversationPrefixBoundaryBindingTests {
    /// Replayed history carrying ARCHIVED system blocks, and a current turn
    /// whose volatile block folds into the user message — so there is NO
    /// trailing system run for the adapter to anchor on.
    private func seededWithArchivedBlocks() -> ConversationPrefixSeeding.Seed {
        let history: [LLMMessage] = [
            .user("turn 1 question"),
            .system("ARCHIVED VOLATILE 1", clearAtNextUserMessage: true),
            .assistantText("turn 1 answer"),
            .user("turn 2 question"),
            .system("ARCHIVED VOLATILE 2", clearAtNextUserMessage: true),
            .assistantText("turn 2 answer"),
        ]
        // sonnet-5 has no mid-conversation system support → userLeadingBlock,
        // so the seeded array ends on the USER message.
        return ConversationPrefixSeeding.seed(
            contextFixture(dynamic: "VOLATILE NOW", history: history, model: "claude-sonnet-5"),
            shape: .v2Prefix
        )
    }

    /// THE DEFECT. With no trailing system run, `lastIndex(.system)` selects an
    /// ARCHIVED block from an old turn — so the cross-turn 1h marker landed
    /// near the START of the conversation and cached almost nothing. Silent and
    /// expensive: the reply is fine, the bill is not.
    @Test func theBoundBindingPutsThePreviousTurnMarkerOnAssistantNMinus1() throws {
        let seed = seededWithArchivedBlocks()
        #expect(seed.delivery == .userLeadingBlock)
        #expect(seed.messages.last?.role == .user)   // no trailing system run

        let bound = ConversationPrefixBoundary.$currentUserIndex
            .withValue(seed.currentUserIndex) {
                AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(seed.messages)
            }
        let index = try #require(bound)
        #expect(seed.messages[index].role == .assistant)
        #expect(text(seed.messages[index]) == "turn 2 answer")
        // It is the last assistant STRICTLY BEFORE the current user turn.
        #expect(index < seed.currentUserIndex)
    }

    @Test func theCurrentTurnSeamIsTheBoundIndex() throws {
        let seed = seededWithArchivedBlocks()
        let resolved = ConversationPrefixBoundary.$currentUserIndex
            .withValue(seed.currentUserIndex) {
                AnthropicOAuthDirectAdapter.currentTurnUserIndex(seed.messages)
            }
        #expect(resolved == seed.currentUserIndex)
        #expect(seed.messages[try #require(resolved)].role == .user)
    }

    /// A stale or out-of-range binding must degrade to the fallback, never
    /// mis-mark: a marker in the wrong place is worse than none.
    @Test func anInvalidBindingDegradesToTheFallback() {
        let seed = seededWithArchivedBlocks()
        for bogus in [-1, 9_999, 0] {
            let resolved = ConversationPrefixBoundary.$currentUserIndex.withValue(bogus) {
                AnthropicOAuthDirectAdapter.currentTurnUserIndex(seed.messages)
            }
            // Index 0 IS a user message, so it validates — that is the
            // fallback's own contract (in range, role .user). The other two
            // are rejected and, with no trailing system run, answer nil.
            if bogus == 0 {
                #expect(resolved == 0)
            } else {
                #expect(resolved == nil)
            }
        }
    }

    /// Within-turn rounds only APPEND, so one binding holds for the whole turn.
    @Test func withinTurnRoundsDoNotMoveTheSeam() throws {
        let seed = seededWithArchivedBlocks()
        var conversation = seed.messages
        conversation.append(.assistantText("calling a tool"))
        conversation.append(.user("[tool result]"))
        let bound = ConversationPrefixBoundary.$currentUserIndex
            .withValue(seed.currentUserIndex) {
                AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(conversation)
            }
        #expect(text(conversation[try #require(bound)]) == "turn 2 answer")
    }
}
