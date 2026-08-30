import Foundation
import Testing
import PersistenceCore
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
        let indexPath = root.appendingPathComponent("chat/sessions.json")
        var indexedRows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: indexPath)
        let index = try #require(indexedRows.firstIndex { $0["id"] == .string(session.id) })
        indexedRows[index]["messageCount"] = .int(2)
        indexedRows[index]["lastMessagePreview"] = .string("Fixture response.")
        try ChatSessionIndexFile.serializedData(for: indexedRows).write(to: indexPath)

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
        #expect(app.chatSessions.first(where: { $0.id == session.id })?.messageCount == 0)
        #expect(app.chatSessions.first(where: { $0.id == session.id })?.lastMessagePreview == nil)
        let clearedIndex = try ChatSessionIndexFile.loadObjectRowsForMutation(at: indexPath)
        #expect(clearedIndex[index]["messageCount"] == .int(0))
        #expect(clearedIndex[index]["lastMessagePreview"] == .null)
        #expect(clearedIndex[index]["title"] == indexedRows[index]["title"])

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

    @Test("malformed index refuses clear before transcript mutation")
    func malformedIndexPreservesTranscript() async throws {
        let root = try temporaryRoot("bad-index")
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = [ChatMessage(id: "kept", sessionId: "s", role: "user", content: "Keep me")]
        try writeMessages(messages, sessionID: "s", root: root)
        let path = messagesURL(sessionID: "s", root: root)
        let before = try Data(contentsOf: path)
        let badIndex = Data("{broken-index".utf8)
        let index = root.appendingPathComponent("chat/sessions.json")
        try badIndex.write(to: index)
        await #expect(throws: ChatSessionIndexFileError.self) {
            _ = try await NativeClient.clearChatMessages(sessionId: "s", dataRoot: root)
        }
        #expect(try Data(contentsOf: path) == before)
        #expect(try Data(contentsOf: index) == badIndex)
    }

    @Test("post-clear index failure reports partial completion instead of success")
    func postClearIndexFailureIsTyped() async throws {
        let root = try temporaryRoot("late-index-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Fixture", sourceKey: "app")
        try writeMessages([ChatMessage(id: "old", role: "user", content: "Old")], sessionID: session.id, root: root)
        let index = root.appendingPathComponent("chat/sessions.json")
        let badIndex = Data("{late-corruption".utf8)
        await #expect(throws: ChatMessageClearError.self) {
            _ = try await NativeClient.clearChatMessages(sessionId: session.id, dataRoot: root, afterTranscriptClear: {
                try badIndex.write(to: index)
            })
        }
        #expect(try Data(contentsOf: messagesURL(sessionID: session.id, root: root)).isEmpty)
        #expect(try Data(contentsOf: index) == badIndex)
    }

    @Test("a newer canonical append keeps its count and preview after clear")
    func appendAfterClearKeepsNewIndexProjection() async throws {
        let root = try temporaryRoot("new-append")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Fixture", sourceKey: "app")
        try writeMessages([ChatMessage(id: "old", role: "user", content: "Old")], sessionID: session.id, root: root)
        let index = root.appendingPathComponent("chat/sessions.json")
        var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: index)
        let rowIndex = try #require(rows.firstIndex { $0["id"] == .string(session.id) })
        rows[rowIndex]["messageCount"] = .int(1)
        rows[rowIndex]["lastMessagePreview"] = .string("New request")
        let newIndexBytes = try ChatSessionIndexFile.serializedData(for: rows)
        let newMessage = ChatMessage(id: "new", sessionId: session.id, role: "user", content: "New request")
        let newMessageBytes = try JSONEncoder().encode(newMessage) + Data([10])
        let path = messagesURL(sessionID: session.id, root: root)
        _ = try await NativeClient.clearChatMessages(sessionId: session.id, dataRoot: root, afterTranscriptClear: {
            try newMessageBytes.write(to: path)
            try newIndexBytes.write(to: index)
        })
        #expect(try Data(contentsOf: path) == newMessageBytes)
        #expect(try Data(contentsOf: index) == newIndexBytes)
    }

    @Test(arguments: [false, true])
    func clearRefreshStaysOnRequestedSessionAndShowsActualRows(partialFailure: Bool) async throws {
        let root = try temporaryRoot("clear-ui")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let target = try await client.createChatSession(title: "Target", sourceKey: "app")
        let other = try await client.createChatSession(title: "Other", sourceKey: "other")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        app.chatSessions = [target, other]
        app.activeChatSessionId = target.id
        let otherRows = [ChatMessage(id: "other-row", sessionId: other.id, role: "user", content: "Unrelated")]
        app.setChatMessages(otherRows, for: other.id)
        app.setChatMessages([ChatMessage(id: "old", sessionId: target.id, content: "Cleared")], for: target.id)
        let actual = partialFailure ? [] : [ChatMessage(id: "new", sessionId: target.id, role: "user", content: "New append")]
        let result = await app.clearActiveChatMessages(clear: { requested in
            #expect(requested == target.id)
            app.activeChatSessionId = other.id
            if partialFailure { throw ChatMessageClearError.transcriptClearedMetadataNotSaved("fixture") }
            return EmptyResponse()
        }, loadMessages: { requested in
            #expect(requested == target.id)
            return actual
        }, loadSessions: { [target, other] })
        #expect(result.succeeded == !partialFailure)
        #expect(app.activeChatSessionId == other.id)
        #expect(app.chatMessages(for: other.id) == otherRows)
        #expect(app.chatMessages(for: target.id) == actual)
        if partialFailure {
            #expect(result.userMessage.contains("Messages were cleared"))
            #expect(result.userMessage.contains("metadata could not be saved"))
        }
    }

    @Test(arguments: [false, true])
    func clearRefreshCannotReplaceTurnThatSettledDuringReload(partialFailure: Bool) async throws {
        let root = try temporaryRoot("clear-reload-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let session = try await client.createChatSession(title: "Target", sourceKey: "app")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        app.chatSessions = [session]
        app.activeChatSessionId = session.id
        let fresh = [
            ChatMessage(id: "new-user", sessionId: session.id, role: "user", content: "New request"),
            ChatMessage(id: "new-tool", sessionId: session.id, role: "tool", content: "Recorded result"),
            ChatMessage(id: "new-final", sessionId: session.id, role: "assistant", content: "New reply"),
        ]
        let start = Date(timeIntervalSince1970: 1_788_110_000)
        let result = await app.clearActiveChatMessages(clear: { _ in
            if partialFailure { throw ChatMessageClearError.transcriptClearedMetadataNotSaved("fixture") }
            return EmptyResponse()
        }, loadMessages: { requested in
            #expect(requested == session.id)
            _ = app.beginChatTurnLifecycle(sessionId: session.id, turnId: "new-turn", at: start)
            app.streamingSessions.insert(session.id)
            app.setChatMessages(fresh, for: session.id)
            _ = app.applyChatTurnLifecycleInput(.init(
                identity: .init(sessionId: session.id, turnId: "new-turn"),
                kind: .completed, occurredAt: start.addingTimeInterval(1)))
            _ = app.closeChatTurnLifecycleIntake(
                sessionId: session.id, turnId: "new-turn", at: start.addingTimeInterval(1))
            app.streamingSessions.remove(session.id)
            return [] // Snapshot taken before the intervening turn.
        }, loadSessions: { [session] })
        #expect(result.succeeded == !partialFailure)
        #expect(app.chatMessages(for: session.id) == fresh)
        #expect(app.activeChatSessionId == session.id)
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
