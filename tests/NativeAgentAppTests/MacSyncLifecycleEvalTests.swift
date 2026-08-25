import Foundation
import Testing
@testable import NativeAgentApp

private actor ChatTranscriptCoalescerProbe {
    private var latestTurn = ""
    private var writes: [String] = []

    func setLatestTurn(_ turn: String) { latestTurn = turn }
    func currentTurn() -> String { latestTurn }
    func recordWrite(_ turn: String) { writes.append(turn) }
    func recordedWrites() -> [String] { writes }
}

@Suite("MacSync lifecycle")
struct MacSyncLifecycleEvalTests {
    @MainActor
    @Test("stop invalidates the generation, preserves digest evidence, and unmounts stale routing roots")
    func stopClearsARealActiveLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = MacSyncEngine(stateDataRootOverride: root)
        let docs = root.appendingPathComponent("documents", isDirectory: true)
        engine.isActive = true
        engine.activeDocsURL = docs
        engine.snapshotDir = docs.appendingPathComponent("snapshots", isDirectory: true)
        engine.inboxDir = docs.appendingPathComponent("inbox", isDirectory: true)
        engine.responsesDir = docs.appendingPathComponent("responses", isDirectory: true)
        engine.transactionDir = docs.appendingPathComponent("transactions", isDirectory: true)
        engine.snapshotFileDigests = ["desk.json": "digest"]
        engine.snapshotLifecycleGeneration = 41
        engine.snapshotWriteInFlight = true
        engine.snapshotWriteQueued = true
        _ = engine.chatSnapshotCoalescer.enqueue(includeTranscripts: true, generation: 41)

        engine.stop()

        #expect(!engine.isActive)
        #expect(engine.snapshotLifecycleGeneration == 42)
        #expect(engine.activeDocsURL == nil)
        #expect(engine.snapshotDir == nil)
        #expect(engine.inboxDir == nil)
        #expect(engine.responsesDir == nil)
        #expect(engine.transactionDir == nil)
        #expect(!engine.snapshotWriteInFlight)
        #expect(!engine.snapshotWriteQueued)
        #expect(engine.chatSnapshotCoalescer.activeGeneration == nil)

        let digestPath = root.appendingPathComponent("icloud/snapshot_digests.json")
        let persisted = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: digestPath))
        #expect(persisted == ["desk.json": "digest"])
    }

    @MainActor
    @Test("an inactive lifecycle has no retained action-response route")
    func stoppedLifecycleCannotRetainResponseDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-lifecycle-inactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = MacSyncEngine(stateDataRootOverride: root)
        engine.responsesDir = URL(fileURLWithPath: "/tmp/macsync-stale-response")
        engine.isActive = false

        engine.stop()

        #expect(engine.responsesDir == nil)
    }

    // app.bridges / macsync.chatTranscriptCoalescer
    @MainActor
    @Test("a completion burst coalesces the real observer into one final transcript projection")
    func completionBurstWritesLatestTranscriptOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-transcript-coalescer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        let notificationCenter = NotificationCenter()
        let probe = ChatTranscriptCoalescerProbe()
        let transcriptURL = snapshots.appendingPathComponent("chat_transcripts.json")
        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            chatTurnCompletedNotificationCenter: notificationCenter,
            chatTranscriptSnapshotWriter: { includeTranscripts in
                guard includeTranscripts else { return }
                let finalTurn = await probe.currentTurn()
                try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
                try? Data(finalTurn.utf8).write(to: transcriptURL, options: .atomic)
                await probe.recordWrite(finalTurn)
            }
        )
        engine.isActive = true
        engine.snapshotDir = snapshots
        engine.startChatTranscriptSnapshotObservation()
        defer { engine.stop() }

        for index in 1...12 {
            await probe.setLatestTurn("assistant turn \(index)")
            notificationCenter.post(name: .chatTurnCompleted, object: "session-coalesced")
        }
        try await Task.sleep(for: .milliseconds(450))

        #expect(await probe.recordedWrites() == ["assistant turn 12"])
        let persistedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(persistedTranscript == "assistant turn 12")
        #expect(engine.chatTranscriptSnapshotPublicationTask == nil)
        #expect(engine.chatSnapshotCoalescer.activeGeneration == nil)

        let cancelledRoot = root.appendingPathComponent("cancelled", isDirectory: true)
        let cancelledCenter = NotificationCenter()
        let cancelledProbe = ChatTranscriptCoalescerProbe()
        let cancelledEngine = MacSyncEngine(
            stateDataRootOverride: root,
            chatTurnCompletedNotificationCenter: cancelledCenter,
            chatTranscriptSnapshotWriter: { includeTranscripts in
                guard includeTranscripts else { return }
                await cancelledProbe.recordWrite("must not publish after stop")
            }
        )
        cancelledEngine.isActive = true
        cancelledEngine.snapshotDir = cancelledRoot
        cancelledEngine.startChatTranscriptSnapshotObservation()
        cancelledCenter.post(name: .chatTurnCompleted, object: "session-cancelled")
        cancelledEngine.stop()
        try await Task.sleep(for: .milliseconds(250))

        #expect(await cancelledProbe.recordedWrites().isEmpty)
        #expect(cancelledEngine.chatSnapshotCoalescer.activeGeneration == nil)
    }
}
