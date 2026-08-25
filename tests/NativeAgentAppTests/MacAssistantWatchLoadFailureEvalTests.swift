import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.macAssistantWatch.loadFailure
@MainActor
@Suite("Mac Assistant Watch load failure", .serialized)
struct MacAssistantWatchLoadFailureEvalTests {
    @Test("a failed first read leaves Assistant Watch unavailable instead of loading")
    func firstLoadFailureLeavesNoLoadingBadge() {
        let failure = "Couldn’t refresh Assistant Watch setup: fixture watch status unavailable"
        let state = MacAssistantWatchSetupLoadState.loading.afterFailure(failure)

        #expect(state == .unavailable(message: failure))
        #expect(state.badgeText == "Unavailable")
        #expect(state.badgeStatus == "failed")
        #expect(state.diagnosticText == failure)
        #expect(state.response == nil)
    }

    @Test("a refresh failure retains inventory but marks it stale")
    func refreshFailureAfterSuccessRetainsAttentionInventoryAsStale() throws {
        let inventory = try fixtureStatus()
        let failure = "Couldn’t refresh Assistant Watch setup: fixture watch status unavailable"
        let state = MacAssistantWatchSetupLoadState.current(inventory).afterFailure(failure)

        #expect(state == .stale(inventory, message: failure))
        #expect(state.badgeText == "Stale")
        #expect(state.badgeStatus == "attention")
        #expect(state.diagnosticText == failure)
        #expect(state.response == inventory)
        #expect(state.response?.watchTemplates.map(\.title) == ["Fixture Daily Watch"])
        #expect(state.response?.templateAttentionCount == 2)
    }

    private func fixtureStatus() throws -> MacAssistantStatusResponse {
        try JSONDecoder().decode(MacAssistantStatusResponse.self, from: Data("""
        {
          "status": "attention",
          "summary": "Fixture status needs two setup steps.",
          "access": [{
            "id": "local_calendar",
            "title": "Fixture Calendar",
            "status": "needs_permission"
          }],
          "watchTemplates": [{
            "id": "fixture_daily_watch",
            "title": "Fixture Daily Watch",
            "status": "needs_permission"
          }],
          "templateAttentionCount": 2,
          "createsJobs": false
        }
        """.utf8))
    }

}
