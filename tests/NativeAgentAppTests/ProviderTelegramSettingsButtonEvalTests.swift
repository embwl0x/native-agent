import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.ProviderSettings.openTelegramSettingsButton

@Suite("Provider Settings Telegram shortcut")
@MainActor
struct ProviderTelegramSettingsButtonEvalTests {
    @Test("the shortcut delivers the exact Telegram destination without claiming the settings are open")
    func mountedMainSceneReceivesTelegramRoute() {
        let coordinator = makeCoordinator()
        var delivered: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { delivered.append($0) }

        let receipt = coordinator.request(.sidebar(.telegram))
        let presentation = ProviderTelegramSettingsButtonPresentation.presentation(for: receipt)

        #expect(presentation == .deliveredToMountedScene)
        #expect(delivered == [.sidebar(.telegram)])
        #expect(presentation.statusText == "Telegram settings request delivered to the main window.")
        #expect(!presentation.statusText.localizedCaseInsensitiveContains("opened"))
    }

    @Test("an unavailable main scene keeps the Telegram route queued and reports that adverse state honestly")
    func routeIsQueuedUntilAMainSceneMounts() {
        let coordinator = makeCoordinator()

        let receipt = coordinator.request(.sidebar(.telegram))
        let presentation = ProviderTelegramSettingsButtonPresentation.presentation(for: receipt)

        #expect(presentation == .queuedForMainScene)
        #expect(presentation.statusText == "Telegram settings will open when the main window is ready.")
        #expect(!presentation.statusText.localizedCaseInsensitiveContains("opened"))

        var delivered: [NativeAgentNavigationDestination] = []
        _ = coordinator.mountMainScene { delivered.append($0) }
        #expect(delivered == [.sidebar(.telegram)])
    }

    private func makeCoordinator() -> NativeAgentAppCoordinator {
        NativeAgentAppCoordinator(
            notificationCenter: NotificationCenter(),
            windowActions: .init(
                activateApplication: {},
                openMainWindow: {}
            )
        )
    }
}
