import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.advancedDisclosure
@Suite("Trust Center Advanced disclosure behavior")
struct TrustCenterAdvancedDisclosureBehaviorEvalTests {
    @Test("collapsed Advanced distinguishes loading, successful emptiness, and unavailable reads")
    func collapsedDisclosureDoesNotCallAnUnreadRegistryEmpty() {
        let loading = TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: false,
            hasPrivacyMap: false,
            backupCount: 0,
            backupBeforeWriteEnabled: nil,
            hasRefreshAttempt: false,
            failedEndpoints: []
        )
        #expect(loading.policy == .loading)
        #expect(loading.privacyMap == .loading)
        #expect(loading.backups == .loading)
        #expect(loading.collapsedBadge == .init(text: "Loading", status: "info"))

        let emptyAfterRead = TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: true,
            hasPrivacyMap: true,
            backupCount: 0,
            backupBeforeWriteEnabled: true,
            hasRefreshAttempt: true,
            failedEndpoints: []
        )
        #expect(emptyAfterRead.backups == .available)
        #expect(emptyAfterRead.collapsedBadge == nil)

        let unavailable = TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: true,
            hasPrivacyMap: false,
            backupCount: 0,
            backupBeforeWriteEnabled: true,
            hasRefreshAttempt: true,
            failedEndpoints: [" privacy map ", "backups"]
        )
        #expect(unavailable.privacyMap == .unavailable)
        #expect(unavailable.backups == .unavailable)
        #expect(unavailable.collapsedBadge == .init(text: "Details unavailable", status: "warn"))
    }

    @Test("collapsed Advanced retains warning truth for stale evidence and disabled backups")
    func disclosureSurfacesRiskWithoutOpeningEveryPanel() {
        let stale = TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: true,
            hasPrivacyMap: true,
            backupCount: 2,
            backupBeforeWriteEnabled: true,
            hasRefreshAttempt: true,
            failedEndpoints: ["privacy map", "backups"]
        )
        #expect(stale.privacyMap == .stale)
        #expect(stale.backups == .stale)
        #expect(stale.collapsedBadge == .init(text: "Details stale", status: "warn"))

        let backupsOff = TrustCenterAdvancedDisclosurePresentation.resolve(
            hasPolicy: true,
            hasPrivacyMap: true,
            backupCount: 0,
            backupBeforeWriteEnabled: false,
            hasRefreshAttempt: true,
            failedEndpoints: []
        )
        #expect(backupsOff.collapsedBadge == .init(text: "Backups off", status: "warn"))
    }
}
