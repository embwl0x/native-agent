import ChatToolParsing
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import CognitiveSubstrate
// Blueprint: | `ChatTurnExecution.swift` | `ChatTurnExecution` class; `keepCapabilityNote` |

package final class ChatTurnExecution: @unchecked Sendable {
    private let lock = NSLock()
    /// The caller marks mechanical bot rows explicitly; the surface cannot distinguish person-authored input.
    private let invocationRow: CognitiveMechanicalRowKind?
    package init(mechanicalRow: CognitiveMechanicalRowKind? = nil) {
        self.invocationRow = mechanicalRow
    }
    package var transcriptRowKind: CognitiveMechanicalRowKind? { invocationRow }
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
    /// A released or replaced context image cannot identify its window.
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
    /// Carry the exact approval ID so waiting bot work can reconcile against the canonical decision.
    package var pendingApprovalID: String? { lock.lock(); defer { lock.unlock() }; return pendingID }
    package func keepApproval(id: String, _ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        pending = value; pendingID = id; waiting = true
    }
    package var waitingForApproval: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    package func waitForApproval() { lock.lock(); defer { lock.unlock() }; waiting = true }

    // MARK: Inline interactions
    // A need stops every surface's tool loop to avoid repeatedly hitting the missing dependency.
    // Carry its durable ID so resolution can resume the same interaction once after relaunch.
    private var pendingInteraction: String?
    /// Text-only routes must say the card's own copy instead of sending silence.
    private var pendingNeed: InlineInteraction?
    package var waitingInteraction: InlineInteraction? { lock.lock(); defer { lock.unlock() }; return pendingNeed }
    package var waitingForInteraction: Bool { lock.lock(); defer { lock.unlock() }; return pendingInteraction != nil }
    /// Compute transcript card prose once so persistence and transport share the same sentence.
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

    /// Card-rendering routes keep model prose without repeating the card; text-only routes append its copy to avoid a silent reply.
    package static func waitingReply(visible: String, turn: Turn) -> String {
        let prose = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let execution = turn.execution,
              let need = execution.waitingInteraction
        else { return prose }
        // Every surface persists the card-lane row; expanded transport prose stays out of the transcript.
        let row = prose.isEmpty ? need.cardLaneProse : prose
        execution.keepWaitingRow(row, synthesized: prose.isEmpty)
        // Card-rendering surfaces keep the agent's prose when present and add no transport explanation.
        guard turn.replyIsTextOnly else { return row }
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
    package func takeStreamSuffix() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { streamSuffix = nil }
        return streamSuffix
    }

    /// Persist the precomputed card-lane sentence for waiting turns; the card itself carries the remaining detail.
    package func transcriptReply(_ reply: String) -> String {
        waitingTranscriptRow ?? reply
    }

    /// The writer marks synthesized card rows as mechanical; text matching never determines provenance.
    package var transcriptReplyIsCardLane: Bool {
        waitingTranscriptRowIsSynthesized
    }
}
