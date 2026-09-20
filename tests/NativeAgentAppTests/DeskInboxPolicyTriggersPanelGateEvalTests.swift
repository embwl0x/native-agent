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
        // 2026-09-06: f4ba3bd8 ("Advanced page kit") re-framed this page on the
        // new shell's section kit — the panel is an `InboxSection` now and the
        // copy says the same thing in a sentence (InboxSettingsView.swift:358).
        // The eval's claim is the unavailable arm reads as unavailable, not off.
        #expect(source.contains("InboxSection(title: \"When the agent sends a notification\")"))
        #expect(source.contains("Notification options are unavailable until it can be loaded."))
        #expect(!source.contains("if masterEnabled {"))
    }
}
