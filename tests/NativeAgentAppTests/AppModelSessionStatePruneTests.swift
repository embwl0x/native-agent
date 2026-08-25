import Foundation
import Testing
@testable import NativeAgentApp

// EVAL — ledger fence app.runtimes, row `appmodel.chat.sessionStatePrune`
// (AppModel+ChatState.swift:467 pruneSessionChatState / :503
// pruneStaleSessionChatState).
//
// Silent failure named in the ledger: state-lifecycle leak. The live
// data/chat/session_state/ directory holds 3,299 entries and
// data/chat/messages 2,003 — if the sweep stops matching known session ids the
// per-session dictionaries grow for the process lifetime with no symptom. The
// inverse is worse: pruning a session that is still being WRITTEN drops a live
// turn's slot mid-stream.
//
// Both directions are pinned here, over every dictionary the sweep unions.
@Suite("App model session chat-state prune")
struct AppModelSessionStatePruneTests {
    @MainActor
    private func seed(_ model: AppModel, session: String) {
        model.chatMessagesBySession[session] = [
            ChatMessage(id: "\(session)-m1", sessionId: session, role: "user", content: "hi"),
        ]
        model.detachedChatRefreshStatus[session] = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSuccessAt: nil,
            failedEndpoints: []
        )
        model.detachedChatContextReceiptRefreshStatus[session] = AppModel.PanelRefreshStatus(
            lastAttemptAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSuccessAt: nil,
            failedEndpoints: []
        )
        model.queuedChatTurnsBySession[session] = [QueuedChatTurn(text: "queued")]
        model.pausedChatQueueSessions.insert(session)
    }

    @MainActor
    private func isCached(_ model: AppModel, session: String) -> Bool {
        model.chatMessagesBySession[session] != nil
            || model.latestContextReceiptBySession[session] != nil
            || model.detachedChatRefreshStatus[session] != nil
            || model.detachedChatContextReceiptRefreshStatus[session] != nil
            || model.queuedChatTurnsBySession[session] != nil
            || model.pausedChatQueueSessions.contains(session)
            || model.chatTurnLifecycleBySession[session] != nil
            || model.activeChatTurnLifecycleIDsBySession[session] != nil
    }

    @MainActor
    @Test("a session the server no longer reports is swept out of every cache")
    func staleSessionIsFullyPruned() {
        let model = AppModel()
        model.activeChatSessionId = "session-active"
        seed(model, session: "session-active")
        seed(model, session: "session-known")
        seed(model, session: "session-gone")

        model.pruneStaleSessionChatState(knownSessionIds: ["session-active", "session-known"])

        #expect(isCached(model, session: "session-gone") == false,
                "a retired session must leave no per-session slot behind")
        // Every union member individually — a partial prune is the leak.
        #expect(model.chatMessagesBySession["session-gone"] == nil)
        #expect(model.detachedChatRefreshStatus["session-gone"] == nil)
        #expect(model.detachedChatContextReceiptRefreshStatus["session-gone"] == nil)
        #expect(model.queuedChatTurnsBySession["session-gone"] == nil)
        #expect(model.pausedChatQueueSessions.contains("session-gone") == false)

        #expect(isCached(model, session: "session-known"))
        #expect(isCached(model, session: "session-active"))
    }

    @MainActor
    @Test("a session with live work is kept even when it is not in the known list")
    func liveWorkIsNeverPruned() {
        let model = AppModel()
        model.activeChatSessionId = "session-active"
        seed(model, session: "session-active")
        seed(model, session: "session-streaming")
        seed(model, session: "session-busy")
        seed(model, session: "session-gone")
        model.streamingSessions.insert("session-streaming")
        model.busySessions.insert("session-busy")

        // The known list is EMPTY — the harshest input the sweep can get.
        model.pruneStaleSessionChatState(knownSessionIds: [])

        #expect(isCached(model, session: "session-streaming"),
                "pruning a streaming session drops the slot its deltas are landing in")
        #expect(isCached(model, session: "session-busy"))
        #expect(isCached(model, session: "session-active"),
                "the session on screen is never stale")
        #expect(isCached(model, session: "session-gone") == false)
    }

    @MainActor
    @Test("an empty sweep over only-known sessions changes nothing")
    func sweepIsANoOpWhenNothingIsStale() {
        let model = AppModel()
        model.activeChatSessionId = "session-a"
        seed(model, session: "session-a")
        seed(model, session: "session-b")
        let before = model.chatMessagesBySession.count

        model.pruneStaleSessionChatState(knownSessionIds: ["session-a", "session-b"])

        // Safe to call from the low-frequency session-list refresh: it must
        // never be the thing that quietly empties the caches.
        #expect(model.chatMessagesBySession.count == before)
        #expect(isCached(model, session: "session-a"))
        #expect(isCached(model, session: "session-b"))
    }
}
