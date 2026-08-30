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
        #expect(beforeFlush.totalDropped == 20)
        #expect(beforeFlush.hasMeasurementGap)

        await recorder.flush()
        let report = await recorder.report()
        #expect(report.recordCount == InstalledPhysiologySoakRecorder.maximumPendingRecords + 1)
        #expect(report.recorderDroppedRecordCount == 20)
        #expect(report.sequenceGapCount == 0)
        #expect(report.claimBlockers.contains("recorder backpressure dropped evidence"))
    }

    // EVAL FENCE: core.substrate.organism
    // Ledger row: telemetry.residualDeadlineArmedFired
    //
    // This drives the real recorder and persisted soak store. Repeated arms for
    // one exact deadline collapse to one row, while a fire clears that dedupe
    // key so the next arm remains observable. A full bounded buffer exposes a
    // durable measurement gap instead of thinning deadline evidence silently.
    @Test("residual deadline telemetry deduplicates arms and exposes bounded loss")
    func residualDeadlineTelemetryIsDedupeSafeAndMeasurementGapHonest() async throws {
        let root = try temporaryRoot("residual-deadline-telemetry")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_150_000_000))
        let recorder = makeRecorder(root: root, runtime: "residual-runtime", clock: clock)
        let deadline = clock.now().addingTimeInterval(90)
        let opportunity = OrganismResidualRepairOpportunity(
            generatedAt: clock.now(),
            evidenceGeneration: "deadline-proof",
            nextWakeAt: deadline
        )

        await recorder.recordResidualDeadlineArmed(deadline: deadline, opportunity: opportunity)
        await recorder.recordResidualDeadlineArmed(deadline: deadline, opportunity: opportunity)
        await recorder.recordResidualDeadlineFired(
            scheduledAt: deadline,
            firedAt: deadline,
            wasDue: true,
            localRepairPerformed: true,
            operationalConsolidationPerformed: false
        )
        // Firing clears the dedupe key: a legitimate re-arm at the same exact
        // date must be observable as a new lifecycle attempt.
        await recorder.recordResidualDeadlineArmed(deadline: deadline, opportunity: opportunity)
        let pending = await recorder.diagnostics()
        #expect(pending.pending == 3)
        #expect(pending.hasMeasurementGap)
        #expect(await recorder.flush())
        #expect((await recorder.diagnostics()).hasMeasurementGap == false)

        let records = try persistedRecords(root: root, runtime: "residual-runtime")
        #expect(records.filter { $0.kind == .residualDeadlineArmed }.count == 2)
        #expect(records.filter { $0.kind == .residualDeadlineFired }.count == 1)

        let lossRecorder = makeRecorder(root: root, runtime: "residual-loss", clock: clock)
        for index in 0...InstalledPhysiologySoakRecorder.maximumPendingRecords {
            await lossRecorder.recordResidualDeadlineFired(
                scheduledAt: deadline.addingTimeInterval(Double(index)),
                firedAt: deadline.addingTimeInterval(Double(index)),
                wasDue: true,
                localRepairPerformed: false,
                operationalConsolidationPerformed: false
            )
        }
        let loss = await lossRecorder.diagnostics()
        #expect(loss.dropped == 1)
        #expect(loss.totalDropped == 1)
        #expect(loss.hasMeasurementGap)
        _ = await lossRecorder.flush()
        let lossReport = await lossRecorder.report()
        #expect(lossReport.recorderDroppedRecordCount == 1)
        #expect(lossReport.claimBlockers.contains("recorder backpressure dropped evidence"))
    }

    @Test("in-flight retries and new arrivals share the exact recorder bound")
    func inFlightRetriesStayBoundedWithoutLosingAcceptedRows() async throws {
        let root = try temporaryRoot("inflight-retry-bound")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = PhysiologyTestClock(Date(timeIntervalSince1970: 2_170_000_000))
        let persistence = GatedRetryPhysiologyPersistence(failingAttempts: 3)
        let runtimeID = "inflight-retry-runtime"
        let recorder = InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: runtimeID,
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: { .init(
                systemUptimeSeconds: 1, userCPUSeconds: 0, systemCPUSeconds: 0,
                interruptWakeups: 0, packageIdleWakeups: 0
            ) },
            store: InstalledPhysiologySoakStore(dataRoot: root, persistence: persistence),
            coalescingDelayNanoseconds: 60_000_000_000
        )
        await recorder.recordRuntimeStarted(reason: "test")
        for index in 1..<128 {
            await recorder.recordCognitiveEvent(
                event(id: "before-\(index)", at: clock.now()),
                scheduledSignalCount: UInt64(index), acceptanceMilliseconds: 0.1
            )
        }
        let drain = Task { await recorder.flush() }
        try await waitUntil { await persistence.blockedAttempt() == 1 }
        let inFlight = await recorder.diagnostics()
        #expect(inFlight.pending == 128)
        #expect(inFlight.hasMeasurementGap)

        // The first 128 rows remain in flight. Only 128 of these arrivals
        // fit, and restoring the failed batch must preserve those newer rows.
        for index in 0..<148 {
            await recorder.recordCognitiveEvent(
                event(id: "during-\(index)", at: clock.now()),
                scheduledSignalCount: UInt64(index + 128), acceptanceMilliseconds: 0.1
            )
        }
        #expect(await recorder.diagnostics().pending == 256)
        #expect(await recorder.diagnostics().totalDropped == 20)
        await persistence.releaseFailure()

        for attempt in 2...3 {
            try await waitUntil { await persistence.blockedAttempt() == attempt }
            #expect(await recorder.diagnostics().pending == 256)
            for index in 0..<15 {
                await recorder.recordCognitiveEvent(
                    event(id: "retry-\(attempt)-\(index)", at: clock.now()),
                    scheduledSignalCount: 256, acceptanceMilliseconds: 0.1
                )
            }
            #expect(await recorder.diagnostics().pending == 256)
            await persistence.releaseFailure()
        }
        #expect(await drain.value)
        let recovered = await recorder.diagnostics()
        #expect(recovered.pending == 0)
        #expect(recovered.totalDropped == 50)
        #expect(recovered.totalWriteFailures == 3)
        #expect(recovered.lastError == nil)
        let records = try persistedRecords(root: root, runtime: runtimeID)
        #expect(records.count == 257)
        #expect(records.map(\.sequence) == Array(UInt64(1)...257))
        #expect(await persistence.persistedSequenceOrder() == Array(1...257))
        #expect(Set(records.map(\.eventID)).count == 257)
        #expect(records.dropLast().allSatisfy { $0.kind != .recorderLoss })
        #expect(records.last?.kind == .recorderLoss)
        #expect(records.last?.droppedRecordCount == 50)
        let report = await recorder.report()
        #expect(report.recorderDroppedRecordCount == 50)
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
        let failedDiagnostics = await recorder.diagnostics()
        #expect(failedDiagnostics.pending == 1)
        #expect(failedDiagnostics.consecutiveWriteFailures == InstalledPhysiologySoakRecorder.maximumAutomaticWriteRetries)
        #expect(failedDiagnostics.totalWriteFailures >= UInt64(InstalledPhysiologySoakRecorder.maximumAutomaticWriteRetries))
        #expect(failedDiagnostics.hasMeasurementGap)

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
        let recoveredDiagnostics = await recorder.diagnostics()
        #expect(recoveredDiagnostics.lastError == nil)
        #expect(recoveredDiagnostics.consecutiveWriteFailures == 0)
        #expect(recoveredDiagnostics.totalWriteFailures > 0)
        #expect(!recoveredDiagnostics.hasMeasurementGap)
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

        // 10s, not 1s: the claim is "the 20ms drain deadline won, not the
        // wedged durability barrier" — any finite bound with headroom proves
        // that, while a 1s bound loses to scheduler noise under full-suite
        // parallelism.
        #expect(elapsed < .seconds(10))
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

    private func persistedRecords(
        root: URL,
        runtime: String
    ) throws -> [InstalledPhysiologySoakRecord] {
        let directory = root
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("installed_physiology_soak", isDirectory: true)
        let decoder = JSONDecoder()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { file in
                try String(decoding: Data(contentsOf: file), as: UTF8.self)
                    .split(separator: "\n")
                    .map { try decoder.decode(InstalledPhysiologySoakRecord.self, from: Data($0.utf8)) }
            }
            .filter { $0.runtimeInstanceID == runtime }
            .sorted { $0.sequence < $1.sequence }
    }

    // 10s deadline, not 2s: positive steps only need the deadline to exceed
    // worst-case scheduler noise under full-suite parallelism — a green run
    // still returns at the first 2ms poll that observes the condition.
    private func waitUntil(
        timeoutSeconds: TimeInterval = 10,
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

private actor GatedRetryPhysiologyPersistence: PersistenceCoreProtocol {
    private let failingAttempts: Int
    private let native = SwiftNativePersistenceCore()
    private var attempts = 0
    private var blocked = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var persistedSequences: [Int64] = []

    init(failingAttempts: Int) { self.failingAttempts = failingAttempts }

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue { defaultValue }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {}
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] { [] }
    func readJSONL(_ path: URL) async throws -> [JSONValue] { [] }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        attempts += 1
        if attempts <= failingAttempts {
            blocked = attempts
            await withCheckedContinuation { waiter = $0 }
            throw NSError(domain: "GatedRetryPhysiologyPersistence", code: attempts)
        }
        try await native.appendJSONL(record, to: path)
        if case .object(let fields) = record, case .int(let sequence)? = fields["sequence"] {
            persistedSequences.append(sequence)
        }
    }

    func blockedAttempt() -> Int { blocked }
    func persistedSequenceOrder() -> [Int64] { persistedSequences }

    func releaseFailure() {
        blocked = 0
        waiter?.resume()
        waiter = nil
    }
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
