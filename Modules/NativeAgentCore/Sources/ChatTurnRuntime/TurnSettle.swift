import Foundation
import NativeAgentCore
import PersistenceCore
import CognitiveSubstrate

/// The settle stage a turn ends through, on every lane: whether it ends
/// waiting on a card, the terminal it gets then, the sentence the transport
/// needs that no delta carried, and the row the transcript keeps — which is
/// also what memory promotion reads, so the two never disagree.
enum TurnSettle {
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
