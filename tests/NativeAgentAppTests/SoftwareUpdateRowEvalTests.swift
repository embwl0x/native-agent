import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.mac · Settings software update row", .serialized)
struct SoftwareUpdateRowEvalTests {
    @Test("the row distinguishes an available update, ready feed, active check, and unavailable build")
    func updateRowStatesAreHonest() {
        let available = SoftwareUpdateRowPresentation.resolve(
            availableVersion: "2.4.0", updatesAreAvailable: true, canCheckForUpdates: true, unavailableDetail: "unused"
        )
        #expect(available.title == "NativeAgent 2.4.0 is available")
        #expect(available.actionEnabled)

        let ready = SoftwareUpdateRowPresentation.resolve(
            availableVersion: nil, updatesAreAvailable: true, canCheckForUpdates: true, unavailableDetail: "unused"
        )
        #expect(ready.status == "ok")
        #expect(ready.actionEnabled)

        let checking = SoftwareUpdateRowPresentation.resolve(
            availableVersion: nil, updatesAreAvailable: true, canCheckForUpdates: false, unavailableDetail: "unused"
        )
        #expect(checking.status == "info")
        #expect(!checking.actionEnabled)

        let unavailable = SoftwareUpdateRowPresentation.resolve(
            availableVersion: nil, updatesAreAvailable: false, canCheckForUpdates: false,
            unavailableDetail: "This build has no published update feed."
        )
        #expect(unavailable.status == "warn")
        #expect(unavailable.actionEnabled)
        #expect(unavailable.detail.contains("no published update feed"))
    }

    @Test("the unavailable update row preserves its honest explanation and recovery action")
    func unavailableRowShowsActionAndUnavailability() throws {
        let row = SoftwareUpdateRowPresentation.resolve(
            availableVersion: nil, updatesAreAvailable: false, canCheckForUpdates: false,
            unavailableDetail: "This locally-built copy has no updater configuration."
        )
        #expect(row.title == "Automatic updates aren’t available in this build")
        #expect(row.detail.contains("no updater configuration"))
        #expect(row.actionEnabled)

        let alert = UpdateUnavailableAlertPresentation.make(
            reason: .notConfigured,
            info: [
                "CFBundleShortVersionString": "2.4.0",
                "NativeAgentReleasePageURL": "https://github.com/example/NativeAgent/releases",
            ]
        )
        #expect(alert.message == row.title + ".")
        #expect(alert.informativeText.contains("NativeAgent 2.4.0"))
        #expect(alert.informativeText.contains("locally-built copy"))
        #expect(alert.buttons.first?.action == .dismiss)
        let releaseURL = try #require(URL(string: "https://github.com/example/NativeAgent/releases"))
        #expect(alert.buttons.last?.action == .openReleases(releaseURL))
    }
}
