import CognitiveSubstrate
@testable import NativeAgentEvaluation
import NativeAgentCore
import Testing
@testable import ChatOrchestration

@Suite("Metacognitive governor shadow")
struct MetacognitiveGovernorShadowTests {
    @Test("ordinary chat prefers a direct response without gaining control")
    func ordinaryChat() throws {
        let recommendation = MetacognitiveShadowEvaluator.recommend(
            plan: plan(goal: "chat", context: "minimal", risk: "low"),
            posture: nil
        )
        #expect(recommendation.governor.selectedAffordance == "respond_now")
        #expect(recommendation.governor.abstentionReason == nil)
        #expect(recommendation.governor.candidates.count == 6)
        guard case .object(let trace) = recommendation.governor.traceValue else {
            Issue.record("expected governor object")
            return
        }
        #expect(trace["controlAuthority"] == .bool(false))
    }

    @Test("research with tool evidence prefers evidence gathering")
    func researchTools() {
        let recommendation = MetacognitiveShadowEvaluator.recommend(
            plan: plan(
                goal: "research",
                context: "research",
                risk: "medium",
                preload: ToolPreloadHeuristics.Prediction(
                    groups: [ToolPreloadHeuristics.GroupMatch(
                        group: "research",
                        matchedPatterns: ["research"]
                    )],
                    candidateTools: ["research_search"]
                )
            ),
            posture: nil
        )
        #expect(recommendation.governor.selectedAffordance == "use_tools")
    }

    @Test("missing approval makes asking the only high-value live move")
    func approvalBlocked() {
        let recommendation = MetacognitiveShadowEvaluator.recommend(
            plan: plan(
                goal: "file_work",
                context: "planned",
                risk: "high",
                requiresApproval: true,
                approvalAvailable: false
            ),
            posture: nil
        )
        #expect(recommendation.computeLane == .askUser)
        #expect(recommendation.governor.selectedAffordance == "ask_user")
        let respond = recommendation.governor.candidates.first { $0.id == "respond_now" }
        #expect(respond?.feasible == false)
    }

    @Test("available approval stages authority instead of pretending the tool may run")
    func approvalStagingIsSeparateFromExecution() {
        let recommendation = MetacognitiveShadowEvaluator.recommend(
            plan: plan(
                goal: "build",
                context: "planned",
                risk: "high",
                requiresApproval: true,
                approvalAvailable: true,
                preload: ToolPreloadHeuristics.Prediction(
                    groups: [ToolPreloadHeuristics.GroupMatch(group: "builder", matchedPatterns: ["build"])],
                    candidateTools: ["run_command"]
                )
            ),
            posture: nil
        )
        #expect(recommendation.governor.selectedAffordance == "stage_approval")
        let tool = recommendation.governor.candidates.first { $0.id == "use_tools" }
        let stage = recommendation.governor.candidates.first { $0.id == "stage_approval" }
        #expect(tool?.feasible == false)
        #expect(stage?.feasible == true)
        #expect(stage?.authority == .approvalRequired)
    }

    @Test("candidate algebra is bounded sorted and deterministic")
    func deterministic() {
        let input = plan(goal: "file_work", context: "planned", risk: "high")
        let first = MetacognitiveShadowEvaluator.recommend(plan: input, posture: nil)
        let second = MetacognitiveShadowEvaluator.recommend(plan: input, posture: nil)
        #expect(first == second)
        #expect(first.governor.candidates.map(\.id) == first.governor.candidates.map(\.id).sorted())
        #expect(first.governor.candidates.allSatisfy { (-3_000...3_000).contains($0.netValue) })
    }

    private func plan(
        goal: String,
        context: String,
        risk: String,
        requiresApproval: Bool = false,
        approvalAvailable: Bool = true,
        preload: ToolPreloadHeuristics.Prediction? = nil
    ) -> TurnPlan {
        TurnPlan(
            id: "governor-test",
            messageCharCount: 80,
            goalType: goal,
            contextMode: context,
            recommendedSurface: "chat",
            risk: risk,
            requiresApprovalHint: requiresApproval,
            matchedCapabilityIds: [],
            preloadPrediction: preload,
            policySnapshot: TurnPolicySnapshot(
                permissionLevel: "ask",
                autonomyDefault: "ask",
                fullMacActive: false,
                developerMode: false,
                remoteSurface: false,
                surfaceTrusted: true,
                fileAccess: "read_only",
                approvalAvailable: approvalAvailable,
                remoteIOSAllowed: false
            ),
            receiptHints: [],
            createdAt: "2026-07-13T00:00:00Z"
        )
    }
}
