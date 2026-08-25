import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Telegram.actionButtons
@MainActor
@Suite("Telegram action buttons", .serialized)
struct TelegramActionButtonsEvalTests {
    @Test("Clear Logs returns the real mounted-root removal receipt and refreshes the panel state")
    func clearLogsReportsWhatItRemoved() async throws {
        let root = try temporaryRoot("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let telegram = root.appendingPathComponent("telegram", isDirectory: true)
        try FileManager.default.createDirectory(at: telegram, withIntermediateDirectories: true)
        for name in ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl", "errors.jsonl.1"] {
            try Data("{\"id\":\"one\"}\n{\"id\":\"two\"}\n".utf8)
                .write(to: telegram.appendingPathComponent(name))
        }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.clearTelegramLogs()

        guard let outcome = app.telegramClearLogsOutcome,
              case .completed(let receipt) = outcome else {
            Issue.record("the destructive action must publish a typed completion receipt")
            return
        }
        #expect(receipt.removedFileCount == 5)
        #expect(receipt.removedRowCount == 10)
        #expect(!receipt.clearedAt.isEmpty)
        #expect(TelegramClearLogsPresentation.summary(for: receipt).contains("5 diagnostic files"))
        #expect(app.telegramStatus?.lastDiagnosticsClearedAt == receipt.clearedAt)
        for name in ["logs.jsonl", "receipts.jsonl", "blocked.jsonl", "errors.jsonl", "errors.jsonl.1"] {
            #expect(!FileManager.default.fileExists(atPath: telegram.appendingPathComponent(name).path))
        }
    }

    @Test("an unreadable diagnostic path reports failure and does not claim a clear")
    func clearFailureRemainsVisible() async throws {
        let root = try temporaryRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let logsDirectory = root.appendingPathComponent("telegram/logs.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.clearTelegramLogs()

        guard let outcome = app.telegramClearLogsOutcome,
              case .failed(let detail) = outcome else {
            Issue.record("an unreadable diagnostic path must render a failed action outcome")
            return
        }
        #expect(!detail.isEmpty)
        #expect(app.statusText.contains("Clear Telegram logs failed"))
        #expect(FileManager.default.fileExists(atPath: logsDirectory.path))
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-action-buttons-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
