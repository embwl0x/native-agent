import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.statusText

@Suite("Provider Settings status text")
struct ProviderSettingsStatusTextEvalTests {
    @Test("provider status text distinguishes loading, saved, repair, and failure outcomes")
    func visibleStatusUsesTheOperationOutcomeRatherThanOneNeutralStyle() throws {
        #expect(ProviderSettingsStatusTextPresentation.state(for: "   \n ") == nil)
        #expect(ProviderSettingsStatusTextPresentation.state(
            for: "Providers loaded at 10:42 AM"
        ) == .init(
            text: "Providers loaded at 10:42 AM",
            tone: .info,
            systemImage: "info.circle",
            isTruncated: false
        ))
        #expect(ProviderSettingsStatusTextPresentation.state(
            for: "Saving Chat model…"
        )?.tone == .progress)
        #expect(ProviderSettingsStatusTextPresentation.state(
            for: "Chat → openai, gpt-5 / High saved"
        )?.tone == .success)
        #expect(ProviderSettingsStatusTextPresentation.state(
            for: "Provider settings need repair before every saved surface can be configured."
        )?.tone == .warning)
        #expect(ProviderSettingsStatusTextPresentation.state(
            for: "Set active failed: policy writer denied the change"
        ) == .init(
            text: "Set active failed: policy writer denied the change",
            tone: .failure,
            systemImage: "exclamationmark.triangle.fill",
            isTruncated: false
        ))
    }

    @Test("an oversized adverse diagnostic remains a bounded failure instead of disappearing or looking healthy")
    func adverseDiagnosticIsBoundedWithoutChangingItsMeaning() throws {
        let state = try #require(ProviderSettingsStatusTextPresentation.state(
            for: "Load failed: " + String(repeating: "x", count: 300)
        ))

        #expect(state.tone == .failure)
        #expect(state.systemImage == "exclamationmark.triangle.fill")
        #expect(state.isTruncated)
        #expect(state.text.hasPrefix("Load failed:"))
        #expect(state.text.hasSuffix("…"))
        #expect(state.text.count == ProviderSettingsStatusTextPresentation.maximumVisibleCharacters + 1)
    }
}
