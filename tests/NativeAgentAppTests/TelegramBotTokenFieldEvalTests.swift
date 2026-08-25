import Foundation
import TelegramBot
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Telegram.botTokenField

@MainActor
@Suite("app.settings · Telegram bot-token field", .serialized)
struct TelegramBotTokenFieldEvalTests {
    private let defaultsKeys = [
        "telegramToken",
        "telegramAllowedChats",
        "telegramAllowedUsers",
        "telegramRequireMention",
        "telegramEnabled",
        "telegramModel",
        "telegramReasoningEffort",
    ]

    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-token-field-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func restoreDefaults(_ values: [String: Any?]) {
        for key in defaultsKeys {
            if let value = values[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    @Test("the token field state saves through the canonical owner, clears its draft, and never projects plaintext")
    func secureFieldRoundTripsOnlyThroughTelegramConfig() async throws {
        let root = try tempRoot("round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        let savedDefaults = Dictionary(uniqueKeysWithValues: defaultsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer { restoreDefaults(savedDefaults) }
        UserDefaults.standard.set("legacy-plaintext-draft", forKey: "telegramToken")

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        #expect(UserDefaults.standard.object(forKey: "telegramToken") == nil,
                "an old plaintext draft is discarded; config.json is the credential owner")

        let token = "123456:AA_bot-token"
        let draftState = TelegramBotTokenPresentation.fieldState(draft: token, tokenConfigured: false)
        #expect(draftState.accessibilityIdentifier == TelegramBotTokenPresentation.accessibilityIdentifier)
        #expect(draftState.canSave)
        #expect(draftState.validationMessage == nil)
        #expect(!draftState.helperText.contains(token))
        #expect(!draftState.tokenStatus.contains(token))

        app.telegramToken = "  \(token)  "
        app.telegramAllowedChats = "42"
        app.telegramEnabled = true
        await app.saveTelegram()

        let persisted = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(persisted.botToken == token)
        #expect(persisted.allowedChatIds == [42])
        #expect(persisted.enabled)
        #expect(app.telegramToken.isEmpty, "the one-time secure-field draft clears after a committed save")
        #expect(UserDefaults.standard.object(forKey: "telegramToken") == nil)
        let savedState = TelegramBotTokenPresentation.fieldState(
            draft: app.telegramToken,
            tokenConfigured: app.telegramTokenConfigured
        )
        #expect(savedState.tokenStatus == "Bot token configured")
        #expect(!savedState.helperText.contains(token))
        #expect(!app.statusText.contains(token))
        let saveOutcome = try #require(app.telegramSettingsSaveOutcome)
        #expect(!saveOutcome.message.contains(token))

        let reloaded = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await reloaded.refreshTelegram()
        #expect(reloaded.telegramTokenConfigured)
        #expect(reloaded.telegramEnabled)
        #expect(reloaded.telegramToken.isEmpty, "a reload exposes configuration state, never the token")
        let reloadedState = TelegramBotTokenPresentation.fieldState(
            draft: reloaded.telegramToken,
            tokenConfigured: reloaded.telegramTokenConfigured
        )
        #expect(reloadedState.tokenStatus == "Bot token configured")
        #expect(!reloadedState.helperText.contains(token))
    }

    @Test("malformed input is refused before the write and preserves the existing credential")
    func malformedTokenCannotReplaceSavedAuthority() async throws {
        let root = try tempRoot("malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let savedDefaults = Dictionary(uniqueKeysWithValues: defaultsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer { restoreDefaults(savedDefaults) }
        let original = TelegramConfig(botToken: "123456:AA_original", allowedChatIds: [42], enabled: true)
        try TelegramConfig.saveToDisk(original, dataRoot: root)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.refreshTelegram()
        app.telegramToken = "this is not a bot token"
        await app.saveTelegram()

        #expect(app.statusText.contains("Telegram save failed"))
        #expect(app.statusText.contains("numeric-bot-ID:secret"))
        #expect(app.telegramToken == "this is not a bot token", "a refused draft stays available for correction")
        #expect(TelegramConfig.loadFromDisk(dataRoot: root) == original)
        #expect(TelegramBotTokenPresentation.canSave(draft: app.telegramToken, tokenConfigured: true) == false)
    }

    @Test("a real store write failure remains visible and never clears the token draft")
    func unavailableConfigLocationFailsWithoutPretendingTheTokenSaved() async throws {
        let root = try tempRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let savedDefaults = Dictionary(uniqueKeysWithValues: defaultsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer { restoreDefaults(savedDefaults) }
        let blockedLocation = root.appendingPathComponent("telegram", isDirectory: false)
        try Data("not a directory".utf8).write(to: blockedLocation)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let token = "123456:AA_retryable"
        app.telegramToken = token
        app.telegramAllowedChats = "42"
        app.telegramEnabled = true
        await app.saveTelegram()

        #expect(app.statusText.contains("Telegram save failed"))
        #expect(app.telegramToken == token)
        #expect(!app.telegramTokenConfigured)
        #expect(FileManager.default.fileExists(atPath: blockedLocation.path))
    }
}
