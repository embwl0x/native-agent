import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private actor QueuedTurnRecorder {
    private(set) var turns: [(String, String)] = []
    func record(_ turn: QueuedChatTurn, sessionId: String) {
        turns.append((sessionId, turn.text))
    }
}

private actor QueuedTurnStartGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func queuedTurnSession(_ id: String) throws -> ChatSession {
    try JSONDecoder().decode(ChatSession.self, from: Data("""
    {
      "id": "\(id)",
      "title": "Queue test",
      "createdAt": "2026-07-12T00:00:00Z"
    }
    """.utf8))
}

@MainActor
@Suite("Chat send-next queue")
struct ChatSendNextQueueTests {
    @Test func queueChromeStaysSingleLineInsteadOfReservingAChatObscuringList() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: repo.appendingPathComponent("Sources/NativeAgentApp/ChatQueuedTurnsView.swift"),
            encoding: .utf8
        )
        #expect(!macSource.contains("ScrollView(.vertical"))
        #expect(!macSource.contains("frame(maxHeight:"))
        #expect(macSource.contains(".lineLimit(1)"))

        let iosSource = try String(
            contentsOf: repo.appendingPathComponent("iOS/NativeAgentMobile/Sources/ChatView.swift"),
            encoding: .utf8
        )
        let start = try #require(iosSource.range(of: "private var queuedSendStrip: some View"))
        let tail = iosSource[start.lowerBound...]
        let end = try #require(tail.range(of: "\n    private var pendingPhotoStrip: some View"))
        let queueChrome = String(tail[..<end.lowerBound])
        #expect(!queueChrome.contains("ScrollView(.vertical"))
        #expect(!queueChrome.contains("frame(maxHeight:"))
        #expect(queueChrome.contains(".lineLimit(1)"))
    }

    @Test func busySessionAcceptsTurnsIntoFIFOWithoutStartingASecondTask() async throws {
        let model = AppModel()
        let session = try queuedTurnSession("queue-session")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)

        let first = await model.startActiveChatTurn("first follow-up", expectedSessionId: session.id)
        let second = await model.startActiveChatTurn("second follow-up", expectedSessionId: session.id)

        guard case .queued(let firstSession, _) = first,
              case .queued(let secondSession, _) = second
        else {
            Issue.record("busy turns must be accepted into send-next")
            return
        }
        #expect(firstSession == session.id)
        #expect(secondSession == session.id)
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == [
            "first follow-up", "second follow-up",
        ])
        #expect(model.chatTasks.isEmpty)
        #expect(model.chatMessages.isEmpty)
    }

    @Test func promoteAndRemoveAreSessionScoped() async throws {
        let model = AppModel()
        let sessionA = try queuedTurnSession("queue-A")
        let sessionB = try queuedTurnSession("queue-B")
        model.chatSessions = [sessionA, sessionB]
        model.activeChatSessionId = sessionA.id
        model.busySessions = [sessionA.id, sessionB.id]

        _ = await model.startActiveChatTurn("A1", expectedSessionId: sessionA.id)
        let a2 = await model.startActiveChatTurn("A2", expectedSessionId: sessionA.id)
        _ = await model.sendChat("B1", sessionId: sessionB.id)

        guard case .queued(_, let a2ID) = a2 else {
            Issue.record("second A turn was not queued")
            return
        }
        #expect(model.promoteQueuedChatTurn(a2ID, sessionId: sessionA.id))
        #expect(model.queuedChatTurns(for: sessionA.id).map(\.text) == ["A2", "A1"])
        #expect(model.queuedChatTurns(for: sessionB.id).map(\.text) == ["B1"])

        model.removeQueuedChatTurn(a2ID, sessionId: sessionA.id)
        #expect(model.queuedChatTurns(for: sessionA.id).map(\.text) == ["A1"])
        #expect(model.queuedChatTurns(for: sessionB.id).map(\.text) == ["B1"])
    }

    @Test func resumeDrainsThePromotedTurnThroughTheSerialStartBoundary() async throws {
        let model = AppModel()
        let session = try queuedTurnSession("queue-drain")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)
        _ = await model.startActiveChatTurn("first", expectedSessionId: session.id)
        let second = await model.startActiveChatTurn("steer me", expectedSessionId: session.id)
        guard case .queued(_, let secondID) = second else {
            Issue.record("steer candidate was not queued")
            return
        }

        let recorder = QueuedTurnRecorder()
        model.queuedChatTurnStartOverride = { turn, sessionId in
            await recorder.record(turn, sessionId: sessionId)
            return .accepted(sessionId: sessionId)
        }
        model.busySessions.remove(session.id)
        model.resumeQueuedChatTurns(sessionId: session.id, startingWith: secondID)
        for _ in 0..<20 where await recorder.turns.isEmpty { await Task.yield() }

        #expect(await recorder.turns.map(\.0) == [session.id])
        #expect(await recorder.turns.map(\.1) == ["steer me"])
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == ["first"])
    }

    @Test func aNewEnterCannotOvertakeAQueuedTurnWhileItsStartIsSuspended() async throws {
        let model = AppModel()
        let session = try queuedTurnSession("queue-start-race")
        model.chatSessions = [session]
        model.activeChatSessionId = session.id
        model.busySessions.insert(session.id)
        _ = await model.startActiveChatTurn("already queued", expectedSessionId: session.id)

        let gate = QueuedTurnStartGate()
        model.queuedChatTurnStartOverride = { _, sessionId in
            await gate.block()
            return .accepted(sessionId: sessionId)
        }
        model.busySessions.remove(session.id)
        model.resumeQueuedChatTurns(sessionId: session.id)
        await gate.waitUntilBlocked()

        let later = await model.startActiveChatTurn("later enter", expectedSessionId: session.id)
        guard case .queued = later else {
            Issue.record("a new Enter overtook the queued turn during its start boundary")
            await gate.release()
            return
        }
        #expect(model.queuedChatTurns(for: session.id).map(\.text) == ["later enter"])
        await gate.release()
    }
}
