import Foundation
import Testing
@testable import TelegramBot
import BackgroundLoops

private struct TelegramStatusLoop: LoopRunner {
    let loopId = "telegram_poll"
    let interval: TimeInterval = 86_400
    func tickOutcome() async -> LoopTickOutcome { .completed(result: nil) }
}

@Suite("Telegram manager status")
struct TelegramManagerStatusTests {
    @Test("poller status follows the injected Core loop owner")
    func pollerStatusTracksCoreManager() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telegram_manager_status_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(
                botToken: "123:test-token",
                allowedChatIds: [123],
                enabled: true
            ),
            dataRoot: root
        )
        let manager = BackgroundLoopsManager()
        let bot = SwiftNativeTelegramBot(
            dataRoot: root,
            backgroundLoopsManager: manager
        )

        #expect(try await bot.getStatus().pollerEnabled == false)
        await manager.start(loops: [TelegramStatusLoop()])
        #expect(try await bot.getStatus().pollerEnabled == true)
        await manager.stop()
        #expect(try await bot.getStatus().pollerEnabled == false)
    }
}
