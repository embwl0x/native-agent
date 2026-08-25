import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.openSlackSettingsButton
@Suite("Slack settings browser handoff", .serialized)
struct ProviderSettingsOpenSlackSettingsButtonEvalTests {
    @Test("the mounted Slack settings action requests the exact Slack Apps portal")
    func opensSlackAppsPortalThroughTheInjectedSystemHandoff() {
        var requestedURL: URL?
        let outcome = SlackSettingsPortal.open { url in
            requestedURL = url
            return true
        }

        #expect(requestedURL == URL(string: "https://api.slack.com/apps"))
        #expect(outcome == .requested)
        #expect(outcome.message == "Requested Slack Apps in your default browser.")
    }

    @Test("a rejected system handoff stays visibly unavailable")
    func refusedBrowserHandoffDoesNotClaimSlackAppsOpened() {
        let outcome = SlackSettingsPortal.open { _ in false }

        #expect(outcome == .unavailable)
        #expect(outcome.message.contains("Could not open Slack Apps"))
        #expect(outcome.message.contains("api.slack.com/apps"))
    }
}
