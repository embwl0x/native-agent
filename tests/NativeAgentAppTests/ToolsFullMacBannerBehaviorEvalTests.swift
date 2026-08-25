import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Tools.fullMacBanner
@Suite("Tools Full Mac banner behavior")
struct ToolsFullMacBannerBehaviorEvalTests {
    @Test("the banner stays hidden only when catalog and current lifecycle agree on active access")
    func activeCatalogDoesNotNeedABanner() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: true,
            expiryState: .active(expiresAt: now.addingTimeInterval(3_600)),
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false,
            now: now
        ) == nil)
    }

    @Test("locked tools distinguish off expired and unread Trust policy states")
    func lockedCatalogExplainsTheActualLifecycle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let off = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            expiryState: .off,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false,
            now: now
        )
        #expect(off?.title == "Full Mac is off")
        #expect(off?.detail.contains("policy-locked") == true)

        let expired = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            expiryState: .expired(at: now.addingTimeInterval(-120)),
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false,
            now: now
        )
        #expect(expired?.title == "Full Mac is unavailable")
        #expect(expired?.detail.contains("EXPIRED") == true)

        let unreadable = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            expiryState: .unreadable,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false,
            now: now
        )
        #expect(unreadable?.detail.contains("timestamps unreadable") == true)
    }

    @Test("unavailable Trust evidence and a catalog-policy mismatch remain explicit")
    func bannerDoesNotInventAnOffState() {
        let unavailable = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: false,
            expiryState: nil,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: true
        )
        #expect(unavailable?.title == "Full Mac tools are locked")
        #expect(unavailable?.detail.contains("could not be refreshed") == true)

        let mismatch = ToolsFullMacBannerPresentation.state(
            catalogFullMacActive: true,
            expiryState: .off,
            hasTrustRefreshAttempt: true,
            trustPolicyReadFailed: false
        )
        #expect(mismatch?.title == "Full Mac status needs refresh")
        #expect(mismatch?.detail.contains("catalog still exposes") == true)
    }
}
