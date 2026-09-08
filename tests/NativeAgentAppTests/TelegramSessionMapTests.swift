import Foundation
import NativeAgentCore
import Testing
import TelegramBot
import PersistenceCore

@Suite("Telegram session map storage")
struct TelegramSessionMapTests {
    @Test func failedNewRollsBackIndexRowAndPreservesPreviousSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)
        let previous = try await store.startNewSession(chatId: 42)
        let map = root.appendingPathComponent("telegram/session_map.json")
        let index = root.appendingPathComponent("chat/sessions.json")
        let healthyMap = try Data(contentsOf: map)
        let previousRows = try JSONValue.parse(Data(contentsOf: index))
        let damaged = Data("{damaged map".utf8)
        try damaged.write(to: map)

        await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
            _ = try await store.startNewSession(chatId: 42)
        }
        #expect(try JSONValue.parse(Data(contentsOf: index)) == previousRows)
        #expect(try Data(contentsOf: map) == damaged)

        try healthyMap.write(to: map)
        #expect(try await store.activeSessionId(chatId: 42) == previous)
        let next = try await store.startNewSession(chatId: 42)
        #expect(next != previous)
        #expect(try await store.activeSessionId(chatId: 42) == next)
    }

    @Test func checkedMapPreservesDamageAndConcurrentBindings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-map-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("telegram/session_map.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = TelegramSessionStore(dataRoot: root)
        let topic = TelegramDestination(chatId: 42, threadId: 7)

        // Missing storage bootstraps; persona-only entries are valid Telegram state.
        let initial = try await store.activeSessionId(chatId: 42)
        #expect(initial == TelegramSessionStore.legacySessionId(42))
        _ = try await store.setPersona(destination: topic, persona: "Topic persona")
        let selected = try await store.startNewSession(chatId: 42)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try await store.activeSessionId(destination: topic) }
            }
            for try await id in group {
                #expect(id == TelegramSessionStore.legacySessionId(topic))
            }
        }
        #expect(try await store.activeSessionId(chatId: 42) == selected)
        #expect(try await store.persona(destination: topic) == "Topic persona")

        let healthy = try Data(contentsOf: path)
        for damaged in [
            "{", "[]", "{}", #"{"chats":[]}"#,
            #"{"chats":{"42":false}}"#,
            #"{"chats":{"42":{}}}"#,
            #"{"chats":{"42":{"activeSessionId":5}}}"#,
            #"{"chats":{"42":{"activeSessionId":"  "}}}"#,
            #"{"chats":{"42":{"persona":false}}}"#,
            #"{"chats":{"42":{"activeSessionId":"saved"},"other":{"persona":null}}}"#,
            #"{"chats":{"42":{"activeSessionId":"saved","updatedAt":[]}}}"#,
        ] {
            let bytes = Data(damaged.utf8)
            try bytes.write(to: path, options: .atomic)
            await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
                _ = try await store.activeSessionId(chatId: 42)
            }
            await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
                _ = try await store.persona(destination: topic)
            }
            await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
                _ = try await store.setPersona(destination: topic, persona: "Replacement")
            }
            await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
                _ = try await store.startNewSession(chatId: 42)
            }
            #expect(try Data(contentsOf: path) == bytes)
        }

        // A directory at the map path is unreadable storage, not a missing map.
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        await #expect(throws: TelegramSessionStoreError.sessionStorageUnavailable) {
            _ = try await store.setPersona(destination: topic, persona: "Replacement")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
        try FileManager.default.removeItem(at: path)
        try healthy.write(to: path)
        #expect(try await store.activeSessionId(chatId: 42) == selected)
        #expect(try await store.persona(destination: topic) == "Topic persona")
    }
}
