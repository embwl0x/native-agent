import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// Coverage ledger app.chat / ui.chat.queue.pausedIndicator (UNCOVERED →
// COVERED).
//
// Silent-failure mode being pinned: ChatQueuedTurnsView renders "Paused" vs
// "Next" from `AppModel.isChatQueuePaused(_:)`. If that predicate stops tracking
// the state that actually gates the drain, a queue that will never run says
// "Next" (the user waits forever) or a live queue says "Paused". The existing
// queue suite (ChatSendNextQueueTests) never touches the paused set.
//
// The envelope asserted: the label predicate and the drain gate are the SAME
// state — a session reported paused provably does not drain, and one reported
// unpaused does. Driven through the public queue API with
// `queuedChatTurnStartOverride` standing in for the turn engine.

private actor PausedQueueRecorder {
    private(set) var started: [String] = []
    private var acceptNext = true
    func setAccepting(_ value: Bool) { acceptNext = value }
    func record(_ text: String) -> Bool {
        started.append(text)
        return acceptNext
    }
}

private func pausedQueueSession(_ id: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {"id": "\(id)", "title": "Queue", "createdAt": "2026-08-23T00:00:00Z"}
    """.utf8))
}

/// Bounded settle: yield until the recorder stops changing rather than sleeping
/// on a wall clock (the drain hops one MainActor Task).
private func settleQueue(_ recorder: PausedQueueRecorder, iterations: Int = 200) async {
    for _ in 0..<iterations { await Task.yield() }
    _ = await recorder.started
}

@MainActor
@Suite("Chat queue paused indicator")
struct ChatQueuePausedIndicatorTests {

    /// A drain attempt that the turn engine refuses must re-queue the turn AND
    /// latch the paused state — the label the user then sees ("Paused") must
    /// match a queue that really has stopped.
    @Test func aRefusedDrainLatchesPausedAndTheQueueStopsDraining() async throws {
        let model = AppModel()
        let session = try pausedQueueSession("paused-queue-\(UUID().uuidString)")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)

        _ = await model.startActiveChatTurn("first", expectedSessionId: session.id)
        #expect(!model.isChatQueuePaused(session.id), "a fresh queue must not read as paused")

        let recorder = PausedQueueRecorder()
        await recorder.setAccepting(false)
        model.queuedChatTurnStartOverride = { turn, sessionId in
            let accepted = await recorder.record(turn.text)
            return accepted ? .accepted(sessionId: sessionId) : .rejected(message: "engine refused")
        }
        model.busySessions.remove(session.id)
        model.resumeQueuedChatTurns(sessionId: session.id)
        await settleQueue(recorder)

        #expect(await recorder.started == ["first"])
        // The refusal preserved the turn and latched the pause.
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == ["first"])
        #expect(model.isChatQueuePaused(session.id),
                "a refused drain left the queue reading as live while nothing drains it")

        // The indicator now says "Paused" — prove that is true: a further Enter
        // is accepted into the queue and STILL nothing drains.
        await recorder.setAccepting(true)
        let later = await model.startActiveChatTurn("second", expectedSessionId: session.id)
        guard case .queued = later else {
            Issue.record("a turn added to a paused queue was not queued")
            return
        }
        await settleQueue(recorder)
        #expect(await recorder.started == ["first"],
                "a paused queue drained a turn the UI said was waiting")
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == ["first", "second"])
        #expect(model.isChatQueuePaused(session.id))
    }

    /// Resume must clear the paused state and let the queue drain in order —
    /// "Next" has to mean a turn is genuinely about to run.
    @Test func resumeClearsPausedAndDrainsInFIFOOrder() async throws {
        let model = AppModel()
        let session = try pausedQueueSession("resume-queue-\(UUID().uuidString)")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)
        _ = await model.startActiveChatTurn("one", expectedSessionId: session.id)
        _ = await model.startActiveChatTurn("two", expectedSessionId: session.id)

        let recorder = PausedQueueRecorder()
        await recorder.setAccepting(false)
        model.queuedChatTurnStartOverride = { turn, sessionId in
            let accepted = await recorder.record(turn.text)
            return accepted ? .accepted(sessionId: sessionId) : .rejected(message: "engine refused")
        }
        model.busySessions.remove(session.id)
        model.resumeQueuedChatTurns(sessionId: session.id)
        await settleQueue(recorder)
        #expect(model.isChatQueuePaused(session.id))

        await recorder.setAccepting(true)
        model.resumeQueuedChatTurns(sessionId: session.id)
        await settleQueue(recorder)

        #expect(!model.isChatQueuePaused(session.id),
                "resume left the queue reading as paused after a successful start")
        #expect(await recorder.started == ["one", "one"],
                "resume did not restart the head turn in FIFO order")
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == ["two"])
    }

    /// The paused set is per session. A paused detached panel must not freeze
    /// the main window's queue (and must not make its strip read "Paused").
    @Test func pausedStateIsScopedToOneSession() async throws {
        let model = AppModel()
        let run = UUID().uuidString
        let a = try pausedQueueSession("queue-A-\(run)")
        let b = try pausedQueueSession("queue-B-\(run)")
        model.chatSessions = [a, b]
        model.activeChatSessionId = a.id
        model.busySessions = [a.id, b.id]
        _ = await model.startActiveChatTurn("A1", expectedSessionId: a.id)
        _ = await model.sendChat("B1", sessionId: b.id)

        let recorder = PausedQueueRecorder()
        await recorder.setAccepting(false)
        model.queuedChatTurnStartOverride = { turn, sessionId in
            let accepted = await recorder.record(turn.text)
            return accepted ? .accepted(sessionId: sessionId) : .rejected(message: "engine refused")
        }
        model.busySessions.remove(a.id)
        model.resumeQueuedChatTurns(sessionId: a.id)
        await settleQueue(recorder)

        #expect(model.isChatQueuePaused(a.id))
        #expect(!model.isChatQueuePaused(b.id),
                "pausing one session's queue latched another session's indicator")
        #expect(model.queuedChatTurns(for: b.id).map(\.text) == ["B1"])
    }

    /// Emptying a queue must clear the pause with it — a paused set that
    /// outlives its turns leaves a "Paused" latch that suppresses the next
    /// drain for that session.
    @Test func removingTheLastQueuedTurnClearsThePausedLatch() async throws {
        let model = AppModel()
        let session = try pausedQueueSession("drain-clear-\(UUID().uuidString)")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)
        let queued = await model.startActiveChatTurn("only", expectedSessionId: session.id)
        guard case .queued(_, let turnId) = queued else {
            Issue.record("turn was not queued")
            return
        }

        let recorder = PausedQueueRecorder()
        await recorder.setAccepting(false)
        model.queuedChatTurnStartOverride = { turn, sessionId in
            let accepted = await recorder.record(turn.text)
            return accepted ? .accepted(sessionId: sessionId) : .rejected(message: "engine refused")
        }
        model.busySessions.remove(session.id)
        model.resumeQueuedChatTurns(sessionId: session.id)
        await settleQueue(recorder)
        #expect(model.isChatQueuePaused(session.id))

        model.removeQueuedChatTurn(turnId, sessionId: session.id)
        #expect(model.queuedChatTurns(for: session.id).isEmpty)
        #expect(!model.isChatQueuePaused(session.id),
                "the paused latch outlived the queue it belonged to")
    }
}
