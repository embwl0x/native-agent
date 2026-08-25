import Foundation
import CryptoKit
import ApprovalInbox
import MCPDispatcher
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Research
import SystemOps
import ToolExecution

// MARK: - Subsystem #22 wave 30 (2026-06-01) — WorkflowOrchestration READ-SIDE port
//
// PORTED-DORMANT (default OFF). This module natively serves the TWO read-side
// workflow routes that are LIVE in the Mac UI via NativeClient:
//
//   • GET /v1/workflows       → NativeClient.getWorkflows()      (line ~3770)
//   • GET /v1/workflows/runs  → NativeClient.getWorkflowRuns()   (line ~3774)
//
// The list path mirrors Runtime.list_workflows EXACTLY:
//   1. read workflows/registry.json (default []),
//   2. merge each built-in default with its saved override (saved keys win),
//   3. append saved-only items not present in defaults,
//   4. WRITE BACK the merged (unsorted) list to registry.json,
//   5. RETURN the merged list sorted by (updatedAt | createdAt | "") DESC.
//
// The runs path mirrors Runtime.list_workflow_runs: tail_jsonl(runs.jsonl, 50)
// then reversed (newest first).
//
// PORTED-DORMANT (wave 32 W12, default OFF): POST /v1/workflows/cancel and
// POST /v1/workflows/rollback. Both are SELF-CONTAINED state-machine
// terminals — they read the per-run state file (workflows/run_state/<slug>.json),
// flip a handful of fields, persist, append one trace event, and return the
// public run view. NEITHER touches the execute_workflow_step engine. They
// mirror Runtime.cancel_workflow_run / Runtime.rollback_workflow_run EXACTLY.
//
// PORTED-DORMANT (wave 34 W11, default OFF): POST /v1/workflows (create_workflow).
// PURE persistence + two side-effects (record_activity + record_trace) — NO
// engine. It normalizes the request body into a workflow record (slugify id +
// per-step normalization, the `[:120]`/`[:1000]`/`[:200]`/`[:160]`/`[:80]`
// code-point caps, loud refusal above 24 steps, the empty-steps "plan" default), does a
// flock-wrapped read->merge->filter-same-id->append->write of registry.json
// (the SAME _list_workflows_locked merge as listWorkflows, then the create
// overwrite — all in ONE lock acquisition), then emits the activity feed +
// trace receipts. Mirrors Runtime.create_workflow EXACTLY (the retired daemon
// 6927-6983). Callers today: script/smoke_all.sh + script/test.sh only (no
// Mac-UI NativeClient.createWorkflow method exists). FLIP PREREQ: identical to
// the listWorkflows registry-write prereq (cross-process flock on
// workflows/registry.json shared with every Python writer) — already satisfied
// by the W12 flock work. See CUTOVER_PLAN.md §6.97.
//
// WIRED (2026-06-03): POST /v1/workflows/run and /resume now execute in Swift.
// The v1 path remains for legacy dry-run and approval-free live receipts. Any
// approval-bearing live v1 definition is healed onto v2, which owns the
// continue_workflow_v2 state machine: conditions, dependsOn blocking, retry
// attempts, approval pause/resume, output-key wiring, run-state persistence,
// terminal cancel/rollback stale-write guards, run ledger appends, and traces.
// Supported live step kinds route to Swift modules: router (SystemOps),
// research (Research), memory writes (MemoryV2), trace append, mcp_tool with
// consent/risk gating (MCPDispatcher), and approval creation (ApprovalInbox).
// `tool_run` routes through ToolExecution's promoted-tool sandbox runner.
//
// KEPT (not represented here, no Mac-UI HTTP caller): the /v1/agent/swarms +
// /v1/agent/swarms/run routes (smoke-script only).
//
// Registry write-back is wrapped in the Swift persistence lock so create/run/list
// mutations do not trample each other.
//
// FLIP PREREQ (cancel/rollback): both write the per-run state file
// workflows/run_state/<slug>.json, which the Python engine ALSO mutates via
// Runtime.save_workflow_state (run_workflow_v2 / continue_workflow_v2 / resume /
// cancel / rollback). The native writes here are flock-wrapped (useFileLock).
// Wave 32 W12 ALSO added `with file_lock(...)` to Python's save_workflow_state so
// the two sides share the same .lock convention. Until BOTH the registry-side
// prereq above AND the state-file flock are confirmed in the running daemon, the
// flag stays DORMANT. See CUTOVER_PLAN.md §6.87.

// MARK: - Client protocol

public protocol WorkflowOrchestrationClient: Sendable {
    /// GET /v1/workflows — returns the defaults-merged registry, sorted by
    /// (updatedAt | createdAt | "") DESC. As a side effect, persists the merged
    /// (unsorted) registry back to disk (matches retired write-back semantics).
    func listWorkflows() async throws -> [JSONValue]
    /// POST /v1/workflows — normalize the request body into a workflow record,
    /// persist it into the registry (replacing any same-id row), emit the
    /// activity + trace side-effects, and return the saved record. Mirrors
    /// Runtime.create_workflow.
    func createWorkflow(_ body: JSONValue) async throws -> JSONValue
    /// GET /v1/workflows/runs — returns the last 50 run records, newest first.
    func listWorkflowRuns() async throws -> [JSONValue]
    /// POST /v1/workflows/run — run a workflow in Swift. Mirrors
    /// Uses durable v2 by default and heals legacy approval-bearing live runs
    /// onto it; unsupported `tool_run` steps fail rather than pretending.
    func runWorkflow(id: String, objective: String, execute: Bool, engineVersion: String?, variables: JSONValue?) async throws -> JSONValue
    /// POST /v1/workflows/resume — resolve or resume a v2 run waiting on an
    /// approval. Approved gates continue; denied/canceled gates settle the run
    /// durably. A recovered in-flight attempt is never replayed blindly.
    func resumeWorkflowRun(id: String) async throws -> JSONValue
    /// POST /v1/workflows/cancel — mark a run-state terminal as `canceled`,
    /// persist, and return the public run view. Mirrors Runtime.cancel_workflow_run.
    func cancelWorkflowRun(id: String) async throws -> JSONValue
    /// POST /v1/workflows/rollback — record compensation receipts for every
    /// succeeded step, mark the run `rolled_back`, persist, and return the
    /// public run view merged with `rollbackReceipts`. Mirrors
    /// Runtime.rollback_workflow_run.
    func rollbackWorkflowRun(id: String) async throws -> JSONValue
}

/// Read-side evidence for the workflow run-ledger family.  The UI's compact
/// run list intentionally remains a last-50 projection, but operations and
/// diagnostics must not mistake an absent, damaged, or unavailable backing
/// source for a real empty workflow history.
public enum WorkflowRunLedgerFeedSource: Sendable, Equatable {
    case absent
    case available
    /// Some valid evidence was retained, but one or more records could not be
    /// decoded.  Consumers may show the valid rows only when they also disclose
    /// this count.
    case partial(malformedRecords: Int)
    case unavailable(reason: String)
}

/// The bounded, durable workflow feed as actually read by
/// `SwiftNativeWorkflowOrchestrationClient`.  This is intentionally a summary
/// of the three co-owned stores rather than a second ledger: `runs.jsonl` is
/// append history, `registry.json` defines what may run, and `run_state/` owns
/// in-progress state across relaunch.
public struct WorkflowRunLedgerFeedFamily: Sendable, Equatable {
    public let recentRuns: [JSONValue]
    public let runsSource: WorkflowRunLedgerFeedSource
    public let registrySource: WorkflowRunLedgerFeedSource
    public let runStateSource: WorkflowRunLedgerFeedSource
    public let registryStatusCounts: [String: Int]
    public let unsupportedStepKinds: [String: Int]
    public let runStatusCounts: [String: Int]
    public let runStateStatusCounts: [String: Int]
    public let staleNonTerminalRunStateIDs: [String]

    public init(
        recentRuns: [JSONValue],
        runsSource: WorkflowRunLedgerFeedSource,
        registrySource: WorkflowRunLedgerFeedSource,
        runStateSource: WorkflowRunLedgerFeedSource,
        registryStatusCounts: [String: Int],
        unsupportedStepKinds: [String: Int],
        runStatusCounts: [String: Int],
        runStateStatusCounts: [String: Int],
        staleNonTerminalRunStateIDs: [String]
    ) {
        self.recentRuns = recentRuns
        self.runsSource = runsSource
        self.registrySource = registrySource
        self.runStateSource = runStateSource
        self.registryStatusCounts = registryStatusCounts
        self.unsupportedStepKinds = unsupportedStepKinds
        self.runStatusCounts = runStatusCounts
        self.runStateStatusCounts = runStateStatusCounts
        self.staleNonTerminalRunStateIDs = staleNonTerminalRunStateIDs
    }
}

// MARK: - Execution preflight

/// Canonical answer to whether a workflow record represents an executable
/// capability in the current Swift runtime. This is deliberately separate
/// from the step executor: callers must be able to hide/reject guaranteed
/// failures before creating run state or receipts.
public struct WorkflowExecutionAvailability: Sendable, Equatable {
    public let isRunnable: Bool
    public let reasons: [String]
    public let unsupportedStepKinds: [String]

    public init(isRunnable: Bool, reasons: [String], unsupportedStepKinds: [String]) {
        self.isRunnable = isRunnable
        self.reasons = reasons
        self.unsupportedStepKinds = unsupportedStepKinds
    }

    public var detail: String {
        reasons.joined(separator: "; ")
    }
}

/// One checked eligibility projection for the three mutable controls attached
/// to a durable v2 run. The view may render these reasons, but the workflow
/// client re-evaluates them under the run-state lock before changing bytes.
/// A disabled button is convenience; it is never the authority.
public struct WorkflowRunControlEligibility: Sendable, Equatable {
    public let isEligible: Bool
    public let detail: String

    public init(isEligible: Bool, detail: String) {
        self.isEligible = isEligible
        self.detail = detail
    }
}

public struct WorkflowRunControlAvailability: Sendable, Equatable {
    public let resume: WorkflowRunControlEligibility
    public let cancel: WorkflowRunControlEligibility
    public let rollback: WorkflowRunControlEligibility

    public init(
        resume: WorkflowRunControlEligibility,
        cancel: WorkflowRunControlEligibility,
        rollback: WorkflowRunControlEligibility
    ) {
        self.resume = resume
        self.cancel = cancel
        self.rollback = rollback
    }

    /// The UI renders this when the current state has no useful next control,
    /// so a terminal/refused run is an explicit condition rather than three
    /// buttons that simply do nothing.
    public var firstIneligibleDetail: String? {
        [resume, cancel, rollback].first(where: { !$0.isEligible })?.detail
    }
}

/// Shared state-machine vocabulary for mounted Run / Resume / Cancel /
/// Rollback controls. Approval decisions remain authoritative in
/// ApprovalInbox; this projection only describes what the currently read
/// decision makes possible.
public enum WorkflowRunControlPreflight {
    public static func evaluate(
        status rawStatus: String?,
        approvalDecision rawApprovalDecision: String? = nil
    ) -> WorkflowRunControlAvailability {
        let status = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let displayedStatus = status.isEmpty ? "missing" : status
        let approvalDecision = rawApprovalDecision?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let resume: WorkflowRunControlEligibility
        if status != "waiting_approval" {
            resume = WorkflowRunControlEligibility(
                isEligible: false,
                detail: "Resume is available only while the run is waiting for approval (current: \(displayedStatus))."
            )
        } else if approvalDecision == "approved" {
            resume = WorkflowRunControlEligibility(
                isEligible: true,
                detail: "Approval is approved; resume will claim and continue this run."
            )
        } else if approvalDecision == "denied" || approvalDecision == "canceled" {
            resume = WorkflowRunControlEligibility(
                isEligible: true,
                detail: "Approval is \(approvalDecision); resume will record the terminal refusal."
            )
        } else if approvalDecision.isEmpty {
            resume = WorkflowRunControlEligibility(
                isEligible: false,
                detail: "Resume is waiting for an approval decision."
            )
        } else {
            resume = WorkflowRunControlEligibility(
                isEligible: false,
                detail: "Resume is unavailable because the approval decision `\(approvalDecision)` is not recognized."
            )
        }

        let cancellable = ["queued", "ready", "running", "waiting_approval", "blocked"].contains(status)
        let cancel = WorkflowRunControlEligibility(
            isEligible: cancellable,
            detail: cancellable
                ? "Cancel will durably stop this \(displayedStatus) run."
                : "Cancel is unavailable after the run is \(displayedStatus)."
        )

        let rollbackEligible = ["succeeded", "failed", "canceled"].contains(status)
        let rollback = WorkflowRunControlEligibility(
            isEligible: rollbackEligible,
            detail: rollbackEligible
                ? "Rollback will record compensation for succeeded steps."
                : "Rollback is available only after a succeeded, failed, or canceled run (current: \(displayedStatus))."
        )

        return WorkflowRunControlAvailability(resume: resume, cancel: cancel, rollback: rollback)
    }
}

/// One owner for the live executor's supported vocabulary. UI, native
/// actions, and direct runtime calls all consult this preflight instead of
/// independently guessing whether a row can run.
public enum WorkflowExecutionPreflight {
    public static let supportedStepKinds: Set<String> = [
        "approval", "mcp_tool", "memory", "research", "router", "tool_run", "trace",
    ]

    public static func evaluate(status: String?, stepKinds: [String?]) -> WorkflowExecutionAvailability {
        let normalizedStatus = status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var reasons: [String] = []
        if let normalizedStatus, !normalizedStatus.isEmpty, normalizedStatus != "active" {
            reasons.append("status is \(normalizedStatus)")
        }

        let normalizedKinds = stepKinds.map { raw -> String in
            let kind = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return kind.isEmpty ? "manual" : kind
        }
        let unsupported = Array(Set(normalizedKinds.filter { !supportedStepKinds.contains($0) })).sorted()
        if !unsupported.isEmpty {
            reasons.append("unsupported step kinds: \(unsupported.joined(separator: ", "))")
        }
        if normalizedKinds.isEmpty {
            reasons.append("workflow has no steps")
        }

        return WorkflowExecutionAvailability(
            isRunnable: reasons.isEmpty,
            reasons: reasons,
            unsupportedStepKinds: unsupported
        )
    }

    public static func evaluate(workflow: JSONValue) -> WorkflowExecutionAvailability {
        guard case .object(let object) = workflow else {
            return WorkflowExecutionAvailability(
                isRunnable: false,
                reasons: ["workflow record is not an object"],
                unsupportedStepKinds: []
            )
        }
        let status: String? = {
            guard case .string(let value)? = object["status"] else { return nil }
            return value
        }()
        let steps: [JSONValue] = {
            guard case .array(let value)? = object["steps"] else { return [] }
            return value
        }()
        let kinds = steps.map { step -> String? in
            guard case .object(let object) = step,
                  case .string(let value)? = object["kind"] else { return nil }
            return value
        }
        return evaluate(status: status, stepKinds: kinds)
    }
}
