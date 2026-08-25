import Foundation
import Testing
@testable import NativeAgentApp

@MainActor
@Suite("app.runtimes · AppModel chat stop stream", .serialized)
struct AppModelChatStopStreamEvalTests {
    @Test("Stop cancels only the requested local task and writes its durable marker at the AppModel root")
    func stopUsesTheInjectedCanonicalRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = "isolated-stream"
        let model = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        model.activeChatSessionId = sessionID
        model.streamingSessions = [sessionID, "other-live-stream"]

        let cancellation = CancellationProbe()
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancellation.didObserveCancellation = Task.isCancelled
            }
        }
        model.chatTasks[sessionID] = task

        model.stopChatStream()
        let cancelWrite = try #require(model.pendingCancelFlagWrites[sessionID])
        await cancelWrite.value
        await task.value

        let marker = root
            .appendingPathComponent("chat/sessions/\(sessionID)/cancelled.flag")
        #expect(FileManager.default.fileExists(atPath: marker.path),
                "Stop must write beside the isolated AppModel's chat session, never the process-global root")
        #expect(cancellation.didObserveCancellation)
        #expect(model.chatTasks[sessionID] == nil)
        #expect(!model.streamingSessions.contains(sessionID))
        #expect(model.streamingSessions.contains("other-live-stream"),
                "Stopping one session must not cancel a detached session")
        #expect(model.pendingCancelFlagWrites[sessionID] == nil)
    }

    @Test("invalid session IDs fail closed without creating a durable cancellation path")
    func invalidSessionIDDoesNotEscapeTheCanonicalChatDirectory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "http://unused", dataRootOverride: root)

        await #expect(throws: Error.self) {
            try await client.cancelChatSession(sessionId: "../outside")
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("outside/cancelled.flag").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("outside/cancelled.flag").path
        ))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appmodel-stop-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@MainActor
private final class CancellationProbe {
    var didObserveCancellation = false
}
