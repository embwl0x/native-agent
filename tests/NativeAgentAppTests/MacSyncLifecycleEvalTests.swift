import Foundation
import Testing
@testable import NativeAgentApp

private actor ChatTranscriptCoalescerProbe {
    private var latestTurn = ""
    private var writes: [String] = []
    private let writeEvents: AsyncStream<String>
    private let writeEventContinuation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream<String>.makeStream()
        writeEvents = stream.stream
        writeEventContinuation = stream.continuation
    }

    func setLatestTurn(_ turn: String) { latestTurn = turn }
    func currentTurn() -> String { latestTurn }
    func recordWrite(_ turn: String) {
        writes.append(turn)
        writeEventContinuation.yield(turn)
    }
    func nextWrite(within timeout: Duration) async -> String? {
        let events = writeEvents
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    func recordedWrites() -> [String] { writes }
}

@MainActor
private final class ChatTranscriptDebounceProbe {
    private var latestTurn = ""
    private var writes: [String] = []
    private let writeEvents: AsyncStream<String>
    private let writeEventContinuation: AsyncStream<String>.Continuation

    init() {
        let stream = AsyncStream<String>.makeStream()
        writeEvents = stream.stream
        writeEventContinuation = stream.continuation
    }

    func setLatestTurn(_ turn: String) { latestTurn = turn }
    func currentTurn() -> String { latestTurn }
    func recordWrite(_ turn: String) {
        writes.append(turn)
        writeEventContinuation.yield(turn)
    }
    func nextWrite(within timeout: Duration) async -> String? {
        await Self.nextValue(from: writeEvents, within: timeout)
    }
    func recordedWrites() -> [String] { writes }

    private static func nextValue<Value: Sendable>(
        from events: AsyncStream<Value>,
        within timeout: Duration
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

@MainActor
private final class ChatTranscriptControlledDelay {
    private let armedEvents: AsyncStream<Duration>
    private let armedEventContinuation: AsyncStream<Duration>.Continuation
    private let releaseEvents: AsyncStream<Void>
    private let releaseEventContinuation: AsyncStream<Void>.Continuation

    init() {
        let armed = AsyncStream<Duration>.makeStream()
        armedEvents = armed.stream
        armedEventContinuation = armed.continuation
        let release = AsyncStream<Void>.makeStream()
        releaseEvents = release.stream
        releaseEventContinuation = release.continuation
    }

    func wait(for duration: Duration) async throws {
        armedEventContinuation.yield(duration)
        var iterator = releaseEvents.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func nextArmedDuration(within timeout: Duration) async -> Duration? {
        await withTaskGroup(of: Duration?.self) { group in
            let events = armedEvents
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func release() {
        releaseEventContinuation.yield(())
    }
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
    @Test(
        "a completion burst coalesces the real observer into one final transcript projection",
        .timeLimit(.minutes(1))
    )
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

        await probe.setLatestTurn("assistant turn 12")
        for _ in 1...12 {
            notificationCenter.post(name: .chatTurnCompleted, object: "session-coalesced")
        }

        #expect(await probe.nextWrite(within: .seconds(10)) == "assistant turn 12")
        #expect(await probe.nextWrite(within: .milliseconds(500)) == nil)
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

        #expect(await cancelledProbe.nextWrite(within: .milliseconds(500)) == nil)
        #expect(await cancelledProbe.recordedWrites().isEmpty)
        #expect(cancelledEngine.chatSnapshotCoalescer.activeGeneration == nil)
    }

    @MainActor
    @Test(
        "the real debounce retains a later completion and publishes only its final transcript",
        .timeLimit(.minutes(1))
    )
    func laterCompletionWinsInsideTheRealDebounceWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-transcript-debounce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        let transcriptURL = snapshots.appendingPathComponent("chat_transcripts.json")
        let notificationCenter = NotificationCenter()
        let probe = ChatTranscriptDebounceProbe()
        let delay = ChatTranscriptControlledDelay()
        let engine = MacSyncEngine(
            stateDataRootOverride: root,
            chatTurnCompletedNotificationCenter: notificationCenter,
            chatTranscriptSnapshotWriter: { includeTranscripts in
                guard includeTranscripts else { return }
                let finalTurn = probe.currentTurn()
                try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
                try? Data(finalTurn.utf8).write(to: transcriptURL, options: .atomic)
                probe.recordWrite(finalTurn)
            },
            chatSnapshotCoalescingDelay: { duration in
                try await delay.wait(for: duration)
            }
        )
        engine.isActive = true
        engine.snapshotDir = snapshots
        engine.startChatTranscriptSnapshotObservation()
        defer {
            delay.release()
            engine.stop()
        }

        probe.setLatestTurn("assistant turn early")
        notificationCenter.post(name: .chatTurnCompleted, object: "session-debounce")
        let requestedDuration = await delay.nextArmedDuration(within: .seconds(10))
        try #require(requestedDuration == .milliseconds(180))
        #expect(probe.recordedWrites().isEmpty)

        probe.setLatestTurn("assistant turn later")
        notificationCenter.post(name: .chatTurnCompleted, object: "session-debounce")
        await Task.yield()
        delay.release()

        #expect(await probe.nextWrite(within: .seconds(10)) == "assistant turn later")
        #expect(await probe.nextWrite(within: .milliseconds(500)) == nil)
        #expect(probe.recordedWrites() == ["assistant turn later"])
        let persistedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(persistedTranscript == "assistant turn later")
        #expect(engine.chatTranscriptSnapshotPublicationTask == nil)
        #expect(engine.chatSnapshotCoalescer.activeGeneration == nil)
    }
}
