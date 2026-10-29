import ChatToolParsing
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import CognitiveSubstrate
// Blueprint: | `ChatTurnExecution.swift` | `ChatTurnExecution` class; `bindHistoryRunID`, `keepCapabilityNote` |

package final class ChatTurnExecution: @unchecked Sendable {
    @TaskLocal package static var current: ChatTurnExecution?
    private let lock = NSLock()
    private var persistedHistoryRunID: String?
    package var historyRunID: String? {
        lock.lock(); defer { lock.unlock() }
        return persistedHistoryRunID
    }
    package func bindHistoryRunID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        persistedHistoryRunID = id
    }

    /// The caller marks mechanical bot rows explicitly; the surface cannot distinguish person-authored input.
    private let invocationRow: CognitiveMechanicalRowKind?
    package init(mechanicalRow: CognitiveMechanicalRowKind? = nil) {
        self.invocationRow = mechanicalRow
    }
    /// The row kind this turn's automatic transcript writes carry, or nil for
    /// an ordinary turn somebody meant.
    package static var transcriptRowKind: CognitiveMechanicalRowKind? {
        ChatTurnExecution.current?.invocationRow
    }
    private var waiting = false
    private var capabilityNote: String?
    package func keepCapabilityNote(_ note: String) { lock.lock(); defer { lock.unlock() }; capabilityNote = note }
    package func statusDetail(_ detail: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        let text = [detail, capabilityNote].compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
    /// A matching source fingerprint reuses the window's frame while its image remains in context.
    private var attachedPixels: [String: (fingerprint: String, frameID: String, image: String)] = [:]
    package func attachedPixelFrame(window: String, fingerprint: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let attached = attachedPixels[window], attached.fingerprint == fingerprint else { return nil }
        return attached.frameID
    }
    /// `image` names the attached picture; nil keeps the one already attached.
    package func notePixelsAttached(window: String, fingerprint: String, frameID: String, image: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let image = image ?? attachedPixels[window]?.image else { return }
        attachedPixels[window] = (fingerprint, frameID, image)
    }
    /// A picture replaced or released from her context no longer stands for its window.
    package func keepPixels(_ images: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        attachedPixels = attachedPixels.filter { images.contains($0.value.image) }
    }
    private var records: [ToolDispatchRecord] = []
    package var toolRecords: [ToolDispatchRecord] { lock.lock(); defer { lock.unlock() }; return records }
    package func keepTools(_ values: [ToolDispatchRecord]) { lock.lock(); defer { lock.unlock() }; records += values }
    private var pending: JSONValue?
    private var pendingID: String?
    package var pendingApproval: JSONValue? { lock.lock(); defer { lock.unlock() }; return pending }
    /// The approval a bot turn stopped on. It travels out with the response so
    /// the shelf entry can later be reconciled against that approval's own
    /// resolution instead of staying "Waiting for approval" forever.
    package var pendingApprovalID: String? { lock.lock(); defer { lock.unlock() }; return pendingID }
    package func keepApproval(id: String, _ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        pending = value; pendingID = id; waiting = true
    }
    package var waitingForApproval: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    package func waitForApproval() { lock.lock(); defer { lock.unlock() }; waiting = true }

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
    package var waitingInteraction: InlineInteraction? { lock.lock(); defer { lock.unlock() }; return pendingNeed }
    package var waitingForInteraction: Bool { lock.lock(); defer { lock.unlock() }; return pendingInteraction != nil }
    /// The row the transcript keeps for this waiting turn — the card-lane one
    /// sentence, computed once by `waitingReply` alongside the transport reply.
    private var waitingRow: String?
    package var waitingTranscriptRow: String? { lock.lock(); defer { lock.unlock() }; return waitingRow }
    package func keepWaitingRow(_ row: String, synthesized: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        waitingRow = row
        waitingRowSynthesized = synthesized
    }
    /// Only synthesized card prose is mechanical to the felt organ; model-authored prose remains experience.
    private var waitingRowSynthesized = false
    package var waitingTranscriptRowIsSynthesized: Bool {
        lock.lock(); defer { lock.unlock() }
        return waitingRow != nil && waitingRowSynthesized
    }
    /// First need wins: the turn suspends on the one the person is being shown,
    /// and a later round cannot overwrite which interaction is being awaited.
    package func waitForInteraction(_ need: InlineInteraction) {
        lock.lock(); defer { lock.unlock() }
        guard pendingInteraction == nil else { return }
        pendingInteraction = need.id
        pendingNeed = need
    }

    /// The final text of a turn that ended waiting on a card: her own words,
    /// written after she read the card's receipt, and on a route that cannot
    /// draw the card, the card's own copy said in prose, so Telegram, Slack and
    /// the bridge never get an empty reply. The Mac and iPhone say nothing extra:
    /// the card is drawn there, and repeating it in prose would double it up.
    package static func waitingReply(visible: String) -> String {
        let prose = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let execution = ChatTurnExecution.current,
              let need = execution.waitingInteraction
        else { return prose }
        // Every surface persists the card-lane row; expanded transport prose stays out of the transcript.
        let row = prose.isEmpty ? need.cardLaneProse : prose
        execution.keepWaitingRow(row, synthesized: prose.isEmpty)
        // Card-rendering surfaces keep her prose when present and add no transport explanation.
        guard ChatToolSessionContext.replyIsTextOnly else { return row }
        let spoken = need.textLaneProse
        guard !spoken.isEmpty else { return prose }
        let suffix = prose.isEmpty ? spoken : "\n\n" + spoken
        // Progress carries the synthesized suffix before the execution scope ends.
        execution.keepStreamSuffix(suffix)
        return prose + suffix
    }

    /// The text-lane sentence `waitingReply` added, consumed once through progress.
    private var streamSuffix: String?
    package func keepStreamSuffix(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        streamSuffix = text
    }
    package static func takeStreamSuffix() -> String? {
        guard let execution = ChatTurnExecution.current else { return nil }
        execution.lock.lock(); defer { execution.lock.unlock() }
        defer { execution.streamSuffix = nil }
        return execution.streamSuffix
    }

    /// What the TRANSCRIPT keeps for this turn, given the reply the transport
    /// is getting. Identical unless the turn ended waiting on a card, in which
    /// case the row is the one-sentence card-lane prose `waitingReply` already
    /// computed — the card carries the rest.
    package static func transcriptReply(_ reply: String) -> String {
        ChatTurnExecution.current?.waitingTranscriptRow ?? reply
    }

    /// The writer marks synthesized card rows as mechanical; text matching never determines provenance.
    package static var transcriptReplyIsCardLane: Bool {
        ChatTurnExecution.current?.waitingTranscriptRowIsSynthesized ?? false
    }
}
