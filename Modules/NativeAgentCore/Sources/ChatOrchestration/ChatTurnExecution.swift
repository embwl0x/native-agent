import Foundation
import NativeAgentCore
import NativeAgentShared
import ProviderRouting
import PersistenceCore
import CognitiveSubstrate

final class ChatTurnExecution: @unchecked Sendable {
    @TaskLocal static var current: ChatTurnExecution?
    private let lock = NSLock()
    private var persistedHistoryRunID: String?
    var historyRunID: String? {
        lock.lock(); defer { lock.unlock() }
        return persistedHistoryRunID
    }
    func bindHistoryRunID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        persistedHistoryRunID = id
    }

    /// PROVENANCE CARRIED BY THE CALLER, for the whole of this invocation.
    ///
    /// A bot run's own two rows — the brief that started it and the reply it
    /// produced — are the bot's machinery, not a moment she lived, exactly as
    /// the imported shelf receipts are (Agent, item 5, 2026-09-14). Until this
    /// existed only the IMPORT was stamped, so a live run's brief and reply
    /// went through ordinary persistence unmarked and fed felt appraisal.
    ///
    /// Set explicitly by the entry that knows what it is starting; never
    /// inferred from `surface`, because a PERSON steering into a bot session
    /// arrives on that same surface and what she hears from a person is
    /// something she lived.
    private let invocationRow: CognitiveMechanicalRowKind?
    init(mechanicalRow: CognitiveMechanicalRowKind? = nil) {
        self.invocationRow = mechanicalRow
    }
    /// The row kind this turn's automatic transcript writes carry, or nil for
    /// an ordinary turn somebody meant.
    static var transcriptRowKind: CognitiveMechanicalRowKind? {
        ChatTurnExecution.current?.invocationRow
    }
    private var waiting = false
    private var capabilityNote: String?
    func keepCapabilityNote(_ note: String) { lock.lock(); defer { lock.unlock() }; capabilityNote = note }
    func statusDetail(_ detail: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let text = [detail, capabilityNote].compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
    private var records: [TurnEngineResult.ToolDispatchRecord] = []
    var toolRecords: [TurnEngineResult.ToolDispatchRecord] { lock.lock(); defer { lock.unlock() }; return records }
    func keepTools(_ values: [TurnEngineResult.ToolDispatchRecord]) { lock.lock(); defer { lock.unlock() }; records += values }
    private var pending: JSONValue?
    private var pendingID: String?
    var pendingApproval: JSONValue? { lock.lock(); defer { lock.unlock() }; return pending }
    /// The approval a bot turn stopped on. It travels out with the response so
    /// the shelf entry can later be reconciled against that approval's own
    /// resolution instead of staying "Waiting for approval" forever.
    var pendingApprovalID: String? { lock.lock(); defer { lock.unlock() }; return pendingID }
    func keepApproval(id: String, _ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        pending = value; pendingID = id; waiting = true
    }
    var waitingForApproval: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func waitForApproval() { lock.lock(); defer { lock.unlock() }; waiting = true }

    // MARK: Inline interactions
    //
    // A raised need parks the turn on a PERSON, exactly as an approval does.
    // Two differences from the approval flag above, and both are deliberate:
    //
    //  * it stops the tool loop on EVERY surface, not just `bot`. An approval
    //    that keeps looping merely re-asks; a need that keeps looping burns
    //    the whole turn re-hitting the same missing connector.
    //  * it travels out as an identifier, because the resolver resumes THIS
    //    interaction once and needs to find it again after a relaunch.
    private var pendingInteraction: String?
    /// The need itself, kept because a route that cannot DRAW the card has to
    /// say it instead, and the card's own copy is the only honest wording for
    /// that sentence.
    private var pendingNeed: InlineInteraction?
    var waitingInteractionID: String? { lock.lock(); defer { lock.unlock() }; return pendingInteraction }
    var waitingInteraction: InlineInteraction? { lock.lock(); defer { lock.unlock() }; return pendingNeed }
    var waitingForInteraction: Bool { lock.lock(); defer { lock.unlock() }; return pendingInteraction != nil }
    /// The row the transcript keeps for this waiting turn — the card-lane one
    /// sentence, computed once by `waitingReply` alongside the transport reply.
    private var waitingRow: String?
    var waitingTranscriptRow: String? { lock.lock(); defer { lock.unlock() }; return waitingRow }
    func keepWaitingRow(_ row: String, synthesized: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        waitingRow = row
        waitingRowSynthesized = synthesized
    }
    /// True when the kept row is the card lane's stock sentence, not words the
    /// model wrote. Only that row is mechanical to the felt organ; the model's
    /// own prose beside a card is still an experience she had (Sol, 2026-09-14).
    private var waitingRowSynthesized = false
    var waitingTranscriptRowIsSynthesized: Bool {
        lock.lock(); defer { lock.unlock() }
        return waitingRow != nil && waitingRowSynthesized
    }
    /// First need wins: the turn suspends on the one the person is being shown,
    /// and a later round cannot overwrite which interaction is being awaited.
    func waitForInteraction(_ need: InlineInteraction) {
        lock.lock(); defer { lock.unlock() }
        guard pendingInteraction == nil else { return }
        pendingInteraction = need.id
        pendingNeed = need
    }

    /// The final text of a turn that ended waiting on a card.
    ///
    /// Two jobs, and the second one is why this exists at all:
    ///
    ///  * The model's own prose is cut at the first protocol marker. The
    ///    text-compat lane used to hand its RAW accumulation through, so a turn
    ///    whose model went straight to the tool persisted the literal
    ///    `<tool_use name="…">{}</tool_use>` as the assistant's reply and the
    ///    person read the marker as Agent's answer (Agent, 2026-09-13).
    ///  * On a route that cannot draw the card, the card's own copy is said in
    ///    prose. Otherwise the turn reaches Telegram, Slack and the bridge as
    ///    an empty string — which they report as "the reply came back empty"
    ///    and "stream ended without final reply". The Mac and iPhone say
    ///    nothing extra here: the card IS the reply there, and repeating it in
    ///    prose would double it up.
    static func waitingReply(visible: String) -> String {
        let prose = ToolCallParser.visiblePrefix(
            in: ToolCallParser.stripToolUseMarkers(visible)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let execution = ChatTurnExecution.current,
              let need = execution.waitingInteraction
        else { return prose }
        // THE TRANSCRIPT ROW IS THE CARD LANE'S, ON EVERY LANE. The card is
        // persisted on the row beneath it whatever surface raised it, so the
        // Mac draws both — and a bridge turn that persisted the long compat
        // sentence showed Agent's reader the sentence AND the card saying the
        // same thing twice (Agent, live on 4fe15f5ea). The long sentence is a
        // TRANSPORT fact — it exists because Telegram, Slack, the bridge and
        // iOS delivery have text and nothing else — so it is handed back to
        // the caller and never written to the conversation.
        let row = prose.isEmpty ? need.cardLaneProse : prose
        execution.keepWaitingRow(row, synthesized: prose.isEmpty)
        // A lane that DRAWS the card gets one sentence in her voice and
        // nothing more: the card under it already carries the reason, the way
        // forward and the cost of saying no, so repeating them in prose is the
        // card said twice (Agent, 2026-09-13). Her own words, when the model
        // wrote any, always win.
        guard ChatToolSessionContext.replyIsTextOnly else { return row }
        let spoken = need.textLaneProse
        guard !spoken.isEmpty else { return prose }
        let suffix = prose.isEmpty ? spoken : "\n\n" + spoken
        // This sentence exists only in the TERMINAL result: no delta ever
        // carried it, because the model never wrote it. A streaming consumer
        // that rebuilds the reply from deltas — and a pure tool-to-card turn
        // streams none at all — then sees a final its deltas do not match.
        // Kept here so the lane about to yield `.final` can stream it first.
        execution.keepStreamSuffix(suffix)
        return prose + suffix
    }

    /// The text-lane sentence `waitingReply` added after the last delta, taken
    /// exactly once by the lane that is about to yield `.final`.
    private var streamSuffix: String?
    func keepStreamSuffix(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        streamSuffix = text
    }
    static func takeStreamSuffix() -> String? {
        guard let execution = ChatTurnExecution.current else { return nil }
        execution.lock.lock(); defer { execution.lock.unlock() }
        defer { execution.streamSuffix = nil }
        return execution.streamSuffix
    }

    /// What the TRANSCRIPT keeps for this turn, given the reply the transport
    /// is getting. Identical unless the turn ended waiting on a card, in which
    /// case the row is the one-sentence card-lane prose `waitingReply` already
    /// computed — the card carries the rest.
    static func transcriptReply(_ reply: String) -> String {
        ChatTurnExecution.current?.waitingTranscriptRow ?? reply
    }

    /// True when `transcriptReply` is handing back the card lane's row rather
    /// than an ordinary reply. The felt organ reads this as PROVENANCE: a row
    /// the interaction lane produced is not an experience she had, and the only
    /// honest way to know that is to be told by the writer. It used to be
    /// guessed from text fragments, which dropped a genuine reply that happened
    /// to contain one of the card lane's stock phrases.
    static var transcriptReplyIsCardLane: Bool {
        ChatTurnExecution.current?.waitingTranscriptRowIsSynthesized ?? false
    }
}

extension SwiftNativeChatOrchestrationClient {
    /// Explicit picker and one aggregate output allowance, scoped to this turn.
    /// `choice` nil means the same route Chat uses: the agent's own model.
    /// `mechanicalRow` stamps BOTH automatic transcript writes of this
    /// invocation — the brief and the reply — with the provenance the caller
    /// names. Nil is the ordinary case.
    public func chat(message: String, sessionId: String, choice: ProviderTurnChoice?,
                     tokenLimit: Int, surface: String,
                     mechanicalRow: CognitiveMechanicalRowKind? = nil,
                     progress: ChatOrchestrationProgressHandler? = nil) async throws -> ChatResponse {
        guard tokenLimit > 0 else { throw ChatOrchestrationError.underlying("The turn token limit must be positive.") }
        let budget = TurnTokenBudget(tokens: tokenLimit)
        let execution = ChatTurnExecution(mechanicalRow: mechanicalRow)
        return try await ProviderTurnChoice.$current.withValue(choice) {
        try await LLMCallContext.$turnTokenBudget.withValue(budget) {
        try await ChatTurnExecution.$current.withValue(execution) {
        try await LLMCallContext.$toolCapabilityNote.withValue({ execution.keepCapabilityNote($0) }) {
            do {
                var response = try await chat(message: message, sessionId: sessionId, model: choice?.model ?? "",
                    reasoningEffort: choice?.reasoningEffort ?? "", fileAccess: "auto", attachments: [], persona: nil,
                    surface: surface, suppressUserAppend: false, progress: progress)
                response.runtimeStatus = execution.waitingForApproval ? "waiting for approval"
                    : execution.waitingForInteraction ? "waiting on you"
                    : budget.exhausted || response.runtimeStatus == "interrupted" ? "interrupted" : "completed"
                response.statusDetail = execution.waitingForApproval ? "Approval is available in Approvals."
                    : execution.waitingForInteraction
                        ? (execution.waitingInteraction?.title).map { "\($0) — answer it in the conversation." }
                            ?? "Waiting on your answer in the conversation."
                    : budget.exhausted ? "Stopped at the per-run token limit." : nil
                response.statusDetail = execution.statusDetail(response.statusDetail)
                response.pendingApprovalID = execution.pendingApprovalID
                return response
            } catch {
                let partial = ToolCallParser.visiblePrefix(in: ToolCallParser.stripToolUseMarkers(budget.partialReply))
                let artifacts = ChatGeneratedImageArtifacts.attachments(from: execution.toolRecords, dataRoot: dataRoot)
                // Preserve already-produced work even when the provider throws.
                // The ordinary transcript and index remain the sole chat owners.
                if !partial.isEmpty {
                    try await appendMessage(sessionId: sessionId, role: "assistant", content: partial,
                        runId: UUID().uuidString, attachments: artifacts, source: surface,
                        responseOutcomeStatus: "incomplete")
                }
                var response = ChatResponse(runId: UUID().uuidString, model: choice?.model ?? "",
                    reasoningEffort: choice?.reasoningEffort, output: partial, sessionId: sessionId, attachments: artifacts.isEmpty ? nil : artifacts)
                response.runtimeStatus = error is CancellationError || budget.exhausted ? "interrupted" : "failed"
                response.statusDetail = budget.exhausted ? "Stopped at the per-run token limit."
                    : error is CancellationError ? "Stopped at the time limit or cancelled." : String(describing: error)
                response.statusDetail = execution.statusDetail(response.statusDetail)
                return response
            }
        }
        }
        }
        }
    }
}
