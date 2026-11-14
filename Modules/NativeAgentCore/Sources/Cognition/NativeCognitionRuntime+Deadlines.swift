import Foundation
import BackgroundLoops
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

// Blueprint: | `NativeCognitionRuntime+Deadlines.swift` | `CoalescingDeadline`. |

/// Only the latest arm may fire an owner's cancellable deadline.
struct CoalescingDeadline {
    /// Compare captured generation on firing so a superseded arm cannot act.
    private(set) var generation: UInt64 = 0
    var task: Task<Void, Never>?
    /// Retain the armed instant so unchanged maintenance deadlines need no new task; residual repair does not use this field.
    var scheduledAt: Date?
    @discardableResult
    mutating func invalidate() -> UInt64 {
        generation &+= 1
        task?.cancel()
        task = nil
        scheduledAt = nil
        return generation
    }

    /// Clamp wall sleep to Task.sleep's range; nonfinite delays leave the deadline unarmed.
    /// The fire closure owns weak re-entry.
    mutating func arm(
        deadline: Date,
        now: Date,
        clampSeconds: TimeInterval,
        fire: @escaping @Sendable () async -> Void
    ) {
        let rawDelay = deadline.timeIntervalSince(now)
        guard rawDelay.isFinite else { return }
        let delay = max(0, rawDelay)
        task = Task {
            if delay > 0 {
                let nanos = UInt64(min(delay, clampSeconds) * 1_000_000_000)
                do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    /// Clear the consumed arm as its firing body begins.
    mutating func consumeForFire() {
        task = nil
        scheduledAt = nil
    }
}

extension NativeCognitionRuntime {
    /// The microcycle beats each settled pass and each failure under the judge's news window. A wake whose dirt an earlier pass already settled
    /// decides nothing and writes no beat.
    @discardableResult
    public func runMicrocycle(reason: String) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure {
            OrganJudge.beat("microcycle", .failed, note: bootstrapFailure)
            return .failed(error: bootstrapFailure)
        }
        do {
            let snapshot = try await substrate.runMicrocycleChecked(reason: reason)
            guard snapshot != nil else {
                let configuration = await substrate.configurationSnapshot()
                guard configuration.enabled && configuration.backgroundMicrocyclesEnabled else {
                    OrganJudge.beatOff("microcycle", because: "inner life or background thinking is off")
                    return .skipped(reason: "inner life or background thinking is off")
                }
                return .notNeeded("nothing new to settle since the last pass")
            }
            publishRuntimeChange(reason: "microcycle:completed")
            OrganJudge.beat("microcycle", .worked, note: "settled the cognitive field")
            return .completed(result: "cognitive field settled through checked persistence")
        } catch {
            publishRuntimeChange(reason: "microcycle:failed")
            OrganJudge.beat("microcycle", .failed, note: error.localizedDescription)
            return .failed(error: "cognitive microcycle failed: \(error.localizedDescription)")
        }
    }

    func scheduleDirtyMicrocycle(
        reason: String
    ) {
        // After terminal snapshot, late replay or organism arrivals cannot arm new microcycles.
        guard !isFlushedForTermination else { return }
        microcycleTelemetry.scheduledSignalCount &+= 1
        if microcycleTask != nil {
            microcycleTelemetry.coalescedReplacementCount &+= 1
        }
        microcycleTelemetry.lastScheduledAt = now()
        microcycleTelemetry.lastReason = String(reason.prefix(160))
        microcycleDirty = true
        guard microcycleTask == nil else { return }
        microcycleTask = Task { [weak self] in
            await self?.drainMicrocycles()
        }
    }

    private func drainMicrocycles() async {
        while microcycleDirty, !isFlushedForTermination, !Task.isCancelled {
            microcycleDirty = false
            guard let reason = microcycleTelemetry.lastReason else {
                let failure = "The dirty microcycle has no source reason."
                OrganJudge.beat("microcycle", .failed, note: failure)
                break
            }
            await runScheduledMicrocycle(reason: reason)
        }
        microcycleTask = nil
    }

    private func runScheduledMicrocycle(reason: String) async {
        let startedAt = now()
        let monotonicStartedAt = monotonicNowNanoseconds()
        microcycleTelemetry.executedCount &+= 1
        microcycleTelemetry.lastStartedAt = startedAt
        let outcome = await runMicrocycle(reason: reason)
        switch outcome {
        case .completed:
            microcycleTelemetry.completedCount &+= 1
            microcycleTelemetry.lastOutcome = "completed"
        case .skipped:
            microcycleTelemetry.skippedCount &+= 1
            microcycleTelemetry.lastOutcome = "skipped"
        case .failed:
            microcycleTelemetry.failedCount &+= 1
            microcycleTelemetry.lastOutcome = "failed"
        }
        let finishedAt = now()
        let monotonicFinishedAt = monotonicNowNanoseconds()
        microcycleTelemetry.lastFinishedAt = finishedAt
        let elapsedNanoseconds = monotonicFinishedAt >= monotonicStartedAt
            ? monotonicFinishedAt - monotonicStartedAt
            : 0
        microcycleTelemetry.lastDurationMilliseconds = Int(min(
            elapsedNanoseconds / 1_000_000,
            UInt64(Int.max)
        ))
        // Reproject maintenance only after canonical mutation; reads and elapsed quiet time remain wake-free.
        await caresSourceChanged()
        await rescheduleCognitionMaintenanceDeadline()
        // Publish after telemetry settles as well as substrate commit so Observatory cannot retain stale counters.
        publishRuntimeChange(reason: "microcycle_settlement:finished")
        await rescheduleResidualRepairDeadline()
    }

    public func microcycleTelemetrySnapshot() -> CognitiveMicrocycleTelemetry {
        microcycleTelemetry
    }

    /// Every path (its loop, its deadline) beats here; an asked run beats through `recordClockRun`.
    @discardableResult
    public func runMaintenance(reason: String, runNow: Bool = false) async -> LoopTickOutcome {
        let outcome = await performMaintenance(reason: reason, runNow: runNow)
        if !runNow {
            OrganJudge.beat(MindClockVerb.maintenance.organ, tick: outcome, cadence: Self.substrateClockCadence)
        }
        return outcome
    }

    private func performMaintenance(reason: String, runNow: Bool) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        do {
            let configuration = await substrate.configurationSnapshot()
            let persistenceEnabled = configuration.persistenceEnabled
            switch try await substrate.runMaintenanceChecked(reason: reason, satisfyWait: runNow) {
            case .ran: maintenanceFailure = nil
            case .disabled:
                return .skipped(reason: LoopTickOutcome.offPrefix + "cognition disabled")
            case .notDue:
                await rescheduleCognitionMaintenanceDeadline()
                return .notNeeded("cognitive maintenance not due yet")
            case .busy:
                // The admitted pass reprojects its next occurrence on settlement.
                return .skipped(reason: "cognitive maintenance busy with another pass")
            }
            await rescheduleCognitionMaintenanceDeadline()
            publishRuntimeChange(reason: "maintenance:completed")
            return .completed(result: persistenceEnabled
                ? "cognitive maintenance checkpoint and receipt are durable"
                : "cognitive maintenance completed in memory-only mode")
        } catch {
            maintenanceFailure = error.localizedDescription
            cognitionDeadline.invalidate()
            publishRuntimeChange(reason: "maintenance:failed")
            return .failed(error: "cognitive maintenance failed: \(error.localizedDescription)")
        }
    }

    private static let residualRepairSleepClampSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let cognitionMaintenanceSleepClampSeconds: TimeInterval = 30 * 24 * 60 * 60

    func rescheduleResidualRepairDeadline() async {
        // Termination prevents every path from rearming this deadline.
        guard !isFlushedForTermination else { return }
        let generation = residualDeadline.invalidate()
        let opportunity = await organismKernel.residualRepairOpportunity()
        guard generation == residualDeadline.generation else { return }
        // Source reads run only on invalidation or real time boundaries; cooldown and expiry share this deadline.
        considerStudioCanonTending()
        // Use source dirtiness and real horizon boundaries to gate forward-register reads.
        considerHorizonExpectations()
        considerRhythm()
        // Prediction expiry only rederives pressure and quiet-repair scheduling; it cannot run cognition or call a provider.
        guard let deadline = [opportunity.nextWakeAt ?? opportunity.nextRepairAt, nextCognitiveSourceWake(at: now())]
            .compactMap({ $0 }).min() else {
            return
        }
        residualDeadline.arm(
            deadline: deadline,
            now: now(),
            clampSeconds: Self.residualRepairSleepClampSeconds
        ) { [weak self] in
            await self?.runResidualRepairDeadline(generation: generation)
        }
    }

    private func runResidualRepairDeadline(generation: UInt64) async {
        guard generation == residualDeadline.generation else { return }
        residualDeadline.consumeForFire()
        let opportunity = await organismKernel.residualRepairOpportunity()
        guard generation == residualDeadline.generation else { return }
        guard opportunity.ready else {
            await rescheduleResidualRepairDeadline()
            return
        }
        let repaired = await organismKernel.runResidualRepairIfDue()
        // Only the current arm may persist, publish or reschedule after awaiting repair.
        guard generation == residualDeadline.generation else { return }
        if repaired {
            let saved = await persistOrganismContinuity(reason: "residual_pressure_repair")
            publishRuntimeChange(reason: "residual_repair:completed")
            beat(.residualRepair, saved ? .init("repaired", "repaired residual pressure and saved it")
                : .init("failed", "repaired residual pressure in memory; continuity was not saved"))
        } else {
            beat(.residualRepair, .init("nothing", "no repairable residual evidence was due"))
        }
        await rescheduleResidualRepairDeadline()
    }

    /// Invalidate the prior arm before Doctor invokes the same due pass so that generation cannot fire twice.
    public func repairDueResidualForDoctor() async -> Bool {
        await bootstrap()
        guard !isFlushedForTermination else { return false }
        guard await organismKernel.residualRepairOpportunity().ready else { return false }
        let before = await organismKernel.snapshot().dreamRepairSummary.receiptCount
        let generation = residualDeadline.invalidate()
        await runResidualRepairDeadline(generation: generation)
        let after = await organismKernel.snapshot().dreamRepairSummary.receiptCount
        let stillReady = await organismKernel.residualRepairOpportunity().ready
        return after > before && !stillReady
    }

    /// Project one wake from canonical substrate deadlines; cognition remains the sole scheduling owner.
    func rescheduleCognitionMaintenanceDeadline(
        force: Bool = false
    ) async {
        // Termination prevents every path from rearming this deadline.
        guard !isFlushedForTermination, maintenanceFailure == nil else { return }
        let currentGeneration = cognitionDeadline.generation
        let opportunity = await substrate.maintenanceOpportunity()
        guard !isFlushedForTermination, cognitionDeadline.generation == currentGeneration else { return }
        guard let deadline = opportunity.nextMaintenanceAt else {
            cognitionDeadline.invalidate()
            return
        }
        // Rearm on system wake because Task.sleep excludes system sleep.
        if !force,
           cognitionDeadline.scheduledAt == deadline,
           cognitionDeadline.task != nil {
            return
        }
        let generation = cognitionDeadline.invalidate()
        cognitionDeadline.scheduledAt = deadline
        cognitionDeadline.arm(
            deadline: deadline,
            now: now(),
            clampSeconds: Self.cognitionMaintenanceSleepClampSeconds
        ) { [weak self] in
            await self?.runCognitionMaintenanceDeadline(
                generation: generation,
                scheduledAt: deadline
            )
        }
    }

    private func runCognitionMaintenanceDeadline(
        generation: UInt64,
        scheduledAt: Date
    ) async {
        guard generation == cognitionDeadline.generation else { return }
        cognitionDeadline.consumeForFire()
        guard now() >= scheduledAt else {
            await rescheduleCognitionMaintenanceDeadline()
            return
        }
        let outcome = await runMaintenance(reason: "cognition_maintenance_deadline")
        await reportLoopOutcome(loopId: "cognition_maintenance", outcome: outcome)
    }

    /// Stamp only real completions when reporting out-of-band work.
    func reportLoopOutcome(
        loopId: String,
        outcome: LoopTickOutcome
    ) async {
        let tick: LoopTickOutcome
        switch outcome {
        case .completed(let detail):
            tick = .completed(result: detail.map { String($0.prefix(200)) })
        case .skipped(let reason, let healthNeutral):
            tick = .skipped(reason: String(reason.prefix(180)), healthNeutral: healthNeutral)
        case .failed(let error):
            tick = .failed(error: String(error.prefix(180)))
        }
        await BackgroundLoops.BackgroundLoopLifetimes.shared
            .recordOutOfBandOutcome(loopId: loopId, outcome: tick)
    }

    /// Reanchor after wake only while the bootstrapped runtime remains active.
    public func reanchorDeadlinesAfterWake() async {
        guard bootstrapTask != nil, !isFlushedForTermination else { return }
        sourceWakes.canonDirty = true
        sourceWakes.horizonDirty = true
        sourceWakes.clockDirty = true
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
    }
}
