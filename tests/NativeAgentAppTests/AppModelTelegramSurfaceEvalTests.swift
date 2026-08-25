import Foundation
import TelegramBot
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.runtimes · AppModel Telegram settings surface", .serialized)
struct AppModelTelegramSurfaceEvalTests {
    @Test("a successful AppModel save records a durable root-scoped receipt and presentation")
    func saveWritesCanonicalConfigurationAndPresentationReceipt() async throws {
        let root = try temporaryRoot("saved")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.telegramToken = "123456:AA_token"
        app.telegramAllowedChats = "42, -1007"
        app.telegramAllowedUsers = "9"
        app.telegramEnabled = true

        let outcome = await app.saveTelegram()
        #expect(outcome == .saved(tokenConfigured: true, enabled: true, allowlistCount: 3))
        #expect(app.telegramSettingsSaveOutcome == outcome)
        #expect(outcome.message == "Telegram settings saved for 3 allowed recipients.")
        #expect(!outcome.isAdverse)

        let saved = try #require(TelegramConfig.loadFromDisk(dataRoot: root))
        #expect(saved.allowedChatIds == [42, -1007])
        #expect(saved.allowedUserIds == [9])
        #expect(saved.enabled)

        let reloaded = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await reloaded.refreshTelegram()
        #expect(reloaded.telegramStatus?.tokenConfigured == true)
        #expect(reloaded.telegramStatus?.enabled == true)
    }

    @Test("invalid input produces a retryable adverse receipt without changing the canonical config")
    func rejectedSaveKeepsTheExistingAuthority() async throws {
        let root = try temporaryRoot("rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = TelegramConfig(botToken: "123456:AA_existing", allowedChatIds: [42], enabled: true)
        try TelegramConfig.saveToDisk(original, dataRoot: root)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.refreshTelegram()
        app.telegramToken = "invalid token"

        let outcome = await app.saveTelegram()
        guard case .rejected(let detail) = outcome else {
            Issue.record("invalid token unexpectedly reported as saved")
            return
        }
        #expect(detail.contains("numeric-bot-ID:secret"))
        #expect(app.telegramSettingsSaveOutcome == outcome)
        #expect(TelegramConfig.loadFromDisk(dataRoot: root) == original)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-telegram-surface-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
