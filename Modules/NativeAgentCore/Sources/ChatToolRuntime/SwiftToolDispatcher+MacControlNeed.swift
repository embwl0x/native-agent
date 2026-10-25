import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+MacControlNeed.swift` | `SwiftToolDispatcher`: `macControlCategoryNeedEnvelope`, `builderFullMacRequired`, `fileOpsNeedEnvelope` |

extension SwiftToolDispatcher {
    /// Trust category refusals share one card path, preserving the requested
    /// axis and leaving posture changes to the owner in Trust. Already-allowed
    /// categories cannot explain a refusal and keep their original error.
    func macControlCategoryNeedEnvelope(
        categories: [String],
        mode: InlineInteraction.AccessMode,
        why: String,
        declineConsequence: String? = nil
    ) -> JSONValue? {
        guard !categories.isEmpty, categories.allSatisfy(InlineInteractionRegistry.isMacControlCategory)
        else { return nil }
        guard categories.contains(where: {
            !InlineInteractionRegistry.macControlCategoryAllowed($0, dataRoot: dataRoot)
        }) else { return nil }
        guard let need = InlineInteractionRegistry.permission(
            categories, why: why, mode: mode, declineConsequence: declineConsequence
        ) else { return nil }
        return InlineInteractionNeed.envelope(need)
    }

    /// The shell-class gate. Same decision, same card; the prose envelope is
    /// what is left when the category is already on (so the refusal is about
    /// something else) or the person's posture forbids raising it at all.
    func builderFullMacRequired(tool: String) -> JSONValue {
        macControlCategoryNeedEnvelope(
            categories: ["file_ops"],
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
        guard case AutonomyGateError.toolDenied(let reason, _) = error,
              reason.contains("outside trusted workspace roots")
        else { return nil }
        let named = (path?.isEmpty == false) ? path! : "that file"
        let verb = mode == .read ? "read" : "change"
        return macControlCategoryNeedEnvelope(
            categories: ["file_ops"],
            mode: mode,
            why: "\(named) is outside the folders I can reach, so \(tool) stopped before touching it.",
            declineConsequence:
                "I won't \(verb) anything outside your workspace, and I'll tell you what I couldn't do."
        )
    }
}
