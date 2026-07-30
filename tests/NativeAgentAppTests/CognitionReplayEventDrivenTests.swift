import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

@Suite("Event-driven cognitive replay", .serialized)
struct CognitionReplayEventDrivenTests {
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-replay-flow-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func replayReceiptCount(_ runtime: NativeCognitionRuntime) async -> Int {
        let substrate = await runtime.substrateForIntegration()
        return await substrate.receiptSnapshot(limit: 100)
            .filter { $0.kind == "replay.integration" }
            .count
    }

    @Test("idle and unrelated somatic signals cause zero replay wakes")
    func zeroIdleReplayWakes() async throws {
        let root = try makeRoot("idle")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )

        #expect(await replayReceiptCount(runtime) == 0)
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 0)
        await runtime.ingestOrganismSignal(
            kind: .providerSucceeded,
            sourceOrgan: "provider",
            prewarmContext: false
        )
        #expect(await replayReceiptCount(runtime) == 0)
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 0)
    }

    @Test("a committed dream signal immediately replays exact root evidence once")
    func dreamSignalDrivesReplayExactlyOnce() async throws {
        let root = try makeRoot("dream")
        defer { try? FileManager.default.removeItem(at: root) }
        let diary = root.appendingPathComponent("dream_diary", isDirectory: true)
        try FileManager.default.createDirectory(at: diary, withIntermediateDirectories: true)
        try "A committed bounded dream that should become one replay episode."
            .write(
                to: diary.appendingPathComponent("2026-07-12.md"),
                atomically: true,
                encoding: .utf8
            )
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )

        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 1)
        #expect(await replayReceiptCount(runtime) == 1)
        let substrate = await runtime.substrateForIntegration()
        let episodes = await substrate.episodeSnapshot()
        #expect(episodes.count == 1)
        #expect(episodes.first?.externalEvidenceIds.count == 1)

        // A duplicate signal rereads canonical reality, but evidence IDs make
        // the transition a durable no-op rather than another replay receipt.
        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 2)
        #expect(await replayReceiptCount(runtime) == 1)
        #expect(await substrate.episodeSnapshot().count == 1)
    }

    @Test("a gated replay remains visible and pending for one deadline retry")
    func gatedReplayIsNotSilentlyDropped() async throws {
        let root = try makeRoot("pending")
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = CognitiveConfiguration.allPhasesEnabled
        configuration.replayEnabled = false
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration,
            organismConfigurationOverride: .disabled
        )

        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )

        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 1)
        #expect(await runtime.replayReconciliationPendingForProof())
        let substrate = await runtime.substrateForIntegration()
        let receipts = await substrate.receiptSnapshot(limit: 100)
        #expect(receipts.contains { $0.kind == "replay.reconciliation_pending" })
        #expect(await replayReceiptCount(runtime) == 0)
    }

    @Test("a cancellation-insensitive replay cannot wedge the somatic caller")
    func wedgedReplayBailsOutAtDeadline() async throws {
        let root = try makeRoot("replay-deadline")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = CognitionReplayDeadlineBlocker()
        let logs = CognitionReplayDeadlineLogCapture()
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            eventDrivenReplayTimeoutSeconds: 0.05,
            eventDrivenReplayOperationOverride: { _ in
                await blocker.wait()
                return .completed("late replay completion")
            },
            deadlineLogger: { logs.append($0) }
        )

        let clock = ContinuousClock()
        let started = clock.now
        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        let elapsed = started.duration(to: clock.now)

        #expect(elapsed < .seconds(2))
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 1)
        #expect(await runtime.replayReconciliationPendingForProof())
        #expect((await runtime.deadlineBailoutCountsForProof()).replay == 1)
        let substrate = await runtime.substrateForIntegration()
        let receipts = await substrate.receiptSnapshot(limit: 100)
        #expect(receipts.contains { $0.kind == "replay.reconciliation_pending" })
        #expect(logs.snapshot().contains {
            $0.contains("TIMEOUT") && $0.contains("event-driven replay")
        })

        // Let the intentionally non-cooperative loser unwind so the test does
        // not leave a parked task behind. The deadline result remains first-wins.
        await blocker.release()
        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        #expect(await runtime.eventDrivenReplayAttemptCountForProof() == 2)
        #expect(!(await runtime.replayReconciliationPendingForProof()))
        #expect((await runtime.deadlineBailoutCountsForProof()).replay == 1)
    }
}

private actor CognitionReplayDeadlineBlocker {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class CognitionReplayDeadlineLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

// MARK: - A4.6: event-driven reflection rides the same commit signal

/// Serialized alongside the replay suite — both drive the shared somatic path.
@Suite("Event-driven cognitive reflection", .serialized)
struct CognitionReflectionEventDrivenTests {
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-reflection-event-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private actor ReasonSpy {
        private(set) var reasons: [String] = []
        func record(_ reason: String) { reasons.append(reason) }
    }

    @Test("a committed dream signal schedules exactly one reflection, after replay")
    func dreamSignalSchedulesReflection() async throws {
        let root = try makeRoot("dream")
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = ReasonSpy()
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            eventDrivenReflectionOperationOverride: { reason in
                await spy.record(reason)
            }
        )

        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 1)
        #expect(await spy.reasons == ["reflection_event:dreamCompleted"])

        await runtime.ingestOrganismSignal(
            kind: .remIntegrated,
            sourceOrgan: "rem",
            prewarmContext: false
        )
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 2)
        #expect(await spy.reasons == [
            "reflection_event:dreamCompleted",
            "reflection_event:remIntegrated",
        ])
    }

    @Test("unrelated somatic signals schedule zero reflections")
    func unrelatedSignalsScheduleNoReflection() async throws {
        let root = try makeRoot("idle")
        defer { try? FileManager.default.removeItem(at: root) }
        let spy = ReasonSpy()
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled,
            eventDrivenReflectionOperationOverride: { reason in
                await spy.record(reason)
            }
        )

        await runtime.ingestOrganismSignal(
            kind: .providerSucceeded,
            sourceOrgan: "provider",
            prewarmContext: false
        )
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 0)
        #expect(await spy.reasons.isEmpty)
    }

    @Test("alternate-root runtime without an override never fires event reflection")
    func nonLiveBodyWithoutOverrideStaysSilent() async throws {
        // The live-body gate is what keeps alternate-root runtimes (tests,
        // isolated tools) from firing real provider work off somatic signals.
        let root = try makeRoot("gated")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: .allPhasesEnabled,
            organismConfigurationOverride: .disabled
        )

        await runtime.ingestOrganismSignal(
            kind: .dreamCompleted,
            sourceOrgan: "dream",
            prewarmContext: false
        )
        await runtime.drainEventDrivenReflectionForProof()
        #expect(await runtime.eventDrivenReflectionAttemptCountForProof() == 0)
    }
}
