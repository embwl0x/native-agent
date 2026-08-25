import Foundation
import Testing

@testable import NativeAgentApp

// EVAL FENCE: app.chat / ui.chat.pinnedTab.runningDot
@MainActor
@Suite("Pinned chat tab running dot")
struct ChatPinnedTabRunningDotEvalTests {
    @Test("the dot names only a session with a live task and current streaming marker")
    func runningDotRequiresTheExactInFlightTurn() {
        let model = AppModel(
            dataRootOverride: FileManager.default.temporaryDirectory,
            startBackgroundTasks: false
        )
        let task = heldTask()
        defer { task.cancel() }

        model.chatTasks["turn-in-flight"] = task
        model.chatTaskGenerations["turn-in-flight"] = 1
        model.streamingSessions = ["turn-in-flight", "stale-marker", "  "]

        #expect(model.pinnedTabRunningSessionIDs == ["turn-in-flight"])
        #expect(PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: "turn-in-flight",
            streamingSessionIDs: model.pinnedTabRunningSessionIDs
        ))
        #expect(!PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: "stale-marker",
            streamingSessionIDs: model.pinnedTabRunningSessionIDs
        ))
        #expect(!PinnedSessionTabPresentation.showsRunningIndicator(
            sessionID: "  ",
            streamingSessionIDs: model.pinnedTabRunningSessionIDs
        ))
    }

    @Test("completed, failed, and stopped turns clear their tab dot without clearing a newer turn")
    func terminalAndStopPathsClearOnlyTheirExactRunningDot() {
        let model = AppModel(
            dataRootOverride: FileManager.default.temporaryDirectory,
            startBackgroundTasks: false
        )
        let completed = heldTask()
        let failed = heldTask()
        let stopped = heldTask()
        let replacement = heldTask()
        defer {
            completed.cancel()
            failed.cancel()
            stopped.cancel()
            replacement.cancel()
        }

        model.chatTasks = [
            "completed": completed,
            "failed": failed,
            "stopped": stopped,
            "replacement": replacement,
        ]
        model.chatTaskGenerations = [
            "completed": 1,
            "failed": 2,
            "stopped": 3,
            "replacement": 5,
        ]
        model.streamingSessions = ["completed", "failed", "stopped", "replacement"]

        let completedIdentity = model.beginChatTurnLifecycle(
            sessionId: "completed",
            turnId: "completed-turn",
            at: .now
        )
        guard let completedIdentity else {
            Issue.record("The completed turn could not enter the lifecycle seam")
            return
        }
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: completedIdentity,
            kind: .completed,
            occurredAt: .now
        ))
        #expect(model.chatTurnLifecycle(for: "completed")?.presentation.phase == .completed)
        _ = model.closeChatTurnLifecycleIntake(
            sessionId: completedIdentity.sessionId,
            turnId: completedIdentity.turnId,
            at: .now
        )
        #expect(model.finishChatTurnRuntime(sessionId: "completed", generation: 1))
        #expect(!model.pinnedTabRunningSessionIDs.contains("completed"))

        let failedIdentity = model.beginChatTurnLifecycle(
            sessionId: "failed",
            turnId: "failed-turn",
            at: .now
        )
        guard let failedIdentity else {
            Issue.record("The failed turn could not enter the lifecycle seam")
            return
        }
        _ = model.applyChatTurnLifecycleInput(MacChatTurnLifecycleInput(
            identity: failedIdentity,
            kind: .failed(reason: "typed failure"),
            occurredAt: .now
        ))
        #expect(model.chatTurnLifecycle(for: "failed")?.presentation.phase == .failed)
        _ = model.closeChatTurnLifecycleIntake(
            sessionId: failedIdentity.sessionId,
            turnId: failedIdentity.turnId,
            at: .now
        )
        #expect(model.finishChatTurnRuntime(sessionId: "failed", generation: 2))
        #expect(!model.pinnedTabRunningSessionIDs.contains("failed"))

        model.stopChatStream(sessionId: "stopped")
        #expect(!model.pinnedTabRunningSessionIDs.contains("stopped"))

        #expect(!model.finishChatTurnRuntime(sessionId: "replacement", generation: 4))
        #expect(model.pinnedTabRunningSessionIDs == ["replacement"])
    }

    private func heldTask() -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // Cancellation is the intended terminal path for this eval seam.
            }
        }
    }
}
