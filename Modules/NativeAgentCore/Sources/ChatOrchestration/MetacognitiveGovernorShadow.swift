import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore

/// A bounded, deterministic estimate of the value of computation/action at a
/// turn boundary. This is evidence, not a chooser: every candidate is derived
/// from an already-authorized TurnPlan and the result is persisted only inside
/// the metacognitive shadow trace.
public struct MetacognitiveShadowAffordance: Sendable, Equatable {
    public enum Authority: String, Sendable, Equatable {
        case none
        case existingPolicy = "existing_policy"
        case approvalRequired = "approval_required"
    }

    public let id: String
    public let feasible: Bool
    public let authority: Authority
    public let expectedErrorReduction: Int
    public let expectedInformationGain: Int
    public let expectedRiskReduction: Int
    public let latencyCost: Int
    public let computeCost: Int
    public let interruptionCost: Int
    public let netValue: Int
    public let reasonCodes: [String]

    public var traceValue: JSONValue {
        .object([
            "id": .string(id),
            "feasible": .bool(feasible),
            "authority": .string(authority.rawValue),
            "errorReduction": .int(Int64(expectedErrorReduction)),
            "informationGain": .int(Int64(expectedInformationGain)),
            "riskReduction": .int(Int64(expectedRiskReduction)),
            "latencyCost": .int(Int64(latencyCost)),
            "computeCost": .int(Int64(computeCost)),
            "interruptionCost": .int(Int64(interruptionCost)),
            "netValue": .int(Int64(netValue)),
            "reasonCodes": .array(reasonCodes.map(JSONValue.string)),
        ])
    }
}

public struct MetacognitiveGovernorShadow: Sendable, Equatable {
    public let selectedAffordance: String?
    public let abstentionReason: String?
    public let candidates: [MetacognitiveShadowAffordance]

    public var traceValue: JSONValue {
        .object([
            "schema": .string("metacognition.governor.shadow.v1"),
            "controlAuthority": .bool(false),
            "selectedAffordance": selectedAffordance.map(JSONValue.string) ?? .null,
            "abstentionReason": abstentionReason.map(JSONValue.string) ?? .null,
            "candidates": .array(candidates.map(\.traceValue)),
        ])
    }
}

/// Integer-valued scoring avoids false floating precision and keeps the same
/// trace byte-stable across processes. Scores are deliberately interpretable;
/// they are hypotheses to evaluate against terminal evidence, never learned
/// authority and never a replacement for TrustCenter.
public enum MetacognitiveGovernorShadowEvaluator {
    public static func evaluate(
        plan: TurnPlan,
        posture: OrganismBehaviorPosture?,
        computeLane: MetacognitiveShadowRecommendation.ComputeLane,
        toolLane: MetacognitiveShadowRecommendation.ToolLane
    ) -> MetacognitiveGovernorShadow {
        let deepNeed = plan.risk == "high" || plan.contextMode == "research"
        let toolEvidence = toolLane == .lazy
        let approvalNeedsStaging = toolLane == .approvalBound
        let approvalBlocked = plan.requiresApprovalHint && !plan.policySnapshot.approvalAvailable
        let conserving = posture?.enabled == true && posture?.loopBudget != .normal

        let candidates = [
            candidate(
                id: "respond_now",
                feasible: !approvalBlocked,
                authority: .none,
                error: plan.goalType == "chat" ? 420 : 180,
                information: 40,
                risk: plan.risk == "high" ? 40 : 180,
                latency: 80,
                compute: 120,
                interruption: 0,
                reasons: ["direct_response", plan.goalType == "chat" ? "chat_goal" : "nonchat_goal"]
            ),
            candidate(
                id: "deliberate_deeply",
                feasible: !approvalBlocked && !conserving,
                authority: .none,
                error: deepNeed ? 820 : 360,
                information: deepNeed ? 420 : 180,
                risk: plan.risk == "high" ? 720 : 180,
                latency: 480,
                compute: 620,
                interruption: 0,
                reasons: [deepNeed ? "depth_evidence" : "limited_depth_value"]
            ),
            candidate(
                id: "use_tools",
                // A required approval is not tool authority. Until the
                // approval is resolved, the feasible move is staging the
                // approval below—not executing the tool.
                feasible: toolEvidence && !approvalBlocked,
                authority: .existingPolicy,
                error: toolEvidence ? 720 : 0,
                information: toolEvidence ? 780 : 0,
                risk: plan.risk == "high" ? 620 : 320,
                latency: 360,
                compute: 260,
                interruption: 0,
                reasons: [toolEvidence ? "tool_evidence" : "no_tool_evidence"]
            ),
            candidate(
                id: "stage_approval",
                feasible: approvalNeedsStaging && !approvalBlocked,
                authority: .approvalRequired,
                error: approvalNeedsStaging ? 640 : 0,
                information: 300,
                risk: approvalNeedsStaging ? 940 : 0,
                latency: 260,
                compute: 40,
                interruption: 420,
                reasons: [approvalNeedsStaging ? "approval_must_precede_action" : "no_approval_boundary"]
            ),
            candidate(
                id: "ask_user",
                feasible: approvalBlocked || computeLane == .askUser,
                authority: .none,
                error: approvalBlocked ? 760 : 360,
                information: 760,
                risk: approvalBlocked ? 920 : 500,
                latency: 680,
                compute: 40,
                interruption: 520,
                reasons: [approvalBlocked ? "approval_unavailable" : "clarification_value"]
            ),
            candidate(
                id: "wait_for_evidence",
                feasible: plan.goalType != "chat" || approvalBlocked,
                authority: .none,
                error: 360,
                information: 520,
                risk: plan.risk == "high" ? 760 : 420,
                latency: 760,
                compute: 20,
                interruption: 0,
                reasons: ["external_evidence_may_change_state"]
            ),
        ].sorted { $0.id < $1.id }

        let feasible = candidates.filter(\.feasible)
        let best = feasible.sorted {
            if $0.netValue != $1.netValue { return $0.netValue > $1.netValue }
            return $0.id < $1.id
        }.first
        return MetacognitiveGovernorShadow(
            selectedAffordance: best?.id,
            abstentionReason: best == nil ? "no_feasible_affordance" : nil,
            candidates: candidates
        )
    }

    private static func candidate(
        id: String,
        feasible: Bool,
        authority: MetacognitiveShadowAffordance.Authority,
        error: Int,
        information: Int,
        risk: Int,
        latency: Int,
        compute: Int,
        interruption: Int,
        reasons: [String]
    ) -> MetacognitiveShadowAffordance {
        func bounded(_ value: Int) -> Int { min(1_000, max(0, value)) }
        let error = bounded(error)
        let information = bounded(information)
        let risk = bounded(risk)
        let latency = bounded(latency)
        let compute = bounded(compute)
        let interruption = bounded(interruption)
        let value = feasible
            ? error + information + risk - latency - compute - interruption
            : -3_000
        return MetacognitiveShadowAffordance(
            id: id,
            feasible: feasible,
            authority: authority,
            expectedErrorReduction: error,
            expectedInformationGain: information,
            expectedRiskReduction: risk,
            latencyCost: latency,
            computeCost: compute,
            interruptionCost: interruption,
            netValue: min(3_000, max(-3_000, value)),
            reasonCodes: Array(Set(reasons)).sorted()
        )
    }
}
