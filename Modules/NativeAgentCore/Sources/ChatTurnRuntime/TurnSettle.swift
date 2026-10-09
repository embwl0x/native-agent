import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate
import ToolRegistry

/// The settle stage a turn ends through, on every lane: whether it ends
/// waiting on a card, the terminal it gets then, the sentence the transport
/// needs that no delta carried, and the row the transcript keeps — which is
/// also what memory promotion reads, so the two never disagree.
enum TurnSettle {
    /// The obligation rides on the result's own durable row. Delivery readers
    /// can retry it without asking the provider or replaying any tool.
    static func requestedResultIntent(
        message: String, plan: TurnPlan?, result: TurnEngineResult,
        sessionID: String, runID: String, surface: String,
        resumedRequest: Bool
    ) -> JSONValue? {
        guard result.completionState == .completed,
              ChatTurnExecution.current?.waitingForInteraction != true,
              ChatTurnExecution.transcriptRowKind == nil else { return nil }
        let completion = ChatPersistenceContext.codexCompletionBinding
        guard completion?.isTerminalCompletion != false else { return nil }
        let origin = ChatPersistenceContext.originProvenance
        guard completion != nil || origin?.authored != .agent else { return nil }
        // Finding an action (app {find}) or expanding context is not work.
        let meaningfulTools = result.toolDispatches.filter {
            ToolNameAliases.ranTool($0.name, input: $0.input) != "context_expand"
                && !($0.name == "app" && $0.input["find"] != nil && $0.input["action"] == nil)
        }
        let authored = NaturalExpressionGuidance.authoredHead(message)
        let routedQuestion = plan?.goalType != "chat" && plan?.goalType != "personality" &&
            !meaningfulTools.isEmpty && UserMessageIntentSignals.isWorkQuestion(authored)
        guard completion != nil || resumedRequest || UserMessageIntentSignals.explicitlyRequestsWork(authored) ||
            (routedQuestion && !NaturalExpressionGuidance.isSocialServe(authored)) else { return nil }
        // An accepted asynchronous assignment is still owed. Its resident
        // continuation, carrying the completion binding, supplies the result.
        if meaningfulTools.contains(where: { dispatch in
            let ran = ToolNameAliases.ranTool(dispatch.name, input: dispatch.input)
            let input = ToolNameAliases.ranInput(dispatch.name, input: dispatch.input)
            guard ["agent_message", "codex_message", "claude_message", "omp_message", "bot_run_once"].contains(ran),
                  case .object(let fields) = dispatch.result else { return false }
            // A one-way note completes when sent: its contract deliberately
            // creates no returning turn to own this obligation later.
            if input["completion_mode"] == .string("receipt_only") ||
                fields["completionMode"] == .string("receipt_only") ||
                input["expects_reply"] == .bool(false) ||
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
        let route = ChatToolSessionContext.replyRoute?.surface ?? surface
        guard route != "caller-result" else { return nil }
        return .object([
            "eventId": .string("requested-result:" + (completion?.deliveryId ?? runID)),
            "sessionId": .string(sessionID), "runId": .string(runID),
            "surface": .string(route), "state": .string("pending"),
        ])
    }

    /// True when the turn settles as waiting on a card. A raised need
    /// outranks the per-round final of the round that raised it — on the
    /// text lane that is the model's `<tool_use …>` marker and nothing else,
    /// and letting it stand persisted the marker as Agent's reply
    /// (2026-09-13). It never outranks a genuine terminal round
    /// (`finishedRound`), nor, where the lane passes it, a capped stop whose
    /// own reply says why the turn ended (`capped`).
    static func isWaitingOnCard(finishedRound: Bool, capped: Bool) -> Bool {
        !finishedRound && !capped && ChatTurnExecution.current?.waitingForInteraction == true
    }

    /// The terminal of a turn that ended waiting on a card: the prose the
    /// person watched render, cut at the first marker, plus — on a route that
    /// cannot draw the card — the card said out loud
    /// (`ChatTurnExecution.waitingReply`). Suspended, not finished: the
    /// continuation on the card completes it.
    static func waitingOnCard(
        visible: String,
        modelUsed: String,
        recalledIds: [String],
        dispatches: [TurnEngineResult.ToolDispatchRecord],
        startNs: UInt64,
        rawLLMResponse: String,
        providerCallCount: Int
    ) -> TurnEngineResult {
        TurnEngineResult(
            reply: ChatTurnExecution.waitingReply(visible: visible),
            modelUsed: modelUsed,
            recalledIds: recalledIds,
            toolDispatches: dispatches,
            elapsedMs: Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000),
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount,
            completionState: .incomplete
        )
    }

    /// The card-lane sentence `waitingOnCard` added after the last delta,
    /// taken once by the lane about to yield `.final`, which streams it
    /// first: a consumer that rebuilds the reply from deltas has to see it.
    static func takeStreamSuffix() -> String? {
        guard let suffix = ChatTurnExecution.takeStreamSuffix(), !suffix.isEmpty else { return nil }
        return suffix
    }

    /// What the conversation keeps for a turn whose transport reply is
    /// `reply`, and the row's provenance. Identical to `reply` unless the
    /// turn ended waiting on a card: then it is the card lane's one sentence
    /// (the card beneath carries the rest; the long compat sentence is the
    /// transport's, not the conversation's), stamped `.cardLane` when the
    /// model wrote none of it.
    static func transcriptRow(for reply: String) -> (text: String, mechanicalRow: CognitiveMechanicalRowKind?) {
        let text = ChatTurnExecution.transcriptReply(reply)
        return (
            text,
            ChatTurnExecution.transcriptReplyIsCardLane ? .cardLane : ChatTurnExecution.transcriptRowKind
        )
    }
}
