import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Telegram.receiptPanels

@Suite("Telegram receipt panels")
struct TelegramReceiptPanelsEvalTests {
    @Test("the real status reader retains readable receipts while disclosing malformed and schema-invalid rows")
    func partialReceiptFeedIsNotPresentedAsClean() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = root.appendingPathComponent("telegram/receipts.jsonl")
        try FileManager.default.createDirectory(at: feed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(([
            #"{"id":"reply-1","at":"2026-08-24T10:00:00Z","kind":"reply","chatId":"42"}"#,
            "not JSON at all",
            "[]",
            #"{"id":"reply-2","at":"2026-08-24T10:02:00Z","kind":"reply","chatId":"42"}"#,
        ].joined(separator: "\n") + "\n").utf8).write(to: feed)

        let status = try await NativeClient(baseURL: "", dataRootOverride: root).getTelegramStatus()

        #expect(status.receipts.map(\.eventId) == ["reply-1", "reply-2"])
        #expect(status.receiptsIssue?.contains("2 unreadable diagnostic rows") == true)
        #expect(status.blocked.isEmpty)
        #expect(status.blockedIssue == nil)
    }

    @Test("missing feed, current snapshot, stale snapshot, and unavailable snapshot remain distinct")
    func panelReadStateDoesNotCallAbsentOrStaleEvidenceCurrent() {
        #expect(TelegramPanelPresentation.readState(status: nil, refreshError: nil) == .loading)
        #expect(TelegramPanelPresentation.readState(
            status: nil,
            refreshError: "status reader unavailable"
        ) == .unavailable(detail: "status reader unavailable"))
        #expect(TelegramPanelPresentation.readState(status: status(), refreshError: nil) == .current)

        let stale = TelegramPanelPresentation.readState(
            status: status(),
            refreshError: String(repeating: "x", count: 300)
        )
        if case .stale(let detail) = stale {
            #expect(detail.count == 241)
            #expect(detail.hasSuffix("…"))
        } else {
            Issue.record("Expected a stale receipt snapshot")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-receipt-panels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func status() -> TelegramStatus {
        TelegramStatus(
            enabled: true,
            tokenConfigured: true,
            allowedChatIds: ["42"],
            allowedUserIds: [],
            requireMention: true,
            model: "gpt-5.6",
            reasoningEffort: "medium",
            pollerEnabled: true,
            lastSeenUpdateId: nil,
            lastSeenAt: nil,
            lastReplyAt: nil,
            lastError: nil,
            pollBackoffFailures: nil,
            lastPollAt: nil,
            lastDiagnosticsClearedAt: nil,
            voiceTranscription: nil,
            receipts: [],
            blocked: [],
            errors: []
        )
    }
}
