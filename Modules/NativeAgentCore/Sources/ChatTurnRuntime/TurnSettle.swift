import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import AgentConversations
// Blueprint: | `TurnSettle.swift` | `TurnSettle` enum; `requestedResultIntent`, `takeStreamSuffix`, `transcriptRow` |

/// Every turn settles waiting state, terminal truth, transport prose and transcript through one owner so delivery and memory agree.
enum TurnSettle {
    /// The obligation rides on the result's own durable row. Delivery readers
    /// can retry it without asking the provider or replaying any tool.
    static func requestedResultIntent(
        message: String, result: TurnEngineResult,
        sessionID: String, runID: String, surface: String,
        resumedRequest: Bool,
        turn: Turn
    ) -> JSONValue? {
        guard result.completionState == .completed,
              turn.execution?.waitingForInteraction != true,
              turn.execution?.transcriptRowKind == nil else { return nil }
        let completion = turn.rows.codexCompletion
        guard completion?.isTerminalCompletion != false else { return nil }
        let origin = turn.origin
        guard completion != nil || origin?.authored != .agent else { return nil }
        // Discovery and context expansion alone cannot satisfy requested work.
        let meaningfulTools = result.toolDispatches.filter {
            $0.ranCall.tool != "context_expand"
                && !($0.name == "app" && $0.input["find"] != nil && $0.input["action"] == nil)
        }
        let authored = NaturalExpressionGuidance.authoredHead(message)
        let workQuestion = !meaningfulTools.isEmpty && UserMessageIntentSignals.isWorkQuestion(authored)
        guard completion != nil || resumedRequest || UserMessageIntentSignals.explicitlyRequestsWork(authored) ||
            (workQuestion && !NaturalExpressionGuidance.isSocialServe(authored)) else { return nil }
        // An accepted asynchronous assignment is still owed. Its resident
        // continuation, carrying the completion binding, supplies the result.
        if meaningfulTools.contains(where: { dispatch in
            let ran = dispatch.ranCall.tool
            let input = dispatch.ranCall.input
            // A job the agent gave another agent settles by waking the context that commissioned it.
            if ran == "app", input["action"] == .string("agent.job"), case .object(let fields) = dispatch.result {
                return ["working", "needs_you"].contains(fields["state"]?.stringValue ?? "")
            }
            guard ["agent_message", "bot_run_once"].contains(ran),
                  case .object(let fields) = dispatch.result else { return false }
            // A one-way note completes when sent: its contract deliberately
            // creates no returning turn to own this obligation later.
            if input["expects_reply"] == .bool(false) ||
                fields["automatic_return"] == .bool(false) { return false }
            if ran == "agent_message", case .string(let state)? = fields["state"] {
                return ["waiting", "sending", "working"].contains(state)
            }
            if fields["terminal"] == .bool(true) || fields["completed"] == .bool(true) ||
                fields["sent"] == .bool(false) { return false }
            let states = [fields["status"], fields["state"]].compactMap { field -> String? in
                if case .string(let value)? = field { return value }; return nil
            }
            return fields["queued"] == .bool(true) || states.contains {
                ["accepted", "enqueued", "queued", "joined", "running", "working", "in_progress", "waiting", "pending", "submitted", "delivering"].contains($0)
            }
        }) { return nil }
        let route = turn.replyRoute?.surface ?? surface
        guard route != "caller-result", route != AgentConversationStore.heldReplySurface else { return nil }
        return .object([
            "eventId": .string("requested-result:" + (completion?.deliveryId ?? runID)),
            "sessionId": .string(sessionID), "runId": .string(runID),
            "surface": .string(route), "state": .string("pending"),
        ])
    }

    /// Consume synthesized card prose once inside the progress execution scope.
    static func takeStreamSuffix(turn: Turn) -> String? {
        guard let suffix = turn.execution?.takeStreamSuffix(), !suffix.isEmpty else { return nil }
        return suffix
    }

    /// Persist the card-lane sentence for waiting turns; expanded text belongs only to transport.
    /// Stamp synthesized-only rows as mechanical so memory never mistakes card copy for model-authored prose.
    static func transcriptRow(for reply: String, turn: Turn) -> (text: String, mechanicalRow: CognitiveMechanicalRowKind?) {
        let text = turn.execution?.transcriptReply(reply) ?? reply
        return (
            text,
            turn.execution?.transcriptReplyIsCardLane == true ? .cardLane : turn.execution?.transcriptRowKind
        )
    }
}
