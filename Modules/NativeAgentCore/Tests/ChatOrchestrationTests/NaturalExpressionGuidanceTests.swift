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
