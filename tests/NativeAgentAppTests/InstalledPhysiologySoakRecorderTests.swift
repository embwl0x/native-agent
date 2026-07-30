import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Suite("Installed physiology soak recorder", .serialized)
struct InstalledPhysiologySoakRecorderTests {
    @Test
    func realProcessSamplerReturnsFiniteMonotonicProcessEvidence() {
        let first = InstalledProcessPhysiologySampler.sample()
        let second = InstalledProcessPhysiologySampler.sample()

        #expect(first.systemUptimeSeconds.isFinite)
        #expect(first.userCPUSeconds.isFinite)
        #expect(first.systemCPUSeconds.isFinite)
        #expect(first.systemUptimeSeconds > 0)
        #expect(first.userCPUSeconds >= 0)
        #expect(first.systemCPUSeconds >= 0)
        #expect(first.cpuCountersAvailable == true)
        #expect(first.wakeCountersAvailable != nil)
        #expect(second.cpuCountersAvailable == true)
        #expect(second.wakeCountersAvailable != nil)
        #expect(second.systemUptimeSeconds >= first.systemUptimeSeconds)
        #expect(second.userCPUSeconds >= first.userCPUSeconds)
        #expect(second.systemCPUSeconds >= first.systemCPUSeconds)
        #expect(second.interruptWakeups >= first.interruptWakeups)
        #expect(second.packageIdleWakeups >= first.packageIdleWakeups)
    }

    @Test("bounded buffer coalesces writes and emits explicit overflow loss")
    func boundedBufferLossIsVisible() async throws {
        let root = try temporaryRoot("buffer")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_100_000_000))
        let recorder = makeRecorder(root: root, runtime: "buffer-runtime", clock: clock)

        await recorder.recordRuntimeStarted(reason: "test")
        let submitted = InstalledPhysiologySoakRecorder.maximumPendingRecords + 20
        for index in 1..<submitted {
            await recorder.recordCognitiveEvent(
                event(id: "buffer-\(index)", at: clock.now()),
                scheduledSignalCount: UInt64(index),
                acceptanceMilliseconds: 0.2
            )
        }
        let beforeFlush = await recorder.diagnostics()
        #expect(beforeFlush.pending == InstalledPhysiologySoakRecorder.maximumPendingRecords)
        #expect(beforeFlush.dropped == 20)

        await recorder.flush()
        let report = await recorder.report()
        #expect(report.recordCount == InstalledPhysiologySoakRecorder.maximumPendingRecords + 1)
        #expect(report.recorderDroppedRecordCount == 20)
        #expect(report.sequenceGapCount == 0)
        #expect(report.claimBlockers.contains("recorder backpressure dropped evidence"))
    }

    @Test("termination flush and later launch distinguish clean stop from crash")
    func restartAccounting() async throws {
        let root = try temporaryRoot("restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_200_000_000))

        let first = makeRecorder(root: root, runtime: "first", clock: clock)
        await first.recordRuntimeStarted(reason: "test")
        await first.recordCognitiveEvent(
            event(id: "first-event", at: clock.now()),
            scheduledSignalCount: 1,
            acceptanceMilliseconds: 0.1
        )
        await first.recordRuntimeStopped(reason: "clean")
        await first.flush()

        clock.advance(60)
        let second = makeRecorder(root: root, runtime: "second", clock: clock)
        await second.recordRuntimeStarted(reason: "test")
        await second.flush()
        var report = await second.report()
        #expect(report.runtimeSessionCount == 2)
        #expect(report.cleanStopCount == 1)
        #expect(report.uncleanRestartCount == 0)

        // Launching another runtime without a stop for `second` proves a prior
        // crash/restart. The newest open session is not itself mislabeled.
        clock.advance(60)
        let third = makeRecorder(root: root, runtime: "third", clock: clock)
        await third.recordRuntimeStarted(reason: "test")
        await third.flush()
        report = await third.report()
        #expect(report.runtimeSessionCount == 3)
        #expect(report.cleanStopCount == 1)
        #expect(report.uncleanRestartCount == 1)
    }

    @Test("bounded write retries stop when quiet and a later event reopens recovery")
    func boundedRetryRecoversOnLaterSignal() async throws {
        let root = try temporaryRoot("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_300_000_000))
        let persistence = FlakyPhysiologyPersistence(failFirstAttempts: 6)
        let store = InstalledPhysiologySoakStore(dataRoot: root, persistence: persistence)
        let recorder = InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: "retry-runtime",
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: { .init(
                systemUptimeSeconds: 1,
                userCPUSeconds: 0,
                systemCPUSeconds: 0,
                interruptWakeups: 0,
                packageIdleWakeups: 0
            ) },
            store: store,
            coalescingDelayNanoseconds: 1_000_000
        )

        await recorder.recordRuntimeStarted(reason: "test")
        try await waitUntil { await persistence.attemptCount() == 5 }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await persistence.attemptCount() == 5)
        #expect(await recorder.diagnostics().pending == 1)

        // No retry heartbeat remains after the bounded budget. A real new
        // event re-opens recovery; attempt six fails and the bounded retry
        // immediately after it succeeds without waiting for termination.
        await recorder.recordCognitiveEvent(
            event(id: "retry-signal", at: clock.now()),
            scheduledSignalCount: 1,
            acceptanceMilliseconds: 0.1
        )
        try await waitUntil { await persistence.attemptCount() >= 7 }
        try await waitUntil { await recorder.diagnostics().pending == 0 }
        #expect(await recorder.diagnostics().lastError == nil)
    }

    @Test("duplicate ingress and provider retry preserve end-to-end chat latency")
    func retryDoesNotShortenChatLatency() async throws {
        let root = try temporaryRoot("chat-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_400_000_000))
        let recorder = makeRecorder(root: root, runtime: "chat-retry-runtime", clock: clock)

        await recorder.recordRuntimeStarted(reason: "test")
        await recorder.recordCognitiveEvent(
            chatEvent(id: "user-1", kind: .userMessageReceived, run: "same-run", at: clock.now()),
            scheduledSignalCount: 1,
            acceptanceMilliseconds: 0.1
        )
        clock.advance(5)
        await recorder.recordCognitiveEvent(
            chatEvent(id: "user-retry", kind: .userMessageReceived, run: "same-run", at: clock.now()),
            scheduledSignalCount: 2,
            acceptanceMilliseconds: 0.1
        )
        clock.advance(2)
        await recorder.recordCognitiveEvent(
            chatEvent(id: "provider-retry", kind: .providerFailure, run: "same-run", at: clock.now()),
            scheduledSignalCount: 3,
            acceptanceMilliseconds: 0.1
        )
        clock.advance(3)
        await recorder.recordCognitiveEvent(
            chatEvent(id: "assistant", kind: .assistantTurnCompleted, run: "same-run", at: clock.now()),
            scheduledSignalCount: 4,
            acceptanceMilliseconds: 0.1
        )

        let report = await recorder.report()
        #expect(report.chatTurnCount == 1)
        #expect(report.chatLatencyP95Milliseconds == 10_000)
    }

    @Test("microcycle duration is recorded separately from event acceptance")
    func microcycleDurationUsesOwnMetric() async throws {
        let root = try temporaryRoot("microcycle-duration")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_450_000_000))
        let recorder = makeRecorder(root: root, runtime: "microcycle-runtime", clock: clock)
        var telemetry = CognitiveMicrocycleTelemetry.fresh(now: clock.now())
        telemetry.scheduledSignalCount = 1
        telemetry.executedCount = 1
        telemetry.lastDurationMilliseconds = 42
        telemetry.lastTurnClass = .system

        await recorder.recordMicrocycleScheduled(telemetry)
        await recorder.recordMicrocycleFinished(telemetry)

        let report = await recorder.report()
        #expect(report.cognitiveAcceptanceP95Milliseconds == nil)
        #expect(report.microcycleExecutionP95Milliseconds == 42)
    }

    @Test("explicit flush spends a bounded durability budget and leaves no retry heartbeat")
    func flushIsBoundedDurabilityBarrier() async throws {
        let root = try temporaryRoot("flush-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_500_000_000))
        let persistence = FlakyPhysiologyPersistence(failFirstAttempts: 10)
        let recorder = InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: "flush-retry-runtime",
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: { .init(
                systemUptimeSeconds: 1,
                userCPUSeconds: 0,
                systemCPUSeconds: 0,
                interruptWakeups: 0,
                packageIdleWakeups: 0
            ) },
            store: InstalledPhysiologySoakStore(dataRoot: root, persistence: persistence),
            coalescingDelayNanoseconds: 1_000_000
        )

        await recorder.recordRuntimeStarted(reason: "test")
        await recorder.flush()
        #expect(await persistence.attemptCount() == InstalledPhysiologySoakRecorder.maximumAutomaticWriteRetries)
        #expect(await recorder.diagnostics().pending == 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await persistence.attemptCount() == InstalledPhysiologySoakRecorder.maximumAutomaticWriteRetries)
    }

    @Test("a wedged persistence append cannot hang report or termination flush")
    func wedgedPersistenceAppendHasABoundedDurabilityBarrier() async throws {
        let root = try temporaryRoot("wedged-persistence")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_550_000_000))
        let persistence = BlockingAppendPhysiologyPersistence()
        let recorder = InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: "wedged-persistence-runtime",
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: { .init(
                systemUptimeSeconds: 1,
                userCPUSeconds: 0,
                systemCPUSeconds: 0,
                interruptWakeups: 0,
                packageIdleWakeups: 0
            ) },
            store: InstalledPhysiologySoakStore(dataRoot: root, persistence: persistence),
            coalescingDelayNanoseconds: 1_000_000,
            flushDrainDeadlineNanoseconds: 20_000_000
        )

        await recorder.recordRuntimeStarted(reason: "test")
        try await waitUntil { await persistence.didStartAppend() }

        let started = ContinuousClock().now
        let report = await recorder.report()
        let elapsed = started.duration(to: ContinuousClock().now)

        #expect(elapsed < .seconds(1))
        #expect(report.claimBlockers.contains(
            "physiology recorder durability barrier did not complete"
        ))
        #expect(await recorder.diagnostics().lastError?.contains("timed out") == true)

        await persistence.release()
        #expect(await recorder.flush())
    }

    private func makeRecorder(
        root: URL,
        runtime: String,
        clock: PhysiologyTestClock
    ) -> InstalledPhysiologySoakRecorder {
        InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: runtime,
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: {
                InstalledPhysiologyProcessSample(
                    systemUptimeSeconds: clock.now().timeIntervalSince1970,
                    userCPUSeconds: 0.01,
                    systemCPUSeconds: 0.01,
                    interruptWakeups: 0,
                    packageIdleWakeups: 0
                )
            },
            coalescingDelayNanoseconds: 60_000_000_000
        )
    }

    private func event(id: String, at: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: .toolSucceeded,
            subject: .init(type: "proof", id: id, label: nil),
            sourceClass: .observed,
            occurredAt: at,
            summary: "payload-free proof event",
            importance: 0.5,
            metadata: ["runId": .string(id)]
        )
    }

    private func chatEvent(
        id: String,
        kind: CognitiveEventKind,
        run: String,
        at: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: .init(type: "chat_turn", id: id, label: nil),
            sourceClass: .observed,
            occurredAt: at,
            summary: "payload-free chat proof event",
            importance: 0.5,
            turnKind: .live,
            metadata: ["runId": .string(run)]
        )
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-physiology-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 2,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for physiology recorder condition")
    }
}

private actor FlakyPhysiologyPersistence: PersistenceCoreProtocol {
    private let failFirstAttempts: Int
    private var attempts = 0

    init(failFirstAttempts: Int) { self.failFirstAttempts = failFirstAttempts }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue { defaultValue }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {}

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        attempts += 1
        if attempts <= failFirstAttempts {
            throw NSError(domain: "FlakyPhysiologyPersistence", code: attempts)
        }
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] { [] }
    func readJSONL(_ path: URL) async throws -> [JSONValue] { [] }
    func attemptCount() -> Int { attempts }
}

private actor BlockingAppendPhysiologyPersistence: PersistenceCoreProtocol {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue { defaultValue }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {}

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        started = true
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] { [] }
    func readJSONL(_ path: URL) async throws -> [JSONValue] { [] }
    func didStartAppend() -> Bool { started }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

private final class PhysiologyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}
