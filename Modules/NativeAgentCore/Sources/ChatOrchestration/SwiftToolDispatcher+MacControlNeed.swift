import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

extension SwiftToolDispatcher {
    /// The Trust Full-Mac category gate, raised as a CARD instead of prose.
    ///
    /// The MacIntegration capabilities have asked this way since the wiring
    /// landed; the Mac Control categories (`file_ops`, `shell`, `applescript`,
    /// …) still answered with a sentence telling the person to go and find a
    /// switch. Both are the same thing — a decision the person has not made
    /// yet — so both are asked where the work is.
    ///
    /// Two rules this keeps:
    ///
    ///  * **The mode travels.** A blocked READ raises a read need, and the
    ///    grant says so. A refused read must never be settled by handing over
    ///    write as well.
    ///  * **The posture is never touched.** Safe and Workspace are the
    ///    person's standing choice; under them the descriptor resolves to
    ///    `trustPostureRequired` and the card can only offer Trust itself.
    ///    Nothing here writes a posture.
    ///
    /// Returns nil when the category is already allowed — then the refusal is
    /// about something else and keeps its own envelope.
    func macControlCategoryNeedEnvelope(
        category: String,
        mode: InlineInteraction.AccessMode,
        why: String,
        declineConsequence: String? = nil
    ) -> JSONValue? {
        guard InlineInteractionRegistry.isMacControlCategory(category) else { return nil }
        guard !InlineInteractionRegistry.macControlCategoryAllowed(category, dataRoot: dataRoot)
        else { return nil }
        guard let need = InlineInteractionRegistry.permission(
            [category], why: why, mode: mode, declineConsequence: declineConsequence
        ) else { return nil }
        return InlineInteractionNeed.envelope(need)
    }

    /// The shell-class gate. Same decision, same card; the prose envelope is
    /// what is left when the category is already on (so the refusal is about
    /// something else) or the person's posture forbids raising it at all.
    func builderFullMacRequired(tool: String) -> JSONValue {
        macControlCategoryNeedEnvelope(
            category: "file_ops",
            mode: .write,
            why: "\(tool) runs on your Mac, and file access is off right now.",
            declineConsequence:
                "I won't run \(tool), and I'll tell you what I couldn't do without it."
        ) ?? Self.builderFullMacRequiredEnvelope(tool: tool)
    }

    /// The file-tool flavour: only a refusal the person could actually lift
    /// becomes a card. A path denial inside a sensitive sub-tree, a missing
    /// argument, or a workspace escape is a FAILURE and stays one — allowing
    /// file access would not make any of them work.
    func fileOpsNeedEnvelope(
        tool: String,
        mode: InlineInteraction.AccessMode,
        path: String?,
        error: Error
    ) -> JSONValue? {
        guard case AutonomyGateError.toolDenied(let reason) = error,
              reason.contains("outside trusted workspace roots")
        else { return nil }
        let named = (path?.isEmpty == false) ? path! : "that file"
        let verb = mode == .read ? "read" : "change"
        return macControlCategoryNeedEnvelope(
            category: "file_ops",
            mode: mode,
            why: "\(named) is outside the folders I can reach, so \(tool) stopped before touching it.",
            declineConsequence:
                "I won't \(verb) anything outside your workspace, and I'll tell you what I couldn't do."
        )
    }
}
