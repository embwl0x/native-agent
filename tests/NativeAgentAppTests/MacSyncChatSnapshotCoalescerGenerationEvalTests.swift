import Foundation
import Testing
@testable import NativeAgentApp

/// EVAL FENCE: app.bridges / macsync.chatSnapshotCoalescerGeneration
///
/// This drives the real MainActor coalescer rather than only its state helper.
/// A session-index write arrives first, then a transcript completion upgrades
/// it inside the 180 ms window. The second half stops that pending lifecycle
/// and opens a new generation, proving stale work makes no write and leaves no
/// transcript-upgrade latch behind.
@Suite("MacSync chat snapshot coalescer generation")
struct MacSyncChatSnapshotCoalescerGenerationEvalTests {
    @MainActor
    @Test("coalesces an upgrade once, then drops a stopped generation without latching the reopened pass")
    func lifecycleGenerationClearsStaleCoalescedWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-chat-coalescer-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = SnapshotWriteRecorder()
        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            chatTurnCompletedNotificationCenter: NotificationCenter(),
            chatTranscriptSnapshotWriter: { includeTranscripts in
                await recorder.record(includeTranscripts)
            }
        )
        engine.isActive = true
        engine.snapshotDir = root.appendingPathComponent("snapshots", isDirectory: true)

        // One deferred task: a session-only mutation is upgraded by a chat
        // completion, never split into two writes or downgraded to false.
        engine.requestChatSnapshotPublication(includeTranscripts: false)
        engine.requestChatSnapshotPublication(includeTranscripts: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(await recorder.values() == [true])
        #expect(engine.chatTranscriptSnapshotPublicationTask == nil)
        #expect(engine.chatSnapshotCoalescer.activeGeneration == nil)
        #expect(!engine.chatSnapshotCoalescer.needsTranscripts)

        // Schedule a transcript pass, invalidate it before its delay elapses,
        // then reopen. The old generation must write nothing; the reopened
        // session-only request must stay false, proving the old upgrade bit
        // was cleared rather than leaking into all later passes.
        engine.requestChatSnapshotPublication(includeTranscripts: true)
        engine.stop()
        engine.isActive = true
        engine.snapshotDir = root.appendingPathComponent("reopened-snapshots", isDirectory: true)
        engine.requestChatSnapshotPublication(includeTranscripts: false)
        try await Task.sleep(for: .milliseconds(350))

        #expect(await recorder.values() == [true, false])
        #expect(engine.chatTranscriptSnapshotPublicationTask == nil)
        #expect(engine.chatSnapshotCoalescer.activeGeneration == nil)
        #expect(!engine.chatSnapshotCoalescer.needsTranscripts)
        engine.stop()
    }

    private actor SnapshotWriteRecorder {
        private var recorded: [Bool] = []

        func record(_ includeTranscripts: Bool) {
            recorded.append(includeTranscripts)
        }

        func values() -> [Bool] {
            recorded
        }
    }
}
