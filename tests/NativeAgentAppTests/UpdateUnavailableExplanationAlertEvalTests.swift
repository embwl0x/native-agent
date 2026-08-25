import AppKit
import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.update.unavailableExplanationAlert
@MainActor
@Suite("Update unavailable explanation alert", .serialized)
struct UpdateUnavailableExplanationAlertEvalTests {
    @Test("an unpublished build retains an HTTPS release-page escape hatch")
    func unpublishedBuildShowsVersionedExplanationAndReleaseAction() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.4.1-dev.fixture",
            "NativeAgentUpdateFeedPublished": false,
            "NativeAgentReleasePageURL": "https://github.com/embwl0x/native-agent/releases",
        ]
        let presentation = UpdateUnavailableAlertPresentation.make(
            reason: .notConfigured,
            info: info
        )

        #expect(presentation.message == "Automatic updates aren’t available in this build.")
        #expect(presentation.informativeText.contains("NativeAgent 0.4.1-dev.fixture"))
        #expect(presentation.buttons.map(\.title) == ["OK", "Open Releases"])
        #expect(presentation.action(for: .alertSecondButtonReturn)
            == .openReleases(URL(string: "https://github.com/embwl0x/native-agent/releases")!))
    }

    @Test("release-page admission accepts only absolute HTTPS locations")
    func releasePageFilterRejectsInsecureAndAmbiguousValues() {
        func page(_ value: Any) -> URL? {
            UpdateUnavailableAlertPresentation.releasePageURL(in: [
                "NativeAgentReleasePageURL": value,
            ])
        }

        #expect(page("https://github.com/embwl0x/native-agent/releases")?.host == "github.com")
        #expect(page(" http://github.com/embwl0x/native-agent/releases ") == nil)
        #expect(page("github.com/embwl0x/native-agent/releases") == nil)
        #expect(page("https:") == nil)
        #expect(page(42) == nil)
    }

    @Test("the selected modal result maps through declared actions, not a hard-coded ordinal")
    func insertedButtonCannotAccidentallyOpenReleases() {
        let releaseURL = URL(string: "https://github.com/embwl0x/native-agent/releases")!
        let presentation = UpdateUnavailableAlertPresentation(
            message: "fixture",
            informativeText: "fixture",
            buttons: [
                .init(title: "OK", action: .dismiss),
                .init(title: "Copy Diagnostics", action: .dismiss),
                .init(title: "Open Releases", action: .openReleases(releaseURL)),
            ]
        )
        let thirdButton = NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2
        )

        #expect(presentation.action(for: .alertSecondButtonReturn) == .dismiss)
        #expect(presentation.action(for: thirdButton) == .openReleases(releaseURL))
    }
}
