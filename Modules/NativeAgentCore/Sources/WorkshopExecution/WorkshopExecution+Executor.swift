import Foundation
import NativeAgentShared
import os
import PersistenceCore
import NativeAgentCore
import Desk
import TrustCenter
// Blueprint: | `WorkshopExecution+Executor.swift` | `WorkshopExecutorLoop` actor, configuration, canonical Desk cancellation, outcome settlement and execution record/timeline/receipt I/O through ExecutionRecordFile |

// Claims, step outcomes and terminal records share the execution file lock.
// Injected dispatch runs with a cancellation observer; all children settle before return.

public actor WorkshopExecutorLoop {
    let root: URL
    let measuredTooledLLMStep: WorkshopStepMeasuredLLM?
    let toolDispatch: WorkshopStepToolDispatch?
    let stageApproval: WorkshopStepApprovalStager?
    let isEnabled: @Sendable () async -> Bool
    let maxActive: Int
    /// Per-step HARD deadline in nanoseconds (0 = disabled). A wedged tool with
    /// no internal timeout would otherwise hang an UNATTENDED step forever;
    /// this auto-fails it. See raceWithCancellationWatch.
    let stepTimeoutNanos: UInt64
    /// Approval-wait deadline in nanoseconds (0 = disabled, the DEFAULT). A
    /// Workshop execution `blocked_on_approval` with no human to approve it freezes
    /// forever — the exact unattended-job stall this leg exists to kill. When
    /// set (env `NATIVE_AGENT_EXECUTION_APPROVAL_TIMEOUT_SECONDS`), drainOnce
    /// auto-fails a blocked Workshop execution whose block has outlived the deadline. OFF
    /// by default on purpose: for INTERACTIVE use a pending approval is correct
    /// behaviour (the user will click it later), not a stall — only headless/
    /// unattended runs want it, so they opt in. See reconcileTimedOutApprovals.
    let approvalTimeoutNanos: UInt64
    /// Whether the per-step autonomy approval gate is enforced (default true).
    /// Wired false under wide-open trust (full-mac yolo) so
    /// Workshop execution approval-only posture runs unattended. This includes
    /// explicit trustRequired: it is an ask/confirm policy request, not a hard
    /// domain block, and an admitted Full Mac grant has already answered it.
    let stepApprovalEnforced: @Sendable () async -> Bool
    private let terminalEventSink: WorkshopTerminalEventSink?
    let now: @Sendable () -> Date
    let approvedToolDispatch: WorkshopStepApprovedToolDispatch?
    /// Every executor on a root shares this admission barrier. Failed recovery
    /// remains retryable; no process-local claim can land until all prior
    /// running records have settled, so retries cannot reclaim our own work.
    static let orphanReclaimOnce = OnceByKey<String>()
    static let logger = ModuleLog(subsystem: "com.nativeagent.workshop", category: "executor")

    /// Claims recheck the concurrent-running cap under the queue lock.
    /// Step deadlines default to 1500 seconds; nonpositive values disable them.
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        measuredTooledLLMStep: WorkshopStepMeasuredLLM? = nil,
        toolDispatch: WorkshopStepToolDispatch? = nil,
        approvedToolDispatch: WorkshopStepApprovedToolDispatch? = nil,
        stageApproval: WorkshopStepApprovalStager? = nil,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        maxActive: Int? = nil,
        stepTimeoutInterval: TimeInterval? = nil,
        approvalTimeoutInterval: TimeInterval? = nil,
        stepApprovalEnforced: @escaping @Sendable () async -> Bool = { true },
        terminalEventSink: WorkshopTerminalEventSink? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.measuredTooledLLMStep = measuredTooledLLMStep
        self.toolDispatch = toolDispatch
        self.stageApproval = stageApproval
        self.isEnabled = isEnabled
        self.maxActive = maxActive ?? Self.defaultMaxActive()
        // Finite positive deadlines stay below the drain timeout with settlement
        // margin; nonpositive/nonfinite values disable the overflow-safe timer.
        let rawTimeoutSecs = stepTimeoutInterval ?? Self.defaultStepTimeoutSeconds()
        let cap = Self.drainPassTimeoutSeconds - 60   // margin for terminal CAS/timeline writes
        let safeTimeoutSecs = (rawTimeoutSecs.isFinite && rawTimeoutSecs > 0)
            ? min(rawTimeoutSecs, cap) : 0
        self.stepTimeoutNanos = UInt64(safeTimeoutSecs * 1_000_000_000)
        // Approval-wait deadline: same clamp shape as the step deadline so a
        // non-finite / pathological env value can't TRAP the UInt64 conversion.
        // Non-finite / <=0 → 0 (disabled, the default). Cap at 7 days — a
        // generous "nobody is coming" horizon; the conversion is overflow-proof
        // below that cap.
        let rawApprovalSecs = approvalTimeoutInterval ?? Self.defaultApprovalTimeoutSeconds()
        let approvalCap: TimeInterval = 7 * 24 * 3600
        let safeApprovalSecs = (rawApprovalSecs.isFinite && rawApprovalSecs > 0)
            ? min(rawApprovalSecs, approvalCap) : 0
        self.approvalTimeoutNanos = UInt64(safeApprovalSecs * 1_000_000_000)
        self.approvedToolDispatch = approvedToolDispatch
        self.stepApprovalEnforced = stepApprovalEnforced
        self.terminalEventSink = terminalEventSink
        self.now = now
    }

    /// Shared active capacity; NATIVE_AGENT_MAX_ACTIVE_MISSIONS retains precedence over NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS.
    static func defaultMaxActive() -> Int {
        let raw = ExecutionEnvVocabulary.value(canonical: "NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS")
        return max(1, Int(raw ?? "") ?? 3)
    }

    /// Default per-step hard deadline in SECONDS. Reads
    /// `NATIVE_AGENT_EXECUTION_STEP_TIMEOUT_SECONDS` (>=0) if set — or the
    /// deprecated `NATIVE_AGENT_MISSION_STEP_TIMEOUT_SECONDS`, which wins when
    /// both are set — else 1500s.
    /// Stays below the WorkshopExecutorDrainRunner pass-timeout (1800s,
    /// BackgroundLoopsAssembly) so a genuinely wedged step records a clean
    /// timeout failure instead of repeatedly releasing the pass claim.
    /// 1500s is still generous for any single step (LLM/tool/invoke_* default
    /// 600s) — a backstop against a wedged tool, not a per-step budget. Tune
    /// DOWN via the env var for faster unattended recovery; keep it < 1800s.
    static func defaultStepTimeoutSeconds() -> TimeInterval {
        if let raw = ExecutionEnvVocabulary.value(
            canonical: "NATIVE_AGENT_EXECUTION_STEP_TIMEOUT_SECONDS"
        ), let v = TimeInterval(raw) {
            return max(0, v)
        }
        return 1500
    }

    /// Default approval-wait deadline in SECONDS. Reads
    /// `NATIVE_AGENT_EXECUTION_APPROVAL_TIMEOUT_SECONDS` (>=0) if set — or the
    /// deprecated `NATIVE_AGENT_MISSION_APPROVAL_TIMEOUT_SECONDS`, which wins
    /// when both are set — else 0
    /// (DISABLED). Off by default: an interactive Workshop execution waiting on the user to
    /// click an approval is correct behaviour, not a stall, so auto-failing it
    /// would destroy legitimate pending work. Headless/unattended runs that
    /// genuinely have no human set the env var (e.g. 21600 = 6h) to opt in.
    static func defaultApprovalTimeoutSeconds() -> TimeInterval {
        if let raw = ExecutionEnvVocabulary.value(
            canonical: "NATIVE_AGENT_EXECUTION_APPROVAL_TIMEOUT_SECONDS"
        ), let v = TimeInterval(raw) {
            return max(0, v)
        }
        return 0
    }

    /// MUST match `WorkshopExecutorDrainRunner.tickTimeoutOverride` (the
    /// LoopRunner that ticks drainOnce). A pass cancellation releases its
    /// live claim back to queued in-process; this constant still bounds a whole
    /// unattended drain pass and caps the cleaner per-step timeout below it.
    static let drainPassTimeoutSeconds: TimeInterval = 1800

    // MARK: paths

    nonisolated var executionRecordsRoot: URL {
        root.appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
    }
    nonisolated func workshopExecutionDir(_ id: String) -> URL {
        executionRecordsRoot.appendingPathComponent(id, isDirectory: true)
    }
    /// Resolved record path — see `SwiftNativeWorkshopRunner.executionRecordPath`.
    nonisolated func executionRecordPath(_ id: String) -> URL {
        ExecutionRecordFile.canonicalPath(in: workshopExecutionDir(id))
    }
    nonisolated func timelinePath(_ id: String) -> URL {
        ExecutionRecordFile.timelinePath(in: workshopExecutionDir(id))
    }

    nonisolated func receiptsDir(_ id: String) -> URL {
        ExecutionRecordFile.receiptsPath(in: workshopExecutionDir(id))
    }

    func deskCanceled(_ record: WorkshopExecutionRecord) async throws -> Bool {
        guard let handle = record.deskHandle else { return false }
        let store = SwiftNativeDeskStore(dataRoot: root)
        if let item = try await store.liveState().items.first(where: { $0.handle == handle }) {
            return item.status == .canceled
        }
        return try await store.archivedRecords().contains { $0.handle == handle && $0.finalStatus == .canceled }
    }

    /// Called at admission or after the in-flight outcome has been saved.
    /// The Desk record is canonical; no second cancellation flag is needed.
    func cancelWithDesk(_ executionId: String, from statuses: Set<String> = ["running"]) async throws -> Bool {
        let saved: Result<Bool, Error> = await settle {
            do { return .success(try await self.recordDeskCancellation(executionId, from: statuses)) }
            catch { return .failure(error) }
        }
        return try saved.get()
    }

    private func recordDeskCancellation(_ executionId: String, from statuses: Set<String> = ["running"]) async throws -> Bool {
        let stamp = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let update = try await ExecutionRecordFile.update(at: executionRecordPath(executionId), id: executionId) { record in
            guard statuses.contains(record.status),
                  try await self.deskCanceled(record) else { return false }
            record.status = "cancelled"
            record.terminalReason = "desk_item_canceled"
            record.currentStepId = ""
            if case .object(let last)? = record.stepsCompleted.last, let output = last["output"] {
                record.result = output
            }
            record.updatedAt = stamp
            record.lastMovementAt = stamp
            return true
        }
        if update.applied {
            try await appendTimelineLocked(.object([
                "event": .string("cancelled"), "reason": .string("desk_item_canceled"), "ts": .string(stamp),
            ]), executionId: executionId)
            await emitTerminalEvent(update.record, reason: "desk_item_canceled")
        }
        return update.record?.status == "cancelled"
    }

    /// Normal and approved steps share one uncancelled outcome commit. A
    /// canceled execution keeps its verdict and accepts the output it produced.
    func commitStepOutcome(_ executionId: String, outcome: WorkshopStepOutcome,
                                   approvedStep: WorkshopExecutionStep? = nil) async throws -> WorkshopExecutionRecord? {
        let saved: Result<WorkshopExecutionRecord?, Error> = await settle {
            do { return .success(try await self.saveStepOutcome(executionId, outcome: outcome, approvedStep: approvedStep)) }
            catch { return .failure(error) }
        }
        return try saved.get()
    }

    private func saveStepOutcome(_ executionId: String, outcome: WorkshopStepOutcome,
                                 approvedStep: WorkshopExecutionStep?) async throws -> WorkshopExecutionRecord? {
        let update = try await casMutateWorkshopExecution(executionId, require: ["running", "cancelled"]) { record in
            if let approvedStep, let index = record.plan.firstIndex(where: { $0.id == approvedStep.id }) {
                record.plan[index].args = approvedStep.args
            }
            if let index = record.stepsCompleted.firstIndex(where: {
                guard case .object(let fields) = $0 else { return false }
                return fields["step_id"] == .string(outcome.stepId)
            }), case .object(var fields) = record.stepsCompleted[index], case .object(let result) = outcome.toJSON() {
                fields.merge(result) { _, new in new }
                record.stepsCompleted[index] = .object(fields)
            } else {
                record.stepsCompleted.append(outcome.toJSON())
            }
            if record.status == "cancelled" { record.result = outcome.output }
        }
        guard update.applied else { return nil }
        await writeReceipt(executionId: executionId, outcome: outcome)
        if update.record?.status == "cancelled" {
            await emitTerminalEvent(update.record, reason: update.record?.terminalReason)
            return try await getRecord(executionId)
        }
        if try await recordDeskCancellation(executionId) { return try await getRecord(executionId) }
        let transition = try await casMutateWorkshopExecution(executionId, require: ["running"]) { record in
            switch outcome.status {
            case "failed", "cancelled", "blocked_on_reconciliation":
                record.status = outcome.status
                record.terminalReason = outcome.error.isEmpty ? nil : outcome.error
                if outcome.status == "blocked_on_reconciliation" { record.result = outcome.output }
                else { record.currentStepId = "" }
            case "blocked_on_approval": record.status = outcome.status
            default: record.currentStepId = ""
            }
        }
        guard transition.applied else { return try await getRecord(executionId) }
        let stamp = SwiftNativeWorkshopRunner.isoTimestamp(now())
        if approvedStep == nil, !["blocked_on_approval", "cancelled", "blocked_on_reconciliation"].contains(outcome.status) {
            try await appendTimelineLocked(.object([
                "event": .string("step_completed"), "step_id": .string(outcome.stepId),
                "status": .string(outcome.status), "ts": .string(stamp),
            ]), executionId: executionId)
        }
        if outcome.status == "failed" {
            try await appendTimelineLocked(.object([
                "event": .string("failed"), "step_id": .string(outcome.stepId),
                "error": .string(outcome.error), "ts": .string(stamp),
            ]), executionId: executionId)
        } else if outcome.status == "blocked_on_approval", approvedStep == nil,
                  let step = transition.record?.plan.first(where: { $0.id == outcome.stepId }) {
            try? await appendTimelineLocked(.object([
                "event": .string("step_blocked_on_approval"), "step_id": .string(step.id),
                "tool": .string(step.toolOrAction), "autonomy": .string(step.autonomy),
                "approval_id": .string(outcome.approvalId), "ts": .string(stamp),
            ]), executionId: executionId)
        }
        await emitTerminalEvent(transition.record, reason: transition.record?.terminalReason)
        return try await getRecord(executionId)
    }

    func executionAllowed() async -> Bool {
        guard await isEnabled(),
              let policy = try? await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicyChecked() else {
            return false
        }
        return SwiftNativeWorkshopRunner.workshopPolicyAllows(policy)
    }

    func getRecord(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(executionId) else { return nil }
        let record = try await ExecutionRecordFile.read(at: executionRecordPath(executionId)).record
        return record?.id == executionId ? record : nil
    }

    func emitTerminalEvent(_ record: WorkshopExecutionRecord?, reason: String?) async {
        guard let record, ["completed", "failed", "cancelled"].contains(record.status) else { return }
        await terminalEventSink?(record, record.terminalReason ?? reason)
    }

    func scanQueue() async throws -> [WorkshopExecutionRecord] {
        try await SwiftNativeWorkshopRunner.readQueueRecords(dataRoot: root).map { id, _, record in
            guard !["corrupt", "unavailable"].contains(record.status) else {
                throw WorkshopExecutionError.persistenceFailure("Workshop queue record \(id) is unreadable or malformed; restore its saved execution record before admitting work")
            }
            return record
        }
    }

    /// Read, status-check and mutation share the execution file lock. Only an
    /// applied write permits dependent receipts; a concurrent transition wins.
    @discardableResult
    func casMutateWorkshopExecution(
        _ executionId: String,
        require allowedStatuses: Set<String>,
        matching predicate: (@Sendable (WorkshopExecutionRecord) -> Bool)? = nil,
        _ mutate: @escaping @Sendable (inout WorkshopExecutionRecord) -> Void
    ) async throws -> (record: WorkshopExecutionRecord?, applied: Bool) {
        guard SwiftNativeWorkshopRunner.isSafeExecutionID(executionId) else {
            return (nil, false)
        }
        let executionRecordJSON = executionRecordPath(executionId)
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        do {
            return try await ExecutionRecordFile.update(at: executionRecordJSON, id: executionId) { record in
                guard allowedStatuses.contains(record.status), predicate?(record) != false else { return false }
                mutate(&record)
                record.updatedAt = nowStr
                record.lastMovementAt = nowStr
                return true
            }
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("executor execution.json write failed: \(error)")
        }
    }

    func appendTimelineLocked(_ event: JSONValue, executionId: String) async throws {
        try await ExecutionRecordFile.appendTimeline(event, to: timelinePath(executionId))
    }

    /// Planner-derived receipt names allow only [A-Za-z0-9._-], capped at 180
    /// characters before the .json suffix; empty IDs are rejected.
    static func sanitizedPathComponent(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let mapped = String(String.UnicodeScalarView(
            raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return String(mapped.prefix(180))
    }

    /// WorkshopStepOutcome JSON output artifacts, exposed by the overview's
    /// receipt-directory location; steps_completed remains durable truth.
    /// Local backup/export include workshop/; no raw phone sync; PrivacyMap
    /// lists Workshop. Writes are best effort, with planner-derived step IDs
    /// sanitized to a single filename inside the receipt directory.
    private func writeReceipt(executionId: String, outcome: WorkshopStepOutcome) async {
        guard outcome.status != "blocked_on_approval" else { return }  // not executed
        guard let safeStepId = Self.sanitizedPathComponent(outcome.stepId) else {
            Self.logger("receipt skipped for \(executionId): empty step id", level: .info)
            return
        }
        let dir = receiptsDir(executionId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(safeStepId).json")
        do {
            try await SwiftNativePersistenceCore.writeJSON(outcome.toJSON(), to: path)
        } catch {
            Self.logger("receipt write failed for \(executionId)/\(outcome.stepId): \(String(describing: error))", level: .info)
        }
    }

}
