import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.inboxPolicy.triggersPanelGate
@Suite("Desk inbox policy trigger panel gate")
struct DeskInboxPolicyTriggersPanelGateEvalTests {
    @Test("trust read result, not a default false, determines the trigger panel")
    func trustReadHasDistinctEnabledDisabledAndUnavailableGates() {
        #expect(InboxPolicyTriggersPanelGate.resolve(trustRead: .loading) == .loading)
        #expect(InboxPolicyTriggersPanelGate.resolve(trustRead: .loaded(enabled: true)) == .enabled)
        #expect(InboxPolicyTriggersPanelGate.resolve(trustRead: .loaded(enabled: false)) == .disabled)
        #expect(InboxPolicyTriggersPanelGate.resolve(trustRead: .unavailable("permission denied"))
            == .unavailable("permission denied"))
    }

    @Test("mounted policy view renders failed trust reads as unavailable rather than disabled")
    func inboxPolicyViewUsesTrustReadGate() throws {
        let source = try AppSourceScraping.appSource("InboxSettingsView.swift")
        #expect(source.contains("@State private var trustReadState: InboxPolicyTrustReadState = .loading"))
        #expect(source.contains("InboxPolicyTriggersPanelGate.resolve(trustRead: trustReadState)"))
        #expect(source.contains("trustReadState = .unavailable(error.localizedDescription)"))
        #expect(source.contains("case .unavailable(let detail):"))
        #expect(source.contains("NativePanel(title: \"Triggers unavailable\""))
        #expect(source.contains("Trigger settings are unavailable, not disabled."))
        #expect(!source.contains("if masterEnabled {"))
    }
}
