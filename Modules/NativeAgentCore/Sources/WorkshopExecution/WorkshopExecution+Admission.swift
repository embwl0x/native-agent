import Foundation
import NativeAgentShared
import os
import PersistenceCore
import NativeAgentCore
import Desk
import ApprovalInbox
// Blueprint: | `WorkshopExecution+Admission.swift` | `WorkshopExecutorLoop` queue admission, drain, slot claims and restart/approval-timeout recovery; originating DataRootLife governs restored records and explicit fresh starts |

extension WorkshopExecutorLoop {
    // MARK: drain

    /// One drain pass's receipt: how many executions it claimed and ran, and
    /// every fault it met on the way. A fault is never folded into the count,
    /// so broken queue access or recovery cannot read as "nothing queued".
    public struct DrainPass: Sendable {
        public var ran = 0
        public var faults: [String] = []
    }

    /// One drain pass: claim + run queued or approved Workshop executions, oldest first, one at a
    /// time. Per-Workshop execution failures are contained (logged + that Workshop execution goes
    /// `failed`); the pass moves on. Safe to call from a LoopRunner tick.
    public func drainOnce() async -> DrainPass {
        var pass = DrainPass()
        do {
            // Crash/restart orphan recovery — completes BEFORE this drain claims
            // anything (the shared barrier; see reconcileTask).
            try await ensureOrphansReconciled()
            for record in try await scanQueue()
            where ["queued", "pending", "blocked_on_approval", "blocked_on_reconciliation"].contains(record.status) {
                _ = try await cancelWithDesk(record.id, from: [record.status])
            }
            // Terminal execution state is canonical; its Desk projection and
            // unified receipt are retryable derived settlement. Reconcile every
            // terminal record before admitting new work so a crash between the
            // terminal CAS and the event sink cannot leave a zombie Desk item.
            try await reconcileTerminalDeskSettlements()
            // Disabling autonomous execution blocks new claims, not durable
            // zero-effect repair of work that was already admitted.
            guard await isEnabled() else { return pass }
            // Fail approvals nobody is coming to answer (no-op unless the
            // approval-wait deadline is configured). Runs each drain tick so the
            // timeout granularity is the drain interval — fine for a multi-hour
            // approval wait.
            try await reconcileTimedOutApprovals()
        } catch {
            Self.logger("Workshop drain unavailable: \(error.localizedDescription)", level: .error)
            pass.faults.append("Desk queue unavailable: \(error.localizedDescription)")
            return pass
        }
        let queued: [WorkshopExecutionRecord]
        do {
            queued = try await scanQueue()
                .filter { $0.status == "queued" || $0.status == "blocked_on_approval" }
                .sorted { $0.createdAt < $1.createdAt }   // submit order
        } catch {
            pass.faults.append("Desk queue unavailable: \(error.localizedDescription)")
            return pass
        }
        for record in queued {
            if Task.isCancelled { return pass }
            do {
                if record.status == "blocked_on_approval" {
                    guard let approval = try await resolvedStepApproval(record) else { continue }
                    _ = try await resumeAfterApproval(
                        executionId: record.id, stepId: record.currentStepId,
                        approved: true, approvalId: approval.approval.id)
                    pass.ran += 1
                    continue
                }
                guard let claimed = try await claim(record.id) else { continue }
                await runClaimedWorkshopExecution(claimed)
                pass.ran += 1
            } catch WorkshopExecutionError.approvalDeferred {
                // The approval and blocked step remain intact for the next capacity edge.
                continue
            } catch is CancellationError {
                return pass
            } catch {
                Self.logger("drain claim failed for \(record.id): \(String(describing: error))", level: .error)
                pass.faults.append("Desk execution \(record.id) could not be claimed or resumed: \(error.localizedDescription)")
            }
        }
        return pass
    }

    private func reconcileTerminalDeskSettlements() async throws {
        await WorkshopDeskReceiptBridge.recordTerminal(try await scanQueue().filter(\.isTerminal), dataRoot: root)
    }

    /// Earliest persisted approval-wait expiry. Queued work is reconciled by
    /// the execution-directory event/startup edge; only a future transition
    /// belongs to the exact-deadline scheduler.
    public func nextMeaningfulDeadline(after date: Date) async -> Date? {
        guard approvalTimeoutNanos > 0 else { return nil }
        let timeout = TimeInterval(approvalTimeoutNanos) / 1_000_000_000
        // An unreadable queue has no known crossing; the drain reports it.
        return ((try? await scanQueue()) ?? []).compactMap { execution -> Date? in
            guard execution.status == "blocked_on_approval" else { return nil }
            let raw = Self.latestBlockedStepExecutedAt(execution) ?? execution.updatedAt
            guard let blockedAt = WorkshopOutcomeScoreboard.parseTimestamp(raw) else {
                return nil
            }
            let due = blockedAt.addingTimeInterval(timeout)
            return due > date ? due : nil
        }.min()
    }

    func ensureOrphansReconciled() async throws {
        try await Self.orphanReclaimOnce.runChecked(root.path) { try await self.reconcileOrphanedRunning() }
    }

    /// Startup recovery resumes only a live Desk continuation at a fully settled
    /// successful step boundary; other running orphans fail with effects unknown.
    private func reconcileOrphanedRunning() async throws {
        let queue = try await scanQueue()
        let orphans = queue.filter { $0.status == "running" }
        for orphan in orphans {
            if try await cancelWithDesk(orphan.id) { continue }
            if let handle = orphan.deskHandle {
                let task = try await SwiftNativeDeskStore(dataRoot: root).liveState().items.first { $0.handle == handle }
                let linked = task?.continuation?.pending.contains {
                    $0.owner == "workshop" && $0.ownerID == orphan.id
                } == true
                let completed = orphan.stepsCompleted.filter { value in
                    guard case .object(let fields) = value else { return false }
                    return fields["status"] == .string(WorkshopStepOutcome.successStatus)
                        && !DeskContinuation.receiptIsUnresolved(value)
                }
                let safeBoundary = orphan.currentStepId.isEmpty || completed.contains { value in
                    guard case .object(let fields) = value else { return false }
                    return fields["step_id"] == .string(orphan.currentStepId)
                }
                if linked, task?.status.isTerminal == false,
                   task?.continuation?.state != .canceled, safeBoundary,
                   completed.count == orphan.stepsCompleted.count {
                    let resumed = try await casMutateWorkshopExecution(orphan.id, require: ["running"]) { rec in
                        rec.status = "queued"
                        rec.currentStepId = ""
                    }
                    if resumed.applied {
                        try await appendTimelineLocked(.object([
                            "event": .string("continued_after_restart"),
                            "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                        ]), executionId: orphan.id)
                        continue
                    }
                }
            }
            let failed = try await casMutateWorkshopExecution(orphan.id, require: ["running"]) { rec in
                rec.status = "failed"
                rec.terminalReason = "interrupted_by_restart"
                rec.result = .object([
                    "error": .string("interrupted_by_restart"),
                    "pending_step_id": .string(rec.currentStepId),
                    "effects": .string("unknown"),
                ])
                rec.currentStepId = ""
            }
            guard let settled = failed.record, settled.status != "running" else {
                throw WorkshopExecutionError.persistenceFailure("Workshop orphan \(orphan.id) did not settle; restore its execution record before admitting work")
            }
            guard failed.applied else { continue }
            try await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string("interrupted_by_restart"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: orphan.id
            )
            await emitTerminalEvent(settled, reason: "interrupted_by_restart")
        }
    }

    /// Configured approval expiry ages the latest blocked step’s stable timestamp,
    /// or updatedAt if absent. The locked status/age check excludes resumed work.
    private func reconcileTimedOutApprovals() async throws {
        guard approvalTimeoutNanos > 0 else { return }
        let deadlineSecs = TimeInterval(approvalTimeoutNanos) / 1_000_000_000
        let nowDate = now()
        let blocked = try await scanQueue().filter { $0.status == "blocked_on_approval" }
        for execution in blocked {
            // An answered approval waiting for capacity is no longer an approval wait.
            do {
                if try await resolvedStepApproval(execution) != nil { continue }
            } catch {
                continue // Unavailable authority cannot justify expiring this approval.
            }
            let blockedSinceRaw = Self.latestBlockedStepExecutedAt(execution) ?? execution.updatedAt
            guard let blockedAt = WorkshopOutcomeScoreboard.parseTimestamp(blockedSinceRaw) else {
                // Unparseable timestamp: do NOT fail a Workshop execution we can't age —
                // a parse miss must not become a silent kill.
                continue
            }
            let elapsed = nowDate.timeIntervalSince(blockedAt)
            guard elapsed >= deadlineSecs else { continue }
            let label = deadlineSecs >= 1
                ? "\(Int(deadlineSecs))s"
                : "\(max(1, Int((deadlineSecs * 1000).rounded())))ms"
            let failed = try? await casMutateWorkshopExecution(
                execution.id, require: ["blocked_on_approval"], matching: { current in
                    // A prior approval may have resumed and reached a NEW
                    // blocked step since scanQueue. Status alone cannot fence
                    // that ABA transition; age the current block under lock.
                    let currentStamp = Self.latestBlockedStepExecutedAt(current) ?? current.updatedAt
                    guard let currentBlockedAt = WorkshopOutcomeScoreboard.parseTimestamp(currentStamp) else {
                        return false
                    }
                    return nowDate.timeIntervalSince(currentBlockedAt) >= deadlineSecs
                }
            ) { rec in
                rec.status = "failed"
                rec.terminalReason = "approval_timeout_exceeded_\(label)"
                rec.currentStepId = ""   // terminal — clear the step pointer
            }
            guard failed?.applied == true else { continue }   // lost CAS → resume/cancel won
            try? await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string("approval_timeout_exceeded_\(label)"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: execution.id
            )
            await emitTerminalEvent(failed?.record, reason: "approval_timeout_exceeded_\(label)")
            Self.logger("auto-failed approval-timed-out Workshop execution \(execution.id) -> failed (waited \(Int(elapsed))s >= \(label))", level: .default)
        }
    }

    /// The `executed_at` of the most-recent blocked_on_approval step record —
    /// the stable "blocked since" timestamp the approval-timeout sweep ages
    /// against (unaffected by unrelated `updatedAt` bumps). nil when no blocked
    /// step record carries a usable timestamp (caller falls back to updatedAt).
    private static func latestBlockedStepExecutedAt(_ execution: WorkshopExecutionRecord) -> String? {
        for sr in execution.stepsCompleted.reversed() {
            guard case .object(let o) = sr,
                  case .string("blocked_on_approval")? = o["status"],
                  case .string(let ts)? = o["executed_at"], !ts.isEmpty else { continue }
            return ts
        }
        return nil
    }

    /// Explicit start claims queued work; a stopped life starts a fresh request
    /// through the ordinary planner, never the restored plan or completed steps.
    @discardableResult
    public func start(executionId: String) async throws -> WorkshopExecutionRecord {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WorkshopExecutionError.invalidRequest("empty missionId") }
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(trimmed) else {
            throw WorkshopExecutionError.invalidRequest(
                "executionId must be a single path component"
            )
        }
        // Reconcile before admission so this process never reclaims its own work.
        try await ensureOrphansReconciled()
        if let stopped = try await getRecord(trimmed), stopped.status == "stopped" {
            let runner = SwiftNativeWorkshopRunner(root: root, planner: SwiftNativeWorkshopPlannerLLM(dataRoot: root))
            let fresh = try await runner.submit(spec: WorkshopExecutionSpec(title: stopped.title,
                objective: stopped.objective, triggerSource: "manual", trustRequired: stopped.trustRequired,
                deskHandle: stopped.deskHandle, projectSpaceId: stopped.projectSpaceId,
                expectedOutputs: stopped.expectedOutputs.compactMap { if case .string(let value) = $0 { value } else { nil } }))
            return try await start(executionId: fresh.executionId)
        }
        guard let claimed = try await claim(trimmed) else {
            let current = try await getRecord(trimmed)
            guard let current else { throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)") }
            throw WorkshopExecutionError.invalidRequest("Workshop execution \(trimmed) cannot be started (status=\(current.status))")
        }
        await runClaimedWorkshopExecution(claimed)
        return try await getRecord(trimmed) ?? claimed
    }

    // MARK: claim

    /// Queue-level claim-lock target: `<queueRoot>/.claim` (withFileLock
    /// flocks its `.lock` sibling). EVERY claim — drain pass or explicit
    /// start, any process — serializes on this ONE cross-process flock, so
    /// the running-count scan and the queued→running write are atomic
    /// ACROSS Workshop executions, not just within one Workshop execution dir.
    nonisolated var queueClaimLockTarget: URL {
        executionRecordsRoot.appendingPathComponent(".claim")
    }

    /// The queue lock makes the running-count scan and status claim atomic
    /// across executions. Lock order is queue then execution; refusal returns nil.
    func claim(_ executionId: String, from status: String = "queued", stepId: String? = nil) async throws -> WorkshopExecutionRecord? {
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(executionId) else { return nil }
        // The queue root may not exist yet on a fresh data root; the
        // lock-file open needs its parent directory.
        try? FileManager.default.createDirectory(
            at: executionRecordsRoot, withIntermediateDirectories: true)
        return try await SwiftNativePersistenceCore.withFileLock(queueClaimLockTarget) {
            try await self.claimUnderQueueLock(executionId, from: status, stepId: stepId)
        }
    }

    /// The scan + per-Workshop execution RMW half of claim(). MUST only be called while
    /// holding the queue-level claim flock.
    private func claimUnderQueueLock(_ executionId: String, from status: String, stepId: String?) async throws -> WorkshopExecutionRecord? {
        if try await cancelWithDesk(executionId, from: [status]) { return nil }
        guard await executionAllowed() else {
            throw WorkshopExecutionError.forbidden("Workshop execution is disabled by trust policy")
        }
        let executionRecordJSON = executionRecordPath(executionId)
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let update = try await ExecutionRecordFile.update(at: executionRecordJSON, id: executionId) { [self] record in
            guard record.status == status else { return false }
            if let stepId, record.currentStepId != stepId { return false }
            // The enclosing queue lock serializes claimers; count under the record lock.
            let queue = try await self.scanQueue()
            let runningCount = queue.filter { $0.status == "running" && $0.id != executionId }.count
            guard runningCount < self.maxActive else { return false }
            record.status = "running"
            if let stepId { record.currentStepId = stepId }
            record.updatedAt = nowStr
            record.lastMovementAt = nowStr
            return true
        }
        return update.applied ? update.record : nil
    }
}
