import Foundation
import Testing
@testable import NativeAgentApp

private func workflowBuilderRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("capabilities-workflow-builder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Capabilities workflow builder — durable creation")
struct CapabilitiesWorkflowBuilderEvalTests {
    @Test("the builder's create, reload, and run owners keep a durable runnable workflow")
    @MainActor
    func builderConfirmsThePersistedWorkflowBeforeRunningIt() async throws {
        let root = try workflowBuilderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let created = try await client.createWorkflow(.object([
            "name": .string("Isolated Builder Workflow"),
        ]))
        #expect(created.steps.count == 1)
        #expect(created.executionAvailability.isRunnable)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("workflows/registry.json").path
        ))

        let reloaded = try await client.getWorkflows()
        let confirmed = try #require(reloaded.first(where: { $0.id == created.id }))
        #expect(confirmed == created)
        #expect(confirmed.executionAvailability.isRunnable)

        let run = try await client.runWorkflow(
            id: confirmed.id,
            objective: "Plan the next action for this isolated workflow.",
            execute: true
        )
        #expect(run.workflowId == confirmed.id)
        #expect(run.status == "succeeded")
    }

    @Test("blank workflow names fail before they create a registry row")
    @MainActor
    func blankNameIsVisibleAsAnAdverseCreationOutcome() async throws {
        let root = try workflowBuilderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        await #expect(throws: WorkflowBuilderError.nameRequired) {
            _ = try await app.createWorkflow(named: "  \n  ")
        }
        #expect(app.workflows.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("workflows/registry.json").path
        ))
    }
}
