import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.SlimSettings.telegramLink

@MainActor
@Suite("Slim Settings Telegram link")
struct SlimSettingsTelegramLinkEvalTests {
    @Test("the Settings integration entry routes to the typed Telegram status destination")
    func telegramLinkUsesTheTypedTelegramSettingsDestination() {
        let link = SlimSettingsTelegramLink.presentation
        #expect(link.destination == .telegram)
        #expect(link.destination.content == .telegramSettings)
        #expect(link.title == "Telegram")
        #expect(link.systemImage == "paperplane")
        #expect(link.accessibilityHint.lowercased().contains("opens telegram settings"))
    }

    @Test("the reached status surface reports missing configuration instead of treating navigation as connection")
    func telegramStatusKeepsTheUnconfiguredStateVisible() {
        let missing = TelegramSettingsPresentation.tokenStatus(tokenConfigured: false)
        #expect(TelegramSettingsPresentation.statusPanelTitle == "Telegram Status")
        #expect(missing.label == "Bot token missing")
        #expect(missing.systemImage == "exclamationmark.triangle.fill")
        #expect(missing.isConfigured == false)

        let configured = TelegramSettingsPresentation.tokenStatus(tokenConfigured: true)
        #expect(configured.label == "Bot token configured")
        #expect(configured.isConfigured)

        let hint = SlimSettingsTelegramLink.presentation.accessibilityHint.lowercased()
        #expect(hint.contains("opens telegram settings"))
        #expect(!hint.contains("connected"))
        #expect(!hint.contains("configured"))
    }
}
