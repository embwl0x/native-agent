import Foundation
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`.
///
/// Rows closed here:
///   * `ios.chat.queuedSendStrip.removeQueued` — "a removed queued turn that
///     stays in the persisted queue store re-appears on next launch."
///   * `ios.chat.queuedSendStrip.overflowMenu` — Send-next reordering must move
///     a turn inside ITS OWN session bucket and survive a relaunch in that
///     order, or the phone sends the user's turns in an order they never chose.
///
/// Silent-failure class: STATE-LIFECYCLE LEAK + DROPPED ROW. Every one of these
/// paths is invisible until the app is relaunched, which is exactly when nobody
/// is watching. The store takes an injected `UserDefaults` suite, so a
/// "relaunch" here is a real second `ChatStore` over the same persisted bytes —
/// not a fixture of what the persisted bytes are assumed to look like.
@MainActor
final class ChatQueuedSendLifecycleEvalTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "NativeAgentMobileTests.queuedSends.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "NativeAgent.unifiedSession.v1")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func queued(_ text: String, session: String?) -> QueuedChatSend {
        QueuedChatSend(
            id: UUID(),
            sessionID: session,
            text: text,
            controls: .defaults,
            attachments: [],
            createdAt: Date()
        )
    }

    /// A second store over the same suite — the persisted state as a RELAUNCH
    /// would actually read it.
    private func relaunch() -> ChatStore {
        ChatStore(defaults: defaults, restoreQueuedSends: true)
    }

    // MARK: - ios.chat.queuedSendStrip.removeQueued

    func test_removedQueuedSendDoesNotComeBackOnRelaunch() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        let keep = queued("keep me", session: "session-a")
        let drop = queued("drop me", session: "session-a")
        store.queuedSends = [keep, drop]

        store.removeQueuedSend(drop.id)
        XCTAssertEqual(store.queuedSends.map(\.id), [keep.id])

        let restored = relaunch()
        XCTAssertEqual(
            restored.queuedSends.map(\.text), ["keep me"],
            "a queued turn the user deleted was resurrected from the persisted queue on relaunch"
        )
    }

    func test_removingTheLastQueuedTurnClearsThePausedLatchForThatSession() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        let only = queued("only", session: "session-a")
        store.queuedSends = [only]
        store.pausedQueueSessionKeys.insert(store.queueSessionKey("session-a"))

        store.removeQueuedSend(only.id)

        XCTAssertTrue(store.queuedSends.isEmpty)
        XCTAssertFalse(
            store.isSelectedQueuePaused,
            "the paused latch outlived the queue it was gating — the next send would sit paused forever with nothing on screen explaining why"
        )
    }

    func test_removingAQueuedTurnLeavesOtherSessionsUntouched() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        let a1 = queued("a1", session: "session-a")
        let b1 = queued("b1", session: "session-b")
        store.queuedSends = [a1, b1]

        store.removeQueuedSend(a1.id)

        XCTAssertEqual(store.queuedSends.map(\.text), ["b1"])
        XCTAssertEqual(relaunch().queuedSends.map(\.text), ["b1"])
    }

    // MARK: - ios.chat.queuedSendStrip.overflowMenu (Send next)

    func test_sendNextPromotesWithinItsOwnSessionAndPersistsTheNewOrder() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        let a1 = queued("a1", session: "session-a")
        let a2 = queued("a2", session: "session-a")
        let a3 = queued("a3", session: "session-a")
        let b1 = queued("b1", session: "session-b")
        store.queuedSends = [b1, a1, a2, a3]

        XCTAssertTrue(store.promoteQueuedSend(a3.id))

        XCTAssertEqual(
            store.queuedSendsForSelectedSession.map(\.text), ["a3", "a1", "a2"],
            "Send next did not put the chosen turn at the head of its own session queue"
        )
        XCTAssertEqual(
            store.queuedSends.map(\.text), ["b1", "a3", "a1", "a2"],
            "promotion reordered another session's queue"
        )
        XCTAssertEqual(relaunch().queuedSends.map(\.text), ["b1", "a3", "a1", "a2"])
    }

    func test_promotingAnUnknownIDIsANoOp() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        let a1 = queued("a1", session: "session-a")
        store.queuedSends = [a1]

        XCTAssertFalse(store.promoteQueuedSend(UUID()))
        XCTAssertEqual(store.queuedSends.map(\.text), ["a1"])
    }

    // MARK: - persisted-queue preservation

    func test_persistedQueueKeepsEveryAdmittedTurnBeyondTheFormerCap() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID("session-a")
        // 56a70cbc preserves every admitted turn instead of evicting paused work.
        store.queuedSends = (0..<75).map { queued("turn-\($0)", session: "session-a") }

        let restored = relaunch()
        let texts = restored.queuedSends.map(\.text)

        XCTAssertEqual(texts.count, 75)
        XCTAssertEqual(texts, (0..<75).map { "turn-\($0)" }, "relaunch must preserve every accepted turn in order")
    }

    // MARK: - session migration (the id the queue is keyed by can change)

    func test_migratingASessionCarriesItsQueuedTurnsAndItsPausedLatch() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        store.setSelectedSessionID(nil)
        let pending = queued("written before the session existed", session: nil)
        store.queuedSends = [pending]
        store.pausedQueueSessionKeys.insert(store.queueSessionKey(nil))

        store.migrateQueuedSends(from: nil, to: "server-assigned-1")
        store.setSelectedSessionID("server-assigned-1")

        XCTAssertEqual(store.queuedSendsForSelectedSession.map(\.text), ["written before the session existed"])
        XCTAssertTrue(
            store.isSelectedQueuePaused,
            "the paused latch was stranded on the old session key, so the queue would drain past a pause the user asked for"
        )
        XCTAssertEqual(relaunch().queuedSends.first?.sessionID, "server-assigned-1")
    }

    func testUnifiedSessionMigrationPurgesOnlyOnceAcrossRelaunch() {
        defaults.set("legacy", forKey: "NativeAgentMobile.chatSessionID")
        defaults.set("legacy-main", forKey: "NativeAgentMobile.mainChatSessionID")
        defaults.removeObject(forKey: "NativeAgent.unifiedSession.v1")
        _ = ChatStore(defaults: defaults, restoreQueuedSends: false)
        XCTAssertNil(defaults.string(forKey: "NativeAgentMobile.chatSessionID"))
        defaults.set("new", forKey: "NativeAgentMobile.chatSessionID")
        _ = ChatStore(defaults: defaults, restoreQueuedSends: false)
        XCTAssertEqual(defaults.string(forKey: "NativeAgentMobile.chatSessionID"), "new")
    }

    func testStreamingHintNeverPretendsAResolvedTurnIsProgress() {
        let store = ChatStore(defaults: defaults, restoreQueuedSends: false)
        let message = ChatMessage(role: .assistant, text: "", isStreaming: false)
        XCTAssertEqual(store.streamingHint(for: message), "Typing")
        store.streamingHintsByMessageId[message.id] = "Working"
        XCTAssertEqual(store.streamingHint(for: message), "Working")
    }
}
