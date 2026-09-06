import Testing
import Foundation
@testable import PersistenceCore

// MARK: - The conversation anchor
//
// User's 2026-09-01 decision: NOT one absorbing thread. `/new` stays a real new
// session ("I use /new to clear Agent's head"); the new one becomes the pinned
// anchor on Mac and iPhone; the old one stays reachable; every surface keeps
// full multi-session.
//
// These tests pin that behavior AND the product constraint that outlives it:
// the anchor is SURFACE-AGNOSTIC. A surface connected next year publishes an
// anchor by making one call, and no consumer learns its name.

@Suite("ConversationAnchor", .serialized)
struct ConversationAnchorTests {

    private func tmpRoot(_ label: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Publish / consume

    @Test("publishing writes the pin and current() reads it back")
    func publishRoundTrip() async throws {
        let root = tmpRoot("round-trip")
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await ConversationAnchor.publish(
            sessionId: "session-1",
            source: "telegram",
            conversationKind: .direct,
            dataRoot: root
        )
        guard case .published(let pin) = outcome else {
            Issue.record("expected published, got \(outcome)")
            return
        }
        #expect(pin.sessionId == "session-1")
        #expect(pin.source == "telegram")
        #expect(!pin.updatedAt.isEmpty)

        let current = try #require(ConversationAnchor.current(dataRoot: root))
        #expect(current == pin)
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "session-1")
    }

    @Test("republishing the same session does not rewrite the file")
    func republishIsUnchanged() async throws {
        let root = tmpRoot("unchanged")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ConversationAnchor.publish(
            sessionId: "s", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        let second = try await ConversationAnchor.publish(
            sessionId: "s", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        // Publishers may call this on every inbound message; churning the file
        // (and the phone snapshot) for an unchanged fact is exactly the kind of
        // busywork that shows up later as sync noise.
        guard case .unchanged = second else {
            Issue.record("expected unchanged, got \(second)")
            return
        }
    }

    // MARK: `/new` — a real new session that takes over the pin

    @Test("a new session takes over the anchor and the old one stays reachable")
    func newSessionMovesTheAnchor() async throws {
        let root = tmpRoot("new")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ConversationAnchor.publish(
            sessionId: "old-session", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        _ = try await ConversationAnchor.publish(
            sessionId: "new-session", source: "telegram", conversationKind: .direct, dataRoot: root
        )

        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "new-session")
        // THE POINT of User's decision: `/new` clears her head without deleting
        // anything. The anchor is a pointer, not a container — moving it
        // touches no transcript and no index row, so the previous session is
        // exactly as reachable as it was a moment ago.
        #expect(ConversationAnchor.protectedSessionIds(dataRoot: root) == ["new-session"])
    }

    @Test("most recently published wins, whichever surface published it")
    func mostRecentWins() async throws {
        let root = tmpRoot("recency")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ConversationAnchor.publish(
            sessionId: "tg", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        _ = try await ConversationAnchor.publish(
            sessionId: "sig", source: "signal", conversationKind: .direct, dataRoot: root
        )
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "sig")
        _ = try await ConversationAnchor.publish(
            sessionId: "tg", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "tg")
    }

    @Test("a publish that stalled cannot clobber a newer anchor")
    func stalePublishIsRefused() async throws {
        let root = tmpRoot("stale")
        defer { try? FileManager.default.removeItem(at: root) }

        // The `/new` User just did on his phone, committed ahead of the loser's
        // clock. (The stamp is taken inside the lock, so a later clock reading
        // is the only way to stage "already committed" deterministically.)
        _ = try await ConversationAnchor.publish(
            sessionId: "the-new-one",
            source: "telegram",
            conversationKind: .direct,
            dataRoot: root,
            now: Date().addingTimeInterval(300)
        )

        // A publish for the conversation he LEFT, arriving late — a slow
        // adapter, a contended lock, a suspended task. It must not reinstate
        // the old conversation: most-recent wins is the anchor's only rule.
        let stalled = try await ConversationAnchor.publish(
            sessionId: "the-one-he-left",
            source: "telegram",
            conversationKind: .direct,
            dataRoot: root
        )

        #expect(stalled == .refused(.supersededByNewerAnchor))
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "the-new-one")
    }

    @Test("the commit stamp is taken at commit time, not at call time")
    func stampIsTakenAtCommitTime() async throws {
        let root = tmpRoot("stamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Date()
        // A caller whose clock is behind (or who started the call long ago)
        // cannot backdate the anchor: the stamp that lands is the lock's.
        let outcome = try await ConversationAnchor.publish(
            sessionId: "s",
            source: "telegram",
            conversationKind: .direct,
            dataRoot: root,
            now: before.addingTimeInterval(-3600)
        )
        guard case .published(let pin) = outcome else {
            Issue.record("expected published, got \(outcome)")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamped = try #require(formatter.date(from: pin.updatedAt))
        #expect(stamped >= before, "an hour-old clock reading must not become the anchor's age")
    }

    // MARK: Refusals

    @Test("a shared room can never become the anchor")
    func sharedRoomsAreRefused() async throws {
        let root = tmpRoot("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try await ConversationAnchor.publish(
            sessionId: "slack-channel-session",
            source: "slack",
            conversationKind: .channel,
            dataRoot: root
        )
        #expect(outcome == .refused(.notADirectConversation))
        #expect(ConversationAnchor.current(dataRoot: root) == nil)

        // Expressed as a KIND, not a surface allowlist — so the rule is already
        // right for a surface that has both DMs and rooms.
        for kind in [ChatThreadKind.builder, .ephemeral, .legacy] {
            let refused = try await ConversationAnchor.publish(
                sessionId: "x", source: "whatever", conversationKind: kind, dataRoot: root
            )
            #expect(refused == .refused(.notADirectConversation))
        }
    }

    @Test("empty inputs are refused with a named reason, not silently dropped")
    func emptyInputsRefused() async throws {
        let root = tmpRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            try await ConversationAnchor.publish(
                sessionId: "  ", source: "telegram", conversationKind: .direct, dataRoot: root
            ) == .refused(.emptySessionID)
        )
        #expect(
            try await ConversationAnchor.publish(
                sessionId: "s", source: " ", conversationKind: .direct, dataRoot: root
            ) == .refused(.emptySource)
        )
    }

    // MARK: Surface-agnostic consumption

    @Test("a surface invented in this test anchors with no change outside itself")
    func aBrandNewSurfaceCanAnchor() async throws {
        let root = tmpRoot("signal")
        defer { try? FileManager.default.removeItem(at: root) }

        // "signal" appears nowhere in PersistenceCore, the Mac pin strip, the
        // snapshot writer, or retention. If this passes, adding a surface costs
        // one call in that surface's own adapter.
        let outcome = try await ConversationAnchor.publish(
            sessionId: "signal-conv-1",
            source: "signal",
            conversationKind: .direct,
            dataRoot: root
        )
        guard case .published = outcome else {
            Issue.record("expected published, got \(outcome)")
            return
        }

        // Every consumer path, exercised without naming a surface.
        #expect(ConversationAnchor.currentSessionId(dataRoot: root) == "signal-conv-1")
        #expect(ConversationAnchor.protectedSessionIds(dataRoot: root) == ["signal-conv-1"])
        #expect(
            ConversationAnchor.merged(into: ["a", "b"], dataRoot: root) == ["signal-conv-1", "a", "b"]
        )
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: ConversationAnchor.currentSessionId(dataRoot: root),
            currentSelection: "a",
            userChoseThisLaunch: false,
            liveSessionIds: ["a", "b", "signal-conv-1"]
        ))
    }

    // MARK: Pin merging

    @Test("the anchor goes first without duplicating or reordering human pins")
    func mergeKeepsHumanPinsIntact() {
        #expect(
            ConversationAnchor.merged(into: ["a", "b", "c"], anchorSessionId: "anchor")
                == ["anchor", "a", "b", "c"]
        )
        // Already pinned by the human: promoted, never duplicated.
        #expect(
            ConversationAnchor.merged(into: ["a", "anchor", "c"], anchorSessionId: "anchor")
                == ["anchor", "a", "c"]
        )
        // No anchor: the human's list is returned untouched.
        #expect(ConversationAnchor.merged(into: ["a", "b"], anchorSessionId: nil) == ["a", "b"])
        #expect(ConversationAnchor.merged(into: ["a", "b"], anchorSessionId: "  ") == ["a", "b"])
    }

    // MARK: Defaulting without yanking

    @Test("the window defaults to the anchor only until the human picks something")
    func adoptionRespectsTheHumansChoice() {
        let live: Set<String> = ["anchor", "other"]

        // Fresh launch, showing something else → adopt.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "anchor",
            currentSelection: "other",
            userChoseThisLaunch: false,
            liveSessionIds: live
        ))

        // The human has chosen this launch → never move the screen. Same
        // protection iOS gives itself in `shouldReturnToMainSession`.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "anchor",
            currentSelection: "other",
            userChoseThisLaunch: true,
            liveSessionIds: live
        ) == false)

        // Already showing it → nothing to do.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "anchor",
            currentSelection: "anchor",
            userChoseThisLaunch: false,
            liveSessionIds: live
        ) == false)

        // A stale pin naming a session that is gone must never blank the
        // window — that would be worse than not defaulting at all.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "archived-or-deleted",
            currentSelection: "other",
            userChoseThisLaunch: false,
            liveSessionIds: live
        ) == false)

        // No anchor yet.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: nil,
            currentSelection: "other",
            userChoseThisLaunch: false,
            liveSessionIds: live
        ) == false)
    }

    // MARK: Retention

    @Test("retention will not archive the anchor even at the cap")
    func retentionProtectsTheAnchor() async throws {
        let root = tmpRoot("retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appendingPathComponent("chat", isDirectory: true)
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)

        // The anchor is the OLDEST row, so recency ordering would archive it
        // first — which is precisely the moment it must not be archived: it is
        // the conversation the human is in.
        _ = try await ConversationAnchor.publish(
            sessionId: "the-anchor", source: "telegram", conversationKind: .direct, dataRoot: root
        )

        var rows: [JSONValue] = []
        for index in 0..<12 {
            rows.append(.object([
                "id": .string("filler-\(index)"),
                "title": .string("Filler \(index)"),
                "source": .string("app"),
                "archived": .bool(false),
                "messageCount": .int(3),
            ]))
        }
        rows.append(.object([
            "id": .string("the-anchor"),
            "title": .string("Live conversation"),
            "source": .string("telegram"),
            "archived": .bool(false),
            "messageCount": .int(9),
        ]))
        try JSONValue.array(rows).serializedData(pretty: false)
            .write(to: chat.appendingPathComponent("sessions.json"))

        ChatSessionRetention.enforceBestEffort(
            dataRoot: root,
            now: Date(),
            policy: ChatSessionRetentionPolicy(maxActiveSessions: 5),
            context: "ConversationAnchorTests"
        )

        guard case .array(let after) = try JSONValue.parse(
            try Data(contentsOf: chat.appendingPathComponent("sessions.json"))
        ) else {
            Issue.record("sessions.json unreadable after retention")
            return
        }
        let survivingIds = after.compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        }
        #expect(survivingIds.contains("the-anchor"), "retention archived the live conversation")
    }
}
