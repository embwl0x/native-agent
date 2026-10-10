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
//   • The workflow REGISTRY (this file's protocol) still backs the Capabilities
//     panel's workflow list. The unused creation path has been removed.
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
// Registry write-back shares the Swift persistence lock with external writers.

// MARK: - Client protocol

public protocol WorkflowOrchestrationClient: Sendable {
    /// GET /v1/workflows — returns the defaults-merged registry, sorted by
    /// (updatedAt | createdAt | "") DESC. As a side effect, persists the merged
    /// (unsorted) registry back to disk when it differs from the saved bytes.
    func listWorkflows() async throws -> [JSONValue]
}

extension WorkflowOrchestrationClient {
    /// The same list as records, for the Capabilities panel; a malformed row
    /// fails the read.
    public func listWorkflowRecords() async throws -> [WorkflowRecord] {
        try await listWorkflows().map(WorkflowRecord.init(row:))
    }
}

public struct WorkflowStep: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: String?
    public var status: String?
    public var requiresApproval: Bool?
    public var detail: String?
}

public struct WorkflowRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var status: String?
    public var trigger: String?
    public var steps: [WorkflowStep]
    public var createdAt: String?
    public var updatedAt: String?
}

extension WorkflowRecord {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), name: try row.string("name"),
            description: try row.optionalString("description"), status: try row.optionalString("status"),
            trigger: try row.optionalString("trigger"),
            steps: try row.array("steps").map(WorkflowStep.init(row:)),
            createdAt: try row.optionalString("createdAt"), updatedAt: try row.optionalString("updatedAt"))
    }
}

extension WorkflowStep {
    init(row: JSONValue) throws {
        let row = try JSONRow(row)
        self.init(
            id: try row.string("id"), title: try row.string("title"), kind: try row.optionalString("kind"),
            status: try row.optionalString("status"), requiresApproval: try row.optionalBool("requiresApproval"),
            detail: try row.optionalString("detail"))
    }
}
