// Move-only extraction (tightness Wave C) from NativeCognitionRuntime.swift

import Foundation
import ChatOrchestration
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ProviderRouting

/// One coalesced, cancellable exact-deadline wake. Extracted (C6) from the two
/// sites that hand-rolled the identical structure — residual-repair and
/// cognition-maintenance — each of which owned a generation counter, the armed
/// trailing-edge sleep task, the last scheduled instant, and (under
/// `manuallyFlushed` proof scheduling) a mirror of the pending
/// `(generation, deadline)` so accelerated tests can fire the exact same path
/// without sleeping.
///
/// The struct owns only *state and mechanics*; each site keeps its own
/// projection/short-circuit/fire body. Generation is the single monotonic
/// authority: every reschedule/cancel begins by `invalidate()`-ing (bump +
/// tear down), each armed task guards on the generation it captured, and a
/// concurrent wake or normal reschedule simply wins the generation while the
/// losers no-op. This is why the wake re-anchor is safe against double-arm.
struct CoalescingDeadline {  // internal for actor extensions (move-only Wave C)
    /// The monotonic arm authority. A fired task compares the generation it
    /// captured against this; a mismatch means a newer arm superseded it.
    private(set) var generation: UInt64 = 0
    /// The armed trailing-edge sleep task, or nil when unarmed.
    var task: Task<Void, Never>?
    /// The absolute instant this deadline is currently armed for. Used by the
    /// cognition-maintenance unchanged-deadline short-circuit; the residual site
    /// never reads it (stays nil there).
    var scheduledAt: Date?
    /// Under `manuallyFlushed` scheduling, the pending arm the generated-evidence
    /// proof seam fires against instead of sleeping.
    var pendingForProof: (generation: UInt64, deadline: Date)?

    /// Bump the generation and tear down any armed task, remembered schedule, and
    /// proof mirror. Every reschedule/cancel path begins here; the returned value
    /// is the fresh generation the caller binds its armed task and fire receipts
    /// to. (Cancelling an already-nil task and re-nilling nil fields is inert, so
    /// this is byte-equivalent to the residual site — which never set
    /// `scheduledAt` — and the cognition site alike.)
    @discardableResult
    mutating func invalidate() -> UInt64 {
        generation &+= 1
        task?.cancel()
        task = nil
        scheduledAt = nil
        pendingForProof = nil
        return generation
    }

    /// Arm the trailing-edge sleep task for `deadline`. `clampSeconds` bounds the
    /// wall sleep so a far-future deadline cannot outlive one `Task.sleep`. A
    /// non-finite delay leaves the deadline unarmed (task nil), matching the
    /// original guard. The `fire` closure carries its own `[weak self]` re-entry.
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

    /// Record the pending `(generation, deadline)` for a `manuallyFlushed` proof
    /// run in place of arming a live sleep task.
    mutating func armForProof(generation: UInt64, deadline: Date) {
        pendingForProof = (generation, deadline)
    }

    /// Clear the armed task, remembered schedule, and proof mirror as a fire body
    /// begins executing (the fired task is consuming itself).
    mutating func consumeForFire() {
        task = nil
        scheduledAt = nil
        pendingForProof = nil
    }

    var proofDeadline: Date? { pendingForProof?.deadline }
}

extension NativeCognitionRuntime {
    // G-M3: single-consumer clamp bounds relocated from the core runtime into the
    // extension that owns their only reader (arm(clampSeconds:) below).
    private static let residualRepairSleepClampSeconds: TimeInterval = 7 * 24 * 60 * 60
    private static let cognitionMaintenanceSleepClampSeconds: TimeInterval = 30 * 24 * 60 * 60

    func rescheduleResidualRepairDeadline() async {  // internal for actor extensions (move-only Wave C)
        // G-H2: covers every re-arm site, not just the wake re-anchor. Once
        // `flushForTermination` has latched, no path may resurrect this timer.
        guard !isFlushedForTermination else { return }
        let generation = residualDeadline.invalidate()
        let opportunity = await organismKernel.residualRepairOpportunity()
        guard generation == residualDeadline.generation else { return }
        // The same exact-deadline owner also wakes at pending prediction/model
        // expiry. That wake only re-derives pressure and may schedule the quiet
        // repair boundary; it does not perform cognition or call a provider.
        guard let deadline = opportunity.nextWakeAt ?? opportunity.nextRepairAt else {
            submitPhysiology { recorder in
                await recorder.recordResidualDeadlineArmed(
                    deadline: nil,
                    opportunity: opportunity
                )
            }
            return
        }
        submitPhysiology { recorder in
            await recorder.recordResidualDeadlineArmed(
                deadline: deadline,
                opportunity: opportunity
            )
        }
        if microcycleSchedulingMode == .manuallyFlushed {
            residualDeadline.armForProof(generation: generation, deadline: deadline)
            return
        }
        residualDeadline.arm(
            deadline: deadline,
            now: now(),
            clampSeconds: Self.residualRepairSleepClampSeconds
        ) { [weak self] in
            await self?.runResidualRepairDeadline(generation: generation, scheduledAt: deadline)
        }
    }

    private func runResidualRepairDeadline(generation: UInt64, scheduledAt: Date) async {
        guard generation == residualDeadline.generation else { return }
        residualDeadline.consumeForFire()
        let firedAt = now()
        let opportunity = await organismKernel.residualRepairOpportunity()
        guard generation == residualDeadline.generation else { return }
        guard opportunity.ready else {
            submitPhysiology { recorder in
                await recorder.recordResidualDeadlineFired(
                    scheduledAt: scheduledAt,
                    firedAt: firedAt,
                    wasDue: false,
                    localRepairPerformed: false,
                    operationalConsolidationPerformed: false
                )
            }
            await rescheduleResidualRepairDeadline()
            return
        }
        let repaired = await organismKernel.runResidualRepairIfDue()
        // G-H1 (2026-07-18): d0bcd775 accidentally severed the operational-
        // consolidation lane from this fire path, hardcoding the telemetry field
        // to false. Restore the call beside the residual repair; the fired record
        // now carries the real disposition.
        let operational = await organismKernel.runOperationalConsolidationIfDue()
        // G-L2 (2026-07-18): re-check generation after the repair/consolidation
        // awaits, mirroring the guards at the top of this function. A concurrent
        // reschedule or wake re-anchor may have superseded this arm while the
        // organism actor ran; the newer arm owns persist/publish/reschedule.
        guard generation == residualDeadline.generation else { return }
        submitPhysiology { recorder in
            await recorder.recordResidualDeadlineFired(
                scheduledAt: scheduledAt,
                firedAt: firedAt,
                wasDue: opportunity.ready,
                localRepairPerformed: repaired,
                operationalConsolidationPerformed: operational != nil
            )
        }
        if repaired {
            _ = await persistOrganismContinuity(reason: "residual_pressure_repair")
            publishRuntimeChange(reason: "residual_repair:completed")
        }
        await rescheduleResidualRepairDeadline()
    }

    /// Re-arm one cancellable wake from the substrate's mutation-free deadline
    /// projection. This remains owned by the cognition runtime; it is not a new
    /// scheduler or a second maintenance authority.
    func rescheduleCognitionMaintenanceDeadline(  // internal for actor extensions (move-only Wave C)
        notBefore: Date? = nil,
        force: Bool = false
    ) async {
        // G-H2: covers every re-arm site, not just the wake re-anchor. Once
        // `flushForTermination` has latched, no path may resurrect this timer.
        guard !isFlushedForTermination else { return }
        let opportunity = await substrate.maintenanceOpportunity()
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
        // R-F4: a system-wake re-anchor forces past this unchanged-deadline
        // short-circuit. `Task.sleep` does not advance across system sleep, so
        // the already-armed task's remaining delay is stale even though the
        // absolute deadline Date is unchanged; re-arming re-derives the delay
        // from the post-wake clock.
        if !force,
           cognitionDeadline.scheduledAt == deadline,
           cognitionDeadline.task != nil || cognitionDeadline.pendingForProof != nil {
            return
        }
        let generation = cognitionDeadline.invalidate()
        cognitionDeadline.scheduledAt = deadline
        if microcycleSchedulingMode == .manuallyFlushed {
            cognitionDeadline.armForProof(generation: generation, deadline: deadline)
            return
        }
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
        _ = await runMaintenance(reason: "cognition_maintenance_deadline")
    }

    /// R-F4: re-anchor the exact-deadline cognition timers after a system wake.
    /// `Task.sleep` does not advance across system sleep, so a deadline armed
    /// before sleep fires late until the next sensory event re-arms it (never
    /// missed-forever — the fire path re-checks + re-arms — only late). Called
    /// from the app's `didWake` handler, mirroring the ContextFlow re-anchor.
    ///
    /// Idempotent and safe against double-arm: both reschedule paths bump their
    /// generation counter and cancel the prior task, and each armed task guards
    /// on its own generation, so a concurrent wake or a normal reschedule simply
    /// wins the generation and the losers no-op. The residual-repair reschedule
    /// always re-derives its delay; the cognition-maintenance reschedule is
    /// forced past its unchanged-deadline short-circuit for the same reason.
    /// No-op before bootstrap — there are no armed timers to re-anchor — and
    /// after `flushForTermination` (review round 2, LOW: a wake landing during
    /// app teardown must not re-arm the timers the flush just cancelled).
    func reanchorDeadlinesAfterWake() async {
        guard bootstrapTask != nil, !isFlushedForTermination else { return }
        await rescheduleCognitionMaintenanceDeadline(force: true)
        await rescheduleResidualRepairDeadline()
    }

    /// Generated-evidence seam for the exact same resident deadline path. It
    /// never sleeps and refuses to fire before the injected analytic clock has
    /// reached the recorded deadline.
    func flushResidualRepairDeadlineForProof() async {
        guard microcycleSchedulingMode == .manuallyFlushed,
              let pending = residualDeadline.pendingForProof,
              now() >= pending.deadline else { return }
        await runResidualRepairDeadline(
            generation: pending.generation,
            scheduledAt: pending.deadline
        )
    }

    func residualRepairDeadlineForProof() -> Date? {
        residualDeadline.proofDeadline
    }

    /// 2026-07-21 flake hunt: when the proof deadline reads nil, this dump
    /// tells the NEXT occurrence WHY (arm machinery vs opportunity input)
    /// instead of a bare Expectation-failed. Proof-only seam, no behavior.
    func residualRepairDiagnosticsForProof() async -> String {
        let opportunity = await organismKernel.residualRepairOpportunity()
        return "proofDeadline=\(String(describing: residualDeadline.proofDeadline)) "
            + "generation=\(residualDeadline.generation) "
            + "mode=\(microcycleSchedulingMode) "
            + "nextWakeAt=\(String(describing: opportunity.nextWakeAt)) "
            + "nextRepairAt=\(String(describing: opportunity.nextRepairAt)) "
            + "ready=\(opportunity.ready)"
    }

    func flushCognitionMaintenanceDeadlineForProof() async {
        guard microcycleSchedulingMode == .manuallyFlushed,
              let pending = cognitionDeadline.pendingForProof,
              now() >= pending.deadline else { return }
        await runCognitionMaintenanceDeadline(
            generation: pending.generation,
            scheduledAt: pending.deadline
        )
    }

    func cognitionMaintenanceDeadlineForProof() -> Date? {
        cognitionDeadline.proofDeadline
    }

    /// R-F4 proof seam: the current cognition-maintenance arm generation. A wake
    /// re-anchor forces a re-arm (generation bumps) even when the projected
    /// deadline Date is unchanged, so a test can prove the re-arm fired past the
    /// unchanged-deadline idempotency short-circuit.
    func cognitionMaintenanceGenerationForProof() -> UInt64 {
        cognitionDeadline.generation
    }
}
