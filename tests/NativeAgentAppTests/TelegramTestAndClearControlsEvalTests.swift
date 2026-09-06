import Foundation
import BackgroundLoops
import protocol BackgroundLoops.LoopRunner
import enum BackgroundLoops.LoopTickOutcome
import NativeAgentCore
import TelegramBot
import Testing
@testable import NativeAgentApp

private typealias CoreBackgroundLoopsManager = BackgroundLoops.BackgroundLoopsManager
private typealias AppBackgroundLoopsManager = NativeAppBackgroundLoopsManager

/// Coverage ledger: app.bridges / telegram.testAndClearControls
///
/// The test-reply control has two independently meaningful observations:
/// Telegram accepted the outgoing message, and the app's own `telegram_poll`
/// registration is actually alive.  The destructive diagnostic clear also
/// needs an explicit mounted confirmation before it can erase the lane's
/// forensic records.
@Suite("app.bridges · Telegram test and clear controls", .serialized)
struct TelegramTestAndClearControlsEvalTests {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-controls-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("test reply reports both token validity and a registered, ticking poller")
    func testReplyDoesNotTurnOutboundDeliveryIntoFalseInboundHealth() async throws {
        let root = try tempRoot("test-reply")
        defer { try? FileManager.default.removeItem(at: root) }
        try TelegramConfig.saveToDisk(
            TelegramConfig(botToken: "123:valid", allowedChatIds: [42], enabled: true),
            dataRoot: root
        )

        let core = CoreBackgroundLoopsManager()
        let manager = AppBackgroundLoopsManager(
            coreManager: core,
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )
        defer { Task { await manager.stop() } }
        await manager.start(loops: [TelegramControlsPollLoop()])
        _ = await manager.runTickOnce(loopId: "telegram_poll")

        let client = NativeClient(
            baseURL: "",
            dataRootOverride: root,
            backgroundLoopsManager: manager
        )
        let response = try await client.testTelegram(
            chatId: "42",
            dataRoot: root,
            telegramBot: TelegramControlsTransport()
        )

        #expect(response.ok)
        #expect(response.tokenConfigured == true)
        #expect(response.pollerRegistered == true)
        #expect(response.pollerTicking == true)
        #expect(TelegramTestReplyPresentation.summary(for: response)
            == "Telegram test sent to 42. Bot token verified. Telegram polling is registered and ticking.")

        let stoppedManager = AppBackgroundLoopsManager(
            coreManager: CoreBackgroundLoopsManager(),
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )
        let outboundOnly = try await NativeClient(
            baseURL: "",
            dataRootOverride: root,
            backgroundLoopsManager: stoppedManager
        ).testTelegram(chatId: "42", dataRoot: root, telegramBot: TelegramControlsTransport())
        #expect(outboundOnly.tokenConfigured == true)
        #expect(outboundOnly.pollerRegistered == false)
        #expect(outboundOnly.pollerTicking == false)
        #expect(TelegramTestReplyPresentation.summary(for: outboundOnly)
            == "Telegram test sent to 42. Bot token verified. Telegram polling is not registered.")
    }

    @Test("diagnostic clear removes the complete fixture and remains confirmation-gated in the mounted view")
    func clearDiagnosticsIsDestructiveOnlyAfterTheMountedConfirmationRoute() async throws {
        let root = try tempRoot("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let telegram = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegram, withIntermediateDirectories: true)
        for (name, rows) in [
            ("logs.jsonl", 1),
            ("receipts.jsonl", 2),
            ("blocked.jsonl", 1),
            ("errors.jsonl", 1),
            ("errors.jsonl.1", 1),
        ] {
            let content = String(repeating: "{\"id\":\"fixture\"}\n", count: rows)
            try Data(content.utf8).write(to: telegram.appendingPathComponent(name))
        }

        let receipt = try await NativeClient(baseURL: "", dataRootOverride: root).clearTelegramLogs(dataRoot: root)
        #expect(receipt.removedFileCount == 5)
        #expect(receipt.removedRowCount == 6)
        #expect(receipt.status.lastDiagnosticsClearedAt == receipt.clearedAt)
        for name in ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl", "errors.jsonl.1"] {
            #expect(!FileManager.default.fileExists(atPath: telegram.appendingPathComponent(name).path))
        }

        let view = try AppSourceScraping.appSource("TelegramView.swift")
        #expect(view.contains("showClearLogsConfirm = true"))
        guard let start = view.range(of: "confirmationDialog(\n            \"Clear Telegram diagnostics?\"") else {
            Issue.record("Telegram diagnostics confirmation moved")
            return
        }
        let dialog = String(view[start.lowerBound...].prefix(900))
        #expect(dialog.contains("isPresented: $showClearLogsConfirm"))
        // 2026-09-06: label only — 89b0f712 ("Advanced reach pages on the page
        // kit: Providers, Telegram, iPhone, Connectors", 2026-09-03) rebuilt
        // TelegramView on the page kit and moved its buttons to sentence case,
        // so the destructive button is now `Button("Clear logs", ...)`
        // (TelegramView.swift:269). The gate itself is unchanged: the
        // destructive role still hangs off the confirmation dialog.
        #expect(dialog.contains("Button(\"Clear logs\", role: .destructive)"))
        #expect(dialog.contains("await appModel.clearTelegramLogs()"))
        #expect(dialog.contains("Button(\"Cancel\", role: .cancel)"))
        #expect(dialog.contains("permanently removes recent replies, blocked-message records, errors, and diagnostic logs"))
    }
}

private struct TelegramControlsPollLoop: LoopRunner {
    let loopId = "telegram_poll"
    let interval: TimeInterval = 3_600

    func tickOutcome() async -> LoopTickOutcome {
        .completed(result: "telegram-controls-eval")
    }
}

private actor TelegramControlsTransport: TelegramBotProtocol {
    func getStatus() async throws -> TelegramBot.TelegramStatus { .init() }
    func clearLogs() async throws {}

    func sendTestMessage(message: String?, chatId: String?) async throws -> TelegramTestResult {
        TelegramTestResult(rawResponse: .object([
            "ok": .bool(true),
            "chatId": .string(chatId ?? ""),
            "messageId": .int(1),
        ]))
    }
}
