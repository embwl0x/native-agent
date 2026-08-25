import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.macControl.setupStatusBadges
@Suite("Mac Control setup status badges")
struct MacControlSetupStatusBadgesEvalTests {
    @Test("setup badges never claim readiness while policy evidence is loading or unavailable")
    func unavailableAndLoadingStatesStayExplicit() {
        let loading = MacControlSetupStatusBadges.resolve(readState: .loading, savedPolicy: nil)
        #expect(loading.access == MacControlSetupStatusBadges.Badge(text: "Checking setup", status: "unknown"))
        #expect(loading.iOSRemote == MacControlSetupStatusBadges.Badge(text: "iOS remote unknown", status: "unknown"))
        #expect(loading.receipts == MacControlSetupStatusBadges.Badge(text: "receipts unknown", status: "unknown"))

        let unavailable = MacControlSetupStatusBadges.resolve(readState: .unavailable, savedPolicy: nil)
        #expect(unavailable.access == MacControlSetupStatusBadges.Badge(text: "Setup unavailable", status: "failed"))
        #expect(unavailable.detail.contains("could not read"))

        let missingBlock = MacControlSetupStatusBadges.resolve(readState: .available, savedPolicy: nil)
        #expect(missingBlock.access == MacControlSetupStatusBadges.Badge(text: "Setup unavailable", status: "failed"))
        #expect(missingBlock.detail.contains("did not include"))
    }

    @Test("configured badges derive from the persisted policy, not an unsaved draft")
    func persistedPolicyControlsSetupBadges() {
        let savedOff = TrustMacControlPolicy(enabled: false, notificationsAllowed: true, remoteFromIosAllowed: false)
        let off = MacControlSetupStatusBadges.resolve(readState: .available, savedPolicy: savedOff)
        #expect(off.access == MacControlSetupStatusBadges.Badge(text: "Mac Control off", status: "disabled"))
        #expect(off.iOSRemote == MacControlSetupStatusBadges.Badge(text: "iOS remote off", status: "disabled"))
        #expect(off.receipts == MacControlSetupStatusBadges.Badge(text: "receipts off", status: "disabled"))

        let savedWatch = TrustMacControlPolicy(enabled: true, notificationsAllowed: true)
        let watch = MacControlSetupStatusBadges.resolve(readState: .available, savedPolicy: savedWatch)
        #expect(watch.access == MacControlSetupStatusBadges.Badge(text: "Watch configured", status: "ready"))
        #expect(watch.receipts == MacControlSetupStatusBadges.Badge(text: "receipts on", status: "ready"))

        let savedAssistant = TrustMacControlPolicy(
            enabled: true,
            fileOpsAllowed: true,
            notificationsAllowed: true,
            remoteFromIosAllowed: true
        )
        let assistant = MacControlSetupStatusBadges.resolve(readState: .available, savedPolicy: savedAssistant)
        #expect(assistant.access == MacControlSetupStatusBadges.Badge(text: "Assistant configured", status: "ready"))
        #expect(assistant.iOSRemote == MacControlSetupStatusBadges.Badge(text: "iOS remote on", status: "ready"))
        #expect(assistant.receipts == MacControlSetupStatusBadges.Badge(text: "receipts on", status: "ready"))

        let savedFull = TrustMacControlPolicy(
            enabled: true,
            accessibilityAllowed: true,
            fileOpsAllowed: true,
            shellAllowed: true,
            notificationsAllowed: false,
            approvalRequiredFor: []
        )
        let full = MacControlSetupStatusBadges.resolve(readState: .available, savedPolicy: savedFull)
        #expect(full.access == MacControlSetupStatusBadges.Badge(text: "Full Mac configured", status: "ready"))
        #expect(full.receipts == MacControlSetupStatusBadges.Badge(text: "receipts off", status: "disabled"))
    }
}
