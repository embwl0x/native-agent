import Foundation
import os
import PersistenceCore
import NativeAgentCore

// MISSIONS EXECUTOR PORT (2026-06-10) — docs/build_plans/missions-executor-port.md
//
// Port of the daemon executor loop (the retired daemon::MissionRunner,
// _run_mission_locked ~L792 + execute_step ~L1029 + _dispatch_step ~L1125 +
// _resume_after_approval_locked ~L1461, at git rev dc79938^) to Swift.
//
// SEMANTICS PORTED (timeline-event parity is pinned by the fixture-replay
// tests against archived daemon-era timelines from the pre-Workshop queue):
//   claim (queued→running, re-checked INSIDE the cross-process flock — closes
//   the W6 check-then-act race) → `started` timeline event → iterate plan
//   steps (current_step_id tracking + per-step receipts into receiptsDir +
//   `step_completed` events) → terminal status (completed/failed/
//   blocked_on_approval/cancelled) + result summary extracted from the last
//   step output.
//
// V1 REDUCED STEP VOCABULARY (build-plan decision, 2026-06-10):
//   - "chat.synthesize" / "llm" / "report" → injected LLM closure. Prior-step
//     outputs are injected into the prompt exactly like the daemon's
//     calibrate-6 anti-confabulation block, which is what made the daemon's
//     final "report" step synthesize from receipts rather than thin air.
//   - any other non-empty tool id → injected tool-dispatch closure.
//   - empty tool id, or a step kind the injected closures can't serve →
//     the step FAILS HONESTLY (W6 lesson: never silent no-op).
//
// MODULE PURITY: this module stays ApprovalInbox/ChatOrchestration-free.
// LLM, tool dispatch, approval staging, and the enable-gate are all INJECTED
// closures (mirrors REMCycleLoop / WeeklySelfImprovementLoop; the production
// wiring lives in BackgroundLoopsAssembly.makeMissionExecutor*).
//
// CONCURRENCY / CANCELLATION (W2 lesson: no orphaned children):
//   - cooperative Task.checkCancellation between steps;
//   - each step dispatch runs inside a throwing task group racing a
//     cancellation observer over mission.json — when cancel() (this process or
//     any other) flips status to "cancelled", the kqueue/vnode edge wakes the
//     observer and the in-flight step
//     Task is cancelled via group.cancelAll(). Structured concurrency
//     guarantees both children are awaited/cancelled before the group
//     returns, which is the same guarantee withTaskCancellationHandler-based
//     shapes are after.

// MARK: - Injected closure types

/// One staged Workshop execution-step approval. The app layer turns this into an
/// ApprovalInbox record + a notifications/inbox.jsonl card whose id equals
/// the approval id (mirror of the REM stager contract).
public struct WorkshopStepApprovalRequest: Sendable, Equatable {
    public var executionId: String
    public var stepId: String
    public var title: String
    public var tool: String
    public var reason: String
    public var args: JSONValue

    public init(executionId: String, stepId: String, title: String, tool: String, reason: String, args: JSONValue) {
        self.executionId = executionId
        self.stepId = stepId
        self.title = title
        self.tool = tool
        self.reason = reason
        self.args = args
    }
}

/// Stage an approval; return the approval id, or nil when staging failed
/// (the step then FAILS honestly — a Workshop execution must never block on an approval
/// that was never filed).
public typealias WorkshopStepApprovalStager = @Sendable (WorkshopStepApprovalRequest) async -> String?

/// LLM completion for "llm"/"report"/chat.synthesize steps. Returns
/// (model, text) — the daemon's run_codex(prompt, timeout=120) pair.
///
/// NOTE (synthesize-quality fix, 2026-06-11): a BARE completion via this
/// closure has NO tool access — the model cannot read the files / memory the
/// synthesize step is supposed to summarize, so it tends to refuse ("I can't
/// access your filesystem"). Prefer the tool-capable closure below; this
/// stays as the honest fallback (with a `synthesize_untooled` timeline note).
public typealias WorkshopStepLLM = @Sendable (_ prompt: String) async throws -> (model: String, text: String)

/// TOOL-CAPABLE synthesize turn (synthesize-quality fix, 2026-06-11). Same
/// (model, text) return as the bare closure, but the prompt is run through a
/// tool loop wired (in BackgroundLoopsAssembly) to a RESTRICTED, READ-ONLY
/// tool set — read_file / list_dir / search_chat_history / recall_memory and
/// their read aliases ONLY; no shell, no write tools, no workshop_submit
/// (recursion). The autonomy gate still governs the dispatched tools. When
/// this is wired the executor routes synthesize steps here instead of the
/// bare `llmStep`, so the model can actually fetch what it's asked to
/// synthesize rather than refusing for lack of access.
public typealias WorkshopStepTooledLLM = @Sendable (_ prompt: String) async throws -> (model: String, text: String)

/// Exact accounting returned by production Workshop-owned model seams. The
/// removable count is narrower than the provider count: synthesis still
/// needs cognition after a procedure is compiled, while orchestration/planning
/// may disappear. Legacy tuple closures remain supported but cannot fabricate
/// these facts.
public struct WorkshopStepLLMCompletion: Sendable, Equatable {
    public let model: String
    public let text: String
    public let providerCallCount: Int
    public let removableOrchestrationProviderCallCount: Int

    public init(
        model: String,
        text: String,
        providerCallCount: Int,
        removableOrchestrationProviderCallCount: Int = 0
    ) {
        self.model = model
        self.text = text
        self.providerCallCount = providerCallCount
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
    }
}

public typealias WorkshopStepMeasuredLLM = @Sendable (_ prompt: String) async throws -> WorkshopStepLLMCompletion

/// Tool dispatch for non-LLM steps. `args` is the step's flat JSON object.
/// Throw to fail the step; unknown tools MUST throw (honest failure), never
/// return a fabricated success.
public typealias WorkshopStepToolDispatch = @Sendable (_ tool: String, _ args: JSONValue) async throws -> JSONValue

/// Emitted only after a terminal Workshop execution CAS wins. App assembly can observe
/// completed/failed/cancelled outcomes without WorkshopExecution importing
/// app-side cognition or notification surfaces.
public typealias WorkshopTerminalEventSink = @Sendable (_ record: WorkshopExecutionRecord, _ reason: String?) async -> Void

// MARK: - Step outcome

/// Mirror of the daemon @dataclass StepResult.
/// Serialized into mission.json `steps_completed` with the same snake_case
/// keys as Python's asdict(StepResult).
public struct WorkshopStepOutcome: Sendable, Equatable {
    public var stepId: String
    public var status: String        // "succeeded"|"failed"|"blocked_on_approval"|"rejected"|"cancelled"
    public var output: JSONValue     // .object — daemon default {}
    public var error: String
    public var approvalId: String
    public var executedAt: String
    /// Direct provider calls owned by this Workshop step. Nil means the
    /// injected/legacy seam did not prove an exact count.
    public var providerCallCount: Int?
    /// Subset of providerCallCount proven removable by declarative procedure
    /// compilation. Nil follows unknown provider accounting.
    public var removableOrchestrationProviderCallCount: Int?

    public init(
        stepId: String,
        status: String,
        output: JSONValue = .object([:]),
        error: String = "",
        approvalId: String = "",
        executedAt: String,
        providerCallCount: Int? = nil,
        removableOrchestrationProviderCallCount: Int? = nil
    ) {
        self.stepId = stepId
        self.status = status
        self.output = output
        self.error = error
        self.approvalId = approvalId
        self.executedAt = executedAt
        self.providerCallCount = providerCallCount
        self.removableOrchestrationProviderCallCount = removableOrchestrationProviderCallCount
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "step_id": .string(stepId),
            "status": .string(status),
            "output": output,
            "error": .string(error),
            "approval_id": .string(approvalId),
            "executed_at": .string(executedAt),
        ]
        if let providerCallCount {
            object["provider_call_count"] = .int(Int64(providerCallCount))
        }
        if let removableOrchestrationProviderCallCount {
            object["removable_orchestration_provider_call_count"] =
                .int(Int64(removableOrchestrationProviderCallCount))
        }
        return .object(object)
    }
}

// MARK: - Executor

public actor WorkshopExecutorLoop {
    private let root: URL
    private let persistence: any PersistenceCoreProtocol
    private let llmStep: WorkshopStepLLM?
    private let tooledLLMStep: WorkshopStepTooledLLM?
    private let measuredLLMStep: WorkshopStepMeasuredLLM?
    private let measuredTooledLLMStep: WorkshopStepMeasuredLLM?
    private let toolDispatch: WorkshopStepToolDispatch?
    private let stageApproval: WorkshopStepApprovalStager?
    private let isEnabled: @Sendable () async -> Bool
    private let maxActive: Int
    private let cancellationReadObserver: (@Sendable () -> Void)?
    /// Per-step HARD deadline in nanoseconds (0 = disabled). A wedged tool with
    /// no internal timeout would otherwise hang an UNATTENDED step forever;
    /// this auto-fails it. See raceWithCancellationWatch.
    private let stepTimeoutNanos: UInt64
    /// Approval-wait deadline in nanoseconds (0 = disabled, the DEFAULT). A
    /// Workshop execution `blocked_on_approval` with no human to approve it freezes
    /// forever — the exact unattended-job stall this leg exists to kill. When
    /// set (env `NATIVE_AGENT_EXECUTION_APPROVAL_TIMEOUT_SECONDS`), drainOnce
    /// auto-fails a blocked Workshop execution whose block has outlived the deadline. OFF
    /// by default on purpose: for INTERACTIVE use a pending approval is correct
    /// behaviour (the user will click it later), not a stall — only headless/
    /// unattended runs want it, so they opt in. See reconcileTimedOutApprovals.
    private let approvalTimeoutNanos: UInt64
    /// Whether the per-STEP autonomy approval gate is enforced (default true =
    /// prior behavior). Wired FALSE under wide-open trust (full-mac yolo) so
    /// Workshop execution tool steps the planner marked `needs_approval` run UNATTENDED —
    /// the "she does everything" posture. An EXPLICIT per-Workshop execution
    /// trustRequired != "none" still gates regardless (a Workshop execution deliberately
    /// asking for approval is honored even under yolo).
    private let stepApprovalEnforced: @Sendable () async -> Bool
    private let terminalEventSink: WorkshopTerminalEventSink?
    /// Resolves the execution→memory recorder LAZILY, on the first terminal event.
    /// Lazy because the production writer touches `SwiftNativeMemoryV2.shared`,
    /// which opens the SQLite store on first access — constructing an executor
    /// must not have that side effect. See `defaultExecutionMemoryProvider`.
    private let executionMemoryProvider: @Sendable () -> WorkshopExecutionMemoryRecorder?
    /// The write queue, built on first terminal event from the resolved
    /// recorder. Terminal transitions HAND OFF to this and return; they never
    /// wait on the memory store. See ``WorkshopExecutionMemoryQueue``.
    private var executionMemoryQueue: WorkshopExecutionMemoryQueue?
    private let now: @Sendable () -> Date
    /// One-shot startup orphan-reclaim, memoized as a Task so EVERY fresh-claim
    /// path (drainOnce, start, resumeAfterApproval) awaits the SAME reclaim to
    /// COMPLETION before it claims/flips anything. This is the barrier that
    /// makes "a `running` execution seen at reclaim time is necessarily a dead
    /// prior instance's orphan" actually true: no claim by THIS process can
    /// land before the reclaim finishes (gpt-5.5 review: a bare bool let
    /// start() claim a live execution that the first drain then wrongly failed).
    ///
    /// PROCESS-WIDE (per data-root), NOT per-instance (gpt-5.5 re-review): the
    /// app may build MORE THAN ONE executor instance on the same root — the
    /// background drain (WorkshopExecutorRef.shared) AND a cold-start fallback in
    /// applyResolvedWorkshopStep when the ref isn't configured yet. Per-instance
    /// memoization gave each its OWN once-guard, so a fallback resume instance
    /// could flip an execution blocked→running and the drain instance's first
    /// reclaim would then fail it as a crash orphan. Keying the barrier on
    /// `root.path` makes both instances share ONE reclaim: it runs exactly once
    /// per process per root, before any claim by any instance. Unique temp roots
    /// keep test isolation; production's single root shares one barrier.
    ///
    /// fix-reconcile-memo-leak (2026-08-02): this used to be a hand-locked
    /// `[String: Task]` with an insert and NO removal — every unique data root
    /// permanently retained its reclaim `Task`, and a Task retains its closure
    /// context, i.e. the executor instance that created it. `OnceByKey` keeps
    /// the identical once-per-process-per-root guarantee but drops the Task
    /// (and its captures) the moment the run completes, keeping only a
    /// completion marker — plus a `reset()` seam so a temp-root-per-test suite
    /// stops growing the table for the life of the test process.
    static let orphanReclaimOnce = OnceByKey<String>(name: "workshop-orphan-reclaim")
    private static let logger = Logger(subsystem: "com.nativeagent.workshop", category: "executor")

    /// - Parameters:
    ///   - maxActive: concurrent-running cap, re-checked INSIDE the claim
    ///     lock. Defaults to the daemon's slot-gate constant
    ///     (`NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS`, default 3).
    ///   - cancellationPollInterval: compatibility-only legacy label. The
    ///     executor no longer polls; cancellation is driven by canonical-file
    ///     change edges. The value is intentionally ignored.
    ///   - cancellationReadObserver: test/diagnostic seam invoked only when an
    ///     initial or real file-change edge causes a canonical status read.
    ///   - stepTimeoutInterval: HARD per-step deadline (seconds). nil →
    ///     `defaultStepTimeoutSeconds()` (env override, else 1500s backstop,
    ///     below the 1800s drain pass-timeout); <= 0 disables it. Backstop
    ///     against a wedged tool in an unattended execution — generous by design
    ///     so it never preempts a tool with its own (shorter) timeout.
    public init(
        root: URL = PersistenceCore.defaultDataRoot(),
        persistence: (any PersistenceCoreProtocol)? = nil,
        llmStep: WorkshopStepLLM? = nil,
        tooledLLMStep: WorkshopStepTooledLLM? = nil,
        measuredLLMStep: WorkshopStepMeasuredLLM? = nil,
        measuredTooledLLMStep: WorkshopStepMeasuredLLM? = nil,
        toolDispatch: WorkshopStepToolDispatch? = nil,
        stageApproval: WorkshopStepApprovalStager? = nil,
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        maxActive: Int? = nil,
        cancellationPollInterval: TimeInterval = 0.25,
        cancellationReadObserver: (@Sendable () -> Void)? = nil,
        stepTimeoutInterval: TimeInterval? = nil,
        approvalTimeoutInterval: TimeInterval? = nil,
        stepApprovalEnforced: @escaping @Sendable () async -> Bool = { true },
        terminalEventSink: WorkshopTerminalEventSink? = nil,
        executionMemory: WorkshopExecutionMemoryRecorder? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.persistence = persistence ?? SwiftNativePersistenceCore()
        self.llmStep = llmStep
        self.tooledLLMStep = tooledLLMStep
        self.measuredLLMStep = measuredLLMStep
        self.measuredTooledLLMStep = measuredTooledLLMStep
        self.toolDispatch = toolDispatch
        self.stageApproval = stageApproval
        self.isEnabled = isEnabled
        self.maxActive = maxActive ?? Self.defaultMaxActive()
        _ = cancellationPollInterval
        self.cancellationReadObserver = cancellationReadObserver
        // Clamp before the nanos conversion: a pathological / non-finite
        // stepTimeoutInterval (or env value) would otherwise TRAP UInt64(_:)
        // (gpt-5.5 review). Non-finite or <=0 → disabled; cap at 24h, well
        // above the 1h default + the invoke_* tools' own <=1h timeouts.
        // Clamp below the drain pass-timeout so the clean per-step failure
        // fires before the pass releases and retries its claim, regardless of
        // env/param — including an existing
        // NATIVE_AGENT_EXECUTION_STEP_TIMEOUT_SECONDS=3600 (gpt-5.5 review). Real
        // max runtime is already bounded by the pass timeout, so this costs no
        // capability. Non-finite / <=0 → disabled (no deadline task). The cap
        // also makes the UInt64 conversion overflow-proof.
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
        self.stepApprovalEnforced = stepApprovalEnforced
        self.terminalEventSink = terminalEventSink
        self.executionMemoryProvider = Self.executionMemoryProvider(
            injected: executionMemory,
            root: root
        )
        self.now = now
    }

    /// Execution→memory wiring rule, in one place.
    ///
    /// An INJECTED recorder always wins (tests, and any future caller that wants
    /// a different store). Otherwise the default writer is used ONLY when this
    /// executor is running against the process's default data root — the same
    /// root `SwiftNativeMemoryV2.shared` is rooted at. An executor on a temp root
    /// (every test, every fixture) gets no recorder rather than silently writing
    /// fixture executions into User's real memory store.
    ///
    /// This is why the plug needs no app-assembly wiring: production builds its
    /// executor on the default root, so it is on by default, in-module, and any
    /// future executor construction inherits it.
    private static func executionMemoryProvider(
        injected: WorkshopExecutionMemoryRecorder?,
        root: URL
    ) -> @Sendable () -> WorkshopExecutionMemoryRecorder? {
        if let injected {
            return { injected }
        }
        guard root.standardizedFileURL.path
            == PersistenceCore.defaultDataRoot().standardizedFileURL.path else {
            return { nil }
        }
        return {
            WorkshopExecutionMemoryRecorder(
                writer: SwiftNativeWorkshopExecutionMemoryWriter(),
                log: { level, message in
                    // A failed write must be findable (gpt-5.5 review A1): the
                    // whole sink used to go through `.info`, which is exactly
                    // where a "she can't remember this execution" line goes to
                    // die at default log level.
                    switch level {
                    case .error: Self.logger.error("\(message, privacy: .public)")
                    case .info: Self.logger.info("\(message, privacy: .public)")
                    }
                }
            )
        }
    }

    /// `NATIVE_AGENT_MAX_ACTIVE_EXECUTIONS` (P2-5), or the deprecated
    /// `NATIVE_AGENT_MAX_ACTIVE_MISSIONS`, which still WINS when both are set —
    /// the SAME env var
    /// `SwiftNativeWorkshopRunner.effectiveWorkshopExecutionSlotsCap()` mirrors.
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
    /// LoopRunner that ticks drainOnce). A pass cancellation now releases its
    /// live claim back to queued in-process; this constant still bounds a whole
    /// unattended drain pass and caps the cleaner per-step timeout below it.
    static let drainPassTimeoutSeconds: TimeInterval = 1800

    // MARK: paths (parity with SwiftNativeWorkshopRunner / the retired daemon+)

    nonisolated var executionRecordsRoot: URL {
        root.appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("executions", isDirectory: true)
    }
    nonisolated func workshopExecutionDir(_ id: String) -> URL {
        executionRecordsRoot.appendingPathComponent(id, isDirectory: true)
    }
    /// Resolved record path — see `SwiftNativeWorkshopRunner.executionRecordPath`.
    nonisolated func executionRecordPath(_ id: String) -> URL {
        ExecutionRecordFile.resolve(in: workshopExecutionDir(id))
    }
    nonisolated func timelinePath(_ id: String) -> URL {
        workshopExecutionDir(id).appendingPathComponent("timeline.jsonl")
    }
    nonisolated func receiptsDir(_ id: String) -> URL {
        workshopExecutionDir(id).appendingPathComponent("receipts", isDirectory: true)
    }

    // MARK: drain

    /// One drain pass: claim + run queued Workshop executions, oldest first, one at a
    /// time. Per-Workshop execution failures are contained (logged + that Workshop execution goes
    /// `failed`); the pass moves on. Safe to call from a LoopRunner tick.
    public func drainOnce() async {
        // Crash/restart orphan recovery — completes BEFORE this drain claims
        // anything (the shared barrier; see reconcileTask).
        await ensureOrphansReconciled()
        // Terminal execution state is canonical; its Desk projection and
        // unified receipt are retryable derived settlement. Reconcile every
        // terminal record before admitting new work so a crash between the
        // terminal CAS and the event sink cannot leave a zombie Desk item.
        await reconcileTerminalDeskSettlements()
        // Disabling autonomous execution blocks new claims, not durable
        // zero-effect repair of work that was already admitted.
        guard await isEnabled() else { return }
        // Fail approvals nobody is coming to answer (no-op unless the
        // approval-wait deadline is configured). Runs each drain tick so the
        // timeout granularity is the drain interval — fine for a multi-hour
        // approval wait.
        await reconcileTimedOutApprovals()
        let queued = await scanQueue()
            .filter { $0.status == "queued" }
            .sorted { $0.createdAt < $1.createdAt }   // submit order
        for record in queued {
            if Task.isCancelled { return }
            do {
                guard let claimed = try await claim(record.id) else { continue }
                await runClaimedWorkshopExecution(claimed)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("drain claim failed for \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func reconcileTerminalDeskSettlements() async {
        for record in await scanQueue()
        where ["completed", "failed", "cancelled", "canceled"].contains(record.status.lowercased()) {
            await WorkshopDeskReceiptBridge.recordTerminal(record, reason: nil, dataRoot: root)
        }
    }

    /// Earliest persisted approval-wait expiry. Queued work is reconciled by
    /// the execution-directory event/startup edge; only a future transition
    /// belongs to the exact-deadline scheduler.
    public func nextMeaningfulDeadline(after date: Date) async -> Date? {
        guard approvalTimeoutNanos > 0 else { return nil }
        let timeout = TimeInterval(approvalTimeoutNanos) / 1_000_000_000
        return await scanQueue().compactMap { execution -> Date? in
            guard execution.status == "blocked_on_approval" else { return nil }
            let raw = Self.latestBlockedStepExecutedAt(execution) ?? execution.updatedAt
            guard let blockedAt = WorkshopOutcomeScoreboard.parseTimestamp(raw) else {
                return nil
            }
            let due = blockedAt.addingTimeInterval(timeout)
            return due > date ? due : nil
        }.min()
    }

    /// Run the one-shot orphan reclaim to completion, memoized PER DATA-ROOT so
    /// concurrent claim paths — across ALL executor instances on that root —
    /// share ONE reclaim and none claims before it finishes. `OnceByKey` is an
    /// actor, so the lookup-or-create is atomic even when two instances race
    /// here, and every caller awaits the same run to COMPLETION. (Strong
    /// self-capture in the operation is intentional and harmless:
    /// reconcileOrphanedRunning only touches root-derived paths, so whichever
    /// instance first starts the reclaim runs it correctly for any instance —
    /// and unlike the old memo table, the capture is released the moment the
    /// run completes.)
    private func ensureOrphansReconciled() async {
        await Self.orphanReclaimOnce.run(root.path) { await self.reconcileOrphanedRunning() }
    }

    /// One-time startup reconcile (crash/restart orphan recovery). An execution
    /// left "running" by a crash is never re-claimed yet still counts against
    /// maxActive: a silent slot leak that degrades throughput across restarts.
    /// Parent/pass cancellation is recovered in-process at the claim boundary;
    /// fail only true startup orphans HONESTLY (not requeue: a
    /// partially-run execution may have side-effecting steps, and silently
    /// re-running them is the fabricated-state shape the W6 audit closed) so
    /// the slot frees and the user sees it did not finish. CAS require:running
    /// → never clobbers an execution that has since moved on.
    private func reconcileOrphanedRunning() async {
        let orphans = await scanQueue().filter { $0.status == "running" }
        for orphan in orphans {
            let failed = try? await casMutateWorkshopExecution(orphan.id, require: ["running"]) { rec in
                rec.status = "failed"
                rec.currentStepId = ""
            }
            guard failed?.applied == true else { continue }
            try? await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string("interrupted_by_restart"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: orphan.id
            )
            await emitTerminalEvent(failed?.record, reason: "interrupted_by_restart")
            Self.logger.notice("reclaimed orphaned Workshop execution \(orphan.id, privacy: .public) -> failed (interrupted_by_restart)")
        }
    }

    /// Auto-fail executions stuck `blocked_on_approval` past the approval-wait
    /// deadline — the "no human is coming" stall this trust leg targets.
    /// No-op when `approvalTimeoutNanos == 0` (the default), so interactive
    /// installs never lose a pending approval.
    ///
    /// "Blocked since" = the stable `executed_at` of the latest
    /// blocked_on_approval STEP record (set ONCE when the step blocked;
    /// runSteps appends it via outcome.toJSON). NOT the execution's `updatedAt`:
    /// `updateWorkshopExecution` bumps updatedAt on unrelated title/objective patches,
    /// which would silently EXTEND the wait every time (gpt-5.5 review). Fall
    /// back to updatedAt only when no such record/timestamp exists. Both are
    /// persisted in mission.json, so the clock survives restarts.
    ///
    /// CONCURRENCY: the CAS requires `blocked_on_approval` and resume now
    /// CAS-claims `blocked_on_approval → running` BEFORE it executes the step
    /// (resumeAfterApproval). So this sweep and a concurrent resume are
    /// mutually exclusive — whichever flips OUT of blocked_on_approval first
    /// wins under the per-execution flock; the loser's CAS fails and bails. A
    /// execution can therefore never be failed-by-timeout mid-execution. (Resume
    /// and the drain that runs this sweep share ONE executor instance via
    /// WorkshopExecutorRef.shared, so the once-only orphan-reclaim barrier spans
    /// both — see applyResolvedWorkshopStep.)
    private func reconcileTimedOutApprovals() async {
        guard approvalTimeoutNanos > 0 else { return }
        let deadlineSecs = TimeInterval(approvalTimeoutNanos) / 1_000_000_000
        let nowDate = now()
        let blocked = await scanQueue().filter { $0.status == "blocked_on_approval" }
        for execution in blocked {
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
            let failed = try? await casMutateWorkshopExecution(execution.id, require: ["blocked_on_approval"]) { rec in
                rec.status = "failed"
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
            Self.logger.notice("auto-failed approval-timed-out Workshop execution \(execution.id, privacy: .public) -> failed (waited \(Int(elapsed))s >= \(label))")
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

    /// Explicit single-execution start — the executor-backed replacement for
    /// the daemon's start() on the QUEUED path. v1 does NOT port the
    /// failed/cancelled re-run branch (rerun_count++) — re-runs stay
    /// unsupported until a caller needs them.
    @discardableResult
    public func start(executionId: String) async throws -> WorkshopExecutionRecord {
        let trimmed = executionId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WorkshopExecutionError.invalidRequest("empty missionId") }
        // Reclaim orphans BEFORE this explicit start claims — else an execution
        // started here (before the first background drain) would be seen as a
        // "running" orphan by that drain and wrongly failed (gpt-5.5 review).
        await ensureOrphansReconciled()
        guard let claimed = try await claim(trimmed) else {
            // Mirror the daemon's typed refusal.
            let current = await getRecord(trimmed)
            guard let current else { throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(trimmed)") }
            throw WorkshopExecutionError.invalidRequest("Workshop execution \(trimmed) cannot be started (status=\(current.status))")
        }
        await runClaimedWorkshopExecution(claimed)
        return await getRecord(trimmed) ?? claimed
    }

    // MARK: claim (W6 race fix + queue-level serialization)

    /// Queue-level claim-lock target: `<queueRoot>/.claim` (withFileLock
    /// flocks its `.lock` sibling). EVERY claim — drain pass or explicit
    /// start, any process — serializes on this ONE cross-process flock, so
    /// the running-count scan and the queued→running write are atomic
    /// ACROSS Workshop executions, not just within one Workshop execution dir.
    nonisolated var queueClaimLockTarget: URL {
        executionRecordsRoot.appendingPathComponent(".claim")
    }

    /// Atomically transition queued→running.
    ///
    /// gpt-5.5 executor-port blocker #4 (2026-06-10): the slot-cap re-check
    /// used to live inside the PER-EXECUTION lock only — two claimers working
    /// on DIFFERENT executions serialized on nothing shared, so both could
    /// read runningCount == 0 and both claim, bursting past maxActive. The
    /// WHOLE scan+claim now runs inside ONE queue-level cross-process flock
    /// (`queueClaimLockTarget`); the per-execution RMW stays nested inside it.
    /// Lock order is always queue-claim-lock → mission.json-lock; nothing
    /// takes them in the other order (cancel()/mutators take only the
    /// execution lock and never the claim lock), so there is no ordering cycle.
    ///
    /// Inside the claim:
    ///   - re-read status INSIDE the execution lock and require "queued" (two
    ///     concurrent executors — same process or cross-process — race here;
    ///     exactly one sees "queued");
    ///   - re-check the running-count slot cap INSIDE the same critical
    ///     section (the W6 check-then-act flag: the daemon checked capacity
    ///     outside the claim).
    /// Returns nil when the execution was not claimable (already claimed, not
    /// queued, or no slot free).
    private func claim(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        // The queue root may not exist yet on a fresh data root; the
        // lock-file open needs its parent directory.
        try? FileManager.default.createDirectory(
            at: executionRecordsRoot, withIntermediateDirectories: true)
        return try await persistence.withFileLock(queueClaimLockTarget) {
            try await self.claimUnderQueueLock(executionId)
        }
    }

    /// The scan + per-Workshop execution RMW half of claim(). MUST only be called while
    /// holding the queue-level claim flock (or with mock persistence, where
    /// there is no cross-process writer to race).
    private func claimUnderQueueLock(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        let executionRecordJSON = executionRecordPath(executionId)
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let work: @Sendable () async throws -> WorkshopExecutionRecord? = { [persistence, self] in
            let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                return nil
            }
            var record = SwiftNativeWorkshopRunner.recordFromJSON(obj)
            guard record.status == "queued" else { return nil }
            // Slot-cap re-check INSIDE the claim critical section. The
            // enclosing queue-level flock serializes claimers across
            // Workshop executions (blocker #4), so this count cannot be concurrently
            // stale-read by another claimer.
            let runningCount = await self.scanQueue()
                .filter { $0.status == "running" && $0.id != executionId }
                .count
            guard runningCount < self.maxActive else { return nil }
            record.status = "running"
            record.updatedAt = nowStr
            try await persistence.writeJSON(record.toJSON(), to: executionRecordJSON)
            return record
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistence.withFileLock(executionRecordJSON, work)
    }

    // MARK: execution run loop (port of _run_mission_locked, the retired daemon)

    private func runClaimedWorkshopExecution(_ claimed: WorkshopExecutionRecord) async {
        let executionId = claimed.id
        do {
            // `started` AFTER the queued→running flip — same order as the
            // daemon (update_status in submit/start, then append in
            // _run_mission_locked L798).
            try await appendTimelineLocked(
                .object(["event": .string("started"), "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now()))]),
                executionId: executionId
            )
            try await runSteps(executionId: executionId, afterStepId: nil)
        } catch is CancellationError {
            // Parent task cancelled (pass timeout, app shutdown, or loop
            // teardown). Release only this still-running claim so the next
            // drain in the SAME process can reclaim it. A concurrent explicit
            // user cancel wins the CAS and remains terminal.
            await releaseClaimAfterParentCancellation(executionId)
            return
        } catch {
            // Mirror the daemon's broad-except tail (L872-L880): mark failed
            // + `failed` timeline event so the error is user-visible, never
            // swallowed. CAS from "running" (blocker #2): a cancel that
            // landed before this tail must not be overwritten by `failed`,
            // and when the CAS loses, the `failed` event is skipped too (it
            // would lie about the on-disk terminal state).
            Self.logger.error("Workshop execution error \(executionId, privacy: .public): \(String(describing: error), privacy: .public)")
            let failedWrite = try? await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.status = "failed"
                rec.currentStepId = ""
            }
            guard failedWrite?.applied == true else { return }
            try? await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string(String(describing: error)),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(failedWrite?.record, reason: String(describing: error))
        }
    }

    private func releaseClaimAfterParentCancellation(_ executionId: String) async {
        let released = try? await casMutateWorkshopExecution(executionId, require: ["running"]) { record in
            record.status = "queued"
            record.currentStepId = ""
        }
        guard released?.applied == true else { return }
        try? await appendTimelineLocked(
            .object([
                "event": .string("execution_interrupted"),
                "reason": .string("parent_task_cancelled"),
                "status": .string("queued"),
                "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
            ]),
            executionId: executionId
        )
        Self.logger.notice("released cancelled execution claim for \(executionId, privacy: .public) -> queued")
    }

    /// Execute plan steps in order. `afterStepId == nil` runs the whole plan
    /// (fresh claim); otherwise only the steps strictly AFTER that id run
    /// (the resume path's "continue remaining steps").
    /// Throws only on infrastructure errors (persistence) or cancellation of
    /// the parent task; step-level failures terminate the Workshop execution honestly
    /// in here and return.
    private func runSteps(executionId: String, afterStepId: String?) async throws {
        var skipping = (afterStepId != nil)
        guard let planSource = await getRecord(executionId) else { return }
        // A parent/pass cancellation may requeue after earlier steps committed.
        // Their outcomes and receipts are durable, so a later claim skips them
        // instead of replaying side effects or double-counting completion.
        let durablyCompletedStepIDs = Set(planSource.stepsCompleted.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let stepID)? = object["step_id"],
                  case .string(let status)? = object["status"],
                  !["failed", "cancelled", "blocked_on_approval"].contains(status) else {
                return nil
            }
            return stepID
        })
        for stepJSON in planSource.plan {
            // Cooperative cancellation between steps (W2).
            try Task.checkCancellation()
            if skipping {
                if stepJSON.id == afterStepId { skipping = false }
                continue
            }
            let step = stepJSON
            if durablyCompletedStepIDs.contains(step.id) { continue }
            // current_step_id tracking + the daemon's per-step "still
            // running?" re-read (L801-L803), folded into ONE locked CAS
            // (blocker #2): an execution cancelled — or otherwise transitioned —
            // since the previous step aborts the loop BEFORE the next step
            // executes, with no read-then-write window in between.
            let stepClaim = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.currentStepId = step.id
            }
            guard stepClaim.applied, let execution = stepClaim.record else { return }
            let outcome = await executeStep(execution: execution, step: step, bypassApproval: false)
            // dispatchStep maps a child CancellationError to a value. When the
            // parent/pass is also cancelled, that synthetic outcome means no
            // completed result crossed the boundary: release the claim without
            // fabricating a terminal user cancellation or a cancelled receipt.
            // A non-cancelled outcome may represent a side effect that ignored
            // cancellation and completed successfully, so it MUST commit below
            // before the parent cancellation is observed.
            if Task.isCancelled && outcome.status == "cancelled" {
                throw CancellationError()
            }
            // Daemon order (L813-L817) hardened to a CAS (blocker #2): only
            // a still-"running" execution accepts the step record. A cancel
            // that landed DURING the step wins — skip the append AND the
            // receipt/timeline writes below.
            let appendWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.stepsCompleted.append(outcome.toJSON())
            }
            guard appendWrite.applied else { return }
            await writeReceipt(executionId: executionId, outcome: outcome)
            if outcome.status != "blocked_on_approval" {
                try await appendTimelineLocked(
                    .object([
                        "event": .string("step_completed"),
                        "step_id": .string(step.id),
                        "status": .string(outcome.status),
                        "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                    ]),
                    executionId: executionId
                )
            }
            switch outcome.status {
            case "blocked_on_approval":
                // CAS: a cancel between the step append and this write wins —
                // the Workshop execution stays cancelled, never flips to blocked. The
                // step_blocked_on_approval event is emitted ONLY on CAS win
                // (mirrors the failed branch) so a cancelled Workshop execution's
                // timeline never claims it blocked.
                let blockedWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                    rec.status = "blocked_on_approval"
                }
                guard blockedWrite.applied else { return }
                try? await appendTimelineLocked(
                    .object([
                        "event": .string("step_blocked_on_approval"),
                        "step_id": .string(step.id),
                        "tool": .string(step.toolOrAction),
                        "autonomy": .string(step.autonomy),
                        "approval_id": .string(outcome.approvalId),
                        "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                    ]),
                    executionId: executionId
                )
                return
            case "cancelled":
                let cancelledWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                    rec.status = "cancelled"
                    rec.currentStepId = ""   // terminal — clear the step pointer
                }
                if cancelledWrite.applied {
                    await emitTerminalEvent(cancelledWrite.record, reason: outcome.error.isEmpty ? nil : outcome.error)
                }
                return
            case "failed":
                let failedWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                    rec.status = "failed"
                    rec.currentStepId = ""   // terminal — clear the step pointer
                }
                // CAS lost (cancel landed in the window) → the cancel wins;
                // the `failed` event would contradict the on-disk state.
                guard failedWrite.applied else { return }
                try await appendTimelineLocked(
                    .object([
                        "event": .string("failed"),
                        "step_id": .string(step.id),
                        "error": .string(outcome.error),
                        "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                    ]),
                    executionId: executionId
                )
                await emitTerminalEvent(failedWrite.record, reason: outcome.error)
                return
            default:
                // The outcome, receipt, and timeline are now durable. Honor a
                // parent/pass cancellation before another step (or terminal
                // completion) so releaseClaimAfterParentCancellation requeues
                // the Workshop execution. The next drain skips this durable step.
                try Task.checkCancellation()
                continue  // succeeded / stubbed
            }
        }
        // All steps done — terminal completed (daemon L855-L865), as a CAS
        // from "running" so a cancel that landed after the last step can
        // never be overwritten by `completed` (blocker #2). Result
        // extraction happens INSIDE the lock against the in-lock record.
        //
        // HONESTY GATE (W3, Agent's catch 2026-07-11): the execution's own
        // success criterion is enforced here. Execution 251da950 recorded
        // `completed` with output "I don't have the required phrase." against
        // an objective demanding the exact phrase "Workshop live proof
        // passed." — steps succeeding is not the execution succeeding. An unmet
        // expected_outputs entry or exact-output objective records `failed`,
        // inside the same CAS so a cancel race can't split the decision.
        let verificationCheckedAt = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let completedWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
            rec.currentStepId = ""
            let verification = Self.verifyCompletedOutcome(
                rec,
                checkedAt: verificationCheckedAt
            )
            rec.verification = verification
            if verification.status == .failed {
                rec.status = "failed"
                rec.result = .object([
                    "error": .string("verification_failed"),
                    "detail": .string(verification.detail),
                ])
            } else {
                rec.status = "completed"
                if !rec.stepsCompleted.isEmpty {
                    let snapshot = rec
                    rec.result = Self.extractWorkshopExecutionResult(snapshot)
                }
            }
        }
        guard completedWrite.applied, let terminalRecord = completedWrite.record else { return }
        if terminalRecord.status == "failed" {
            let detail: String = {
                if case .object(let o) = terminalRecord.result,
                   case .string(let d)? = o["detail"] { return d }
                return "outcome verification failed"
            }()
            try await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "error": .string("verification_failed: \(detail)"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(completedWrite.record, reason: "verification_failed: \(detail)")
            return
        }
        try await appendTimelineLocked(
            .object(["event": .string("completed"), "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now()))]),
            executionId: executionId
        )
        await emitTerminalEvent(completedWrite.record, reason: nil)
    }

    /// W3 success-criterion check, pure and testable. Returns a human detail
    /// string when the execution's own definition of success is unmet, nil
    /// when satisfied or when no criterion exists.
    ///
    /// Two criterion sources, both matched by CONTAINMENT against the joined
    /// step outputs (exact equality would false-fail on quoting/wrapping):
    /// 1. Every non-empty string entry in `expected_outputs`.
    /// 2. An exact-output objective: "Return exactly: <phrase>" (case-
    ///    insensitive marker; phrase runs to the first sentence end).
    static func unmetSuccessCriterion(_ record: WorkshopExecutionRecord) -> String? {
        let combinedOutput = record.stepsCompleted.compactMap { step -> String? in
            guard case .object(let obj) = step,
                  case .object(let output)? = obj["output"],
                  case .string(let text)? = output["text"] else { return nil }
            return text
        }.joined(separator: "\n")

        for entry in record.expectedOutputs {
            guard case .string(let expected) = entry else { continue }
            let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !combinedOutput.contains(trimmed) {
                return "expected output missing: \(trimmed.prefix(120))"
            }
        }

        let marker = "return exactly:"
        if let range = record.objective.range(of: marker, options: .caseInsensitive) {
            let remainder = record.objective[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phrase: String = {
                // Sentence end = "." followed by ANY whitespace (space or
                // newline) — "Return exactly: X.\nUse no tools…" must extract
                // only "X." or the gate false-fails on the trailing
                // instruction (review round 3, finding 3).
                if let sentenceEnd = remainder.range(of: #"\.\s"#, options: .regularExpression) {
                    return String(remainder[..<sentenceEnd.lowerBound]) + "."
                }
                return remainder
            }()
            if !phrase.isEmpty, !combinedOutput.contains(phrase) {
                return "objective requires exact phrase not present: \(phrase.prefix(120))"
            }
        }
        return nil
    }

    /// Verify only outcomes for which Workshop owns exact local evidence.
    /// This deliberately does not ask an LLM to judge its own work and does
    /// not infer external success from a tool's absence of an error.
    ///
    /// Currently provable:
    /// - explicit textual success criteria already stored on the execution;
    /// - `write_file` bytes, read back from the exact resolved result path.
    ///
    /// Read/synthesis steps are evidence-neutral. Any other action step keeps
    /// the overall execution `unverified` even when its tool returned success.
    /// A verifiable claim whose evidence disagrees fails the execution.
    static func verifyCompletedOutcome(
        _ record: WorkshopExecutionRecord,
        checkedAt: String,
        fileManager: FileManager = .default
    ) -> WorkshopVerificationRecord {
        if let unmet = unmetSuccessCriterion(record) {
            return WorkshopVerificationRecord(
                status: .failed,
                checkedAt: checkedAt,
                methods: ["exact_output"],
                detail: unmet
            )
        }

        var methods: [String] = []
        let hasTextCriterion = record.expectedOutputs.contains {
            guard case .string(let value) = $0 else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || record.objective.range(of: "return exactly:", options: .caseInsensitive) != nil
        if hasTextCriterion { methods.append("exact_output") }

        var hasExactEvidence = hasTextCriterion
        var unsupportedAction = false
        for step in record.plan {
            let tool = step.toolOrAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if tool == "write_file" {
                switch verifyFileWrite(step: step, record: record, fileManager: fileManager) {
                case .satisfied:
                    hasExactEvidence = true
                    if !methods.contains("file_bytes") { methods.append("file_bytes") }
                case .failed(let detail):
                    return WorkshopVerificationRecord(
                        status: .failed,
                        checkedAt: checkedAt,
                        methods: methods + ["file_bytes"],
                        detail: detail
                    )
                case .unverifiable:
                    unsupportedAction = true
                }
            } else if !isVerificationNeutral(tool: tool) {
                unsupportedAction = true
            }
        }

        if hasExactEvidence && !unsupportedAction {
            return WorkshopVerificationRecord(
                status: .satisfied,
                checkedAt: checkedAt,
                methods: methods,
                detail: "Declared outcome matched exact local evidence."
            )
        }
        return WorkshopVerificationRecord(
            status: .unverified,
            checkedAt: checkedAt,
            methods: methods,
            detail: unsupportedAction
                ? "At least one action has no exact domain verifier."
                : "No exact outcome criterion was declared."
        )
    }

    private enum FileVerificationVerdict {
        case satisfied
        case failed(String)
        case unverifiable
    }

    /// One bounded terminal read. The verifier never persists file content or
    /// the path; it records only the evidence method and verdict.
    private static func verifyFileWrite(
        step: WorkshopExecutionStep,
        record: WorkshopExecutionRecord,
        fileManager: FileManager
    ) -> FileVerificationVerdict {
        let resolvedArgs = resolveStepReferences(in: step.args, execution: record)
        guard case .object(let args) = resolvedArgs,
              case .string(let content)? = args["content"],
              let completed = record.stepsCompleted.last(where: { value in
                  guard case .object(let object) = value,
                        case .string(let stepID)? = object["step_id"] else { return false }
                  return stepID == step.id
              }),
              case .object(let completedObject) = completed,
              case .string("succeeded")? = completedObject["status"],
              case .object(let output)? = completedObject["output"],
              case .bool(true)? = output["ok"],
              case .string(let path)? = output["path"]
        else { return .failed("write_file completed without an exact success receipt") }

        let expected = Data(content.utf8)
        let verificationByteLimit = 1_048_576
        guard expected.count <= verificationByteLimit else { return .unverifiable }
        let append: Bool = {
            if case .bool(let value)? = args["append"] { return value }
            return false
        }()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber
        else { return .failed("write_file target is absent after execution") }
        let fileSize = sizeNumber.intValue
        if append {
            guard fileSize >= expected.count,
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            else { return .failed("write_file append target cannot be read back") }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(fileSize - expected.count))
                let actual = try handle.read(upToCount: expected.count) ?? Data()
                return actual == expected
                    ? .satisfied
                    : .failed("write_file append bytes do not match the declared content")
            } catch {
                return .failed("write_file append target cannot be read back")
            }
        }
        guard fileSize == expected.count,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return .failed("write_file target size does not match the declared content") }
        defer { try? handle.close() }
        do {
            let actual = try handle.read(upToCount: expected.count) ?? Data()
            return actual == expected
                ? .satisfied
                : .failed("write_file bytes do not match the declared content")
        } catch {
            return .failed("write_file target cannot be read back")
        }
    }

    private static func isVerificationNeutral(tool: String) -> Bool {
        if tool.isEmpty { return false }
        let exact: Set<String> = [
            "chat.synthesize", "llm", "report", "read_file", "list_dir",
            "file_excerpt", "grep", "recall_memory", "recall_search", "search_kg",
        ]
        if exact.contains(tool) { return true }
        let leaf = tool.split(separator: ".").last.map(String.init) ?? tool
        return ["read", "list", "search", "get", "fetch", "status", "availability", "screenshot"]
            .contains { leaf == $0 || leaf.hasPrefix("\($0)_") }
    }

    // MARK: step execution (port of execute_step + _dispatch_step)

    /// `bypassApproval` is the resume-after-approval path's "user approved
    /// this exact step" replay — the only caller that may skip the gate.
    private func executeStep(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep, bypassApproval: Bool) async -> WorkshopStepOutcome {
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        // Approval gate (v1 reduced rule per the build plan): the execution's
        // trustRequired escalates every step; a step may also mark itself.
        // YOLO: under wide-open trust stepApprovalEnforced() is false, so the
        // planner's per-tool `needs_approval` default does NOT gate (executions
        // run unattended). An EXPLICIT per-execution trustRequired != "none" is
        // still honored regardless — an execution deliberately asking for approval
        // gates even under yolo.
        let enforceStepAutonomy = await stepApprovalEnforced()
        // Non-yolo: the planner's per-step autonomy_hint must NOT be able to
        // downgrade a tool that intrinsically needs approval. A sloppy/compromised
        // planner marking email.send / calendar.cancel_event / *.send as "auto"
        // would otherwise fire it unattended. Enforce the tool's intrinsic
        // autonomy from DefaultToolAutonomy — but ONLY for KNOWN tools (explicit
        // map entry/glob). Unknown tools are left to reach dispatch and fail
        // honestly (no dispatcher → "no tool dispatcher wired"), which is why the
        // earlier blanket version was reverted: resolve() returns send_approval
        // for the "default" fallback, so it force-gated every unknown tool.
        // YOLO (enforceStepAutonomy == false) is exempt by design — "she does
        // everything" unattended (2026-06-15, re-applies the reverted HIGH).
        let toolIntrinsicGate: Bool = {
            guard enforceStepAutonomy else { return false }
            guard DefaultToolAutonomy.hasKnownEntry(step.toolOrAction) else { return false }
            return DefaultToolAutonomy.needsApproval(
                DefaultToolAutonomy.resolve(toolId: step.toolOrAction))
        }()
        let needsApproval = !bypassApproval
            && (execution.trustRequired != "none"
                || (step.autonomy == "needs_approval" && enforceStepAutonomy)
                || toolIntrinsicGate)
        if needsApproval {
            guard let stageApproval else {
                // No stager injected → FAIL honestly. Blocking forever on an
                // approval that was never filed is the dead-end the W6 audit
                // called fabricated state.
                return WorkshopStepOutcome(
                    stepId: step.id, status: "failed",
                    error: "approval required but no approval stager is wired",
                    executedAt: nowStr
                )
            }
            let request = WorkshopStepApprovalRequest(
                executionId: execution.id,
                stepId: step.id,
                title: "Workshop step approval: \(step.description)",
                tool: step.toolOrAction,
                reason: "Workshop trust=\(execution.trustRequired); step autonomy=\(step.autonomy); tool=\(step.toolOrAction)",
                args: step.args
            )
            guard let approvalId = await stageApproval(request) else {
                return WorkshopStepOutcome(
                    stepId: step.id, status: "failed",
                    error: "approval staging failed",
                    executedAt: nowStr
                )
            }
            // The daemon emitted step_blocked_on_approval from inside
            // execute_step. DIVERGENCE (delta
            // review 2026-06-10): the event is emitted by the CALLER after
            // the blocked-status CAS wins — appending it here races cancel()
            // and leaves a blocked event in the timeline of an execution whose
            // status write the CAS correctly skipped.
            return WorkshopStepOutcome(
                stepId: step.id, status: "blocked_on_approval",
                approvalId: approvalId, executedAt: nowStr
            )
        }
        return await dispatchStep(execution: execution, step: step)
    }

    private func dispatchStep(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep) async -> WorkshopStepOutcome {
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let tool = step.toolOrAction
        if tool.isEmpty {
            // daemon L1130-L1131
            return WorkshopStepOutcome(stepId: step.id, status: "failed", error: "Empty tool_or_action", executedAt: nowStr)
        }
        // Capture the injected closures + clock as locals: the dispatch op
        // runs as a child task of the cancellation-watch group, and Sendable
        // locals keep the closure free of cross-actor property access.
        let llmStep = self.llmStep
        let tooledLLMStep = self.tooledLLMStep
        let measuredLLMStep = self.measuredLLMStep
        let measuredTooledLLMStep = self.measuredTooledLLMStep
        let toolDispatch = self.toolDispatch
        let nowFn = self.now
        do {
            let outcome: WorkshopStepOutcome = try await raceWithCancellationWatch(executionId: execution.id) {
                switch tool {
                case "chat.synthesize", "llm", "report":
                    // Synthesize-quality fix (2026-06-11): prefer the
                    // TOOL-CAPABLE turn so the model can actually read what it
                    // is being asked to synthesize. The bare `llmStep` is the
                    // honest fallback when no tooled closure is wired — but the
                    // step output is flagged `tooled:false` so dispatchStep can
                    // emit a `synthesize_untooled` timeline note (no silent
                    // degradation, W6).
                    let usedTooled = measuredTooledLLMStep != nil || tooledLLMStep != nil
                    guard measuredTooledLLMStep != nil || tooledLLMStep != nil
                            || measuredLLMStep != nil || llmStep != nil else {
                        throw WorkshopExecutionError.invalidRequest("no LLM closure wired for step kind '\(tool)'")
                    }
                    let prompt = Self.buildLLMPrompt(execution: execution, step: step)
                    let completion: WorkshopStepLLMCompletion
                    let providerCallCount: Int?
                    let removableProviderCallCount: Int?
                    if let measuredTooledLLMStep {
                        completion = try await measuredTooledLLMStep(prompt)
                        providerCallCount = completion.providerCallCount
                        removableProviderCallCount = completion.removableOrchestrationProviderCallCount
                    } else if let tooledLLMStep {
                        let (model, text) = try await tooledLLMStep(prompt)
                        completion = WorkshopStepLLMCompletion(model: model, text: text, providerCallCount: 0)
                        providerCallCount = nil
                        removableProviderCallCount = nil
                    } else if let measuredLLMStep {
                        completion = try await measuredLLMStep(prompt)
                        providerCallCount = completion.providerCallCount
                        removableProviderCallCount = completion.removableOrchestrationProviderCallCount
                    } else if let llmStep {
                        let (model, text) = try await llmStep(prompt)
                        completion = WorkshopStepLLMCompletion(model: model, text: text, providerCallCount: 0)
                        providerCallCount = nil
                        removableProviderCallCount = nil
                    } else {
                        throw WorkshopExecutionError.invalidRequest("no LLM closure wired for step kind '\(tool)'")
                    }
                    let model = completion.model
                    let text = completion.text
                    let trimmedText = String(text.prefix(4000))  // daemon L1356
                    // OUTPUT VALIDATION before scoring (2026-06-11). A bare
                    // completion (or even a tooled one) can return a refusal or
                    // empty body; scoring that `succeeded` is the
                    // fabricated-success disease Agent caught on 752636c5.
                    let verdict = Self.validateSynthesizeOutput(trimmedText)
                    let baseOutput: [String: JSONValue] = [
                        "model": .string(model),
                        "text": .string(trimmedText),
                        "tooled": .bool(usedTooled),
                    ]
                    switch verdict {
                    case .ok:
                        return WorkshopStepOutcome(
                            stepId: step.id, status: "succeeded",
                            output: .object(baseOutput),
                            executedAt: SwiftNativeWorkshopRunner.isoTimestamp(nowFn()),
                            providerCallCount: providerCallCount,
                            removableOrchestrationProviderCallCount: removableProviderCallCount
                        )
                    case .refusal:
                        var out = baseOutput
                        out["validation"] = .string("model_refusal")
                        return WorkshopStepOutcome(
                            stepId: step.id, status: "failed",
                            output: .object(out),
                            error: "model_refusal",
                            executedAt: SwiftNativeWorkshopRunner.isoTimestamp(nowFn()),
                            providerCallCount: providerCallCount,
                            removableOrchestrationProviderCallCount: removableProviderCallCount
                        )
                    case .empty:
                        var out = baseOutput
                        out["validation"] = .string("empty_output")
                        return WorkshopStepOutcome(
                            stepId: step.id, status: "failed",
                            output: .object(out),
                            error: "empty_output",
                            executedAt: SwiftNativeWorkshopRunner.isoTimestamp(nowFn()),
                            providerCallCount: providerCallCount,
                            removableOrchestrationProviderCallCount: removableProviderCallCount
                        )
                    }
                default:
                    guard let toolDispatch else {
                        // Unknown/unservable step kind → honest failure, not
                        // a silent no-op (W6).
                        throw WorkshopExecutionError.invalidRequest("no tool dispatcher wired for step kind '\(tool)'")
                    }
                    // Thread prior step outputs into this tool's args: replace
                    // any {{step:<id>}} token (the planner is taught to emit
                    // these) with that completed step's actual output text. This
                    // is how a write_file step gets the body produced by an
                    // earlier chat.synthesize/data step — without it the token
                    // (or a literal "<...>" placeholder) lands in the file
                    // verbatim (2026-06-15). Pure on the no-token path.
                    let resolvedArgs = Self.resolveStepReferences(in: step.args, execution: execution)
                    let result = try await toolDispatch(tool, resolvedArgs)
                    // Mirror the connector branch (daemon L1419-L1423): honor
                    // a "status" key on the result, default succeeded.
                    var status = "succeeded"
                    if case .object(let obj) = result, case .string(let s)? = obj["status"], !s.isEmpty {
                        status = s
                    }
                    let output: JSONValue = {
                        if case .object = result { return result }
                        return .object(["output": result])
                    }()
                    return WorkshopStepOutcome(
                        stepId: step.id, status: status, output: output,
                        executedAt: SwiftNativeWorkshopRunner.isoTimestamp(nowFn()),
                        providerCallCount: 0,
                        removableOrchestrationProviderCallCount: 0
                    )
                }
            }
            // TRIPWIRE timeline notes (2026-06-11) — visible in workshop_status
            // receipts. Emitted from the actor AFTER the race returns (the race
            // closure is Sendable + has no actor access). Best-effort: a
            // timeline IO hiccup must not change the step outcome.
            await emitSynthesizeNotes(executionId: execution.id, step: step, outcome: outcome)
            return outcome
        } catch let timeout as WorkshopStepTimedOut {
            // Wedged tool exceeded the hard step deadline → honest failed step
            // (NOT cancelled — nothing cancelled it; it ran out of time). The
            // runSteps `failed` branch fails the execution + emits a visible
            // timeline event carrying this error string.
            // Sub-second deadlines (tests) report ms so the diagnostic isn't a
            // misleading "_0s" (gpt-5.5 review); production (>=1s) reports s.
            let label = timeout.seconds >= 1
                ? "\(Int(timeout.seconds))s"
                : "\(Int(timeout.seconds * 1000))ms"
            return WorkshopStepOutcome(
                stepId: step.id, status: "failed",
                error: "step_timeout_exceeded_\(label)",
                executedAt: nowStr
            )
        } catch is WorkshopExecutionCancelledDuringStep {
            return WorkshopStepOutcome(stepId: step.id, status: "cancelled", error: "execution_cancelled", executedAt: nowStr)
        } catch is CancellationError {
            // Parent task cancelled — surface as a cancelled step; the
            // caller's post-step re-read decides what sticks on disk.
            return WorkshopStepOutcome(stepId: step.id, status: "cancelled", error: "execution_cancelled", executedAt: nowStr)
        } catch {
            // daemon L1426-L1431: any dispatch exception → failed step.
            return WorkshopStepOutcome(stepId: step.id, status: "failed", error: String(describing: error), executedAt: nowStr)
        }
    }

    /// Synthesize-step tripwire notes (2026-06-11). Two honest, user-visible
    /// timeline events keyed off the synthesize-step output metadata:
    ///   - `synthesize_untooled` — the step ran on the BARE llmStep because no
    ///     tool-capable closure was wired (degraded mode, not silent).
    ///   - `synthesize_validation_failed` — output validation rejected the
    ///     result (model_refusal / empty_output) before scoring, so the
    ///     receipt + status reflect the real failure instead of a fabricated
    ///     "succeeded".
    /// Only fires for synthesize-class steps; tool steps are untouched.
    private func emitSynthesizeNotes(
        executionId: String, step: WorkshopExecutionStep, outcome: WorkshopStepOutcome
    ) async {
        let tool = step.toolOrAction
        guard tool == "chat.synthesize" || tool == "llm" || tool == "report" else { return }
        let ts = SwiftNativeWorkshopRunner.isoTimestamp(now())
        // tooled flag lives on the synthesize output metadata.
        if case .object(let o) = outcome.output, case .bool(false)? = o["tooled"] {
            try? await appendTimelineLocked(
                .object([
                    "event": .string("synthesize_untooled"),
                    "step_id": .string(step.id),
                    "tool": .string(tool),
                    "ts": .string(ts),
                ]),
                executionId: executionId
            )
        }
        if outcome.status == "failed",
           case .object(let o) = outcome.output,
           case .string(let reason)? = o["validation"],
           reason == "model_refusal" || reason == "empty_output" {
            try? await appendTimelineLocked(
                .object([
                    "event": .string("synthesize_validation_failed"),
                    "step_id": .string(step.id),
                    "reason": .string(reason),
                    "ts": .string(ts),
                ]),
                executionId: executionId
            )
        }
    }

    /// Marker error the cancellation watcher throws when cancel() flipped
    /// mission.json to "cancelled" while a step was in flight.
    private struct WorkshopExecutionCancelledDuringStep: Error {}

    /// Thrown by the step-deadline task in raceWithCancellationWatch when a
    /// step exceeds stepTimeoutNanos. dispatchStep maps it to a `failed` step.
    private struct WorkshopStepTimedOut: Error { let seconds: TimeInterval }

    /// Identifies which child completed the step race. Observer cancellation
    /// caused by a parent/pass cancellation is not itself the step result: the
    /// operation may still return a successful side effect that must be
    /// committed before the claim is released.
    private enum StepRaceEvent<Value: Sendable>: Sendable {
        case operationSucceeded(Value)
        case operationFailed(any Error)
        case workshopExecutionCancelled
        case timedOut
        case observerCancelled
    }

    /// Race the step dispatch against a kqueue/vnode observer over mission.json.
    /// It performs one initial canonical read to close the registration race,
    /// then sleeps without timers until the file changes. When cancel() lands
    /// (any process), the observer reports it and the
    /// coordinator cancels the in-flight step Task — no orphaned children
    /// running to private timeouts (W2).
    ///
    /// PROMPT-PREEMPTION LIMIT (gpt-5.5 executor-port #6, 2026-06-10,
    /// orchestrator disposition): group.cancelAll() delivers COOPERATIVE
    /// cancellation. A dispatch closure that never reaches a suspension/
    /// cancellation point (a wedged synchronous shim, a tight loop that
    /// swallows CancellationError) keeps running, and structured concurrency
    /// AWAITS it — the group cannot return until that child does. So PROMPT
    /// preemption depends on the closure's cooperativeness. STATE
    /// correctness does NOT: every post-step mission.json write is a
    /// compare-and-swap (casMutateMission) that re-reads the status in-lock
    /// and only transitions from "running"/"blocked_on_approval", so a
    /// late-finishing step can never overwrite a cancelled execution —
    /// pinned by cancelDuringNonCooperativeStepNeverOverwritesCancelled.
    /// Full (hard-deadline) preemption is a ledgered follow-up, not this
    /// port's scope.
    private func raceWithCancellationWatch<T: Sendable>(
        executionId: String,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // RESOLVED ONCE, AT ARM TIME (P2-1). The kqueue target is the record
        // name that exists NOW — canonical, or a legacy `mission.json` the
        // rename pass hasn't reached. It cannot be renamed out from under the
        // watcher mid-run: WorkshopStorageMigrator runs synchronously in
        // applicationDidFinishLaunching, before any executor exists, so no
        // rename ever races a live step. Watching BOTH names instead would
        // double the fd cost per in-flight step to defend against a window
        // that cannot open; and it would not even help, since a rename of the
        // watched file is itself a vnode event that FileChangeWatcher re-arms
        // on. If the file is absent entirely, FileChangeWatcher falls back to
        // the parent directory, so first-creation still wakes the observer.
        let executionRecordJSON = executionRecordPath(executionId)
        let deadlineNanos = stepTimeoutNanos
        let persistence = self.persistence
        let cancellationReadObserver = self.cancellationReadObserver
        let changes = FileChangeEvents(paths: [executionRecordJSON])
        return try await withThrowingTaskGroup(of: StepRaceEvent<T>.self) { group in
            group.addTask {
                do {
                    return .operationSucceeded(try await op())
                } catch {
                    return .operationFailed(error)
                }
            }
            group.addTask {
                defer { changes.cancel() }
                do {
                    for await _ in changes.stream {
                        try Task.checkCancellation()
                        cancellationReadObserver?()
                        let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
                        if case .object(let obj) = raw,
                           case .string(let status)? = obj["status"],
                           status == "cancelled" {
                            return .workshopExecutionCancelled
                        }
                    }
                    return .observerCancelled
                } catch is CancellationError {
                    return .observerCancelled
                }
            }
            // HARD STEP DEADLINE (the "ledgered follow-up" the comment above
            // deferred): a wedged tool (dead network, an MCP server that never
            // answers, a stalled stream) reaches NO cancel() in an unattended
            // execution, so without this it hangs the step forever — and because
            // drainOnce awaits each execution and slots are capped, enough hung
            // steps starve ALL execution throughput until restart. The deadline
            // throws WorkshopStepTimedOut → dispatchStep records a clean
            // `failed` step → the slot frees. SAME cooperative-cancellation
            // limit as the watcher: a NON-cooperative wedge (a tight sync loop
            // that never suspends) still can't be preempted — the task group
            // awaits the child at scope exit — but every realistic I/O hang is
            // cooperative and IS broken here. deadlineNanos == 0 disables it.
            if deadlineNanos > 0 {
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanos)
                        return .timedOut
                    } catch is CancellationError {
                        return .observerCancelled
                    }
                }
            }
            while let event = try await group.next() {
                switch event {
                case .operationSucceeded(let value):
                    group.cancelAll()
                    return value
                case .operationFailed(let error):
                    group.cancelAll()
                    throw error
                case .workshopExecutionCancelled:
                    group.cancelAll()
                    throw WorkshopExecutionCancelledDuringStep()
                case .timedOut:
                    group.cancelAll()
                    throw WorkshopStepTimedOut(seconds: Double(deadlineNanos) / 1_000_000_000)
                case .observerCancelled:
                    // Parent/pass cancellation also cancels the observer
                    // children. Keep waiting for the operation: a cooperative
                    // child reports CancellationError, while an operation that
                    // already completed its side effect can still return the
                    // success that must cross the durable boundary.
                    if Task.isCancelled { continue }
                    group.cancelAll()
                    throw CancellationError()
                }
            }
            throw WorkshopExecutionError.underlying("empty task group")
        }
    }

    // MARK: resume after approval (port of _resume_after_approval_locked, L1461-L1590)

    /// Resume an execution blocked on a step approval. `approved == true` must
    /// actually EXECUTE the approved step (W6: resume must never
    /// mark-without-executing), then continue the remaining plan steps.
    /// `approved == false` marks the step rejected and fails the execution.
    @discardableResult
    public func resumeAfterApproval(
        executionId: String,
        stepId: String,
        approved: Bool,
        approvalId: String? = nil
    ) async throws -> WorkshopExecutionRecord {
        // Reclaim orphans before a resume flips a blocked step to running, so
        // the first reclaim can't race a concurrent resume (gpt-5.5 review).
        await ensureOrphansReconciled()
        guard let execution = await getRecord(executionId) else {
            throw WorkshopExecutionError.invalidRequest("Workshop execution not found: \(executionId)")
        }
        let existing = Self.lastStepRecord(execution, stepId: stepId)
        let existingStatus: String = {
            if case .object(let o)? = existing, case .string(let s)? = o["status"] { return s }
            return ""
        }()
        let existingApprovalId: String = {
            if case .object(let o)? = existing, case .string(let s)? = o["approval_id"] { return s }
            return ""
        }()
        if let approvalId, !approvalId.isEmpty, !existingApprovalId.isEmpty, approvalId != existingApprovalId {
            throw WorkshopExecutionError.invalidRequest("approval_id_does_not_match_blocked_step")
        }
        if existing == nil && execution.status != "blocked_on_approval" {
            throw WorkshopExecutionError.invalidRequest("mission_step_not_waiting_on_approval")
        }
        if existingStatus == "succeeded" || existingStatus == "stubbed" {
            try await appendTimelineLocked(
                .object([
                    "event": .string("approval_decision_ignored"),
                    "step_id": .string(stepId),
                    "reason": .string("step_already_completed"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            return execution
        }
        if existingStatus == "rejected" && !approved {
            return execution
        }
        if approved && !existingStatus.isEmpty && existingStatus != "blocked_on_approval" {
            throw WorkshopExecutionError.invalidRequest("mission_step_not_waiting_on_approval:\(existingStatus)")
        }

        // gpt-5.5 executor-port blocker #3 (2026-06-10): IN-LOCK EXECUTION-
        // status precondition. The guards above check the STEP record — but
        // a CANCELLED (or failed/completed) execution can still carry a
        // blocked_on_approval step record, and its approval card stays
        // clickable. Approving that stale card must NOT execute the step or
        // flip the execution back to running. Require the EXECUTION status be
        // blocked_on_approval, read under the mission.json flock so the
        // check cannot interleave with an in-flight cancel()'s RMW. (The
        // step executes AFTER the lock is released — holding a flock across
        // a minutes-long step would block cancel(); a cancel that lands
        // DURING the resumed step is handled by the CAS writes below,
        // blocker #2.)
        let lockedStatus = try await readRecordLocked(executionId)?.status ?? ""
        guard lockedStatus == "blocked_on_approval" else {
            throw WorkshopExecutionError.staleApproval(
                "Workshop execution no longer blocked (status=\(lockedStatus.isEmpty ? "missing" : lockedStatus)) — not executed")
        }

        try await appendTimelineLocked(
            .object([
                "event": .string("approval_decision"),
                "step_id": .string(stepId),
                "approved": .bool(approved),
                "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
            ]),
            executionId: executionId
        )

        if !approved {
            // CAS from blocked_on_approval (blocker #2): a cancel that
            // landed since the precondition above wins — the cancelled
            // Workshop execution must not be flipped to failed, and the `failed` event
            // is skipped with it.
            let denyWrite = try await casMutateWorkshopExecution(executionId, require: ["blocked_on_approval"]) { rec in
                rec.stepsCompleted = rec.stepsCompleted.map { sr in
                    guard case .object(var o) = sr, case .string(let sid)? = o["step_id"], sid == stepId else { return sr }
                    o["status"] = .string("rejected")
                    return .object(o)
                }
                rec.status = "failed"
                rec.currentStepId = ""   // terminal — clear the step pointer
            }
            guard denyWrite.applied, let updated = denyWrite.record else {
                return denyWrite.record ?? execution
            }
            try await appendTimelineLocked(
                .object([
                    "event": .string("failed"),
                    "step_id": .string(stepId),
                    "error": .string("Step rejected by user"),
                    "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                ]),
                executionId: executionId
            )
            await emitTerminalEvent(updated, reason: "Step rejected by user")
            return updated
        }

        // Approved: find the plan step and EXECUTE it with the gate bypassed.
        guard let planStep = execution.plan.first(where: { $0.id == stepId }) else {
            throw WorkshopExecutionError.invalidRequest("Step \(stepId) not found in Workshop execution \(executionId)")
        }
        // CLAIM the execution OUT of blocked_on_approval into running BEFORE we
        // execute the step. This is the fix for the approval-timeout race: the
        // sweep (reconcileTimedOutApprovals) only CAS-fails blocked_on_approval
        // executions, so once we've flipped to running it can't touch us — and if
        // the sweep (or a cancel) flipped us first, THIS CAS loses and we bail
        // WITHOUT executing. Previously resume ran the step while still
        // blocked_on_approval, so the sweep could fail the execution mid-step.
        // Whoever leaves blocked_on_approval first wins under the per-execution
        // flock; the loser aborts cleanly. A crash after this claim leaves the
        // execution "running" → the startup orphan-reclaim fails it honestly,
        // instead of a half-run blocked step that re-executes on re-approval.
        let claimWrite = try await casMutateWorkshopExecution(executionId, require: ["blocked_on_approval"]) { rec in
            rec.status = "running"
        }
        guard claimWrite.applied else {
            return claimWrite.record ?? execution
        }
        let result = await dispatchStep(execution: execution, step: planStep)
        // Update (or append) the step record with the replay result —
        // daemon updates the existing dict in place (L1545-L1551). CAS from
        // running (blocker #2, post-claim): a cancel that landed while the
        // resumed step ran flips running→cancelled and wins this CAS — skip the
        // record update, the receipt, and every status write below.
        let updateWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
            var replaced = false
            rec.stepsCompleted = rec.stepsCompleted.map { sr in
                guard !replaced, case .object(var o) = sr, case .string(let sid)? = o["step_id"], sid == stepId else { return sr }
                replaced = true
                if case .object(let new) = result.toJSON() {
                    for (k, v) in new { o[k] = v }
                }
                return .object(o)
            }
            if !replaced {
                rec.stepsCompleted.append(result.toJSON())
            }
        }
        guard updateWrite.applied else {
            return updateWrite.record ?? execution
        }
        await writeReceipt(executionId: executionId, outcome: result)
        // NOTE: the daemon does NOT emit step_completed for the resumed step
        // itself (fixture 3e718ce5: approval_decision → step_completed for
        // step-2/3 only). Match it.
        if result.status == "failed" || result.status == "blocked_on_approval" || result.status == "cancelled" {
            let terminal = (result.status == "blocked_on_approval") ? "blocked_on_approval"
                : (result.status == "cancelled" ? "cancelled" : "failed")
            let terminalWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
                rec.status = terminal
                if terminal == "failed" || terminal == "cancelled" {
                    rec.currentStepId = ""   // terminal — clear the step pointer
                }
            }
            if result.status == "failed", terminalWrite.applied {
                try await appendTimelineLocked(
                    .object([
                        "event": .string("failed"),
                        "step_id": .string(stepId),
                        "error": .string(result.error),
                        "ts": .string(SwiftNativeWorkshopRunner.isoTimestamp(now())),
                    ]),
                    executionId: executionId
                )
            }
            if terminalWrite.applied && (terminal == "failed" || terminal == "cancelled") {
                await emitTerminalEvent(terminalWrite.record, reason: result.error.isEmpty ? nil : result.error)
            }
            return terminalWrite.record ?? execution
        }

        // Continue the remaining steps. The Workshop execution is already "running" (the
        // claim above); this CAS is now a GUARD, not the blocked→running flip:
        // require "running" so a cancel that landed during the resumed step
        // (running→cancelled) wins and runSteps does not proceed. The status
        // write is idempotent (running→running). (Was the blocked→running flip
        // pre-claim; the claim moved that earlier — blocker #2/#3 preserved.)
        let runWrite = try await casMutateWorkshopExecution(executionId, require: ["running"]) { rec in
            rec.status = "running"
        }
        guard runWrite.applied else {
            return runWrite.record ?? execution
        }
        try await runSteps(executionId: executionId, afterStepId: stepId)
        return await getRecord(executionId) ?? execution
    }

    // MARK: helpers

    private func getRecord(_ executionId: String) async -> WorkshopExecutionRecord? {
        let raw = await persistence.readJSON(executionRecordPath(executionId), defaultValue: .null)
        guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else { return nil }
        return SwiftNativeWorkshopRunner.recordFromJSON(obj)
    }

    private func emitTerminalEvent(_ record: WorkshopExecutionRecord?, reason: String?) async {
        guard let record, ["completed", "failed", "cancelled"].contains(record.status) else { return }
        await terminalEventSink?(record, reason)
        // Receipts first, memory second — and the memory write is HANDED OFF,
        // never awaited (gpt-5.5 review A1, BLOCKING). `recorder.record` embeds,
        // inserts, then sweeps retention; awaiting it here meant a busy SQLite
        // or a stalled embedder held the terminal path and the executor did not
        // advance to the next queued execution. The queue preserves order, keeps
        // the write, and logs its own failures at `.error`.
        // `waitForExecutionMemoryWrites()` is the seam for anyone who needs the
        // tail (shutdown, tests).
        await resolvedExecutionMemoryQueue(building: true)?.enqueue(record, reason: reason)
    }

    /// Resolve — and on first use, build — the execution-memory queue.
    /// `building: false` never constructs one, so the wait seam cannot create a
    /// queue (and thus touch `SwiftNativeMemoryV2.shared`) as a side effect.
    private func resolvedExecutionMemoryQueue(building: Bool) -> WorkshopExecutionMemoryQueue? {
        if let executionMemoryQueue { return executionMemoryQueue }
        guard building, let recorder = executionMemoryProvider() else { return nil }
        let queue = WorkshopExecutionMemoryQueue(recorder: recorder)
        executionMemoryQueue = queue
        return queue
    }

    /// Await every execution-memory write handed off so far. Nothing on the
    /// execution path calls this — it exists so shutdown and tests can observe
    /// a lane that is deliberately off the hot path.
    ///
    /// `timeout` is the SHUTDOWN CONTRACT (gpt-5.5 review, BLOCKING 1,
    /// 2026-08-02). Production quit stops loops, MCP, context and cognition
    /// under a 3s budget and never drained this queue, so a terminal execution
    /// whose write was still in embed/SQLite left `mission.json` on disk with
    /// no memory behind it — silently. Draining fixes that; draining
    /// UNBOUNDED would trade a lost memory for a hung quit, so an unfinished
    /// drain is ABANDONED at the deadline and says so at `.error`.
    ///
    /// Returns true when the tail actually drained. `nil` timeout = wait
    /// forever (tests).
    @discardableResult
    public func waitForExecutionMemoryWrites(timeout: TimeInterval? = nil) async -> Bool {
        guard let queue = resolvedExecutionMemoryQueue(building: false) else { return true }
        guard let timeout, timeout.isFinite, timeout > 0 else {
            await queue.drain()
            return true
        }
        let gate = WorkshopExecutionMemoryGate()
        let drain = Task.detached(priority: .utility) {
            await queue.drain()
            gate.signal(true)
        }
        let timer = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(min(timeout, 3600) * 1_000_000_000))
            gate.signal(false)
        }
        let drained = await gate.wait()
        // The drain task is deliberately NOT cancelled on timeout: the write may
        // still land before the process actually exits, and cancelling it could
        // only make the loss more certain.
        timer.cancel()
        if !drained {
            let pending = await queue.pendingCount()
            Self.logger.error(
                """
                [workshop-memory] shutdown drain ABANDONED after \(timeout, privacy: .public)s with \
                \(pending, privacy: .public) execution-memory write(s) still pending — those executions are on \
                disk and she will not remember them.
                """
            )
        }
        _ = drain
        return drained
    }

    /// CRASH RECONCILIATION — the other half of BLOCKING 1.
    ///
    /// A bounded drain covers a clean quit. A crash (or a kill inside the
    /// shutdown budget) still ends with a terminal `mission.json` and no memory
    /// row, and nothing ever went back for it. This does, at launch.
    ///
    /// BOUNDED, TWICE, and here is the choice: only executions whose record was
    /// last written inside `within` (default 7 days) are considered, and at most
    /// `maxRecords` (default 100) of them, newest first. 7 days because the loss
    /// window it repairs is "the last time this app was killed", not "all of
    /// history", and because the store's own execution lane only keeps
    /// `retentionCap` (200) rows anyway — rescanning a year of executions on
    /// every launch would read hundreds of files to re-mint memories retention
    /// is about to archive. The scan reads directory MODIFICATION DATES first
    /// and only opens `mission.json` for the survivors, so the file reads are
    /// bounded by `maxRecords`, not by the size of the history.
    ///
    /// Returns the number of executions handed to the write queue.
    @discardableResult
    public func reconcileMissedExecutionMemories(
        within: TimeInterval = 7 * 24 * 3600,
        maxRecords: Int = 100
    ) async -> Int {
        guard maxRecords > 0 else { return 0 }
        let cutoff = now().addingTimeInterval(-max(0, within))
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: executionRecordsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Cheap pass: dates only, no JSON reads.
        let recent: [(url: URL, modified: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true else { return nil }
            guard let modified = values.contentModificationDate, modified >= cutoff else { return nil }
            return (url, modified)
        }
        .sorted { $0.modified > $1.modified }
        .prefix(maxRecords)
        .map { $0 }
        // Resolve the queue only once there is something to reconcile: on the
        // production root, building it opens the MemoryV2 SQLite store, and a
        // launch with no recent executions should not pay for that here.
        guard !recent.isEmpty, let queue = resolvedExecutionMemoryQueue(building: true) else { return 0 }

        // KNOWN EDGE, deliberately accepted: `recordedSources` sees ACTIVE rows
        // only, so an execution whose memory retention already ARCHIVED reads as
        // missing and gets re-written. It costs one duplicate narrative at
        // worst (`store()` collapses byte-identical content), and it only
        // reaches a row that is both inside the 7-day window AND already past
        // the 200-row cap — i.e. 200+ executions in a week. Widening the read to
        // archived rows would trade that for re-reading retired history on
        // every launch, which is the cost this window exists to avoid.
        let known = await queue.recordedSources()
        var reconciled = 0
        for entry in recent {
            let raw = await persistence.readJSON(
                ExecutionRecordFile.resolve(in: entry.url), defaultValue: .null
            )
            guard case .object(let object) = raw,
                  case .string(let id)? = object["id"], !id.isEmpty else { continue }
            let record = SwiftNativeWorkshopRunner.recordFromJSON(object)
            guard ["completed", "failed", "cancelled"].contains(record.status) else { continue }
            guard case .remember = WorkshopExecutionMemory.decide(record) else { continue }
            guard !known.contains(WorkshopExecutionMemory.source(for: record)) else { continue }
            Self.logger.info(
                """
                [workshop-memory] reconcile: terminal execution \(id, privacy: .public) \
                (status \(record.status, privacy: .public)) has no memory — re-queuing the write \
                that a crash or a killed shutdown lost.
                """
            )
            await queue.enqueue(record, reason: nil)
            reconciled += 1
        }
        if reconciled > 0 {
            Self.logger.info(
                "[workshop-memory] reconcile: re-queued \(reconciled, privacy: .public) missed execution memories"
            )
        }
        return reconciled
    }

    private func scanQueue() async -> [WorkshopExecutionRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: executionRecordsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        var out: [WorkshopExecutionRecord] = []
        for sub in entries {
            let isDir = (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let raw = await persistence.readJSON(
                ExecutionRecordFile.resolve(in: sub, fileManager: fm), defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else { continue }
            out.append(SwiftNativeWorkshopRunner.recordFromJSON(obj))
        }
        return out
    }

    /// Compare-and-swap mission.json mutation (gpt-5.5 executor-port
    /// blocker #2, 2026-06-10). The WHOLE read-check-mutate-write runs
    /// inside ONE cross-process withFileLock(mission.json) critical section,
    /// and the mutation only applies when the IN-LOCK status is in
    /// `require`. A cancel() — or any other transition — that landed since
    /// the caller's last (unlocked) read therefore WINS: the stale write is
    /// aborted, and `applied == false` tells the caller to skip the
    /// dependent receipt/timeline appends. This is what makes the
    /// terminal/blocked status writes safe against the
    /// cancel-lands-between-guard-and-write race the old unconditional
    /// mutate had.
    ///
    /// Returns (post-write record, true) when the swap applied;
    /// (latest on-disk record, false) when the status precondition failed;
    /// (nil, false) when mission.json is absent/malformed.
    @discardableResult
    private func casMutateWorkshopExecution(
        _ executionId: String,
        require allowedStatuses: Set<String>,
        _ mutate: @escaping @Sendable (inout WorkshopExecutionRecord) -> Void
    ) async throws -> (record: WorkshopExecutionRecord?, applied: Bool) {
        let executionRecordJSON = executionRecordPath(executionId)
        let nowStr = SwiftNativeWorkshopRunner.isoTimestamp(now())
        let work: @Sendable () async throws -> (WorkshopExecutionRecord?, Bool) = { [persistence] in
            let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                return (nil, false)
            }
            var record = SwiftNativeWorkshopRunner.recordFromJSON(obj)
            guard allowedStatuses.contains(record.status) else {
                return (record, false)   // CAS lost — concurrent transition wins
            }
            mutate(&record)
            record.updatedAt = nowStr
            try await persistence.writeJSON(record.toJSON(), to: executionRecordJSON)
            return (record, true)
        }
        do {
            // Uniform locking (L7, 2026-08-01): `withFileLock` is a
            // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
            // every conformer already has it. The old downcast to
            // SwiftNativePersistenceCore only had the effect of running this critical
            // section UNLOCKED for any other conformer.
            return try await persistence.withFileLock(executionRecordJSON, work)
        } catch let e as WorkshopExecutionError {
            throw e
        } catch {
            throw WorkshopExecutionError.persistenceFailure("executor mission.json write failed: \(error)")
        }
    }

    /// Read mission.json under its cross-process flock — a quiesced-point
    /// read for in-lock status preconditions (cannot interleave with a
    /// concurrent RMW's read→write window). Used by resumeAfterApproval's
    /// blocked_on_approval precondition (blocker #3).
    private func readRecordLocked(_ executionId: String) async throws -> WorkshopExecutionRecord? {
        let executionRecordJSON = executionRecordPath(executionId)
        let work: @Sendable () async throws -> WorkshopExecutionRecord? = { [persistence] in
            let raw = await persistence.readJSON(executionRecordJSON, defaultValue: .null)
            guard case .object(let obj) = raw, case .string(let gotId)? = obj["id"], !gotId.isEmpty else {
                return nil
            }
            return SwiftNativeWorkshopRunner.recordFromJSON(obj)
        }
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        return try await persistence.withFileLock(executionRecordJSON, work)
    }

    /// Same cross-process `<timeline>.lock` flock the runner + daemon take
    /// on every timeline append (SwiftNativeWorkshopRunner.appendTimelineLocked).
    private func appendTimelineLocked(_ event: JSONValue, executionId: String) async throws {
        let timeline = timelinePath(executionId)
        // Uniform locking (L7, 2026-08-01): `withFileLock` is a
        // PersistenceCoreProtocol EXTENSION (PersistenceCore+FileLock.swift:4), so
        // every conformer already has it. The old downcast to
        // SwiftNativePersistenceCore only had the effect of running this critical
        // section UNLOCKED for any other conformer.
        let core = persistence
        try await core.withFileLock(timeline) {
            try await core.appendJSONL(event, to: timeline)
        }
    }

    /// Sanitize a PLANNER-DERIVED string for use as a single filename
    /// component (gpt-5.5 executor-port blocker #5, 2026-06-10). Step ids
    /// come from LLM planner output and are kept VERBATIM by the plan
    /// parsers (WorkshopExecution.swift parsePlanJSON / parsePlanSteps), so a step id
    /// like "../execution" would escape receiptsDir. Whitelist [A-Za-z0-9._-];
    /// every other scalar becomes "_"; empty input → nil (caller must
    /// reject). Capped at 180 chars so the ".json"-suffixed name stays under
    /// the 255-byte filename limit. The caller-appended ".json" suffix also
    /// means a residual "." / ".." can never form a relative path component.
    static func sanitizedPathComponent(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let mapped = String(String.UnicodeScalarView(
            raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return String(mapped.prefix(180))
    }

    /// Per-step receipt: <receiptsDir>/<sanitized step_id>.json with the
    /// full outcome. The daemon-era executor created receipts/ but never
    /// populated it; the build plan makes the receipt write explicit in the
    /// Swift port. Best-effort: a receipt IO failure must not fail the step
    /// (the durable record is steps_completed in mission.json).
    /// SECURITY (blocker #5): stepId is planner-derived — sanitize before it
    /// becomes a path component so "../execution" cannot escape receiptsDir.
    private func writeReceipt(executionId: String, outcome: WorkshopStepOutcome) async {
        guard outcome.status != "blocked_on_approval" else { return }  // not executed
        guard let safeStepId = Self.sanitizedPathComponent(outcome.stepId) else {
            Self.logger.info("receipt skipped for \(executionId, privacy: .public): empty step id")
            return
        }
        let dir = receiptsDir(executionId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(safeStepId).json")
        do {
            try await persistence.writeJSON(outcome.toJSON(), to: path)
        } catch {
            Self.logger.info("receipt write failed for \(executionId, privacy: .public)/\(outcome.stepId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Synthesize-output validation verdict (2026-06-11).
    enum SynthesizeVerdict: Equatable { case ok, refusal, empty }

    /// Refusal phrases. CONSERVATIVE on purpose — false-FAIL is worse than
    /// false-pass for long executions (a wrongly-failed synthesize step burns a
    /// whole execution), so a phrase here only triggers a refusal when it ALSO
    /// co-occurs with a SHORT, non-substantive body (see validateSynthesizeOutput).
    /// A legitimate answer that merely MENTIONS access ("the file you can't
    /// access from iOS is X, here is its content: ...") is long + substantive,
    /// so it passes. Lowercased-substring match.
    ///
    /// Every phrase is REFUSAL-SHAPED ("I" + inability verb) — no bare
    /// fragment like "as an ai" alone (gpt-5.5 review 2026-06-11: a short
    /// synthesis QUOTING source text could carry such a fragment). "as an ai"
    /// only fires bundled with an inability verb ("as an ai i can't/cannot...").
    static let synthesizeRefusalPhrases: [String] = [
        "i can't access",
        "i cannot access",
        "i can't directly access",
        "i cannot directly access",
        "i don't have access",
        "i do not have access",
        "i don't have the ability",
        "i do not have the ability",
        "i'm unable to",
        "i am unable to",
        "i'm not able to",
        "i am not able to",
        "as an ai, i can't",
        "as an ai, i cannot",
        "as an ai i can't",
        "as an ai i cannot",
        "as an ai language model",
        "i can't help with that",
        "i cannot help with that",
    ]

    /// Length (chars, trimmed) at/above which a body is considered
    /// "substantive" — a refusal phrase inside a long answer is treated as
    /// the answer merely DISCUSSING access, not refusing. 220 chars is a
    /// couple of sentences: well above a bare "I can't access your filesystem,
    /// here's some jq instead." brush-off, well below a real synthesis.
    static let synthesizeSubstantiveLength = 220

    /// Validate a synthesize step's text BEFORE scoring it succeeded.
    ///   - empty / whitespace-only / "returned no results"-class → `.empty`.
    ///   - a refusal phrase in a SHORT body (the model gave up for lack of
    ///     access) → `.refusal`.
    ///   - everything else (including a long answer that mentions access) → `.ok`.
    static func validateSynthesizeOutput(_ text: String) -> SynthesizeVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let lower = trimmed.lowercased()
        // A body that is BOTH short AND carries a refusal phrase is a refusal.
        // Long bodies are substantive regardless of an incidental mention.
        if trimmed.count < synthesizeSubstantiveLength {
            for phrase in synthesizeRefusalPhrases where lower.contains(phrase) {
                return .refusal
            }
        }
        return .ok
    }

    /// Port of _extract_mission_result.
    static func extractWorkshopExecutionResult(_ execution: WorkshopExecutionRecord) -> JSONValue {
        guard case .object(let last)? = execution.stepsCompleted.last else { return .null }
        let output = last["output"] ?? .null
        switch output {
        case .object(let o):
            if case .string(let text)? = o["text"] { return .string(text) }
            if case .object(let inner)? = o["output"] {
                if case .string(let text)? = inner["text"] { return .string(text) }
                return .string((try? JSONValue.object(inner).serialize(pretty: false)) ?? "")
            }
            return .string((try? JSONValue.object(o).serialize(pretty: false)) ?? "")
        case .string(let s):
            return .string(s)
        default:
            return .null
        }
    }

    /// Port of the calibrate-6 prompt builder:
    /// inject prior step outputs so the synthesize/report step works from
    /// receipts instead of confabulating.
    static func buildLLMPrompt(execution: WorkshopExecutionRecord, step: WorkshopExecutionStep) -> String {
        let basePrompt: String = {
            if case .object(let args) = step.args {
                // The canonical planner historically emitted both `prompt`
                // and `text` for synthesis steps. Treat them as equivalent
                // input-schema aliases at the executor boundary so a valid
                // planned instruction cannot silently collapse to the short
                // step description.
                for key in ["prompt", "text"] {
                    if case .string(let value)? = args[key],
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
            }
            return step.description
        }()
        let priorSteps: [[String: JSONValue]] = execution.stepsCompleted.compactMap { sr in
            guard case .object(let o) = sr else { return nil }
            if case .string(let sid)? = o["step_id"], sid == step.id { return nil }
            return o
        }
        guard !priorSteps.isEmpty else { return basePrompt }
        var planToolMap: [String: String] = [:]
        for pd in execution.plan { planToolMap[pd.id] = pd.toolOrAction }
        let contextLines = priorSteps.map { sr -> String in
            let sid: String = {
                if case .string(let s)? = sr["step_id"] { return s }
                return "?"
            }()
            let toolName = planToolMap[sid] ?? sid
            let summary = summarizeStepOutput(sr["output"] ?? .null)
            return "[step \(sid) via \(toolName)]: \(summary)"
        }
        let contextBlock = contextLines.joined(separator: "\n")
        return """
            You are completing a step in a multi-step Workshop execution.

            Workshop task objective: \(execution.objective)

            Prior step outputs (your work so far):
            \(contextBlock)

            Your current step: \(basePrompt)

            If prior steps returned empty / useless results, acknowledge that explicitly rather than filling in plausible content. The user prefers honest "I couldn't find that" over fabricated synthesis.

            Produce the output for this step.
            """
    }

    /// Substitute `{{step:<id>}}` tokens in a tool step's args with the FULL
    /// text output of the referenced completed step. The planner emits these
    /// tokens (see planWorkshopExecution) so a tool step — typically write_file — can
    /// consume a PRIOR step's output. chat.synthesize steps don't need it
    /// (buildLLMPrompt already threads prior outputs into their prompt); this is
    /// the tool-arg equivalent. Contract is a flat string-valued args object
    /// (planner rule), so only top-level string values are scanned. An id with
    /// no matching completed step is left VERBATIM — honest (the unresolved
    /// token is visible) rather than silently blanking. Pure when no token is
    /// present, preserving prior behaviour for every existing plan. (2026-06-15)
    static func resolveStepReferences(in args: JSONValue, execution: WorkshopExecutionRecord) -> JSONValue {
        guard case .object(let obj) = args else { return args }
        // id -> full output text for every completed step (last write wins, so a
        // re-run step resolves to its latest output).
        var outputs: [String: String] = [:]
        for sr in execution.stepsCompleted {
            guard case .object(let o) = sr, case .string(let sid)? = o["step_id"] else { continue }
            outputs[sid] = fullStepOutputText(o["output"] ?? .null)
        }
        guard !outputs.isEmpty else { return args }
        // SINGLE-PASS, left-to-right: each {{step:id}} is replaced exactly once
        // and the inserted text is NEVER re-scanned. A naive loop of
        // replacingOccurrences would re-expand a token that happens to appear
        // INSIDE a prior step's output (gpt-5.5 review, 2026-06-15) — order-
        // dependent corruption. Unknown id and unterminated token are left
        // verbatim (honest).
        func substitute(_ s: String) -> String {
            guard s.contains("{{step:") else { return s }
            var result = ""
            var rest = Substring(s)
            while let open = rest.range(of: "{{step:") {
                result += rest[..<open.lowerBound]
                let afterOpen = rest[open.upperBound...]
                guard let close = afterOpen.range(of: "}}") else {
                    result += rest[open.lowerBound...]   // unterminated → verbatim
                    return result
                }
                let sid = String(afterOpen[..<close.lowerBound])
                if let text = outputs[sid] {
                    result += text                        // NOT rescanned
                } else {
                    result += "{{step:\(sid)}}"           // unknown id → verbatim
                }
                rest = afterOpen[close.upperBound...]
            }
            result += rest
            return result
        }
        var newObj: [String: JSONValue] = [:]
        for (k, v) in obj {
            if case .string(let s) = v {
                newObj[k] = .string(substitute(s))
            } else {
                newObj[k] = v
            }
        }
        return .object(newObj)
    }

    /// Full (untruncated) text of a step output, for `{{step:id}}` substitution.
    /// Mirrors summarizeStepOutput's extraction but returns the raw text with no
    /// 500-char cap and no "returned no results" sentinel — an empty/absent
    /// output substitutes as the empty string (so an empty prior step yields an
    /// empty insert, not the literal words "returned no results").
    static func fullStepOutputText(_ output: JSONValue) -> String {
        switch output {
        case .null:
            return ""
        case .string(let s):
            return s
        case .object(let o):
            if case .string(let t)? = o["text"] { return t }
            if case .object(let inner)? = o["output"] {
                if case .string(let t)? = inner["text"] { return t }
                return (try? JSONValue.object(inner).serialize(pretty: false)) ?? ""
            }
            if case .string(let t)? = o["output"] { return t }
            return (try? JSONValue.object(o).serialize(pretty: false)) ?? ""
        default:
            return (try? output.serialize(pretty: false)) ?? ""
        }
    }

    /// Port of _summarize_step_output.
    static func summarizeStepOutput(_ output: JSONValue, maxChars: Int = 500) -> String {
        let text: String
        switch output {
        case .null:
            return "returned no results"
        case .string(let s):
            text = s
        case .object(let o):
            if case .string(let t)? = o["text"] {
                text = t
            } else if case .object(let inner)? = o["output"] {
                if case .string(let t)? = inner["text"] {
                    text = t
                } else if inner.isEmpty {
                    return "returned no results"
                } else {
                    text = (try? JSONValue.object(inner).serialize(pretty: false)) ?? ""
                }
            } else if o.isEmpty {
                return "returned no results"
            } else {
                text = (try? JSONValue.object(o).serialize(pretty: false)) ?? ""
            }
        default:
            text = (try? output.serialize(pretty: false)) ?? ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "returned no results" }
        if trimmed.count > maxChars {
            return String(trimmed.prefix(maxChars)) + "…"
        }
        return trimmed
    }

    /// Last steps_completed record for a step id (daemon _step_record,
    /// reversed scan L686-L690).
    static func lastStepRecord(_ execution: WorkshopExecutionRecord, stepId: String) -> JSONValue? {
        for sr in execution.stepsCompleted.reversed() {
            if case .object(let o) = sr, case .string(let sid)? = o["step_id"], sid == stepId {
                return sr
            }
        }
        return nil
    }
}
