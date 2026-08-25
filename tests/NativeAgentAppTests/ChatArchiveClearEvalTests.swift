import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / appmodel.chat.archiveClear
@MainActor
@Suite("Chat archive and clear durability", .serialized)
struct ChatArchiveClearEvalTests {
    @Test("clear and archive update the active projection only after their durable records agree")
    func clearThenArchiveAgreeInMemoryAndOnDisk() async throws {
        let root = try temporaryRoot("durable")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Fixture chat", sourceKey: "app")
        let messages = [
            ChatMessage(id: "fixture-user", sessionId: session.id, role: "user", content: "Keep this until clear."),
            ChatMessage(id: "fixture-assistant", sessionId: session.id, role: "assistant", content: "Fixture response."),
        ]
        try writeMessages(messages, sessionID: session.id, root: root)

        let app = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        app.chatSessions = try await client.getChatSessions()
        app.activeChatSessionId = session.id
        app.setChatMessages(messages, for: session.id)

        let clear = await app.clearActiveChatMessages()
        #expect(clear.succeeded)
        #expect(clear.userMessage == "Chat messages cleared")
        #expect(app.chatMessages(for: session.id).isEmpty)
        #expect(try await client.getChatMessages(sessionId: session.id).isEmpty)
        #expect(try Data(contentsOf: messagesURL(sessionID: session.id, root: root)).isEmpty)

        // A fresh AppModel must see the canonical empty transcript rather than
        // resurrecting the bubbles that clear just removed. This goes through
        // the real session-selection read boundary rather than inspecting only
        // the writer's file bytes.
        let relaunched = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        relaunched.chatSessions = try await client.getChatSessions()
        await relaunched.selectChatSession(session)
        #expect(relaunched.activeChatSessionId == session.id)
        #expect(relaunched.chatMessages(for: session.id).isEmpty)

        let archive = await app.archiveActiveChat()
        #expect(archive.succeeded)
        #expect(archive.userMessage == "Chat archived")
        #expect(!app.chatSessions.contains { $0.id == session.id })
        #expect(!(try await client.getChatSessions()).contains { $0.id == session.id })
        let archived = try archivedSessionRows(root: root)
        #expect(archived.contains {
            ($0["id"] as? String) == session.id && ($0["archived"] as? Bool) == true
        })
    }

    @Test("a failed clear persistence keeps the visible transcript and returns a typed failure")
    func failedClearDoesNotOptimisticallyEraseMemory() async throws {
        let root = try temporaryRoot("failed-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Blocked fixture", sourceKey: "app")
        let messages = [ChatMessage(
            id: "preserved-message", sessionId: session.id, role: "user", content: "This must stay visible."
        )]

        // A directory at the canonical transcript-file location makes the
        // native atomic writer fail. The AppModel must leave its matching
        // in-memory transcript intact and return failure rather than claiming
        // a successful clear that would resurrect after relaunch.
        try FileManager.default.createDirectory(
            at: messagesURL(sessionID: session.id, root: root),
            withIntermediateDirectories: true
        )
        let app = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        app.chatSessions = try await client.getChatSessions()
        app.activeChatSessionId = session.id
        app.setChatMessages(messages, for: session.id)

        let result = await app.clearActiveChatMessages()
        #expect(!result.succeeded)
        #expect(result.userMessage.contains("Clear failed:"))
        #expect(app.chatMessages(for: session.id) == messages)
        #expect(app.statusText == result.userMessage)
    }

    @Test("a failed archive persist leaves the live session index and active selection intact")
    func failedArchiveDoesNotOptimisticallyRemoveSession() async throws {
        let root = try temporaryRoot("failed-archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Archive failure fixture", sourceKey: "app")
        let archiveURL = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not-valid-archive-json\n".utf8).write(to: archiveURL, options: .atomic)

        let app = AppModel(
            dataRootOverride: root,
            startBackgroundTasks: false,
            activeChatSessionIDWriter: { _ in },
            chatSnapshotPublisher: {}
        )
        app.chatSessions = try await client.getChatSessions()
        app.activeChatSessionId = session.id

        let result = await app.archiveActiveChat()
        #expect(!result.succeeded)
        #expect(result.userMessage.contains("Archive failed:"))
        #expect(app.activeChatSessionId == session.id)
        #expect(app.chatSessions.contains { $0.id == session.id })
        #expect((try await client.getChatSessions()).contains { $0.id == session.id })
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-archive-clear-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func messagesURL(sessionID: String, root: URL) -> URL {
        root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    private func writeMessages(_ messages: [ChatMessage], sessionID: String, root: URL) throws {
        let url = messagesURL(sessionID: sessionID, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try messages.map { message in
            String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    private func archivedSessionRows(root: URL) throws -> [[String: Any]] {
        let url = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("sessions.jsonl")
        return try Data(contentsOf: url)
            .split(separator: 10)
            .map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:] }
    }
}
