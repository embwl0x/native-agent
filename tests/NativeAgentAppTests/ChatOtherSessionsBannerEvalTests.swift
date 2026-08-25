import Foundation
import Testing

@testable import NativeAgentApp

@MainActor
@Suite("Chat other-sessions banner")
struct ChatOtherSessionsBannerEvalTests {
    @Test("the mounted banner projection is exactly live streams minus the active session")
    func bannerProjectsOnlyOtherLiveSessionsInStableOrder() {
        let model = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        model.activeChatSessionId = "active"
        model.streamingSessions = ["active", "background-b", "background-a", "  "]

        #expect(model.otherRunningChatSessionIDs == ["background-a", "background-b"])
        #expect(MacChatOtherSessionsAffordances.decide(
            otherRunning: model.otherRunningChatSessionIDs
        ) == .many(count: 2))
    }

    @Test("Stop removes a background turn from the banner immediately and relaunch starts with no phantom stream")
    func stopAndRelaunchRepairBannerState() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-other-sessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        model.activeChatSessionId = "active"
        model.streamingSessions = ["active", "background"]
        #expect(model.otherRunningChatSessionIDs == ["background"])

        model.stopChatStream(sessionId: "background")
        #expect(model.otherRunningChatSessionIDs.isEmpty)
        #expect(MacChatOtherSessionsAffordances.decide(
            otherRunning: model.otherRunningChatSessionIDs
        ) == .none)

        // streamingSessions is deliberately in-memory runtime state; a fresh
        // app model cannot resurrect a stopped/abandoned turn as a banner row.
        let relaunched = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        relaunched.activeChatSessionId = "active"
        #expect(relaunched.otherRunningChatSessionIDs.isEmpty)
    }

    @Test("an index-stale running session remains visible and stoppable instead of disappearing")
    func unknownRunningSessionIsAnHonestAdverseBannerRow() {
        let model = AppModel(dataRootOverride: FileManager.default.temporaryDirectory, startBackgroundTasks: false)
        model.activeChatSessionId = "active"
        model.streamingSessions = ["index-not-yet-loaded"]

        let running = model.otherRunningChatSessionIDs
        #expect(running == ["index-not-yet-loaded"])
        #expect(MacChatOtherSessionsAffordances.decide(otherRunning: running)
            == .single(sessionId: "index-not-yet-loaded"))
        #expect(MacChatRunningSessionRoute.routes(sessionIds: running, sessions: []).first?.sessionId
            == "index-not-yet-loaded")
    }
}
