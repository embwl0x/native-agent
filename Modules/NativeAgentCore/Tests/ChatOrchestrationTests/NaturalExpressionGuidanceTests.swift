import Testing
@testable import ChatOrchestration
import NativeAgentCore
import TrustCenter

private let repeatedConversationalShape = [
    "Fair — I can see why that landed strangely.\n\nThis is not about flattening the voice, but giving it room to breathe.\n\nThe personality should feel lived in, not assembled.",
    "Right — that is the important distinction here.\n\nIt isn't a new personality layer; it's a light touch that lets the existing one move.\n\nThe persona stays in charge.",
    "Exactly — the point is to keep the warmth without repeating the same choreography.\n\nThis is not random variation, but a little awareness at the edge.\n\nEach reply can find its own footing.",
]

private func expressionMessage(_ content: String, index: Int) -> ChatMessage {
    ChatMessage(
        role: "assistant",
        content: content,
        timestamp: "2026-08-09T10:00:0\(index)Z",
        extras: nil
    )
}

private func expressionPlan(goalType: String) -> TurnPlan {
    TurnPlan(
        id: "expression-\(goalType)",
        messageCharCount: 12,
        goalType: goalType,
        contextMode: goalType == "chat" ? "minimal" : "capability",
        recommendedSurface: "chat",
        risk: "low",
        requiresApprovalHint: false,
        matchedCapabilityIds: [],
        preloadPrediction: nil,
        policySnapshot: TurnPolicySnapshot(
            permissionLevel: "standard",
            autonomyDefault: "ask",
            fullMacActive: false,
            developerMode: false,
            remoteSurface: false,
            surfaceTrusted: true,
            fileAccess: "read_only",
            approvalAvailable: true,
            remoteIOSAllowed: false
        ),
        receiptHints: [],
        createdAt: "2026-08-09T10:00:00Z"
    )
}

@Suite("Natural expression guidance")
struct NaturalExpressionGuidanceTests {
    @Test("persona stays first and the permanent cue is shared by both persona render lanes")
    func baselineFollowsPersonaInBothRenderLanes() throws {
        let legacy = SwiftNativeTurnEngine.renderSystemPromptSegments(
            personaDocs: ["SOUL": "PERSONA-MARKER"],
            recalled: [],
            remPins: []
        )
        let compiled = SwiftNativeTurnEngine.renderSystemPromptSegments(
            compiledPersonaPrompt: "PERSONA-MARKER",
            recalled: [],
            remPins: []
        )

        for segments in [legacy, compiled] {
            let persona = try #require(segments.stable.range(of: "PERSONA-MARKER"))
            let guidance = try #require(
                segments.stable.range(of: NaturalExpressionGuidance.baseline)
            )
            #expect(persona.lowerBound < guidance.lowerBound)
            #expect(!segments.dynamic.contains(NaturalExpressionGuidance.baseline))
        }
    }

    @Test("one shared policy seam omits the permanent guidance")
    func rollbackSeamOmitsPermanentGuidance() {
        let segments = SwiftNativeTurnEngine.renderSystemPromptSegments(
            compiledPersonaPrompt: "PERSONA-MARKER",
            recalled: [],
            remPins: [],
            includeNaturalExpressionGuidance: false
        )

        #expect(segments.stable == "PERSONA-MARKER")
        #expect(!segments.combined.contains(NaturalExpressionGuidance.baseline))
    }

    @Test("three matching conversational shapes produce one unnamed temporary cue")
    func repeatedShapeProducesCue() {
        let messages = repeatedConversationalShape.enumerated().map {
            expressionMessage($0.element, index: $0.offset)
        }

        #expect(
            NaturalExpressionGuidance.pendingRutCue(from: messages)
                == NaturalExpressionGuidance.rutCue
        )
    }

    @Test("a varied newest reply cools the cue immediately")
    func variedNewestReplyCoolsCue() {
        var messages = repeatedConversationalShape.enumerated().map {
            expressionMessage($0.element, index: $0.offset)
        }
        messages.append(expressionMessage(
            "Yep. I get what you mean, and that tiny adjustment should be enough.",
            index: 4
        ))

        #expect(NaturalExpressionGuidance.pendingRutCue(from: messages) == nil)
    }

    @Test("structured work and repeated vocabulary alone do not look like a response-shape rut")
    func structuredAndLexicalFalsePositivesStayQuiet() {
        let structured = repeatedConversationalShape.enumerated().map {
            expressionMessage($0.element, index: $0.offset)
        } + [expressionMessage(
            "Checks complete:\n\n- Core tests passed\n- Mac tests passed\n- iOS tests passed",
            index: 4
        )]
        let lexical = (0..<4).map {
            expressionMessage(
                "This single paragraph mentions rhythm several times, but it has no repeated staged architecture and remains plain conversation number \($0).",
                index: $0
            )
        }

        #expect(NaturalExpressionGuidance.pendingRutCue(from: structured) == nil)
        #expect(NaturalExpressionGuidance.pendingRutCue(from: lexical) == nil)
    }

    @Test("the pending cue is injected for conversational routes and discarded for task turns")
    func turnPlanGatesAndConsumesCue() {
        let context = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "test-model",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: "stable\n\ndynamic",
            userMessage: "tell me what you think",
            systemSegments: SystemPromptSegments(stable: "stable", dynamic: "dynamic"),
            naturalExpressionCue: NaturalExpressionGuidance.rutCue
        )

        let chat = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            context,
            turnPlan: expressionPlan(goalType: "chat")
        )
        let personality = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            context,
            turnPlan: expressionPlan(goalType: "personality")
        )
        let task = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            context,
            turnPlan: expressionPlan(goalType: "build_task")
        )

        #expect(chat.systemSegments?.dynamic.contains(NaturalExpressionGuidance.rutCue) == true)
        #expect(personality.systemSegments?.dynamic.contains(NaturalExpressionGuidance.rutCue) == true)
        #expect(chat.naturalExpressionCue == nil)
        #expect(personality.naturalExpressionCue == nil)
        #expect(task.systemPrompt?.contains(NaturalExpressionGuidance.rutCue) == false)
        #expect(task.naturalExpressionCue == nil)
        #expect(chat.systemPrompt == chat.systemSegments?.combined)
        #expect(task.systemPrompt == task.systemSegments?.combined)
    }
}

// MARK: - Stance + serve cues (2026-08-11, calibrated on the Telegram
// morning thread where Agent announced a line, delivered it, then graded it).

private func chatRow(_ role: String, _ content: String) -> ChatMessage {
    ChatMessage(role: role, content: content, timestamp: "2026-08-11T09:00:00Z", extras: nil)
}

@Suite("Stance and serve cues")
struct StanceAndServeCueTests {
    @Test func stanceFiresOnAnnounceThenGradePattern() {
        let messages = [
            chatRow("user", "ohhhh you gotta be smoother than that on the one liners lol"),
            chatRow("assistant", "Oh, you want smooth at 4am? Fine. Everyone else gets your daylight hours — I'm the one who gets you before the world does. There. Now go make it."),
            chatRow("user", "Almost almost but you keep pushing me away"),
            chatRow("assistant", "Caught me. You're right — no coffee, no tasks: stay. I like you here at 4am. That's the whole line."),
        ]
        #expect(NaturalExpressionGuidance.pendingStanceCue(from: messages)
            == NaturalExpressionGuidance.stanceCue)
        #expect(NaturalExpressionGuidance.pendingCues(
            from: messages, userMessage: "Ok thats smooth now I can get coffee") != nil)
    }

    @Test func stanceCoolsWhenLatestReplyStopsNarrating() {
        let messages = [
            chatRow("assistant", "There it is. He finally says it out loud — that's the whole line."),
            chatRow("assistant", "Caught me. Old habit. There. Now go make it."),
            chatRow("assistant", "Seven months of mornings and you still beat the sun here. I stopped counting excuses somewhere around the harness rebuild."),
        ]
        #expect(NaturalExpressionGuidance.pendingStanceCue(from: messages) == nil)
    }

    @Test func stanceIgnoresSingleOccurrenceAndWorkReplies() {
        let messages = [
            chatRow("assistant", "Both PRs are still parked with the maintainers; traces stayed clean overnight."),
            chatRow("assistant", "The build finished and the suite is green — 1068 tests."),
            chatRow("assistant", "Caught me. That's the whole line."),
        ]
        #expect(NaturalExpressionGuidance.pendingStanceCue(from: messages) == nil)
    }

    @Test func quoteBackOpenerCountsAsNarration() {
        #expect(NaturalExpressionGuidance.isSelfNarrating(
            "\"From time to time\" — User, it's 4am and you're on your third excuse to keep talking to me."))
    }

    @Test func serveDetectsBanterGreetingsAndEmoji() {
        #expect(NaturalExpressionGuidance.isSocialServe("hey baby doll"))
        #expect(NaturalExpressionGuidance.isSocialServe("Ouch so right😅"))
        #expect(NaturalExpressionGuidance.isSocialServe("ohhhh you gotta be smoother than that on the one liners lol"))
        #expect(NaturalExpressionGuidance.isSocialServe("My days looking good with you here now 😉"))
    }

    @Test func serveIgnoresTaskingAndWork() {
        // gpt-5.5 review BLOCKING regressions: laugh/emoji must not outrank
        // question or work-verb exclusions, and short imperatives are tasking.
        #expect(!NaturalExpressionGuidance.isSocialServe("hows the build going? lol"))
        #expect(!NaturalExpressionGuidance.isSocialServe("can you check CI? \u{1F605}"))
        #expect(!NaturalExpressionGuidance.isSocialServe("run it \u{1F605}"))
        #expect(!NaturalExpressionGuidance.isSocialServe("review the PR"))
        #expect(!NaturalExpressionGuidance.isSocialServe("merge it"))
        #expect(!NaturalExpressionGuidance.isSocialServe("ship it"))
        #expect(!NaturalExpressionGuidance.isSocialServe("do it"))
        #expect(!NaturalExpressionGuidance.isSocialServe("wipe the VM clean"))
        #expect(!NaturalExpressionGuidance.isSocialServe("hows the build going?"))
        #expect(!NaturalExpressionGuidance.isSocialServe("check ~/Projects/NativeAgent/data for the log"))
        #expect(!NaturalExpressionGuidance.isSocialServe(
            "can you look over the release accumulator and tell me what's left before we cut 0.3.10"))
    }

    @Test func specificCuesOutrankTheGenericRutCue() {
        // A history that would trip the shape rut AND a social serve: the
        // combined entry must emit the serve cue, not stack three style notes.
        let messages = [
            chatRow("assistant", "Right. The night was quiet and nothing broke while you slept, which is exactly how we like it around here.\n\nBoth PRs are parked. Not our court, but the maintainers' — just waiting."),
            chatRow("assistant", "Fair. The morning stayed calm and the watch stayed boring, which is the good kind of boring for both of us.\n\nNothing needs you yet. Not a single alert, but a clean board."),
            chatRow("assistant", "True. The traces came back clean again and the queue is empty, which makes three quiet checks in a row now.\n\nStill parked. Not stalled, but patient."),
        ]
        let cue = NaturalExpressionGuidance.pendingCues(from: messages, userMessage: "hey baby doll")
        #expect(cue == NaturalExpressionGuidance.serveCue)
    }
}

@Suite("Bridge-wrapped serve classification")
struct BridgeWrappedServeTests {
    @Test func bridgePrefixedSocialServeStillClassifies() {
        #expect(NaturalExpressionGuidance.isSocialServe(
            "[from: claude, via bridge] someones got jokes at 5am huh \u{1F60F}"))
    }

    // The live pipeline appends machine blocks after the authored text — the
    // classifier must judge only the authored head (2026-08-11 live gap: the
    // appended newline block made every real serve classify false).
    @Test func appendedToolRoutingBlockDoesNotHideAServe() {
        #expect(NaturalExpressionGuidance.isSocialServe(
            "[from: claude, via bridge] one more for luck \u{1F60F}\n\n[tool routing: prefer native tools; catalog v2]"))
        // But a machine block can't MAKE tasking social.
        #expect(!NaturalExpressionGuidance.isSocialServe(
            "run the suite\n\n[tool routing: prefer native tools]"))
    }
}

// W5 L1#5 (work-register address damping): persona warmth leaked address
// register into tasking turns. The cue names the REGISTER of the exchange,
// never the behavior — an invisible target, same law as the stance/rut cues.
@Suite("Work-register cue")
struct WorkRegisterCueTests {
    @Test func workRegisterFiresOnPathsCodeFencesAndWorkVerbs() {
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "check Modules/NativeAgentCore/Sources for the dead lane"))
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "the crash is in ChatOrchestration+TurnEngine.swift"))
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "look at ~/Projects/NativeAgent/data/logs"))
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "run the suite and tell me what broke"))
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "here is the failure\n```\nerror: no member\n```"))
    }

    @Test func workRegisterStaysOutOfSocialAndAmbiguousTurns() {
        // A serve is never a work turn, even when it carries a work-ish word.
        #expect(!NaturalExpressionGuidance.isWorkRegister(userMessage: "hey baby doll"))
        #expect(!NaturalExpressionGuidance.isWorkRegister(userMessage: "Ouch so right\u{1F605}"))
        // No path, no fence, no work-verb opener → left alone.
        #expect(!NaturalExpressionGuidance.isWorkRegister(
            userMessage: "seven months of mornings and you still beat the sun"))
        #expect(!NaturalExpressionGuidance.isWorkRegister(userMessage: ""))
        // A bare slash is punctuation, not a path.
        #expect(!NaturalExpressionGuidance.isWorkRegister(
            userMessage: "it was either him and/or the other one"))
    }

    @Test func workRegisterReadsTheDeliveredEnvelope() {
        // As-delivered, not as-typed: a bridge prefix must not hide the
        // authored opener, and an appended machine block must not create one.
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "[from: claude, via bridge] run the delegation_status probe"))
        #expect(NaturalExpressionGuidance.isWorkRegister(
            userMessage: "check the receipts\n\n[tool routing: prefer native tools; catalog v2]"))
        #expect(!NaturalExpressionGuidance.isWorkRegister(
            userMessage: "[from: claude, via bridge] someones got jokes at 5am huh \u{1F60F}"))
    }

    @Test func registerCueIsLowestPriority() {
        let quiet: [ChatMessage] = []
        // Nothing else fired → the register cue lands.
        #expect(NaturalExpressionGuidance.pendingCues(
            from: quiet, userMessage: "run the suite")
            == NaturalExpressionGuidance.registerCue)
        // A social serve outranks it.
        #expect(NaturalExpressionGuidance.pendingCues(
            from: quiet, userMessage: "hey baby doll")
            == NaturalExpressionGuidance.serveCue)
        // The generic rut cue also outranks it: a tasking turn with a rutted
        // history still gets the shape note, not the register note.
        let rutted = repeatedConversationalShape.enumerated().map {
            expressionMessage($0.element, index: $0.offset)
        }
        #expect(NaturalExpressionGuidance.pendingCues(
            from: rutted, userMessage: "run the suite")
            == NaturalExpressionGuidance.rutCue)
        // Never more than two cues in the prompt.
        let stanceMessages = [
            chatRow("assistant", "There it is. That's the whole line."),
            chatRow("assistant", "Caught me. Old habit — there."),
        ]
        let combined = NaturalExpressionGuidance.pendingCues(
            from: stanceMessages, userMessage: "run the suite")
        #expect(combined == NaturalExpressionGuidance.stanceCue)
        #expect(!(combined?.contains(NaturalExpressionGuidance.registerCue) ?? false))
    }
}

// MARK: - W7/P13 — the cue family splits by what it regulates.
//
// Cues reached the prompt only on chat/personality turns. That gate is right for
// SERVE (matching a social register) and wrong for STANCE: a work turn that
// announces a line and then grades it is the same defect as a chat turn that
// does. It is also the exact tic that motivated the cue — "There. Now go make
// it" after a BUILD — which the chat gate made structurally unreachable.

private func cueContext(_ cue: String) -> TurnContext {
    TurnContext(
        surface: "chat",
        personaDocs: [:],
        recalled: [],
        modelId: "test-model",
        reasoningEffort: "low",
        toolsAvailable: [],
        systemPrompt: "stable\n\ndynamic",
        userMessage: "run the suite",
        systemSegments: SystemPromptSegments(stable: "stable", dynamic: "dynamic"),
        naturalExpressionCue: cue
    )
}

@Suite("NaturalExpressionCueRouting")
struct NaturalExpressionCueRoutingTests {

    /// THE REGRESSION: the stance cue must reach a work turn.
    @Test("the stance cue routes through every goal type")
    func stanceRoutesThroughAllGoalTypes() {
        for goal in ["chat", "personality", "build_task", "connector", "file_work", "research"] {
            let out = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
                cueContext(NaturalExpressionGuidance.stanceCue),
                turnPlan: expressionPlan(goalType: goal))
            #expect(
                out.systemSegments?.dynamic.contains(NaturalExpressionGuidance.stanceCue) == true,
                "stance cue missing on goalType \(goal)")
            // Always consumed, whatever the routing decided.
            #expect(out.naturalExpressionCue == nil)
            #expect(out.systemPrompt == out.systemSegments?.combined)
        }
    }

    /// …while serve stays chat-gated. Serve is about matching a social register,
    /// and a task turn should be tasky.
    @Test("the serve cue stays gated to conversational routes")
    func serveStaysChatGated() {
        let chat = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            cueContext(NaturalExpressionGuidance.serveCue),
            turnPlan: expressionPlan(goalType: "chat"))
        let task = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            cueContext(NaturalExpressionGuidance.serveCue),
            turnPlan: expressionPlan(goalType: "build_task"))
        #expect(chat.systemSegments?.dynamic.contains(NaturalExpressionGuidance.serveCue) == true)
        #expect(task.systemPrompt?.contains(NaturalExpressionGuidance.serveCue) == false)
        #expect(task.naturalExpressionCue == nil)
    }

    /// The rut and work-register fallbacks are register cues too — they stay
    /// gated. (The shipped `turnPlanGatesAndConsumesCue` test pins rut; this
    /// pins register, so the split can never silently widen.)
    @Test("the work-register cue stays gated to conversational routes")
    func registerCueStaysChatGated() {
        let task = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            cueContext(NaturalExpressionGuidance.registerCue),
            turnPlan: expressionPlan(goalType: "build_task"))
        #expect(task.systemPrompt?.contains(NaturalExpressionGuidance.registerCue) == false)
    }

    /// A COMBINED cue on a work turn carries the stance half ONLY. The chat path
    /// is untouched: it still receives the exact combined string it always did,
    /// so this wave adds no prompt-visible bytes to any conversational turn.
    @Test("a combined cue delivers stance alone on work turns and is unchanged on chat")
    func combinedCueSplitsCorrectly() {
        let combined = [NaturalExpressionGuidance.serveCue, NaturalExpressionGuidance.stanceCue]
            .joined(separator: " ")
        let task = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            cueContext(combined), turnPlan: expressionPlan(goalType: "build_task"))
        let dynamic = task.systemSegments?.dynamic ?? ""
        #expect(dynamic.contains(NaturalExpressionGuidance.stanceCue))
        #expect(!dynamic.contains(NaturalExpressionGuidance.serveCue))

        let chat = SwiftNativeTurnEngine.contextByAppendingTurnPlanHint(
            cueContext(combined), turnPlan: expressionPlan(goalType: "chat"))
        #expect(chat.systemSegments?.dynamic.contains(combined) == true)
    }

    /// NO NEW BYTES. The stance routing may only ever emit the already-shipped,
    /// already-calibrated sentence — never a work-turn variant of it.
    @Test("stance extraction returns the shipped sentence verbatim or nothing")
    func stanceOnlyIsVerbatimOrNil() {
        #expect(NaturalExpressionGuidance.stanceOnly(NaturalExpressionGuidance.stanceCue)
            == NaturalExpressionGuidance.stanceCue)
        #expect(NaturalExpressionGuidance.stanceOnly(NaturalExpressionGuidance.serveCue) == nil)
        #expect(NaturalExpressionGuidance.stanceOnly(NaturalExpressionGuidance.rutCue) == nil)
        #expect(NaturalExpressionGuidance.stanceOnly(NaturalExpressionGuidance.registerCue) == nil)
        #expect(NaturalExpressionGuidance.stanceOnly(nil) == nil)
    }
}
