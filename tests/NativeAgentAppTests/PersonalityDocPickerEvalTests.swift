import Testing
@testable import NativeAgentApp
import NativeAgentShared

private func personalityPickerDocument(
    id: String,
    content: String
) -> PersonalityDoc {
    PersonalityDoc(
        id: id,
        title: id.capitalized,
        filename: "\(id).md",
        content: content
    )
}

@Suite("Personality document picker drafts")
struct PersonalityDocPickerEvalTests {
    // app.mind / ui.personality.docPicker
    @Test("select edit select-other preserves each document's unsaved draft")
    func draftsSurviveDocumentSwitchesAndReloadReconciliation() {
        let soul = personalityPickerDocument(id: "SOUL", content: "Canonical soul")
        let voice = personalityPickerDocument(id: "VOICE", content: "Canonical voice")
        let documents = [soul, voice]
        var state = PersonalityDocumentDraftState()

        #expect(state.reconcile(documents: documents) == "Canonical soul")
        #expect(state.selectedDocumentID == "SOUL")

        state.recordEdit("Unsaved soul", documents: documents)
        #expect(state.hasUnsavedDrafts)
        #expect(state.select("VOICE", documents: documents) == "Canonical voice")

        state.recordEdit("Unsaved voice", documents: documents)
        #expect(state.select("SOUL", documents: documents) == "Unsaved soul")
        #expect(state.select("VOICE", documents: documents) == "Unsaved voice")

        // A successful reload may replace canonical bytes, but it must not
        // overwrite the unsaved buffer for either currently edited document.
        let reloaded = [
            personalityPickerDocument(id: "SOUL", content: "Reloaded soul"),
            personalityPickerDocument(id: "VOICE", content: "Reloaded voice"),
        ]
        #expect(state.reconcile(documents: reloaded) == "Unsaved voice")
        #expect(state.select("SOUL", documents: reloaded) == "Unsaved soul")
    }

    // app.mind / ui.personality.docPicker
    @Test("empty or malformed catalogs leave no fake editable selection")
    func malformedCatalogFailsClosedWithoutDiscardingAStoredDraft() {
        let soul = personalityPickerDocument(id: "SOUL", content: "Canonical soul")
        var state = PersonalityDocumentDraftState()
        _ = state.reconcile(documents: [soul])
        state.recordEdit("Unsaved soul", documents: [soul])

        let malformed = personalityPickerDocument(id: " \n ", content: "bad")
        #expect(state.reconcile(documents: [malformed]).isEmpty)
        #expect(state.selectedDocumentID.isEmpty)
        #expect(state.hasUnsavedDrafts)

        // Once the valid catalog returns, the existing unsaved draft wins over
        // the reloaded canonical text rather than silently disappearing.
        let restored = personalityPickerDocument(id: "SOUL", content: "Reloaded soul")
        #expect(state.reconcile(documents: [restored]) == "Unsaved soul")
    }
}
