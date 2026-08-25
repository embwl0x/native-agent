import Foundation
import TelegramBot
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.sidebar.rowSourceBadge
@Suite("Chat sidebar session source badge", .serialized)
struct ChatSidebarRowSourceBadgeEvalTests {
    @Test("sidebar source badge has a closed honest label for local, remote, and damaged rows")
    func sourceBadgeNeverHidesOrLeaksStoredProvenance() {
        #expect(ChatSidebarSessionSourceBadge.make(source: "app") == nil)
        #expect(ChatSidebarSessionSourceBadge.make(source: " Telegram ")?.label == "Telegram")
        #expect(ChatSidebarSessionSourceBadge.make(source: "ios")?.label == "iPhone / iPad")
        #expect(ChatSidebarSessionSourceBadge.make(source: "slack")?.label == "Slack")
        #expect(ChatSidebarSessionSourceBadge.make(source: "bridge")?.label == "Bridge")

        let missing = ChatSidebarSessionSourceBadge.make(source: nil)
        #expect(missing?.label == "Unknown origin")
        #expect(missing?.tone == .unknown)
        #expect(ChatSidebarSessionSourceBadge.make(source: "   ")?.label == "Unknown origin")

        let unrecognized = ChatSidebarSessionSourceBadge.make(source: "partner-private-route")
        #expect(unrecognized?.label == "External source")
        #expect(unrecognized?.tone == .unknown)
        #expect(unrecognized?.label.contains("partner") == false)
    }

    @MainActor
    @Test("app, iOS, Slack, and Telegram session writers preserve a renderable source in one clone root")
    func sessionIngressWritersPersistDistinctSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-source-badge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let local = try await NativeClient.createChatSession(
            title: "Mac session",
            sourceKey: "app",
            dataRoot: root
        )
        let iosID = "ios-\(UUID().uuidString)"
        try await AppDelegate.ensureChatSessionIndex(sessionID: iosID, dataRoot: root)
        let slackID = "slack-\(UUID().uuidString)"
        try await SlackSessionStore.ensureSessionRow(
            id: slackID,
            title: "Slack session",
            sourceKey: "slack:clone",
            dataRoot: root
        )
        let telegramID = try await TelegramSessionStore(dataRoot: root).startNewSession(chatId: 41_337)

        let indexURL = root.appendingPathComponent("chat/sessions.json")
        let indexData = try Data(contentsOf: indexURL)
        let rows = try #require(JSONSerialization.jsonObject(with: indexData) as? [[String: Any]])
        let sourcesByID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
            guard let id = row["id"] as? String, let source = row["source"] as? String else { return nil }
            return (id, source)
        })

        #expect(sourcesByID[local.id] == "app")
        #expect(sourcesByID[iosID] == "ios")
        #expect(sourcesByID[slackID] == "slack")
        #expect(sourcesByID[telegramID] == "telegram")
        for id in [iosID, slackID, telegramID] {
            #expect(ChatSidebarSessionSourceBadge.make(source: sourcesByID[id]) != nil)
        }
    }

    @Test("mounted row uses the source badge rather than raw stored source text")
    func sidebarRowUsesClosedBadgeModel() throws {
        let view = try AppSourceScraping.appSource("ContextReceiptView.swift")
        #expect(view.contains("ChatSidebarSessionSourceBadge.make(source: session.source)"))
        #expect(view.contains("Session origin: \\(sourceBadge.label)"))
        #expect(!view.contains("if let source = session.source, source != \"app\""))
    }
}
