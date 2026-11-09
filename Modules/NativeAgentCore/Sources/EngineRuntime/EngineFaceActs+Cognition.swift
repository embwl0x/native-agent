import BackgroundLoops
import Cognition
import Foundation
import NativeAgentShared
// Blueprint: | `EngineFaceActs+Cognition.swift` | Copied Observatory commands use the resident mind's checked outcomes and configuration |

extension EngineFaceActs {
    func cognition(_ command: CognitionAct) async throws -> FaceActReply {
        guard let runtime = engine.cognition else { throw Self.failure("body_unavailable", "This root has no resident mind.") }
        let state = await runtime.subconsciousRuntimeState()
        let status: String
        let message: String
        switch command {
        case .runMicrocycle:
            (status, message) = try Self.cognitionOutcome(await runtime.runMicrocycle(reason: "observatory manual run"))
        case .runReflection:
            (status, message) = try Self.cognitionOutcome(await runtime.runManualReflection())
        case .clearTransientState:
            switch await runtime.clearTransientState() {
            case .cleared: (status, message) = ("completed", "Thinking and body state cleared.")
            case .persistenceFailed(let cause):
                throw Self.failure("cognition_clear_failed", "Nothing was cleared; the state was kept: " + cause)
            case .bodyPersistenceFailed:
                throw Self.failure("cognition_clear_partial",
                    "Thinking state cleared. Body state cleared in memory, but could not be saved.", effects: .known)
            }
        case .settleContinuity, .resetContinuity:
            let outcome: OrganismContinuityApplyOutcome
            if case .resetContinuity = command { outcome = await runtime.resetOrganismContinuityChecked() }
            else { outcome = await runtime.settleOrganismContinuityChecked() }
            switch outcome.status {
            case .applied:
                status = "completed"
                if case .resetContinuity = command { message = "Body state reset and saved." }
                else { message = "Body state settled and saved." }
            case .organismDisabled: (status, message) = ("skipped", "Body signals are off.")
            case .persistenceFailed:
                throw WireFailure(code: "body_continuity_save_failed", message: "Body state could not be saved.",
                    cause: outcome.error, effects: .known)
            }
        case .setCapsuleEnabled(let enabled):
            if state.capsuleEnabled != enabled { await runtime.setCapsuleEnabled(enabled) }
            (status, message) = ("saved", enabled ? "Thought summary enabled." : "Thought summary disabled.")
        case .setBackgroundEnabled(let enabled):
            if state.backgroundEnabled != enabled { await runtime.setBackgroundEnabled(enabled) }
            (status, message) = ("saved", enabled ? "Background thinking enabled." : "Background thinking disabled.")
        case .setReflectionBudget(let budget):
            guard (0...8).contains(budget) else { throw Self.failure("reflection_budget_invalid", "Choose a reflection budget from 0 through 8.") }
            if state.reflectionBudget != budget { await runtime.setReflectionBudget(budget) }
            (status, message) = ("saved", "Reflection budget saved.")
        case .setAblation(let name, let enabled):
            guard name == "workspace" else { throw Self.failure("ablation_unknown", "This Observatory control names no supported intervention.") }
            let detail = await runtime.observatoryDetail()
            if (detail.summary.ablations[name] != false) != enabled { await runtime.setAblation(name, enabled: enabled) }
            (status, message) = ("saved", enabled ? "Workspace included." : "Workspace excluded.")
        case .setLane:
            throw Self.failure("cognition_lane_unknown", "Use the named inner life controls in Settings.")
        }
        await engine.cognitionView.refreshObservatory(contextFlowHealthRead: { @Sendable [engine] in
            await engine.contextFlow.observatoryHealthState()
        })
        return .result(.object(["status": .string(status), "message": .string(message)]))
    }

    private static func cognitionOutcome(_ outcome: LoopTickOutcome) throws -> (String, String) {
        switch outcome {
        case .completed(let result): return ("completed", result ?? "The requested work completed.")
        case .skipped(let reason, _): return ("skipped", "Skipped: " + reason)
        case .failed(let cause): throw failure("cognition_work_failed", cause, effects: .unknown)
        }
    }
}
