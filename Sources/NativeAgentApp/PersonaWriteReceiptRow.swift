import EngineRuntime
import SwiftUI

// Blueprint: | `PersonaWriteReceiptRow.swift` | `PersonaWriteReceiptRow`: settled persona-write receipt projection using the existing inline receipt grammar |

/// The settled persona-write receipt uses `InlineCardReceipt` under the producing answer.
/// `ChatShellToolSummary.personaReceipt` qualifies writes; other calls keep their ordinary row.
struct PersonaWriteReceiptRow: View {
    let outcome: String
    let meta: String

    /// Only the first conversation's successful write with its exact exempted title qualifies.
    static func receipt(
        for message: ChatMessage,
        exemptTitle: String?
    ) -> (outcome: String, meta: String)? {
        guard let exemptTitle, !exemptTitle.isEmpty,
              message.metadata?.toolName == "persona_append_section" || message.metadata?.toolName == "app" else { return nil }
        guard let receipt = ChatShellToolSummary.personaReceipt(
            toolName: message.metadata?.toolName,
            inputJSON: message.metadata?.inputJSON,
            resultSummary: message.metadata?.resultSummary,
            requiredTitle: exemptTitle
        ) else { return nil }
        return receipt
    }

    var body: some View {
        InlineCardReceipt(mark: .done, outcome: outcome, meta: meta)
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
    }
}
