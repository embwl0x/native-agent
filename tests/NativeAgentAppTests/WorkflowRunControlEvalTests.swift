import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// Runs the same AppModel actions mounted by CapabilitiesView against an
/// isolated durable root. This is deliberately not a source-shape test: every
/// assertion crosses NativeClient, WorkflowOrchestration, ApprovalInbox, and a
/// fresh AppModel reload before it calls a visible outcome true.
@Suite("core.workshop · workflow run controls", .serialized)
struct WorkflowRunControlEvalTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-run-controls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workflow(
        id: String,
        name: String,
        steps: [JSONValue]
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "status": .string("active"),
            "engineVersion": .string("2"),
            "steps": .array(steps),
        ])
    }

    @Test @MainActor func mountedRunControlsPersistAndReloadTheirActualOutcomes() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        let approvalFlow = try await client.createWorkflow(workflow(
            id: "approval-flow",
            name: "Approval Flow",
            steps: [.object([
                "id": .string("trace"),
                "kind": .string("trace"),
                "requiresApproval": .bool(true),
            ])]
        ))
        await app.runWorkflow(approvalFlow, objective: "wait for a human")
        let waiting = try #require(app.workflowRuns.first { $0.workflowId == "approval-flow" })
        #expect(waiting.status == "waiting_approval")
        let pendingControls = waiting.controlAvailability(
            approvalDecision: app.approvals.first(where: { $0.id == waiting.approvalId })?.decision
        )
        #expect(!pendingControls.resume.isEligible)
        #expect(pendingControls.resume.detail.contains("approval decision"))

        let approval = try #require(app.approvals.first { $0.id == waiting.approvalId })
        await app.resolveApproval(approval, decision: "approved")
        let approvedControls = waiting.controlAvailability(
            approvalDecision: app.approvals.first(where: { $0.id == waiting.approvalId })?.decision
        )
        #expect(approvedControls.resume.isEligible)
        await app.resumeWorkflowRun(waiting)
        #expect(app.statusText.contains("Workflow resume persisted as succeeded"))

        // This flow cannot execute because its dependency has no producer. It
        // becomes a real persisted blocked run, which the mounted Cancel then
        // turns into a ledger-visible terminal before Rollback records its own
        // durable terminal outcome.
        let blockedFlow = try await client.createWorkflow(workflow(
            id: "blocked-flow",
            name: "Blocked Flow",
            steps: [.object([
                "id": .string("trace"),
                "kind": .string("trace"),
                "dependsOn": .array([.string("missing")]),
            ])]
        ))
        await app.runWorkflow(blockedFlow, objective: "show a blocked control")
        let blocked = try #require(app.workflowRuns.first { $0.workflowId == "blocked-flow" })
        #expect(blocked.status == "blocked")
        #expect(blocked.controlAvailability().cancel.isEligible)
        await app.cancelWorkflowRun(blocked)
        #expect(app.statusText.contains("Workflow cancel persisted as canceled"))
        let canceled = try #require(app.workflowRuns.first { $0.id == blocked.id })
        #expect(canceled.status == "canceled")
        #expect(canceled.controlAvailability().rollback.isEligible)
        await app.rollbackWorkflowRun(canceled)
        #expect(app.statusText.contains("Workflow rollback persisted as rolled_back"))

        let reloaded = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await reloaded.refreshAll()
        let terminal = try #require(reloaded.workflowRuns.first { $0.id == blocked.id })
        #expect(terminal.status == "rolled_back")
        let terminalControls = terminal.controlAvailability()
        #expect(!terminalControls.resume.isEligible)
        #expect(!terminalControls.cancel.isEligible)
        #expect(!terminalControls.rollback.isEligible)

        // Unsupported step vocabulary never creates a run row, and the
        // mounted AppModel leaves the refusal visible rather than a success
        // toast over a nonexistent durable outcome.
        let unsupportedFlow = try await client.createWorkflow(workflow(
            id: "unsupported-flow",
            name: "Unsupported Flow",
            steps: [.object(["id": .string("draft"), "kind": .string("llm")])]
        ))
        await app.runWorkflow(unsupportedFlow, objective: "must refuse")
        #expect(app.statusText.contains("Workflow run failed"))
        #expect(!app.workflowRuns.contains { $0.workflowId == "unsupported-flow" })
    }
}
