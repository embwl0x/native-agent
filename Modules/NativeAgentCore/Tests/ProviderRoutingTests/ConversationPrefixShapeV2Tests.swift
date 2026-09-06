import Foundation
import Testing
import NativeAgentCore
@testable import ProviderRouting

// Cross-turn cached transcript, foundation layer (2026-09-01).
//
// These tests pin the v2Prefix wire shape, the mid-conversation `.system`
// role on every adapter that encodes messages, the per-request clear_at beta,
// and the catalog capability rows. The v1Legacy arm's byte identity is pinned
// by the pre-existing tests in LLMCallTelemetryTests /
// AnthropicStreamMessagesSSETests, which now bind `.v1Legacy` explicitly, plus
// `v1Legacy_identityBlockUnchanged` below.
//
// Everything here drives PURE builders (no URL stubs, no shared static
// state), so the suite needs no serialization.

private let stableSeg = "PERSONA-STABLE persona packet\n\n# Pinned facts\n- pin"
private let suffixSeg = "# Session tool contract\n- tool_load is available"
private let dynamicSeg = "Recent memory:\n- hit"

private func tools() -> [LLMToolSchema] {
    let schema = try! JSONSerialization.data(withJSONObject: [
        "type": "object", "properties": ["q": ["type": "string"]],
    ])
    return [
        LLMToolSchema(name: "tool_a", description: "first", parametersJSON: schema),
        LLMToolSchema(name: "tool_b", description: "last", parametersJSON: schema),
    ]
}

private func systemBlocks(_ body: [String: Any]) -> [[String: Any]] {
    body["system"] as? [[String: Any]] ?? []
}

private func wireMessages(_ body: [String: Any]) -> [[String: Any]] {
    body["messages"] as? [[String: Any]] ?? []
}

private func cacheControl(_ block: [String: Any]) -> [String: Any]? {
    block["cache_control"] as? [String: Any]
}

private func breakpointTotal(_ body: [String: Any]) -> Int {
    systemBlocks(body).filter { $0["cache_control"] != nil }.count
        + (body["tools"] as? [[String: Any]] ?? []).filter { $0["cache_control"] != nil }.count
        + wireMessages(body)
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["cache_control"] != nil }.count
}

private func v2Body(
    messages: [LLMMessage],
    segments: SystemPromptSegments?,
    system: String?,
    withTools: Bool = false,
    model: String = "claude-opus-5"
) -> [String: Any] {
    ConversationPrefixShape.$override.withValue(.v2Prefix) {
        LLMCallContext.$systemSegments.withValue(segments) {
            AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                messages: messages,
                system: system,
                coercedModel: model,
                maxTokens: 1024,
                tools: withTools ? tools() : nil,
                stream: false
            )
        }
    }
}

// MARK: - SystemPromptSegments.stableSuffix

@Suite struct SystemPromptSegmentsSuffixTests {
    @Test func combined_joinsNonEmptySegmentsInOrder() {
        let all = SystemPromptSegments(
            stable: "A", stableSuffix: "B", dynamic: "C"
        )
        #expect(all.combined == "A\n\nB\n\nC")
        #expect(all.reassembles(into: "A\n\nB\n\nC"))
        #expect(!all.reassembles(into: "A\n\nC"))
    }

    @Test func combined_skipsEveryEmptyPartAndItsSeparator() {
        #expect(SystemPromptSegments(stable: "A", dynamic: "C").combined == "A\n\nC")
        #expect(SystemPromptSegments(stable: "A", stableSuffix: "B", dynamic: "").combined == "A\n\nB")
        #expect(SystemPromptSegments(stable: "", stableSuffix: "B", dynamic: "C").combined == "B\n\nC")
        #expect(SystemPromptSegments(stable: "A", stableSuffix: "", dynamic: "").combined == "A")
        #expect(SystemPromptSegments(stable: "", stableSuffix: "", dynamic: "").combined == "")
    }

    /// The two-arg init is the pre-existing call shape and must keep
    /// compiling AND keep producing the exact two-segment bytes.
    @Test func twoArgInit_isUnchanged() {
        let legacy = SystemPromptSegments(stable: "A", dynamic: "C")
        #expect(legacy.stableSuffix.isEmpty)
        #expect(legacy.combined == "A\n\nC")
    }
}

// MARK: - v2 system-block shape

@Suite struct ConversationPrefixShapeV2SystemBlockTests {
    @Test func v2_identityCarriesNoCacheControl_stableEndCarriesTheOnlyOne() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(messages: [.user("hi")], segments: seg, system: seg.combined)
        let system = systemBlocks(body)
        #expect(system.count == 3)
        #expect((system[0]["text"] as? String)?.contains("Claude Code") == true)
        #expect(system[0]["cache_control"] == nil)
        #expect(cacheControl(system[1])?["type"] as? String == "ephemeral")
        #expect(system[2]["cache_control"] == nil)
        #expect(system.filter { $0["cache_control"] != nil }.count == 1)
        // BYTE IDENTITY: the non-identity block texts concatenate to `sys`.
        #expect((system[1]["text"] as? String ?? "") + (system[2]["text"] as? String ?? "")
                == seg.combined)
    }

    /// v1 keeps its own breakpoint on the identity block — the rollback arm
    /// stays byte-identical.
    @Test func v1Legacy_identityBlockUnchanged() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = ConversationPrefixShape.$override.withValue(.v1Legacy) {
            LLMCallContext.$systemSegments.withValue(seg) {
                AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                    messages: [.user("hi")], system: seg.combined,
                    coercedModel: "claude-opus-5", maxTokens: 1024,
                    tools: nil, stream: false
                )
            }
        }
        let system = systemBlocks(body)
        #expect(system.count == 3)
        #expect(cacheControl(system[0])?["type"] as? String == "ephemeral")
        #expect(cacheControl(system[0])?["ttl"] == nil)
        #expect(cacheControl(system[1])?["type"] as? String == "ephemeral")
        #expect(system[2]["cache_control"] == nil)
    }

    @Test func v2_stableSuffixBlock_carriesTheBreakpoint_andBytesStillReassemble() {
        let seg = SystemPromptSegments(
            stable: stableSeg, stableSuffix: suffixSeg, dynamic: dynamicSeg
        )
        let body = v2Body(messages: [.user("hi")], segments: seg, system: seg.combined)
        let system = systemBlocks(body)
        #expect(system.count == 4)
        #expect(system[1]["text"] as? String == stableSeg + "\n\n")
        #expect(system[1]["cache_control"] == nil)      // NOT the last stable block
        #expect(system[2]["text"] as? String == suffixSeg + "\n\n")
        #expect(cacheControl(system[2])?["type"] as? String == "ephemeral")
        #expect(system[3]["text"] as? String == dynamicSeg)
        #expect(system[3]["cache_control"] == nil)
        #expect(system.filter { $0["cache_control"] != nil }.count == 1)
        let concat = system.dropFirst().compactMap { $0["text"] as? String }.joined()
        #expect(concat == seg.combined)
    }

    @Test func v2_emptyDynamic_emitsNoDynamicBlock() {
        let seg = SystemPromptSegments(stable: stableSeg, stableSuffix: suffixSeg, dynamic: "")
        let body = v2Body(messages: [.user("hi")], segments: seg, system: seg.combined)
        let system = systemBlocks(body)
        #expect(system.count == 3)   // identity + stable + stableSuffix
        #expect(system[1]["text"] as? String == stableSeg + "\n\n")
        #expect(system[2]["text"] as? String == suffixSeg)   // no trailing separator
        #expect(cacheControl(system[2])?["type"] as? String == "ephemeral")
        let concat = system.dropFirst().compactMap { $0["text"] as? String }.joined()
        #expect(concat == seg.combined)
    }

    /// Mismatched segments can never change model-visible content: the guard
    /// falls all the way back to the single combined block (v1 arm), identity
    /// breakpoint included.
    @Test func v2_mismatchedSegments_fallBackToCombinedBlock() {
        let seg = SystemPromptSegments(stable: "OTHER", dynamic: "SEGMENTS")
        let body = v2Body(messages: [.user("hi")], segments: seg, system: "the real system prompt")
        let system = systemBlocks(body)
        #expect(system.count == 2)
        #expect(cacheControl(system[0])?["type"] as? String == "ephemeral")
        #expect(system[1]["text"] as? String == "the real system prompt")
    }

    /// The grown-prompt compat lever disables v2 as well — one rollback
    /// switch restores the entire legacy wire layout.
    @Test func grownPromptCompatLever_forcesLegacyArmEvenOnV2() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = AnthropicOAuthDirectAdapter.GrownPromptCompat.$compatOverride.withValue(true) {
            v2Body(messages: [.user("hi")], segments: seg, system: seg.combined)
        }
        let system = systemBlocks(body)
        #expect(cacheControl(system[0])?["type"] as? String == "ephemeral")
        #expect(breakpointTotal(body) == 2)   // identity + stable-end, no message marker
    }
}

// MARK: - TTL placement (1h cross-turn vs 5m within-turn)

@Suite struct ConversationPrefixShapeV2TTLTests {
    /// The SEEDED v2 shape (live 400, 2026-09-01): the mid-conversation
    /// system message must immediately follow a user turn and end the array.
    ///   [0] user  [1] assistant  [2] user  [3] assistant(N-1)
    ///   [4] user(N) — the current turn's user message
    ///   [5] system(volatile) — LAST
    private func multiTurn() -> [LLMMessage] {
        [
            .user("first"),
            .assistantText("first answer"),
            .user("second"),
            .assistantText("second answer"),
            .user("third"),
            .system("volatile per-turn context", clearAtNextUserMessage: true),
        ]
    }

    /// Round 2 of a within-turn loop: the round's messages append AFTER the
    /// trailing system message.
    ///   [6] assistant(tool_use)  [7] user(tool_result) — newest
    private func multiTurnRoundTwo() -> [LLMMessage] {
        multiTurn() + [
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "toolu_1", name: "read_file", inputJSON: Data("{}".utf8)),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseId: "toolu_1", content: "body", isError: false),
            ]),
        ]
    }

    @Test func oneShot_getsPlain5mOnStableEnd_noSpeculative1hWrite() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        // 0 prior turns.
        let body = v2Body(messages: [.user("hi")], segments: seg, system: seg.combined)
        let stable = systemBlocks(body)[1]
        #expect(cacheControl(stable)?["type"] as? String == "ephemeral")
        #expect(cacheControl(stable)?["ttl"] == nil)
    }

    @Test func oneCompletedTurn_isStillTooEarlyFor1h() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(
            messages: [.user("a"), .assistantText("b"), .user("c")],
            segments: seg, system: seg.combined
        )
        #expect(cacheControl(systemBlocks(body)[1])?["ttl"] == nil)
    }

    @Test func twoOrMorePriorTurns_promoteStableEndTo1h() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(messages: multiTurn(), segments: seg, system: seg.combined)
        let stable = systemBlocks(body)[1]
        #expect(cacheControl(stable)?["type"] as? String == "ephemeral")
        #expect(cacheControl(stable)?["ttl"] as? String == "1h")
    }

    /// SEEDED ORDER: markers land on user(N) @5m and assistant(N-1) @1h; the
    /// trailing system message carries NONE.
    @Test func seededOrder_markersOnCurrentUserAndPreviousAssistant_neverOnSystem() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let messages = multiTurn()
        #expect(AnthropicOAuthDirectAdapter.currentTurnUserIndex(messages) == 4)
        #expect(AnthropicOAuthDirectAdapter.currentBoundaryIndex(messages) == 4)
        #expect(AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(messages) == 3)

        let body = v2Body(messages: messages, segments: seg, system: seg.combined)
        let wire = wireMessages(body)
        #expect(wire.count == 6)
        #expect(wire.last?["role"] as? String == "system")
        for (i, msg) in wire.enumerated() {
            let marker = (msg["content"] as? [[String: Any]])?.last.flatMap { cacheControl($0) }
            switch i {
            case 3:   // assistant(N-1) — the cross-turn read
                #expect(marker?["ttl"] as? String == "1h")
            case 4:   // user(N) — the current boundary, 5m (no ttl key)
                #expect(marker?["type"] as? String == "ephemeral")
                #expect(marker?["ttl"] == nil)
            default:
                #expect(marker == nil, "index \(i)")
            }
        }
        // stable-end + previous + current = 3; with tools, 4 — never 5.
        #expect(breakpointTotal(body) == 3)
        let withTools = v2Body(
            messages: messages, segments: seg, system: seg.combined, withTools: true
        )
        #expect(breakpointTotal(withTools) == 4)
    }

    /// A within-turn round appends PAST the trailing system message: the
    /// current marker follows the newest non-system message so the next round
    /// still reads the established prefix, while the 1h previous boundary
    /// stays anchored on assistant(N-1) — NOT on this turn's own assistant
    /// tool_use, which would be a speculative extended-TTL write.
    @Test func withinTurnRound_currentMarkerMovesToNewestNonSystemMessage() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let messages = multiTurnRoundTwo()
        // The round's appends have pushed past the trailing system run, so the
        // fallback anchor is gone — the seeding layer's bound index is what
        // keeps this exact.
        let body = ConversationPrefixBoundary.$currentUserIndex.withValue(4) {
            #expect(AnthropicOAuthDirectAdapter.currentTurnUserIndex(messages) == 4)
            #expect(AnthropicOAuthDirectAdapter.currentBoundaryIndex(messages) == 7)
            #expect(AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(messages) == 3)
            return v2Body(
                messages: messages, segments: seg, system: seg.combined, withTools: true
            )
        }
        let wire = wireMessages(body)
        #expect(wire.count == 8)
        #expect(wire[5]["role"] as? String == "system")
        for (i, msg) in wire.enumerated() {
            let marker = (msg["content"] as? [[String: Any]])?.last.flatMap { cacheControl($0) }
            switch i {
            case 3: #expect(marker?["ttl"] as? String == "1h")
            case 7: #expect(marker?["type"] as? String == "ephemeral")
            default: #expect(marker == nil, "index \(i)")
            }
        }
        // stable-end + previous + current + last tool = 4, still at budget.
        #expect(breakpointTotal(body) == 4)
    }

    /// The system message can NEVER carry cache_control, on any shape.
    @Test func systemMessagesNeverCarryCacheControl() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        for messages in [multiTurn(), multiTurnRoundTwo(), [LLMMessage.user("a"), .system("v")]] {
            for withTools in [false, true] {
                let body = v2Body(
                    messages: messages, segments: seg, system: seg.combined,
                    withTools: withTools
                )
                for msg in wireMessages(body) where msg["role"] as? String == "system" {
                    let blocks = msg["content"] as? [[String: Any]] ?? []
                    #expect(blocks.allSatisfy { $0["cache_control"] == nil })
                }
            }
        }
    }

    /// A request whose ONLY message is the system message has no markable
    /// boundary at all — neither marker ships, rather than one landing on it.
    @Test func systemOnlyRequest_shipsNoConversationMarker() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        #expect(AnthropicOAuthDirectAdapter.currentBoundaryIndex([.system("v")]) == nil)
        let body = v2Body(messages: [.system("v")], segments: seg, system: seg.combined)
        #expect(wireMessages(body).allSatisfy {
            (($0["content"] as? [[String: Any]])?.last?["cache_control"]) == nil
        })
    }

    @Test func noSystemMessage_meansNoPreviousBoundary() {
        let messages: [LLMMessage] = [.user("a"), .assistantText("b"), .user("c")]
        #expect(AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(messages) == nil)
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(messages: messages, segments: seg, system: seg.combined)
        let marked = wireMessages(body).enumerated().filter { _, msg in
            ((msg["content"] as? [[String: Any]])?.last?["cache_control"]) != nil
        }.map(\.offset)
        #expect(marked == [2])
    }

    @Test func priorTurnCount_countsAssistantMessagesOnly() {
        #expect(AnthropicOAuthDirectAdapter.priorTurnCount([]) == 0)
        #expect(AnthropicOAuthDirectAdapter.priorTurnCount([.user("a")]) == 0)
        #expect(AnthropicOAuthDirectAdapter.priorTurnCount([
            .user("a"), .assistantText("b"), .system("s"), .user("c"), .assistantText("d"),
        ]) == 2)
    }
}

// MARK: - Mid-conversation system role encoding

@Suite struct MidConversationSystemRoleTests {
    private let flagged = LLMMessage.system("volatile", clearAtNextUserMessage: true)
    private let plain = LLMMessage.system("volatile")

    @Test func flagIsValidOnlyOnSystemRole() {
        #expect(flagged.turnScopedClearAtNextUserMessage)
        #expect(!plain.turnScopedClearAtNextUserMessage)
        // Silently normalized to false on every other role — no encoder has
        // to re-check the invariant.
        let user = LLMMessage(
            role: .user, content: [.text("hi")], turnScopedClearAtNextUserMessage: true
        )
        #expect(!user.turnScopedClearAtNextUserMessage)
        let assistant = LLMMessage(
            role: .assistant, content: [.text("hi")], turnScopedClearAtNextUserMessage: true
        )
        #expect(!assistant.turnScopedClearAtNextUserMessage)
    }

    /// Fixture uses the LEGAL order: the system message immediately follows a
    /// user turn and ends the array.
    @Test func anthropicOAuth_encodesSystemRoleAndClearAt() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(
            messages: [.user("a"), .assistantText("b"), .user("c"), flagged],
            segments: seg, system: seg.combined
        )
        let wire = wireMessages(body)
        #expect(wire.map { $0["role"] as? String } == ["user", "assistant", "user", "system"])
        #expect(wire[3]["clear_at"] as? String == "next_user_message")
        #expect(wire[0]["clear_at"] == nil)
        #expect(wire[2]["clear_at"] == nil)
    }

    @Test func anthropicOAuth_unflaggedSystemMessageCarriesNoClearAt() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let body = v2Body(
            messages: [.user("a"), .assistantText("b"), .user("c"), plain],
            segments: seg, system: seg.combined
        )
        let wire = wireMessages(body)
        #expect(wire[3]["role"] as? String == "system")
        #expect(wire[3]["clear_at"] == nil)
    }

    /// The api-key native-tools lane encodes the same three-way role, so a
    /// projected transcript does not silently become assistant prose there.
    @Test func anthropicAPIKeyNativeLane_encodesSystemRoleAndClearAt() {
        let wire = AnthropicAdapter.nativeAnthropicMessages([
            .user("a"), .assistantText("b"), .user("c"), flagged,
        ])
        #expect(wire.map { $0["role"] as? String } == ["user", "assistant", "user", "system"])
        #expect(wire[3]["clear_at"] as? String == "next_user_message")
    }

    @Test func wireRole_isTotalOverEveryRole() {
        #expect(AnthropicOAuthDirectAdapter.wireRole(.user) == "user")
        #expect(AnthropicOAuthDirectAdapter.wireRole(.assistant) == "assistant")
        #expect(AnthropicOAuthDirectAdapter.wireRole(.system) == "system")
    }

    /// Responses input messages accept user/assistant/system/developer;
    /// `developer` is the instruction role, and every INPUT item's parts are
    /// `input_text` (output_text is assistant-only).
    @Test func openAIResponses_encodesDeveloperRoleWithInputTextParts() {
        let adapter = OpenAIOAuthDirectAdapter(
            authPathOverride: URL(fileURLWithPath: "/nonexistent/auth.json")
        )
        let body = adapter.buildResponsesBodyFromMessages(
            model: "gpt-5.6-sol",
            messages: [.user("a"), .assistantText("b"), LLMMessage.system("volatile")],
            system: "instructions",
            tools: nil
        )
        let items = body["input"] as? [[String: Any]] ?? []
        #expect(items.count == 3)
        #expect(items.map { $0["role"] as? String } == ["user", "assistant", "developer"])
        func partType(_ item: [String: Any]) -> String? {
            ((item["content"] as? [[String: Any]])?.first)?["type"] as? String
        }
        #expect(partType(items[0]) == "input_text")
        #expect(partType(items[1]) == "output_text")
        #expect(partType(items[2]) == "input_text")
        // The one-line fallback constant, so flipping it is a single edit.
        #expect(OpenAIOAuthDirectAdapter.midConversationSystemRole == "developer")
        #expect(OpenAIOAuthDirectAdapter.responsesTextType(.system) == "input_text")
    }

    @Test func defaultFlatten_prefixesSystemMessagesHonestly() async throws {
        // The non-structured fallback must not relabel a system message as
        // assistant prose.
        let client = FlattenCapturingClient()
        _ = try await client.completeMessages(
            messages: [.user("a"), .assistantText("b"), LLMMessage.system("c")],
            system: nil, model: nil, surface: "test", tools: nil
        )
        let captured = await client.lastPrompt
        #expect(captured == "USER: a\nASSISTANT: b\nSYSTEM: c")
    }
}

/// Minimal LLMClient that only implements the prompt overload, so the
/// protocol's DEFAULT `completeMessages` flatten is what runs.
private actor FlattenCapturingClient: LLMClient {
    var lastPrompt: String?

    nonisolated func complete(prompt: String, system: String?, model: String?) async throws -> String {
        await record(prompt)
        return "ok"
    }
    private func record(_ prompt: String) { lastPrompt = prompt }
}

// MARK: - Per-request beta header

@Suite struct MidConversationClearAtBetaHeaderTests {
    private func beta(_ headers: [String: String]) -> [String] {
        (headers["anthropic-beta"] ?? "").split(separator: ",").map(String.init)
    }

    @Test func betaRidesOnlyWhenAMessageCarriesTheFlag() {
        let flagged = LLMMessage.system("v", clearAtNextUserMessage: true)
        let without = AnthropicOAuthDirectAdapter.apiHeaders(
            accessToken: "t", model: "claude-fable-5-1",
            messages: [.user("a"), .assistantText("b"), LLMMessage.system("v")]
        )
        let with = AnthropicOAuthDirectAdapter.apiHeaders(
            accessToken: "t", model: "claude-fable-5-1",
            messages: [.user("a"), flagged, .user("b")]
        )
        let target = AnthropicOAuthDirectAdapter.midConversationSystemClearAtBeta
        #expect(!beta(without).contains(target))
        #expect(beta(with).contains(target))
        // The static list is otherwise untouched, and the flagged request
        // only APPENDS — every pre-existing beta keeps its position.
        #expect(beta(with).dropLast() == beta(without)[...])
    }

    @Test func noMessagesArgument_keepsTheLegacyHeaderSetExactly() {
        let legacy = AnthropicOAuthDirectAdapter.apiHeaders(accessToken: "t")
        #expect(beta(legacy) == [
            "claude-code-20250219",
            "oauth-2025-04-20",
            "fine-grained-tool-streaming-2025-05-14",
        ])
        #expect(legacy["anthropic-version"] == "2023-06-01")
    }
}

// MARK: - Catalog capability rows

@Suite struct MidConversationSystemCapabilityTests {
    @Test func capabilityRows() throws {
        for id in ["claude-fable-5-1", "claude-fable-5", "claude-opus-5", "claude-opus-4-8"] {
            let d = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: id))
            #expect(d.supportsMidConversationSystem, "\(id)")
        }
        // clear_at is Fable 5.1 only.
        for id in ["claude-fable-5", "claude-opus-5", "claude-opus-4-8"] {
            let d = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: id))
            #expect(!d.supportsMidConversationSystemClearAt, "\(id)")
        }
        let fable51 = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: "claude-fable-5-1"))
        #expect(fable51.supportsMidConversationSystemClearAt)

        // Older Claude rows and other providers stay false.
        for id in ["claude-opus-4-7", "claude-sonnet-5", "claude-haiku-4-5"] {
            let d = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: id))
            #expect(!d.supportsMidConversationSystem, "\(id)")
        }
    }

    @Test func freeFunctions_mirrorVerifiedContextLengthContract() {
        #expect(supportsMidConversationSystem(forModel: "claude-opus-5"))
        #expect(supportsMidConversationSystem(forModel: "  CLAUDE-OPUS-5  "))
        #expect(supportsMidConversationSystemClearAt(forModel: "claude-fable-5-1"))
        #expect(!supportsMidConversationSystemClearAt(forModel: "claude-opus-5"))
        // Unknown → false/false, never a guess.
        #expect(!supportsMidConversationSystem(forModel: "not-a-real-model"))
        #expect(!supportsMidConversationSystemClearAt(forModel: "not-a-real-model"))
        #expect(!supportsMidConversationSystem(forModel: "gpt-5.6-sol"))
    }

    @Test func clearAtIsAStrictRefinementOfTheBaseCapability() {
        let bogus = FirstPartyModelDescriptor(
            id: "x", name: "X", contextLength: 1,
            defaultReasoningEffort: "none", supportedReasoningEfforts: ["none"],
            supportsMidConversationSystem: false,
            supportsMidConversationSystemClearAt: true
        )
        #expect(!bogus.supportsMidConversationSystemClearAt)
    }

    @Test func providerJSONCarriesBothRows() throws {
        let json = try #require(FirstPartyModelCatalog.anthropicDescriptor(for: "claude-fable-5-1"))
            .providerJSON()
        #expect(json["supports_mid_conversation_system"] == .bool(true))
        #expect(json["supports_mid_conversation_system_clear_at"] == .bool(true))
    }
}

// MARK: - Kill switch

@Suite struct ConversationPrefixShapeResolutionTests {
    @Test func parse_acceptsBothSpellings_rejectsGarbage() {
        #expect(ConversationPrefixShape.parse("v1Legacy") == .v1Legacy)
        #expect(ConversationPrefixShape.parse("v1") == .v1Legacy)
        #expect(ConversationPrefixShape.parse(" V2Prefix ") == .v2Prefix)
        #expect(ConversationPrefixShape.parse("v2") == .v2Prefix)
        #expect(ConversationPrefixShape.parse("") == nil)
        #expect(ConversationPrefixShape.parse(nil) == nil)
        #expect(ConversationPrefixShape.parse("legacy") == nil)
        #expect(ConversationPrefixShape.defaultsKey == "chatConversationPrefixShape")
    }

    /// TURN-BOUNDARY RULE: adapters read the BOUND value only. Unbound —
    /// every non-chat caller (dream, REM, executions) and any turn the
    /// history builder seeded as v1 — must produce the v1 bytes exactly, even
    /// though `effective` would say v2Prefix.
    @Test func unboundOverride_producesByteIdenticalV1Request() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        func build() -> [String: Any] {
            LLMCallContext.$systemSegments.withValue(seg) {
                AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                    messages: [.user("a"), .assistantText("b"), .user("c")],
                    system: seg.combined, coercedModel: "claude-opus-5",
                    maxTokens: 1024, tools: nil, stream: false
                )
            }
        }
        #expect(ConversationPrefixShape.override == nil)
        let unbound = build()
        let boundV1 = ConversationPrefixShape.$override.withValue(.v1Legacy) { build() }
        #expect(NSDictionary(dictionary: unbound) == NSDictionary(dictionary: boundV1))
        // And it IS the v1 shape, not merely self-consistent: identity keeps
        // its own breakpoint and no conversation breakpoint is added.
        let system = systemBlocks(unbound)
        #expect(cacheControl(system[0])?["type"] as? String == "ephemeral")
        #expect(breakpointTotal(unbound) == 2)
        #expect(wireMessages(unbound).allSatisfy {
            (($0["content"] as? [[String: Any]])?.last?["cache_control"]) == nil
        })
    }

    @Test func adaptersIgnoreTheUserDefaultAndReadOnlyTheBinding() {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        // `effective` may well say v2Prefix here (production default), but an
        // unbound adapter call must NOT act on it.
        #expect(ConversationPrefixShape.override == nil)
        #expect(!AnthropicOAuthDirectAdapter.usesV2PrefixShape(seg.combined, segments: seg))
        ConversationPrefixShape.$override.withValue(.v2Prefix) {
            #expect(AnthropicOAuthDirectAdapter.usesV2PrefixShape(seg.combined, segments: seg))
        }
        ConversationPrefixShape.$override.withValue(.v1Legacy) {
            #expect(!AnthropicOAuthDirectAdapter.usesV2PrefixShape(seg.combined, segments: seg))
        }
    }

    @Test func override_winsOverEverything_andProductionDefaultsToV2() {
        ConversationPrefixShape.$override.withValue(.v1Legacy) {
            #expect(ConversationPrefixShape.effective == .v1Legacy)
        }
        ConversationPrefixShape.$override.withValue(.v2Prefix) {
            #expect(ConversationPrefixShape.effective == .v2Prefix)
        }
        // Unbound + no user default written by this test process → v2Prefix.
        if UserDefaults.standard.string(forKey: ConversationPrefixShape.defaultsKey) == nil {
            #expect(ConversationPrefixShape.effective == .v2Prefix)
        }
    }
}

// MARK: - API-key lanes: stableSuffix + clear_at beta header

/// Own URLProtocol stub (the shared ones capture only bodies, and their
/// statics race across suites) — this one captures HEADERS.
private final class ClearAtHeaderStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastHeaders: [String: String]?
    nonisolated(unsafe) static var responseBody = Data()
    static func reset() { lastHeaders = nil; responseBody = Data() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        ClearAtHeaderStubURLProtocol.lastHeaders = request.allHTTPHeaderFields
        let http = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ClearAtHeaderStubURLProtocol.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func clearAtHeaderStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [ClearAtHeaderStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

@Suite(.serialized) struct AnthropicAPIKeyMidConversationSystemTests {
    private static let okBody = Data(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#.utf8)

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-at-beta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func adapter(root: URL) -> AnthropicAdapter {
        AnthropicAdapter(
            session: clearAtHeaderStubSession(),
            apiKeyOverride: "sk-ant-test",
            dataRootOverride: root,
            telemetryDataRootOverride: root
        )
    }

    private func schema() -> LLMToolSchema {
        LLMToolSchema(
            name: "git_status", description: "status",
            parametersJSON: try! JSONSerialization.data(withJSONObject: [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false,
            ] as [String: Any])
        )
    }

    private func beta() -> String? {
        ClearAtHeaderStubURLProtocol.lastHeaders?["anthropic-beta"]
    }

    /// The api-key MESSAGES lane emits clear_at in the body (structured
    /// branch), so it must send the beta — and must NOT send it otherwise.
    @Test func messagesLane_betaHeaderPresentIffClearAt() async throws {
        let root = try tempRoot()
        let image = LLMContentBlock.image(
            mediaType: "image/png", base64: "QUJDRA==", name: "x.png", byteSize: 4
        )
        func send(_ system: LLMMessage) async throws {
            ClearAtHeaderStubURLProtocol.reset()
            ClearAtHeaderStubURLProtocol.responseBody = Self.okBody
            _ = try await adapter(root: root).completeMessages(
                messages: [.userWithImages("look", images: [image]), system],
                system: "sys", model: "claude-fable-5-1", tools: nil
            )
        }
        try await send(LLMMessage.system("v"))
        #expect(beta() == nil)
        try await send(LLMMessage.system("v", clearAtNextUserMessage: true))
        #expect(beta() == AnthropicOAuthDirectAdapter.midConversationSystemClearAtBeta)
    }

    @Test func nativeToolsLane_betaHeaderPresentIffClearAt() async throws {
        let root = try tempRoot()
        func send(_ system: LLMMessage) async throws {
            ClearAtHeaderStubURLProtocol.reset()
            ClearAtHeaderStubURLProtocol.responseBody = Self.okBody
            _ = try await adapter(root: root).completeMessagesWithTools(
                messages: [.user("status?"), system],
                system: "sys", model: "claude-fable-5-1", tools: [schema()]
            )
        }
        try await send(LLMMessage.system("v"))
        #expect(beta() == nil)
        try await send(LLMMessage.system("v", clearAtNextUserMessage: true))
        #expect(beta() == AnthropicOAuthDirectAdapter.midConversationSystemClearAtBeta)
    }

    /// HIGH: the api-key split branch used to emit only [stable][dynamic],
    /// silently dropping stableSuffix from the model's view — the segments
    /// guard checks the SEGMENTS against `sys`, not the emitted blocks.
    @Test func makeSystemBlocks_emitsStableSuffixInsideTheCachedPrefix() throws {
        let seg = SystemPromptSegments(
            stable: stableSeg, stableSuffix: suffixSeg, dynamic: dynamicSeg
        )
        let blocks = try #require(AnthropicAdapter.makeSystemBlocks(
            seg.combined, segments: seg, cacheEligible: true
        ))
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"] as? String == stableSeg + "\n\n")
        #expect(blocks[0]["cache_control"] == nil)          // not the last stable block
        #expect(blocks[1]["text"] as? String == suffixSeg + "\n\n")
        #expect(cacheControl(blocks[1])?["type"] as? String == "ephemeral")
        #expect(blocks[2]["text"] as? String == dynamicSeg)
        #expect(blocks[2]["cache_control"] == nil)
        // BYTE FAITHFULNESS: nothing dropped, nothing invented.
        #expect(blocks.compactMap { $0["text"] as? String }.joined() == seg.combined)
        #expect(blocks.filter { $0["cache_control"] != nil }.count == 1)
    }

    @Test func makeSystemBlocks_emptySuffix_isByteIdenticalToTheTwoBlockShape() throws {
        let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)
        let blocks = try #require(AnthropicAdapter.makeSystemBlocks(
            seg.combined, segments: seg, cacheEligible: true
        ))
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"] as? String == stableSeg + "\n\n")
        #expect(cacheControl(blocks[0])?["type"] as? String == "ephemeral")
        #expect(blocks[1]["text"] as? String == dynamicSeg)
        #expect(blocks[1]["cache_control"] == nil)
    }
}

// MARK: - Boundary anchoring audit (live cache-read regression, 2026-09-02)

/// The live signature was: turns inside 5 minutes read the full prefix, turns
/// after an 8-minute gap read only tools+system. That is the cross-turn
/// marker failing to survive the gap — either never placed, or placed where
/// it cached almost nothing. These pin the two causes found.
@Suite struct ConversationPrefixBoundaryAuditTests {
    private let seg = SystemPromptSegments(stable: stableSeg, dynamic: dynamicSeg)

    /// Replayed history carries ARCHIVED system blocks, each sitting after its
    /// own user message. When the turn's volatile block is NOT delivered as a
    /// system message — it was empty, or the model lacks mid-conversation
    /// system support — the array does not end in a system run, and the old
    /// `lastIndex(.system)` anchor selected an ARCHIVED block instead. That
    /// put the current-turn anchor several turns back and the 1h marker near
    /// the START of the conversation, which is exactly a gap read of
    /// tools+system and nothing else.
    private func replayedHistoryWithoutTrailingSystem() -> [LLMMessage] {
        [
            .user("first"),              // 0
            .system("archived turn 1"),  // 1  <- what lastIndex(.system) used to find
            .assistantText("reply 1"),   // 2
            .user("second"),             // 3
            .system("archived turn 2"),  // 4  <- ...or this one
            .assistantText("reply 2"),   // 5  <- the TRUE previous boundary
            .user("third"),              // 6  <- the TRUE current user message
        ]
    }

    @Test func archivedSystemBlocksNoLongerHijackTheCurrentTurnAnchor() {
        let messages = replayedHistoryWithoutTrailingSystem()
        // The old anchor would have answered 3 (the user before the archived
        // block at 4) and then marked assistant index 2 — two turns too early.
        #expect(AnthropicOAuthDirectAdapter.currentTurnUserIndex(messages) == nil)
        #expect(AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(messages) == nil)

        // Fail closed: the current 5m marker still ships, but NO 1h marker is
        // placed anywhere. A cross-turn marker in the wrong place costs a 2x
        // write and caches nearly nothing; none at all costs only the gap.
        let body = v2Body(messages: messages, segments: seg, system: seg.combined)
        let marked = wireMessages(body).enumerated().compactMap { i, msg -> Int? in
            (msg["content"] as? [[String: Any]])?.last?["cache_control"] == nil ? nil : i
        }
        #expect(marked == [6])
        // 2026-09-06 (cb1cb132): "one long-TTL decision per request feeds
        // tools, stable-end and the previous-turn boundary in render order",
        // so the STABLE SYSTEM block legitimately carries the 1h breakpoint —
        // it is the session-stable prefix, and withholding it there would cost
        // the cache the adapter is built around. What must not appear is a 1h
        // marker in the MESSAGES, which is the cross-turn boundary this test
        // refuses to guess at.
        let messageMarkers = AnthropicOAuthDirectAdapter.cacheMarkers(in: body)
            .filter { $0.position.hasPrefix("messages[") }
        #expect(!messageMarkers.isEmpty)
        #expect(messageMarkers.allSatisfy { $0.ttl == "5m" })
    }

    /// The seeding layer knows the answer exactly; binding it restores the
    /// cross-turn marker on precisely the shape the fallback refuses to guess.
    @Test func boundSeamRestoresTheCrossTurnMarker() {
        let messages = replayedHistoryWithoutTrailingSystem()
        ConversationPrefixBoundary.$currentUserIndex.withValue(6) {
            #expect(AnthropicOAuthDirectAdapter.currentTurnUserIndex(messages) == 6)
            #expect(AnthropicOAuthDirectAdapter.previousTurnBoundaryIndex(messages) == 5)
            let body = v2Body(messages: messages, segments: seg, system: seg.combined)
            let markers = AnthropicOAuthDirectAdapter.cacheMarkers(in: body)
            #expect(markers.contains { $0.position == "messages[5]" && $0.ttl == "1h" })
            #expect(markers.contains { $0.position == "messages[6]" && $0.ttl == "5m" })
        }
    }

    /// A stale or out-of-range binding must degrade to the fallback, never
    /// mis-mark: the index is validated before it is trusted.
    @Test func invalidSeamBindingFallsBackInsteadOfMisMarking() {
        let messages = replayedHistoryWithoutTrailingSystem()
        for bogus in [-1, 99, 5 /* an assistant, not a user */, 4 /* a system */] {
            ConversationPrefixBoundary.$currentUserIndex.withValue(bogus) {
                #expect(AnthropicOAuthDirectAdapter.currentTurnUserIndex(messages) == nil)
            }
        }
    }

    /// ORDERING RULE: Anthropic renders tools → system → messages and requires
    /// longer-TTL entries to appear BEFORE shorter ones. The tools breakpoint
    /// is always first, so it can never be the 5m one while a 1h marker sits
    /// behind it — which is what a per-section TTL decision would have done.
    @Test func longTTLRequest_neverPutsA5mMarkerAheadOfA1hMarker() {
        let messages: [LLMMessage] = [
            .user("a"), .assistantText("b"), .user("c"), .assistantText("d"),
            .user("e"), .system("volatile", clearAtNextUserMessage: true),
        ]
        for withTools in [false, true] {
            let body = v2Body(
                messages: messages, segments: seg, system: seg.combined,
                withTools: withTools
            )
            let markers = AnthropicOAuthDirectAdapter.cacheMarkers(in: body)
            // 2+ prior turns → the request is on the long TTL.
            #expect(markers.first?.ttl == "1h")
            if withTools {
                #expect(markers.first?.position == "tools[1]")
            }
            // Once a 5m marker appears, no 1h marker may follow it.
            var seenShort = false
            for marker in markers {
                if marker.ttl == "5m" { seenShort = true }
                #expect(!(seenShort && marker.ttl == "1h"), "\(markers)")
            }
            // Only the CURRENT boundary is 5m, and it is last.
            #expect(markers.last?.ttl == "5m")
            #expect(markers.dropLast().allSatisfy { $0.ttl == "1h" })
        }
    }

    /// A short conversation stays entirely on 5m — no section may
    /// speculatively opt into the 2x extended-TTL write on its own.
    @Test func shortConversation_everyMarkerStays5m() {
        for messages in [
            [LLMMessage.user("a"), .system("v")],
            [LLMMessage.user("a"), .assistantText("b"), .user("c"), .system("v")],
        ] {
            let body = v2Body(
                messages: messages, segments: seg, system: seg.combined, withTools: true
            )
            let markers = AnthropicOAuthDirectAdapter.cacheMarkers(in: body)
            #expect(!markers.isEmpty)
            #expect(markers.allSatisfy { $0.ttl == "5m" }, "\(messages.count)")
        }
    }

    /// priorTurnCount must credit REPLAYED assistants — a resumed session
    /// carries its turns in the projection, and restarting the count from
    /// zero would hold every long session on 5m forever.
    @Test func priorTurnCountCreditsReplayedAssistants() {
        let replayed = replayedHistoryWithoutTrailingSystem()
        #expect(AnthropicOAuthDirectAdapter.priorTurnCount(replayed) == 2)
        // Archived system blocks are not turns.
        #expect(AnthropicOAuthDirectAdapter.priorTurnCount([
            .user("a"), .system("s1"), .system("s2"), .user("b"),
        ]) == 0)
        #expect(AnthropicOAuthDirectAdapter.requestLongTTL(
            usesPrefixShape: true, messages: replayed
        ) == "1h")
        #expect(AnthropicOAuthDirectAdapter.requestLongTTL(
            usesPrefixShape: false, messages: replayed
        ) == nil)
        #expect(AnthropicOAuthDirectAdapter.requestLongTTL(
            usesPrefixShape: true, messages: [.user("a"), .assistantText("b"), .user("c")]
        ) == nil)
    }

    /// The receipt is derived from the FINISHED BODY, in render order, so it
    /// proves what shipped rather than what the placement code intended.
    @Test func cacheMarkersReadTheBodyInRenderOrder() {
        let body: [String: Any] = [
            "tools": [
                ["name": "a"],
                ["name": "b", "cache_control": ["type": "ephemeral", "ttl": "1h"]],
            ],
            "system": [
                ["type": "text", "text": "identity"],
                ["type": "text", "text": "stable",
                 "cache_control": ["type": "ephemeral", "ttl": "1h"]],
            ],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "hi"]]],
                ["role": "assistant", "content": [
                    ["type": "text", "text": "yo",
                     "cache_control": ["type": "ephemeral"]],
                ]],
            ],
        ]
        let markers = AnthropicOAuthDirectAdapter.cacheMarkers(in: body)
        #expect(markers.map(\.position) == ["tools[1]", "system[1]", "messages[1]"])
        // The absent `ttl` key IS the 5m default, spelled out for readability.
        #expect(markers.map(\.ttl) == ["1h", "1h", "5m"])
        #expect(AnthropicOAuthDirectAdapter.cacheMarkers(in: [:]).isEmpty)
    }
}
