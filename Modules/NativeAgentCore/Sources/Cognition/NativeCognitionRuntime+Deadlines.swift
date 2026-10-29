import Foundation
import BackgroundLoops
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

// Blueprint: | `NativeCognitionRuntime+Deadlines.swift` | `CoalescingDeadline` and cognition background settlement: dirty microcycles, checked maintenance, residual repair and exact wakes |

/// One cancellable deadline per owner; only its latest arm may fire.
struct CoalescingDeadline {
    /// The monotonic arm authority. A fired task compares the generation it
    /// captured against this; a mismatch means a newer arm superseded it.
    private(set) var generation: UInt64 = 0
    /// The armed trailing-edge sleep task, or nil when unarmed.
    var task: Task<Void, Never>?
    /// The absolute instant this deadline is currently armed for. Used by the
    /// cognition-maintenance unchanged-deadline short-circuit; the residual site
    /// never reads it (stays nil there).
    var scheduledAt: Date?
    /// Cancel the armed task, clear its schedule and return the new arm generation.
    @discardableResult
    mutating func invalidate() -> UInt64 {
        generation &+= 1
        task?.cancel()
        task = nil
        scheduledAt = nil
        return generation
    }

    /// Arm the trailing-edge sleep task for `deadline`. `clampSeconds` bounds the
    /// wall sleep so a far-future deadline cannot outlive one `Task.sleep`. A
    /// non-finite delay leaves the deadline unarmed (task nil).
    /// The `fire` closure carries its own `[weak self]` re-entry.
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
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    /// Clear the armed task and remembered schedule as a fire body
    /// begins executing (the fired task is consuming itself).
    mutating func consumeForFire() {
        task = nil
        scheduledAt = nil
    }
}

extension NativeCognitionRuntime {
    private static let cognitionMaintenanceRetryDelay: TimeInterval = 60 * 60
    /// When due maintenance is excluded by the
    /// microcycle's commit window, the natural next deadline is
    /// effectively "now" — a plain reschedule would arm a zero-delay task and
    /// hot-loop against a slow SQLite commit. Retry on a short bounded delay
    /// instead; the hour-scale retry above is for gate/error skips, not
    /// momentary commit contention.
    private static let cognitionMaintenanceContentionRetryDelay: TimeInterval = 30

    @discardableResult
    public func runMicrocycle(reason: String) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        do {
            let snapshot = try await substrate.runMicrocycleChecked(reason: reason)
            guard snapshot != nil else {
                return .skipped(reason: "cognitive substrate disabled or clean")
            }
            publishRuntimeChange(reason: "microcycle:completed")
            return .completed(result: "cognitive field settled through checked persistence")
        } catch {
            publishRuntimeChange(reason: "microcycle:failed")
            return .failed(error: "cognitive microcycle failed: \(error.localizedDescription)")
        }
    }

    func scheduleDirtyMicrocycle(
        reason: String
    ) {
        // Post-flush arrivals (a replay tail, a late
        // organism drain) must not arm new microcycles after the terminal
        // snapshot. Same latch the reschedule bodies honor.
        guard !isFlushedForTermination else { return }
        microcycleTelemetry.scheduledSignalCount &+= 1
        if microcycleTimer.isPending {
            microcycleTelemetry.coalescedReplacementCount &+= 1
        }
        microcycleTelemetry.lastScheduledAt = now()
        microcycleTelemetry.lastReason = String(reason.prefix(160))
        microcycleTimer.schedule(delay: .seconds(Self.microcycleCoalescingDelay)) { [weak self] generation in
            await self?.runScheduledMicrocycle(generation: generation, reason: reason)
        }
    }

    private func runScheduledMicrocycle(generation: UInt64, reason: String) async {
        guard !isFlushedForTermination,
              microcycleTimer.take(generation) else { return }
        // This generation is now in flight, not pending. A reentrant event
        // arriving while persistence awaits must start a distinct generation
        // instead of being merged into work already started by this cycle.
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
        // A microcycle may change the field and its visible projections.
        // Re-project the single maintenance deadline after that canonical
        // transition; ordinary reads and quiet elapsed time remain wake-free.
        await caresSourceChanged()
        await rescheduleCognitionMaintenanceDeadline()
        // `runMicrocycle` publishes after the substrate commit; scheduled
        // settlement publishes once more after its telemetry has reached the
        // same terminal state so Observatory readers cannot see stale counters.
        publishRuntimeChange(reason: "microcycle_settlement:finished")
        await rescheduleResidualRepairDeadline()
    }

    public func microcycleTelemetrySnapshot() -> CognitiveMicrocycleTelemetry {
        microcycleTelemetry
    }

    @discardableResult
    public func runMaintenance(reason: String) async -> LoopTickOutcome {
        await bootstrap()
        if let bootstrapFailure { return .failed(error: bootstrapFailure) }
        do {
            let configuration = await substrate.configurationSnapshot()
            let persistenceEnabled = configuration.persistenceEnabled
            let ran = try await substrate.runMaintenanceChecked(reason: reason)
            guard ran else {
                // A not-ran outcome includes "still due
                // but excluded by the microcycle commit window" — re-arming at
                // the natural (already-due) deadline would spin. The bounded
                // contention delay wins only when the natural deadline is
                // effectively now; a genuinely future deadline still wins.
                await rescheduleCognitionMaintenanceDeadline(
                    notBefore: now().addingTimeInterval(Self.cognitionMaintenanceContentionRetryDelay)
                )
                return .skipped(reason: configuration.enabled
                    ? "cognitive maintenance not due or busy"
                    : LoopTickOutcome.offPrefix + "cognition disabled")
            }
            await rescheduleCognitionMaintenanceDeadline()
            publishRuntimeChange(reason: "maintenance:completed")
            return .completed(result: persistenceEnabled
                ? "cognitive maintenance checkpoint and receipt are durable"
                : "cognitive maintenance completed in memory-only mode")
        } catch {
            await rescheduleCognitionMaintenanceDeadline(
                notBefore: now().addingTimeInterval(Self.cognitionMaintenanceRetryDelay)
            )
            publishRuntimeChange(reason: "maintenance:failed")
            return .failed(error: "cognitive maintenance failed: \(error.localizedDescription)")
        }
    }

    private static let residualRepairSleepClampSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let cognitionMaintenanceSleepClampSeconds: TimeInterval = 30 * 24 * 60 * 60

    func rescheduleResidualRepairDeadline() async {
        // Termination prevents every path from re-arming this deadline.
        guard !isFlushedForTermination else { return }
        if let due = sourceWakes.pursuitNextAt, due <= now() {
            sourceWakes.pursuitNextAt = nil
            await startPursuitRefresh()
            guard !isFlushedForTermination else { return }
        }
        let generation = residualDeadline.invalidate()
        let opportunity = await organismKernel.residualRepairOpportunity()
        guard generation == residualDeadline.generation else { return }
        // Source reads enter only on their invalidation or real time boundary;
        // the existing deadline owns their cooldown/expiry, with no new timer.
        considerStudioCanonTending()
        // The forward register's source dirty bit and real eligibility/expiry
        // boundaries gate its retained read task (+Expectations).
        considerHorizonExpectations()
        // Her hour shares this deadline and performs no reads or writes while disabled.
        considerStudioWander()
        // Reach uses source invalidations plus quiet, expiry and cooldown
        // boundaries, sharing this deadline (+Reach).
        considerReach()
        let carriedDeadline = await considerCarried()
        guard generation == residualDeadline.generation else { return }
        // The same exact-deadline owner also wakes at pending prediction/model
        // expiry. That wake only re-derives pressure and may schedule the quiet
        // repair boundary; it does not perform cognition or call a provider.
        guard let deadline = [opportunity.nextWakeAt ?? opportunity.nextRepairAt, carriedDeadline, nextCognitiveSourceWake(at: now())]
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
        // Only the current arm may persist, publish or reschedule after the repair await.
        guard generation == residualDeadline.generation else { return }
        if repaired {
            _ = await persistOrganismContinuity(reason: "residual_pressure_repair")
            publishRuntimeChange(reason: "residual_repair:completed")
        }
        await rescheduleResidualRepairDeadline()
    }

    /// Doctor may invoke the same already-due owner pass as the exact deadline.
    /// Invalidating the prior arm prevents a second firing of that generation.
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

    /// Re-arm one cancellable wake from the substrate's mutation-free deadline
    /// projection. This remains owned by the cognition runtime; it is not a new
    /// scheduler or a second maintenance authority.
    func rescheduleCognitionMaintenanceDeadline(
        notBefore: Date? = nil,
        force: Bool = false
    ) async {
        // Termination prevents every path from re-arming this deadline.
        guard !isFlushedForTermination else { return }
        let currentGeneration = cognitionDeadline.generation
        let opportunity = await substrate.maintenanceOpportunity()
        guard !isFlushedForTermination, cognitionDeadline.generation == currentGeneration else { return }
        let projectedDeadline = opportunity.nextMaintenanceAt
        let deadline: Date
        if let projectedDeadline,
           let notBefore,
           notBefore > projectedDeadline {
            deadline = notBefore
        } else if let projectedDeadline {
            deadline = projectedDeadline
        } else {
            cognitionDeadline.invalidate()
            return
        }
        // System wake forces re-arming: Task.sleep excludes system sleep, so its delay is stale.
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

    /// Report out-of-band cognition work; only real completions receive completion stamps.
    func reportLoopOutcome(  // internal for actor extensions
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

    /// Re-anchor both deadlines after wake, only while the bootstrapped runtime is active.
    public func reanchorDeadlinesAfterWake() async {
        guard bootstrapTask != nil, !isFlushedForTermination else { return }
        sourceWakes.canonDirty = true
        sourceWakes.horizonDirty = true
        sourceWakes.reachDirty = true
        sourceWakes.clockDirty = true
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
    }
}
