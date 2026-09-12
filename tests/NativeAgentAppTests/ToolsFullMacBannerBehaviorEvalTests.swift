import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.fullMacBanner
//
// 2026-09-10: Full Mac has no timer, so the banner has three states — on
// (silent), off, and "the loaded catalog disagrees with Trust".
@Suite("Tools Full Mac banner behavior")
struct ToolsFullMacBannerBehaviorEvalTests {
    @Test("the banner stays hidden only when catalog and Trust agree Full Mac is on")
    func activeCatalogDoesNotNeedABanner() {
        #expect(ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: true,
            trustFullMacActive: true,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false
        ) == nil)
    }

    @Test("locked tools distinguish off from an unread Trust policy")
    func lockedCatalogExplainsTheActualState() {
        let off = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            trustFullMacActive: false,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false
        )
        #expect(off?.title == "Full Mac is off")
        #expect(off?.detail.contains("policy-locked") == true)

        let notLoaded = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            trustFullMacActive: nil,
            hasTrustRefreshAttempt: false,
            trustPolicyReadFailed: false
        )
        #expect(notLoaded?.title == "Full Mac tools are locked")
        #expect(notLoaded?.detail.contains("has not loaded yet") == true)

        let trustSaysOn = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            trustFullMacActive: true,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false
        )
        #expect(trustSaysOn?.title == "Full Mac tools are locked")
        #expect(trustSaysOn?.detail.contains("Refresh Tools") == true)
    }

    @Test("unavailable Trust evidence and a catalog-policy mismatch remain explicit")
    func bannerDoesNotInventAnOffState() {
        let unavailable = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            trustFullMacActive: nil,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: true
        )
        #expect(unavailable?.title == "Full Mac tools are locked")
        #expect(unavailable?.detail.contains("could not be refreshed") == true)

        let mismatch = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: true,
            trustFullMacActive: false,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false
        )
        #expect(mismatch?.title == "Full Mac status needs refresh")
        #expect(mismatch?.detail.contains("catalog still exposes") == true)
    }
}
