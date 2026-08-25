import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.TrustCenter.featurePermissionsGrid
@Suite("Trust Center feature permissions grid")
struct TrustFeaturePermissionsGridEvalTests {
    @Test("the mounted card registry is exhaustive, unique, and constructs every real permission view")
    func gridOwnsEveryDeclaredPermissionCard() {
        let cards = TrustFeaturePermissionCards.all
        #expect(cards.map(\.id) == TrustFeaturePermissionCardID.allCases)
        #expect(Set(cards.map(\.id)).count == TrustFeaturePermissionCardID.allCases.count)
        #expect(cards.map(\.title) == [
            "Multimodal", "Chrome Control", "Self-Improvement", "Desk Autonomy", "Living Memory",
        ])
        #expect(cards.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })

        for id in TrustFeaturePermissionCardID.allCases {
            // This calls the production card factory used by TrustCenterView.
            // A removed or unregistered child is nil rather than an empty card.
            #expect(TrustFeaturePermissionCards.content(for: id) != nil)
        }
    }
}
