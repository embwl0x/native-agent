import Foundation
import PersistenceCore

// MARK: - WorkflowOrchestration — registry half
//
// RETIRED 2026-09-01: User authorized retiring the workflow RUN engine.
//
// Evidence at retirement: data/workflows/runs.jsonl held 42 runs, all frozen
// since 2026-05-08 (17 of them permanently `waiting_approval`);
// workflows/registry.json held 5 records, none of which had ever been
// instantiated by a user; the module's own create/cancel/rollback paths were
// labelled PORTED-DORMANT (default OFF) across 16 markers in 8 files; and
// `getWorkflowRuns()` was polled on every AppModel refresh purely to render a
// list that could not change. The live successor for "do a piece of work" is
// workshop/executions.
//
// What went: runWorkflow / resumeWorkflowRun / cancelWorkflowRun /
// rollbackWorkflowRun / listWorkflowRuns, the v1 and v2 step executors, the
// per-run state machine (workflows/run_state), the run ledger append, the run
// ledger feed family, the run-control preflight, the execution preflight, the
// motor-action projection over runs, and every Mac-UI control that drove them.
//
// What stayed and why:
//   • The workflow REGISTRY (this file's protocol): `GET /v1/workflows` still
//     backs the Capabilities panel's workflow list, and `createWorkflow` is
//     still the canonical registry writer used by script/smoke_all.sh and
//     script/test.sh.
//   • The APPROVALS half is a different module (ApprovalInbox) writing
//     data/workflows/approvals/requests.json. It is LIVE — written today — and
//     was never part of the run engine. Nothing here touches it.
//   • data/workflows/runs.jsonl and run_state/*.json stay on disk as history
//     (User's keep-history rule). Nothing in the app reads them any more.
//
// The list path:
//   1. read workflows/registry.json (default []),
//   2. merge each built-in default with its saved override (saved keys win),
//   3. append saved-only items not present in defaults,
//   4. WRITE BACK the merged (unsorted) list to registry.json when it changed,
//   5. RETURN the merged list sorted by (updatedAt | createdAt | "") DESC.
//
// Registry writes are wrapped in the Swift persistence lock so create/list
// mutations do not trample each other or a concurrent external writer.

// MARK: - Client protocol

public protocol WorkflowOrchestrationClient: Sendable {
    /// GET /v1/workflows — returns the defaults-merged registry, sorted by
    /// (updatedAt | createdAt | "") DESC. As a side effect, persists the merged
    /// (unsorted) registry back to disk when it differs from the saved bytes.
    func listWorkflows() async throws -> [JSONValue]
    /// POST /v1/workflows — normalize the request body into a workflow record,
    /// persist it into the registry (replacing any same-id row), and emit the
    /// activity + trace side-effects.
    func createWorkflow(_ body: JSONValue) async throws -> JSONValue
}
