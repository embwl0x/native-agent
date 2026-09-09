import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.statusLine
@MainActor
@Suite("Slim Settings status line behavior")
struct SlimSettingsStatusLineBehaviorEvalTests {
    @Test("runtime truth does not inherit the last action string")
    func runtimeStateIsOwnedByLiveHealthAndRefreshEvidence() throws {
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["CAPABILITIES_COPY_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try CapabilitiesView.renderCopyReview(to: directory)
            try PersonalityView.renderCopyReview(to: directory)
        }
        #endif
        let unchecked = SlimSettingsStatusLinePresentation.runtimeState(
            runtimeOK: nil,
            lastRefreshError: nil
        )
        #expect(unchecked.text == "App status has not been checked")
        #expect(unchecked.tone == .neutral)
        #expect(unchecked.detail == nil)

        let online = SlimSettingsStatusLinePresentation.runtimeState(
            runtimeOK: true,
            lastRefreshError: nil
        )
        #expect(online.text == "App is online")
        #expect(online.tone == .success)

        let partial = SlimSettingsStatusLinePresentation.runtimeState(
            runtimeOK: true,
            lastRefreshError: "getInboxItems: permission denied"
        )
        #expect(partial.text == "App is online; some app data is unavailable")
        #expect(partial.tone == .warning)
        #expect(partial.detail == "Last refresh error: getInboxItems: permission denied")

        let unavailable = SlimSettingsStatusLinePresentation.runtimeState(
            runtimeOK: nil,
            lastRefreshError: "health: connection refused"
        )
        #expect(unavailable.text == "App status is unavailable")
        #expect(unavailable.tone == .failure)
        #expect(unavailable.detail == "Last refresh error: health: connection refused")
    }

    @Test("a Settings action keeps its own outcome instead of becoming a runtime claim")
    func settingsActionUsesItsScopedPresentation() {
        let runtime = SlimSettingsStatusLinePresentation.runtimeState(
            runtimeOK: true,
            lastRefreshError: nil
        )
        let updateAction = SoftwareUpdateRowPresentation.resolve(
            availableVersion: nil,
            updatesAreAvailable: false,
            canCheckForUpdates: false,
            unavailableDetail: UpdateController.Unavailability.notConfigured.detail
        )
        let unavailableOutcome = UpdateUnavailableAlertPresentation.make(
            reason: .notConfigured,
            info: [:]
        )

        #expect(runtime.text == "App is online")
        #expect(updateAction.title == "Automatic updates aren’t available in this build")
        #expect(updateAction.actionEnabled)
        #expect(unavailableOutcome.message == "Automatic updates aren’t available in this build.")
        #expect(unavailableOutcome.informativeText.contains("locally-built copy"))
        #expect(unavailableOutcome.buttons.map(\.title) == ["OK"])
    }
}
