import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.mac · main-window restart toolbar button", .serialized)
struct MainWindowRestartToolbarButtonEvalTests {
    @Test("restart action requires confirmation before it becomes a relaunch request")
    func restartRequestAndConfirmationAreOwnedByThePresentation() {
        var presentation: MainWindowRestartToolbarPresentation = .ready
        #expect(presentation.isActionEnabled)
        #expect(!presentation.showsConfirmation)
        presentation.beginRelaunch()
        #expect(presentation == .ready)

        presentation.requestConfirmation()
        #expect(presentation.showsConfirmation)
        presentation.cancelConfirmation()
        #expect(presentation == .ready)

        presentation.requestConfirmation()
        presentation.beginRelaunch()
        #expect(presentation == .relaunching)
        #expect(!presentation.isActionEnabled)
    }

    @Test("the real helper failure returns the confirmation flow to a visible retryable presentation")
    func relaunchHelperFailureReturnsToToolbarPresentation() {
        let invalidHelper = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-relaunch-helper-\(UUID().uuidString)")
        var presentation: MainWindowRestartToolbarPresentation = .ready
        presentation.requestConfirmation()
        presentation.beginRelaunch()

        AppRelauncher.relaunchApp(
            helperExecutableURL: invalidHelper,
            onSpawnFailure: { presentation.markStartFailure() }
        )

        #expect(presentation == .failedToStart)
        #expect(presentation.isActionEnabled)
        #expect(
            presentation.failureMessage == "Restart couldn't start. NativeAgent is still running — try again.",
            "the real Process launch failure must be routed back instead of terminating the app"
        )
    }
}
