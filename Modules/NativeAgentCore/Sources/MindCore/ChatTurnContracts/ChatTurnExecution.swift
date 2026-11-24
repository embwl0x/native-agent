import Synchronization
import MacNerves
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `ChatTurnExecution.swift` | `ChatTurnExecution` class; `keepCapabilityNote` |

package final class ChatTurnExecution: Sendable {
    private struct State {
        var waiting = false
        var filedPromise = false
        var capabilityNote: String?
        var attachedPixels: [String: (fingerprint: String, frameID: String, image: String)] = [:]
        var records: [ToolDispatchRecord] = []
        var pending: JSONValue?
        var pendingID: String?
        var pendingInteraction: String?
        var pendingNeed: InlineInteraction?
        var waitingRow: String?
        var waitingRowSynthesized = false
        var streamSuffix: String?
    }
    private let state = Mutex(State())
    /// The caller marks mechanical bot rows explicitly; the surface cannot distinguish person-authored input.
    private let invocationRow: CognitiveMechanicalRowKind?
    package init(mechanicalRow: CognitiveMechanicalRowKind? = nil) {
        self.invocationRow = mechanicalRow
    }
    package var transcriptRowKind: CognitiveMechanicalRowKind? { invocationRow }
    package var hasFiledPromise: Bool { state.withLock { $0.filedPromise } }
    package func noteFiledPromise() { state.withLock { $0.filedPromise = true } }
    package func keepCapabilityNote(_ note: String) { state.withLock { $0.capabilityNote = note } }
    package func statusDetail(_ detail: String?) -> String? {
        state.withLock { state in
            let text = [detail, state.capabilityNote].compactMap { $0 }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }
    /// A matching source fingerprint reuses the window's frame while its image remains in context.
    package func attachedPixelFrame(window: String, fingerprint: String) -> String? {
        state.withLock { state in
            guard let attached = state.attachedPixels[window], attached.fingerprint == fingerprint else { return nil }
            return attached.frameID
        }
    }
    /// `image` names the attached picture; nil keeps the one already attached.
    package func notePixelsAttached(window: String, fingerprint: String, frameID: String, image: String? = nil) {
        state.withLock { state in
            guard let image = image ?? state.attachedPixels[window]?.image else { return }
            state.attachedPixels[window] = (fingerprint, frameID, image)
        }
    }
    /// A released or replaced context image cannot identify its window.
    package func keepPixels(_ images: Set<String>) {
        state.withLock { state in
            state.attachedPixels = state.attachedPixels.filter { images.contains($0.value.image) }
        }
    }
    package var toolRecords: [ToolDispatchRecord] { state.withLock { $0.records } }
    package func keepTools(_ values: [ToolDispatchRecord]) { state.withLock { $0.records += values } }
    package var pendingApproval: JSONValue? { state.withLock { $0.pending } }
    /// Carry the exact approval ID so waiting bot work can reconcile against the canonical decision.
    package var pendingApprovalID: String? { state.withLock { $0.pendingID } }
    package func keepApproval(id: String, _ value: JSONValue) {
        state.withLock { state in
            state.pending = value; state.pendingID = id; state.waiting = true
        }
    }
    package var waitingForApproval: Bool { state.withLock { $0.waiting } }
    package func waitForApproval() { state.withLock { $0.waiting = true } }

    // MARK: Inline interactions
    // A need stops every surface's tool loop to avoid repeatedly hitting the missing dependency.
    // Carry its durable ID so resolution can resume the same interaction once after relaunch.
    /// Text-only routes must say the card's own copy instead of sending silence.
    package var waitingInteraction: InlineInteraction? { state.withLock { $0.pendingNeed } }
    package var waitingForInteraction: Bool { state.withLock { $0.pendingInteraction != nil } }
    /// Compute transcript card prose once so persistence and transport share the same sentence.
    package var waitingTranscriptRow: String? { state.withLock { $0.waitingRow } }
    package func keepWaitingRow(_ row: String, synthesized: Bool = false) {
        state.withLock { state in
            state.waitingRow = row
            state.waitingRowSynthesized = synthesized
        }
    }
    /// Only synthesized card prose is mechanical to the felt organ; model-authored prose remains experience.
    package var waitingTranscriptRowIsSynthesized: Bool {
        state.withLock { state in
            return state.waitingRow != nil && state.waitingRowSynthesized
        }
    }
    /// First need wins: the turn suspends on the one the person is being shown,
    /// and a later round cannot overwrite which interaction is being awaited.
    package func waitForInteraction(_ need: InlineInteraction) {
        state.withLock { state in
            guard state.pendingInteraction == nil else { return }
            state.pendingInteraction = need.id
            state.pendingNeed = need
        }
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
    package func keepStreamSuffix(_ text: String) {
        state.withLock { state in
            state.streamSuffix = text
        }
    }
    package func takeStreamSuffix() -> String? {
        state.withLock { state in
            defer { state.streamSuffix = nil }
            return state.streamSuffix
        }
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
