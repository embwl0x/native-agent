import Foundation
import Testing
import ApprovalInbox
import struct ChatOrchestration.TurnEnvelope
import enum ChatOrchestration.ChatToolSessionContext
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
@testable import NativeAgentApp

// MARK: - The Mac side of the conversation anchor
//
// User's 2026-09-01 decision: the remote conversation he is currently in should
// be one tap away on the Mac and the iPhone, WITHOUT either surface losing its
// own multiple sessions ("I run several sessions at once to knock out a couple
// things; that must not be lost").
//
// So the Mac does exactly two things with the anchor, and both are additive:
//   * merges it into the front of the pin strip, without writing it into the
//     human's pin list;
//   * defaults the main window to it on launch, and stops the moment the human
//     picks something else.
//
// Nothing in this file — or in the code it tests — names a messaging surface.
// That is the product constraint: Signal or WhatsApp tomorrow must cost one
// call inside its own adapter and nothing here.

@Suite("Mac conversation anchor", .serialized)
struct MacAnchorSessionTests {

    private func tmpRoot(_ label: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-anchor-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: The pin strip

    @Test("the anchor rides in front of the human's pins without joining them")
    func anchorIsMergedNotWritten() async throws {
        let root = tmpRoot("merge")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await ConversationAnchor.publish(
            sessionId: "live-conversation",
            source: "signal",          // a surface the Mac has never heard of
            conversationKind: .direct,
            dataRoot: root
        )

        let humanPins = ["project-a", "project-b"]
        let shown = ConversationAnchor.merged(into: humanPins, dataRoot: root)

        #expect(shown == ["live-conversation", "project-a", "project-b"])
        // The human's own list is untouched — order, membership, and their
        // right to unpin anything. An auto-WRITE would fight them on every
        // unpin and rewrite the file on every `/new`.
        #expect(humanPins == ["project-a", "project-b"])
    }

    @Test("multi-session is preserved — the anchor adds a pin, it replaces nothing")
    func multiSessionSurvives() async throws {
        let root = tmpRoot("multi")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ConversationAnchor.publish(
            sessionId: "anchor", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        let shown = ConversationAnchor.merged(into: ["p1", "p2", "p3"], dataRoot: root)
        #expect(shown.count == 4)
        for pin in ["p1", "p2", "p3"] {
            #expect(shown.contains(pin), "the human's own sessions must all survive")
        }
    }

    // MARK: Defaulting, and the protection against yanking

    @Test("the window adopts the anchor on launch")
    @MainActor
    func defaultsToTheAnchorOnLaunch() {
        MacChatSelectionIntent.resetForTesting()
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "anchor",
            currentSelection: "stale-from-last-launch",
            userChoseThisLaunch: MacChatSelectionIntent.userChoseThisLaunch,
            liveSessionIds: ["anchor", "stale-from-last-launch"]
        ))
    }

    @Test("once the human picks a session this launch, the anchor stops moving the window")
    @MainActor
    func neverYanksTheHumanOffTheirChoice() {
        MacChatSelectionIntent.resetForTesting()
        MacChatSelectionIntent.noteUserChoice()

        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "anchor",
            currentSelection: "the-one-he-opened",
            userChoseThisLaunch: MacChatSelectionIntent.userChoseThisLaunch,
            liveSessionIds: ["anchor", "the-one-he-opened"]
        ) == false)

        // Even after a `/new` on the remote surface moves the anchor: he is
        // mid-thought in a session he opened, and a background republish does
        // not get to change the screen. Same protection iOS gives itself in
        // `shouldReturnToMainSession`.
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "a-newer-anchor",
            currentSelection: "the-one-he-opened",
            userChoseThisLaunch: MacChatSelectionIntent.userChoseThisLaunch,
            liveSessionIds: ["a-newer-anchor", "the-one-he-opened"]
        ) == false)

        MacChatSelectionIntent.resetForTesting()
    }

    @Test("an anchor naming a session that is gone never blanks the window")
    @MainActor
    func staleAnchorIsIgnored() {
        MacChatSelectionIntent.resetForTesting()
        #expect(ConversationAnchor.shouldAdoptAnchor(
            anchorSessionId: "archived-yesterday",
            currentSelection: "current",
            userChoseThisLaunch: false,
            liveSessionIds: ["current"]
        ) == false)
    }

    // MARK: The strip actually shows it (the merge has to reach the view)

    private func anchorTestSession(_ id: String) throws -> ChatSession {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "title": id,
            "messageCount": 0,
            "createdAt": "2026-09-01T00:00:00Z",
        ])
        return try JSONDecoder().decode(ChatSession.self, from: data)
    }

    @Test("the projected strip puts the anchor in front, and moving it rebuilds")
    @MainActor
    func projectedStripShowsTheAnchor() throws {
        let cache = ChatSidebarProjectionCache()
        let sessions = try ["project-a", "live-conversation", "a-later-one"]
            .map(anchorTestSession)
        let pinnedRaw = "project-a"

        // Merging in `decodedPinnedSessionIds()` was never enough: the strip is
        // built by this cache, which decoded the raw pin string directly, so
        // the anchor never reached `PinnedSessionTabStrip` at all.
        let withAnchor = cache.project(
            sessions: sessions,
            pinnedRaw: pinnedRaw,
            anchorSessionId: "live-conversation",
            search: ""
        )
        #expect(withAnchor.pinnedTabs.map(\.id) == ["live-conversation", "project-a"])
        #expect(withAnchor.sections.pinned.map(\.id) == ["live-conversation", "project-a"])

        // Identical inputs stay cached — the strip must not rebuild at token
        // cadence.
        let rebuilds = cache.rebuildCount
        _ = cache.project(
            sessions: sessions,
            pinnedRaw: pinnedRaw,
            anchorSessionId: "live-conversation",
            search: ""
        )
        #expect(cache.rebuildCount == rebuilds)

        // A `/new` on the phone changes NOTHING else: same sessions, same pin
        // string, same search. If the anchor is not part of the cache key the
        // strip keeps showing the conversation User just left.
        let moved = cache.project(
            sessions: sessions,
            pinnedRaw: pinnedRaw,
            anchorSessionId: "a-later-one",
            search: ""
        )
        #expect(cache.rebuildCount == rebuilds + 1)
        #expect(moved.pinnedTabs.map(\.id) == ["a-later-one", "project-a"])

        // And an anchor the human has already pinned himself is not duplicated.
        let alsoPinned = cache.project(
            sessions: sessions,
            pinnedRaw: "project-a|live-conversation",
            anchorSessionId: "live-conversation",
            search: ""
        )
        #expect(alsoPinned.pinnedTabs.map(\.id) == ["live-conversation", "project-a"])

        // No anchor: the human's pins, untouched.
        let none = cache.project(
            sessions: sessions,
            pinnedRaw: pinnedRaw,
            anchorSessionId: nil,
            search: ""
        )
        #expect(none.pinnedTabs.map(\.id) == ["project-a"])
    }

    @Test("the strip's anchor read is memoized so a streaming body does not hit the disk")
    @MainActor
    func anchorReadIsMemoized() {
        MacConversationAnchorReading.resetForTesting()
        var reads = 0
        let start = Date()
        let first = MacConversationAnchorReading.currentSessionId(
            now: start, read: { reads += 1; return "anchor-1" }
        )
        let second = MacConversationAnchorReading.currentSessionId(
            now: start.addingTimeInterval(0.1), read: { reads += 1; return "anchor-2" }
        )
        #expect(first == "anchor-1")
        #expect(second == "anchor-1")
        #expect(reads == 1, "body passes within the window must not re-read the file")

        let later = MacConversationAnchorReading.currentSessionId(
            now: start.addingTimeInterval(2), read: { reads += 1; return "anchor-2" }
        )
        #expect(later == "anchor-2", "a `/new` must still land")
        #expect(reads == 2)
        MacConversationAnchorReading.resetForTesting()
    }

    // MARK: An approval filed from an envelope-only surface can get home

    @Test("an approval filed from an envelope-only route carries destination, thread and source")
    func approvalCarriesTheEnvelopeRoute() async throws {
        let root = tmpRoot("approval")
        defer { try? FileManager.default.removeItem(at: root) }

        let filer = NativeAgentChatApprovalFiler(dataRoot: root)
        // A new adapter binds an envelope and nothing else — no
        // `ChatToolSessionContext.replyRoute`, no `verifiedChatId`. Reading
        // those task-locals directly filed an approval with a null route, so
        // the reply a human approved minutes later had nowhere to go.
        let envelope = TurnEnvelope(
            surface: "signal",
            verifiedChatId: "sig-conv-1",
            verifiedUserId: "sig-user-1",
            deliveryRoute: ChatToolSessionContext.ReplyRoute(
                surface: "signal",
                destinationId: "+15550100",
                threadId: "thread-7",
                sourceKey: "signal_app",
                replyTo: "msg-42",
                correlationId: "corr-9"
            )
        )
        let id = try await ChatToolSessionContext.$envelope.withValue(envelope) {
            try await filer.fileApprovalRequest(
                toolName: "mac.shell",
                surface: "chat",
                payload: .object(["command": .string("whoami")]),
                reason: "needs a human"
            )
        }

        let record = try await SwiftNativeApprovalInbox(root: root).get(id)
        guard case .object(let payload) = record.payload,
              case .object(let origin)? = payload["origin"] else {
            Issue.record("approval payload has no origin")
            return
        }
        #expect(origin["surface"] == .string("signal"))
        #expect(origin["chatId"] == .string("sig-conv-1"))
        #expect(origin["userId"] == .string("sig-user-1"))
        #expect(origin["destinationId"] == .string("+15550100"))
        #expect(origin["threadId"] == .string("thread-7"))
        #expect(origin["sourceKey"] == .string("signal_app"))
        #expect(origin["replyTo"] == .string("msg-42"))
        #expect(origin["correlationId"] == .string("corr-9"))
    }

    @Test("a pre-envelope surface files exactly what it filed before")
    func approvalFallsBackToLegacyBindings() async throws {
        let root = tmpRoot("approval-legacy")
        defer { try? FileManager.default.removeItem(at: root) }

        let filer = NativeAgentChatApprovalFiler(dataRoot: root)
        let id = try await ChatToolSessionContext.$verifiedChatId.withValue("1394548068") {
            try await ChatToolSessionContext.$replyRoute.withValue(
                ChatToolSessionContext.ReplyRoute(surface: "telegram", destinationId: "1394548068")
            ) {
                try await filer.fileApprovalRequest(
                    toolName: "mac.shell",
                    surface: "telegram",
                    payload: .object(["command": .string("whoami")]),
                    reason: "needs a human"
                )
            }
        }

        let record = try await SwiftNativeApprovalInbox(root: root).get(id)
        guard case .object(let payload) = record.payload,
              case .object(let origin)? = payload["origin"] else {
            Issue.record("approval payload has no origin")
            return
        }
        #expect(origin["chatId"] == .string("1394548068"))
        #expect(origin["destinationId"] == .string("1394548068"))
        #expect(origin["surface"] == .string("telegram"))
    }

    // MARK: The phone's copy

    @Test("the anchor rides in the same snapshot group as the sessions it names")
    func anchorIsPublishedInTheCoreGroup() {
        // If it shipped in a different group the phone could receive a pin
        // naming a session it has not been given yet.
        let core = NAMobileSnapshotGroup.core.filenames
        #expect(core.contains("chat_anchor.json"))
        #expect(core.contains("sessions.json"))
        #expect(core.contains("pinned_chat_sessions.json"))
        #expect(NAMobileSnapshotGroup.groups(containingAny: ["chat_anchor.json"])
            == Set([NAMobileSnapshotGroup.core]))
    }

    // MARK: The delivery rule (plan §3.7)

    @Test("nothing in the anchor path can push to another surface")
    func anchorNeverPushes() async throws {
        let root = tmpRoot("no-push")
        defer { try? FileManager.default.removeItem(at: root) }

        // The strongest available structural statement of plan §3.7 at this
        // layer: the anchor is a POINTER to a session id, and carries no
        // destination, no route, and no transport handle. There is nothing in
        // it for a delivery path to read, so "the anchor changed" cannot become
        // "notify the attached surfaces" — the failure mode (§8 R2) most likely
        // to get this feature reverted on day one.
        //
        // A Mac turn's reply still goes only to its own envelope's
        // deliveryRoute; see TurnEnvelope and its tests.
        _ = try await ConversationAnchor.publish(
            sessionId: "s", source: "telegram", conversationKind: .direct, dataRoot: root
        )
        let pin = try #require(ConversationAnchor.current(dataRoot: root))
        let mirror = Mirror(reflecting: pin)
        let fields = Set(mirror.children.compactMap(\.label))
        #expect(fields == ["sessionId", "source", "updatedAt"])
    }
}
