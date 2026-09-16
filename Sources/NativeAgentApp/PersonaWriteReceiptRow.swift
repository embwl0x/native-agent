import SwiftUI

/// The settled receipt for a line the agent wrote into its own persona.
///
/// One mark, one line, and metadata naming the document and the section — the
/// grammar `InlineCardReceipt` already carries everywhere else in the room, so
/// this adds no new furniture (mockups/onboarding/flow.md: "the only piece of
/// furniture in the entire flow is the settled receipt already in the tree").
///
/// It renders where the write happened, directly under the answer that produced
/// it, rather than inside the turn's collapsed tool fold. See
/// `ChatShellToolSummary.personaReceipt` for which calls qualify; anything that
/// does not returns nil there and keeps its ordinary row.
struct PersonaWriteReceiptRow: View {
    var message: ChatMessage
    /// The exact section title the first conversation's exemption was armed
    /// with, read once per transcript by the caller rather than per row.
    var exemptTitle: String?

    /// Nil for every tool call that is not THE first conversation's own write.
    ///
    /// Sol P2-10: this used to fire for any successful `persona_append_section`
    /// in any conversation, so an ordinary growth write months later was
    /// promoted out of its quiet fold into a ceremonial receipt nobody asked
    /// for. The receipt belongs to the one write the opener exists to make, and
    /// the way to know that write is the exact section title the exemption was
    /// armed with — recorded on disk beside the persona documents, live or
    /// spent. No title recorded means no first conversation, and no receipt.
    static func receipt(
        for message: ChatMessage,
        exemptTitle: String?
    ) -> (outcome: String, meta: String)? {
        guard let exemptTitle, !exemptTitle.isEmpty else { return nil }
        let status = ChatShellToolSummary.status(
            kind: message.metadata?.kind,
            ok: message.metadata?.ok,
            resultSummary: message.metadata?.resultSummary,
            resultStatus: message.metadata?.resultStatus,
            interactionState: message.metadata?.interactionState
        )
        guard let receipt = ChatShellToolSummary.personaReceipt(
            toolName: message.metadata?.toolName,
            inputJSON: message.metadata?.inputJSON,
            status: status,
            requiredTitle: exemptTitle
        ) else { return nil }
        return receipt
    }

    var body: some View {
        if let receipt = Self.receipt(for: message, exemptTitle: exemptTitle) {
            InlineCardReceipt(
                mark: .done,
                outcome: receipt.outcome,
                meta: receipt.meta
            )
            .frame(maxWidth: NativeAgentShellLayout.replyMaxWidth, alignment: .leading)
        }
    }
}
