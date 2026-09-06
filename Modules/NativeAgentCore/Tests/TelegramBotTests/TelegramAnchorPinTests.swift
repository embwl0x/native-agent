import Testing
import Foundation
import PersistenceCore
@testable import TelegramBot

// MARK: - Telegram as an anchor PUBLISHER (and the racy-read fix)
//
// Two things land here, and they are independent:
//
//   1. `activeSessionId` did a racy unlocked read-then-patch. Two concurrent
//      first messages for one chat both missed, both minted, and the second
//      patch clobbered the first — orphaning that turn's session context.
//      Slack fixed exactly this on 2026-07-21; Telegram had not.
//   2. Telegram publishes the surface-agnostic conversation anchor. It is the
//      only publisher that exists today and it knows nothing special about
//      that fact: it calls `ConversationAnchor.publish` with its own source
//      name and `.direct`, the way any adapter would.

@Suite("Telegram anchor + session identity", .serialized)
struct TelegramAnchorPinTests {

    private func tmpRoot(_ label: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tg-anchor-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sessionIds(in root: URL) throws -> [String] {
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions.json")
        guard case .array(let rows) = try JSONValue.parse(try Data(contentsOf: path)) else { return [] }
        return rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        }
    }

    // MARK: The pin

    @Test("the first message publishes the chat's session as the anchor")
    func firstMessagePublishesTheAnchor() async throws {
        let root = tmpRoot("first")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        let sessionId = try await store.activeSessionId(chatId: 1394548068)

        let pin = try #require(ConversationAnchor.current(dataRoot: root))
        #expect(pin.sessionId == sessionId)
        #expect(pin.source == "telegram")
    }

    @Test("/new is a real new session AND becomes the anchor; the old one survives")
    func newSessionRepublishesThePin() async throws {
        let root = tmpRoot("new")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        let first = try await store.activeSessionId(chatId: 42)
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == first)

        // User: "I use /new to clear Agent's head." A REAL new session — not a
        // view epoch, not a reset of the old one.
        let second = try await store.startNewSession(chatId: 42)
        #expect(second != first)
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == second)

        // And the previous stretch is still there, unarchived and addressable.
        let ids = try sessionIds(in: root)
        #expect(ids.contains(first), "the previous session must stay reachable after /new")
        #expect(ids.contains(second))
    }

    @Test("/resume moves the anchor onto the session it resumed")
    func resumeMovesThePin() async throws {
        let root = tmpRoot("resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        let first = try await store.activeSessionId(chatId: 7)
        let second = try await store.startNewSession(chatId: 7)
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == second)

        _ = try await store.bindSession(chatId: 7, requestedSessionId: first)
        // Without this the Mac and phone would keep pinning the session he
        // just left — the pin has to follow the conversation, not the clock.
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == first)
    }

    @Test("re-resolving an unchanged session does not churn the pin")
    func repeatedResolutionIsStable() async throws {
        let root = tmpRoot("stable")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        let first = try await store.activeSessionId(chatId: 9)
        let firstPin = try #require(ConversationAnchor.current(dataRoot: root))
        for _ in 0..<3 { _ = try await store.activeSessionId(chatId: 9) }
        let laterPin = try #require(ConversationAnchor.current(dataRoot: root))

        #expect(laterPin.sessionId == first)
        // Byte-identical, including `updatedAt`: the publish short-circuits on
        // an unchanged id rather than rewriting the file (and re-publishing the
        // phone snapshot) on every inbound message.
        #expect(laterPin == firstPin)
    }

    // MARK: The racy read

    @Test("concurrent first messages for one chat resolve to ONE session")
    func concurrentFirstMessagesDoNotClobber() async throws {
        let root = tmpRoot("race")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        // Before the fix: both tasks saw the unlocked-read miss, both minted,
        // and the second patch clobbered the first. The mint decision now
        // happens INSIDE the flock, so the loser adopts rather than overwrites.
        let resolved = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 {
                group.addTask { try await store.activeSessionId(chatId: 555) }
            }
            var out: [String] = []
            for try await id in group { out.append(id) }
            return out
        }

        #expect(Set(resolved).count == 1, "concurrent resolution produced \(Set(resolved))")

        // And exactly one index row exists for it — no orphans left behind.
        let ids = try sessionIds(in: root)
        let resolvedId = try #require(resolved.first)
        #expect(ids.filter { $0 == resolvedId }.count == 1)
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == resolvedId)
    }

    @Test("a session already in the map is adopted, never re-minted")
    func existingMappingIsAdopted() async throws {
        let root = tmpRoot("adopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramSessionStore(dataRoot: root)

        let minted = try await store.startNewSession(chatId: 3)
        let resolved = try await store.activeSessionId(chatId: 3)
        #expect(resolved == minted)
        let ids = try sessionIds(in: root)
        #expect(ids.filter { $0 == minted }.count == 1)
    }
}
