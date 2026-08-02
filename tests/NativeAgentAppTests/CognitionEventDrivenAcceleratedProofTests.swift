import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Accelerated evidence for Wave 3's mechanism. These tests advance an injected
/// analytic clock; they are not a substitute for installed multi-day CPU or
/// restart dogfood and must never be reported as elapsed wall-clock evidence.
@Suite("Cognition event-driven accelerated proof", .serialized)
struct CognitionEventDrivenAcceleratedProofTests {
    @Test("cognition maintenance owns one exact deadline and no five-minute checkpoint")
    func exactCognitionMaintenanceDeadline() async throws {
        let root = try temporaryRoot("exact-cognition-maintenance")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 1_500_000))
        let runtime = makeRuntime(root: root, clock: clock)

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == clock.now())
        await runtime.flushCognitionMaintenanceDeadlineForProof()

        let substrate = await runtime.substrateForIntegration()
        let firstCount = await substrate.receiptSnapshot(limit: 80)
            .filter { $0.kind == "maintenance" }.count
        #expect(firstCount == 1)
        let exactDeadline = try #require(await runtime.cognitionMaintenanceDeadlineForProof())
        #expect(exactDeadline == clock.now().addingTimeInterval(20 * 60 * 60))

        let microcyclesBefore = await runtime.microcycleTelemetrySnapshot()
        clock.advance(5 * 60)
        await runtime.flushCognitionMaintenanceDeadlineForProof()
        #expect(await substrate.receiptSnapshot(limit: 80).filter { $0.kind == "maintenance" }.count == 1)
        #expect(await runtime.cognitionMaintenanceDeadlineForProof() == exactDeadline)

        clock.advance(exactDeadline.timeIntervalSince(clock.now()))
        await runtime.flushCognitionMaintenanceDeadlineForProof()
        #expect(await substrate.receiptSnapshot(limit: 80).filter { $0.kind == "maintenance" }.count == 2)
        let microcyclesAfter = await runtime.microcycleTelemetrySnapshot()
        #expect(microcyclesAfter.scheduledSignalCount == microcyclesBefore.scheduledSignalCount)
        #expect(microcyclesAfter.executedCount == microcyclesBefore.executedCount)
    }

    @Test("three analytic days create no idle wakes and restore the same decayed tissue")
    func analyticTimeAndRestartParity() async throws {
        let root = try temporaryRoot("analytic-restart")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 2_000_000))

        let first = makeRuntime(root: root, clock: clock)
        await first.bootstrap()
        #expect(await first.microcycleTelemetrySnapshot().executedCount == 0)
        await first.flushPendingMicrocycleForProof()

        await first.observe(proofEvent(
            id: "analytic-memory",
            kind: .userMessageReceived,
            at: clock.now()
        ))
        // The chat/event path only marks the resident field dirty. Settlement is
        // not inline, so its latency contains no microcycle, timer, or model call.
        let beforeFlush = await first.microcycleTelemetrySnapshot()
        #expect(beforeFlush.executedCount == 1)
        await first.flushPendingMicrocycleForProof()

        let dayZeroNode = try #require(await node(id: "analytic-memory", in: first))
        let dayZeroTelemetry = await first.microcycleTelemetrySnapshot()

        clock.advance(3 * 24 * 60 * 60)
        let dayThreeNode = try #require(await node(id: "analytic-memory", in: first))
        let quietTelemetry = await first.microcycleTelemetrySnapshot()

        #expect(dayThreeNode.activation < dayZeroNode.activation)
        #expect(dayThreeNode.activation > 0)
        #expect(abs(dayThreeNode.activation - dayZeroNode.activation * 0.125) < 0.000_001)
        #expect(abs(dayThreeNode.salience - dayZeroNode.salience * 0.125) < 0.000_001)
        #expect(quietTelemetry.scheduledSignalCount == dayZeroTelemetry.scheduledSignalCount)
        #expect(quietTelemetry.executedCount == dayZeroTelemetry.executedCount)

        // A fresh runtime restores the persisted day-zero anchor, analytically
        // settles it to the injected day-three clock, and schedules exactly one
        // wake reconciliation without waiting on a real timer.
        let relaunched = makeRuntime(root: root, clock: clock)
        await relaunched.bootstrap()
        let relaunchedBeforeFlush = await relaunched.microcycleTelemetrySnapshot()
        let restoredNode = try #require(await node(id: "analytic-memory", in: relaunched))

        #expect(relaunchedBeforeFlush.scheduledSignalCount == 1)
        #expect(relaunchedBeforeFlush.executedCount == 0)
        #expect(abs(restoredNode.activation - dayThreeNode.activation) < 0.000_001)

        await relaunched.flushPendingMicrocycleForProof()
        let relaunchedAfterFlush = await relaunched.microcycleTelemetrySnapshot()
        #expect(relaunchedAfterFlush.executedCount == 1)
        #expect(relaunchedAfterFlush.completedCount == 1)
    }

    @Test("a chat turn returns before settlement and a burst loses no events")
    func coalescingWakeCountsEventLossAndChatLatency() async throws {
        let root = try temporaryRoot("coalescing")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 3_000_000))
        let runtime = makeRuntime(root: root, clock: clock)

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        let baseline = await runtime.microcycleTelemetrySnapshot()

        let latencyClock = ContinuousClock()
        let latencyStart = latencyClock.now
        await runtime.observe(proofEvent(
            id: "mock-chat-turn",
            kind: .userMessageReceived,
            at: clock.now()
        ))
        let mockChatLatency = latencyStart.duration(to: latencyClock.now)
        let afterChatReturn = await runtime.microcycleTelemetrySnapshot()

        #expect(afterChatReturn.scheduledSignalCount == baseline.scheduledSignalCount + 1)
        #expect(afterChatReturn.executedCount == baseline.executedCount)
        // Warm local acceptance must stay well below the old synchronous
        // organism export/encode/write path observed in installed evidence
        // (multi-second). 1s, not 25ms: the structural claims above already
        // prove settlement stayed off this path; the latency bound only needs
        // to catch a synchronous-path regression, and a 25ms single-sample
        // bound loses to scheduler noise under full-suite parallelism.
        #expect(mockChatLatency < .seconds(1))

        let burstCount = 24
        for index in 0..<burstCount {
            await runtime.observe(proofEvent(
                id: "coalesced-event-\(index)",
                kind: .toolSucceeded,
                at: clock.now()
            ))
        }
        let beforeFlush = await runtime.microcycleTelemetrySnapshot()
        #expect(beforeFlush.scheduledSignalCount == baseline.scheduledSignalCount + UInt64(burstCount + 1))
        #expect(beforeFlush.coalescedReplacementCount == baseline.coalescedReplacementCount + UInt64(burstCount))
        #expect(beforeFlush.executedCount == baseline.executedCount)

        await runtime.flushPendingMicrocycleForProof()
        let afterFlush = await runtime.microcycleTelemetrySnapshot()
        let substrate = await runtime.substrateForIntegration()
        let liveIDs = Set(await substrate.snapshot().nodes.map(\.subjectReference.id))

        #expect(afterFlush.executedCount == baseline.executedCount + 1)
        #expect(afterFlush.completedCount == baseline.completedCount + 1)
        #expect(afterFlush.failedCount == baseline.failedCount)
        #expect(liveIDs.contains("mock-chat-turn"))
        #expect((0..<burstCount).allSatisfy { liveIDs.contains("coalesced-event-\($0)") })

        // A second flush with no signal is a true no-op: no synthetic wake.
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.microcycleTelemetrySnapshot().executedCount == afterFlush.executedCount)
    }

    @Test("exact resident event replay creates no new wake or owner work")
    func exactDuplicateEventIsFullyInert() async throws {
        let root = try temporaryRoot("duplicate-inert")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 3_250_000))
        let runtime = makeRuntime(root: root, clock: clock, organismConfiguration: .enabled)

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        let event = proofEvent(
            id: "exact-duplicate",
            kind: .toolSucceeded,
            at: clock.now()
        )
        await runtime.observe(event)
        let afterFirst = await runtime.microcycleTelemetrySnapshot()
        let organismAfterFirst = await runtime.organismSnapshot()

        await runtime.observe(event)
        let afterDuplicate = await runtime.microcycleTelemetrySnapshot()
        let organismAfterDuplicate = await runtime.organismSnapshot()

        #expect(afterDuplicate == afterFirst)
        #expect(organismAfterDuplicate.signalCount == organismAfterFirst.signalCount)
        await runtime.flushPendingMicrocycleForProof()
        #expect(await runtime.microcycleTelemetrySnapshot().executedCount == afterFirst.executedCount + 1)
    }

    @Test("motor consequences reject stale and equal-time contradictions across restart")
    func motorConsequenceAdmissionIsDurablyMonotonic() async throws {
        let root = try temporaryRoot("motor-monotonic")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 3_275_000))
        let identity = String(repeating: "a", count: 64)
        let first = makeRuntime(root: root, clock: clock, organismConfiguration: .enabled)
        await first.bootstrap()
        await first.flushPendingMicrocycleForProof()

        let succeeded = motorModel(
            identity: identity,
            phase: .succeeded,
            state: "completed",
            verification: .satisfied,
            updatedAt: "2026-07-14T12:00:03Z"
        )
        await first.observeMotorActionState(succeeded)
        let afterSuccess = await first.microcycleTelemetrySnapshot()
        let signalCountAfterSuccess = await first.organismSnapshot().signalCount

        let staleFailure = motorModel(
            identity: identity,
            phase: .failed,
            state: "failed",
            verification: .failed,
            updatedAt: "2026-07-14T12:00:02Z"
        )
        let equalTimeContradiction = motorModel(
            identity: identity,
            phase: .failed,
            state: "failed",
            verification: .failed,
            updatedAt: "2026-07-14T12:00:03Z"
        )
        await first.observeMotorActionState(staleFailure)
        await first.observeMotorActionState(equalTimeContradiction)
        await first.observeMotorActionState(succeeded)
        #expect(await first.microcycleTelemetrySnapshot() == afterSuccess)
        #expect(await first.organismSnapshot().signalCount == signalCountAfterSuccess)
        await first.flushPendingMicrocycleForProof()
        await first.flushForTermination()

        let relaunched = makeRuntime(root: root, clock: clock, organismConfiguration: .enabled)
        await relaunched.bootstrap()
        await relaunched.flushPendingMicrocycleForProof()
        let restartBaseline = await relaunched.microcycleTelemetrySnapshot()
        let restartSignalBaseline = await relaunched.organismSnapshot().signalCount
        await relaunched.observeMotorActionState(staleFailure)
        #expect(await relaunched.microcycleTelemetrySnapshot() == restartBaseline)
        #expect(await relaunched.organismSnapshot().signalCount == restartSignalBaseline)

        let newerCorrection = motorModel(
            identity: identity,
            phase: .failed,
            state: "failed",
            verification: .failed,
            updatedAt: "2026-07-14T12:00:04Z"
        )
        await relaunched.observeMotorActionState(newerCorrection)
        #expect(await relaunched.microcycleTelemetrySnapshot().scheduledSignalCount
            == restartBaseline.scheduledSignalCount + 1)
        #expect(await relaunched.organismSnapshot().signalCount == restartSignalBaseline + 1)
    }

    @Test("microcycle duration uses injected monotonic time rather than wall time")
    func microcycleDurationUsesMonotonicClock() async throws {
        let root = try temporaryRoot("monotonic-duration")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 3_300_000))
        // Bootstrap reconciliation may own one generated microcycle first.
        let monotonic = CognitionMonotonicClock(values: [
            900_000_000, 900_000_000,
            1_000_000_000, 1_042_000_000,
        ])
        let runtime = makeRuntime(
            root: root,
            clock: clock,
            monotonicNowNanoseconds: { monotonic.next() }
        )

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        await runtime.observe(proofEvent(
            id: "monotonic-duration",
            kind: .toolSucceeded,
            at: clock.now()
        ))
        await runtime.flushPendingMicrocycleForProof()

        #expect(await runtime.microcycleTelemetrySnapshot().lastDurationMilliseconds == 42)
    }

    @Test("blocked organism persistence stays off the warm turn and coalesces a burst")
    func organismPersistenceIsOffPathOrderedAndBounded() async throws {
        let root = try temporaryRoot("organism-persistence-lane")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 3_500_000))
        let writer = CognitionOrganismPersistenceProbe(blockAfterWriteCount: 1)
        let runtime = makeRuntime(
            root: root,
            clock: clock,
            organismConfiguration: .enabled,
            organismPersistenceWriter: { state, url in
                try await writer.write(state, to: url)
            }
        )

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        #expect(await writer.writeCount() == 1, "bootstrap owns the first durable write")

        // The first event starts the sole drain; the injected writer then stays
        // blocked until the burst has been accepted.
        await runtime.observe(proofEvent(
            id: "blocked-persistence-anchor",
            kind: .userMessageReceived,
            at: clock.now()
        ))
        await writer.waitUntilBlocked()

        let burstCount = 24
        let latencyClock = ContinuousClock()
        var warmLatencies: [Duration] = []
        for index in 0..<burstCount {
            let started = latencyClock.now
            await runtime.observe(proofEvent(
                id: "blocked-persistence-burst-\(index)",
                kind: .toolSucceeded,
                at: clock.now()
            ))
            warmLatencies.append(started.duration(to: latencyClock.now))
        }
        let sortedLatencies = warmLatencies.sorted()
        let p95Index = min(
            sortedLatencies.count - 1,
            Int(ceil(Double(sortedLatencies.count) * 0.95)) - 1
        )
        // 1s, not 25ms: the writeCount/drain assertions below carry the
        // structural claim (a blocked writer never runs on the warm path);
        // this bound only needs to catch a synchronous-write regression, and
        // a 25ms p95 loses to scheduler noise under full-suite parallelism.
        #expect(sortedLatencies[p95Index] < .seconds(1))

        let blockedStatus = await runtime.organismPersistenceStatusForProof()
        #expect(blockedStatus.drainActive)
        #expect(blockedStatus.requestedGeneration > blockedStatus.completedGeneration)
        #expect(await writer.writeCount() == 2, "the blocked burst must not start more writers")

        await writer.release()
        #expect(await runtime.flushOrganismPersistenceForProof())
        let drainedStatus = await runtime.organismPersistenceStatusForProof()
        #expect(drainedStatus.requestedGeneration == drainedStatus.completedGeneration)
        #expect(!drainedStatus.drainActive)
        #expect(await writer.writeCount() == 3, "the burst must coalesce into one follow-up write")

        let path = root
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            OrganismPersistentState.self,
            from: Data(contentsOf: path)
        )
        #expect(persisted.signalCount == (await runtime.organismSnapshot()).signalCount)
    }

    @Test("fourteen analytic days prove exact residual wake, restart, chat timing, and no idle heartbeat")
    func compressedInstalledBodyMechanics() async throws {
        let root = try temporaryRoot("installed-body-mechanics")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 4_000_000))
        let recorder = acceleratedRecorder(root: root, runtime: "analytic-a", clock: clock)
        let runtime = makeRuntime(
            root: root,
            clock: clock,
            organismConfiguration: OrganismConfiguration(enabled: true),
            recorder: recorder
        )

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        await runtime.ingestOrganismSignal(
            kind: .providerStarted,
            sourceOrgan: "accelerated-provider",
            intensity: 0.9,
            metadata: ["predictionCorrelationId": .string("turn-1")],
            prewarmContext: false
        )
        await runtime.ingestOrganismSignal(
            kind: .providerFailed,
            sourceOrgan: "accelerated-provider",
            intensity: 0.9,
            metadata: ["predictionCorrelationId": .string("turn-1")],
            prewarmContext: false
        )
        // A violated prediction must leave the body with residual pressure and an
        // un-inhibited quiet-repair lane. Asserting the opportunity first turns a
        // scheduler regression into a diagnosis instead of a bare `nil` deadline —
        // notably `resourceInhibited`, which nils every candidate wake.
        let opportunity = await runtime.organismSnapshot().residualRepairOpportunity
        #expect(!opportunity.resourceInhibited)
        #expect(opportunity.localRepairPressure >= OrganismResidualRepair.minimumPressure)
        #expect(opportunity.nextRepairAt != nil)
        // 2026-07-21 flake trap: this read nil'd in 2/3 full-gate runs during
        // the integration window (never standalone). If it recurs, the dump
        // distinguishes arm-machinery dropout from opportunity-input change.
        let deadlineOpt = await runtime.residualRepairDeadlineForProof()
        if deadlineOpt == nil {
            Issue.record("residual deadline nil — \(await runtime.residualRepairDiagnosticsForProof())")
        }
        let deadline = try #require(deadlineOpt)
        let delay = deadline.timeIntervalSince(clock.now())
        #expect(delay > 0)

        clock.advance(delay - 0.001)
        await runtime.flushResidualRepairDeadlineForProof()
        var report = try #require(await runtime.installedPhysiologySoakReport())
        #expect(report.residualDeadlineFireCount == 0)

        clock.advance(0.001)
        let microcyclesBeforeRepair = await runtime.microcycleTelemetrySnapshot()
        await runtime.flushResidualRepairDeadlineForProof()
        report = try #require(await runtime.installedPhysiologySoakReport())
        #expect(report.residualDeadlineFireCount == 1)
        #expect(report.deadlineAbsoluteErrorP95Milliseconds == 0)
        let microcyclesAfterRepair = await runtime.microcycleTelemetrySnapshot()
        #expect(microcyclesAfterRepair.scheduledSignalCount == microcyclesBeforeRepair.scheduledSignalCount)
        #expect(microcyclesAfterRepair.executedCount == microcyclesBeforeRepair.executedCount)

        // Same run digest produces a payload-free end-to-end chat latency.
        await runtime.observe(proofEvent(
            id: "chat-user",
            kind: .userMessageReceived,
            at: clock.now(),
            runID: "chat-run"
        ))
        clock.advance(2)
        await runtime.observe(proofEvent(
            id: "chat-assistant",
            kind: .assistantTurnCompleted,
            at: clock.now(),
            runID: "chat-run"
        ))
        await runtime.flushPendingMicrocycleForProof()
        report = try #require(await runtime.installedPhysiologySoakReport())
        #expect(report.chatTurnCount == 1)
        #expect(report.chatLatencyP95Milliseconds == 2_000)

        let beforeQuiet = await runtime.microcycleTelemetrySnapshot()
        let signalCountBeforeQuiet = await runtime.organismSnapshot().signalCount
        clock.advance(14 * 24 * 60 * 60)
        let afterQuiet = await runtime.microcycleTelemetrySnapshot()
        let signalCountAfterQuiet = await runtime.organismSnapshot().signalCount
        #expect(afterQuiet.scheduledSignalCount == beforeQuiet.scheduledSignalCount)
        #expect(afterQuiet.executedCount == beforeQuiet.executedCount)
        #expect(signalCountAfterQuiet == signalCountBeforeQuiet)

        await runtime.flushForTermination()
        let relaunchedRecorder = acceleratedRecorder(root: root, runtime: "analytic-b", clock: clock)
        let relaunched = makeRuntime(
            root: root,
            clock: clock,
            organismConfiguration: OrganismConfiguration(enabled: true),
            recorder: relaunchedRecorder
        )
        await relaunched.bootstrap()
        await relaunched.flushPendingMicrocycleForProof()
        let restartReport = try #require(await relaunched.installedPhysiologySoakReport())
        #expect(restartReport.runtimeSessionCount == 2)
        #expect(restartReport.cleanStopCount == 1)
        #expect(restartReport.uncleanRestartCount == 0)
        #expect(!restartReport.realMultiDayClaimEligible)
        #expect(restartReport.claimBlockers.contains("evidence is generated, mixed, or absent"))
    }

    @Test("all physiology emissions retain causal order through one recorder tail")
    func recorderTailPreservesMicrocycleAndDeadlineOrder() async throws {
        let root = try temporaryRoot("ordered-physiology-tail")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 5_000_000))
        let runtimeID = "ordered-tail"
        let runtime = makeRuntime(
            root: root,
            clock: clock,
            organismConfiguration: OrganismConfiguration(enabled: true),
            recorder: acceleratedRecorder(root: root, runtime: runtimeID, clock: clock)
        )

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        for index in 0..<24 {
            await runtime.observe(proofEvent(
                id: "ordered-event-\(index)",
                kind: .toolSucceeded,
                at: clock.now()
            ))
            await runtime.flushPendingMicrocycleForProof()
        }

        await runtime.ingestOrganismSignal(
            kind: .providerStarted,
            sourceOrgan: "ordered-provider",
            intensity: 0.9,
            metadata: ["predictionCorrelationId": .string("ordered-turn")],
            prewarmContext: false
        )
        await runtime.ingestOrganismSignal(
            kind: .providerFailed,
            sourceOrgan: "ordered-provider",
            intensity: 0.9,
            metadata: ["predictionCorrelationId": .string("ordered-turn")],
            prewarmContext: false
        )
        // Same contract as the fourteen-day proof: the wake exists because the
        // lane is eligible and un-inhibited, not by accident of the host body.
        #expect(!(await runtime.organismSnapshot().residualRepairOpportunity.resourceInhibited))
        // 2026-07-21 flake trap: this read nil'd in 2/3 full-gate runs during
        // the integration window (never standalone). If it recurs, the dump
        // distinguishes arm-machinery dropout from opportunity-input change.
        let deadlineOpt = await runtime.residualRepairDeadlineForProof()
        if deadlineOpt == nil {
            Issue.record("residual deadline nil — \(await runtime.residualRepairDiagnosticsForProof())")
        }
        let deadline = try #require(deadlineOpt)
        clock.advance(deadline.timeIntervalSince(clock.now()))
        await runtime.flushResidualRepairDeadlineForProof()

        let report = try #require(await runtime.installedPhysiologySoakReport())
        #expect(report.unexpectedMicrocycleWakeCount == 0)
        #expect(report.residualDeadlineFireCount == 1)

        let records = try loadPhysiologyRecords(root: root, runtimeID: runtimeID)
        let armedSequence = try #require(records.first { $0.kind == .residualDeadlineArmed }?.sequence)
        let firedSequence = try #require(records.first { $0.kind == .residualDeadlineFired }?.sequence)
        #expect(armedSequence < firedSequence)
        for finish in records.filter({ $0.kind == .microcycleFinished }) {
            #expect(records.contains {
                $0.kind == .microcycleScheduled
                    && $0.sequence < finish.sequence
                    && ($0.scheduledSignalCount ?? 0) >= (finish.executedMicrocycleCount ?? 0)
            })
        }
    }

    @Test("a wedged physiology submission cannot hold the drain barrier forever")
    func wedgedPhysiologySubmissionBailsOutAtDeadline() async throws {
        let root = try temporaryRoot("wedged-physiology-submission")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceleratedCognitionClock(Date(timeIntervalSince1970: 6_000_000))
        let blocker = CognitionPhysiologyDeadlineBlocker()
        let logs = CognitionPhysiologyDeadlineLogCapture()
        let runtime = makeRuntime(
            root: root,
            clock: clock,
            recorder: acceleratedRecorder(root: root, runtime: "wedged-tail", clock: clock),
            physiologyDrainTimeoutSeconds: 0.05,
            deadlineLogger: { logs.append($0) }
        )

        await runtime.bootstrap()
        await runtime.flushPendingMicrocycleForProof()
        _ = await runtime.installedPhysiologySoakReport()
        await runtime.submitPhysiologyForProof { _ in
            await blocker.wait()
        }

        let wallClock = ContinuousClock()
        let started = wallClock.now
        let report = await runtime.installedPhysiologySoakReport()
        let elapsed = started.duration(to: wallClock.now)

        #expect(report != nil)
        // 10s, not 2s: the claim is "the 0.05s drain deadline won, not the
        // indefinitely-wedged submission" — any finite bound with headroom
        // proves that, while a 2s bound loses to scheduler noise under
        // full-suite parallelism.
        #expect(elapsed < .seconds(10))
        #expect((await runtime.deadlineBailoutCountsForProof()).physiologyDrain == 1)
        #expect(logs.snapshot().contains {
            $0.contains("PHYSIOLOGY BAIL-OUT") && $0.contains("deadline")
        })

        // Release the deliberately non-cooperative loser. Its stale generation
        // cannot decrement or clear any later submission tail.
        await blocker.release()
        await runtime.submitPhysiologyForProof { _ in }
        #expect(await runtime.installedPhysiologySoakReport() != nil)
        #expect((await runtime.deadlineBailoutCountsForProof()).physiologyDrain == 1)
    }

    private func makeRuntime(
        root: URL,
        clock: AcceleratedCognitionClock,
        organismConfiguration: OrganismConfiguration = .disabled,
        recorder: InstalledPhysiologySoakRecorder? = nil,
        monotonicNowNanoseconds: (@Sendable () -> UInt64)? = nil,
        physiologyDrainTimeoutSeconds: TimeInterval = NativeCognitionRuntime.physiologySubmissionDrainDeadlineSeconds,
        deadlineLogger: (@Sendable (String) -> Void)? = nil,
        organismPersistenceWriter:
            (@Sendable (OrganismPersistentState, URL) async throws -> Void)? = nil
    ) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                replayEnabled: true,
                backgroundMicrocyclesEnabled: true,
                observatoryEnabled: true,
                defaultDecayHalfLife: 24 * 60 * 60,
                maximumCapsuleCharacters: 4_000,
                maximumThoughtSeeds: 64
            ),
            organismConfigurationOverride: organismConfiguration,
            now: { clock.now() },
            monotonicNowNanoseconds: monotonicNowNanoseconds ?? {
                DispatchTime.now().uptimeNanoseconds
            },
            microcycleSchedulingMode: .manuallyFlushed,
            installedPhysiologySoakEnabled: false,
            physiologySoakRecorderOverride: recorder,
            physiologySubmissionDrainDeadlineSeconds: physiologyDrainTimeoutSeconds,
            deadlineLogger: deadlineLogger,
            organismPersistenceWriterOverride: organismPersistenceWriter
        )
    }

    private func acceleratedRecorder(
        root: URL,
        runtime: String,
        clock: AcceleratedCognitionClock
    ) -> InstalledPhysiologySoakRecorder {
        InstalledPhysiologySoakRecorder(
            dataRoot: root,
            runtimeInstanceID: runtime,
            evidenceClass: .generatedAccelerated,
            now: { clock.now() },
            processSampler: {
                InstalledPhysiologyProcessSample(
                    systemUptimeSeconds: clock.now().timeIntervalSince1970,
                    userCPUSeconds: 0,
                    systemCPUSeconds: 0,
                    interruptWakeups: 0,
                    packageIdleWakeups: 0
                )
            },
            coalescingDelayNanoseconds: 60_000_000_000
        )
    }

    private func node(
        id: String,
        in runtime: NativeCognitionRuntime
    ) async -> CognitiveNode? {
        let substrate = await runtime.substrateForIntegration()
        return await substrate.snapshot().nodes.first { $0.subjectReference.id == id }
    }

    private func motorModel(
        identity: String,
        phase: MotorActionPhase,
        state: String,
        verification: MotorVerificationState,
        updatedAt: String
    ) -> MotorActionReadModel {
        MotorActionReadModel(
            domain: "test_motor",
            actionIdentity: identity,
            phase: phase,
            domainState: state,
            verification: verification,
            expectedNextEvidence: nil,
            updatedAt: updatedAt
        )
    }

    private func loadPhysiologyRecords(
        root: URL,
        runtimeID: String
    ) throws -> [InstalledPhysiologySoakRecord] {
        let directory = root
            .appendingPathComponent("evals", isDirectory: true)
            .appendingPathComponent("installed_physiology_soak", isDirectory: true)
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return try files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { file -> [InstalledPhysiologySoakRecord] in
                let data = try Data(contentsOf: file)
                let text = String(decoding: data, as: UTF8.self)
                return try text.split(separator: "\n").map {
                    try decoder.decode(InstalledPhysiologySoakRecord.self, from: Data($0.utf8))
                }
            }
            .filter { $0.runtimeInstanceID == runtimeID }
            .sorted { $0.sequence < $1.sequence }
    }

    private func proofEvent(
        id: String,
        kind: CognitiveEventKind,
        at date: Date,
        runID: String = "accelerated-proof-run"
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: id,
            kind: kind,
            subject: CognitiveSubjectReference(type: "accelerated_proof", id: id, label: id),
            sourceClass: .observed,
            occurredAt: date,
            summary: "bounded accelerated cognition proof event \(id)",
            importance: 0.7,
            metadata: [
                "sessionId": .string("accelerated-proof"),
                "runId": .string(runID),
            ]
        )
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-accelerated-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor CognitionPhysiologyDeadlineBlocker {
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

private actor CognitionOrganismPersistenceProbe {
    private let blockAfterWriteCount: Int
    private var writes = 0
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockAfterWriteCount: Int) {
        self.blockAfterWriteCount = blockAfterWriteCount
    }

    func write(_ state: OrganismPersistentState, to url: URL) async throws {
        writes += 1
        if writes > blockAfterWriteCount, !released {
            blocked = true
            let entered = blockedWaiters
            blockedWaiters.removeAll(keepingCapacity: true)
            for waiter in entered { waiter.resume() }
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { continuation in
            if blocked {
                continuation.resume()
            } else {
                blockedWaiters.append(continuation)
            }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    func writeCount() -> Int { writes }
}

private final class CognitionPhysiologyDeadlineLogCapture: @unchecked Sendable {
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

private final class AcceleratedCognitionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

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

private final class CognitionMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}
