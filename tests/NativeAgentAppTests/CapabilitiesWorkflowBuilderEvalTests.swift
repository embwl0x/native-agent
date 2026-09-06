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
    @Test("the builder's create and reload owners keep a durable registry row")
    @MainActor
    func builderConfirmsThePersistedWorkflowAfterReload() async throws {
        let root = try workflowBuilderRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NativeClient(baseURL: "", dataRootOverride: root)

        let created = try await client.createWorkflow(.object([
            "name": .string("Isolated Builder Workflow"),
        ]))
        #expect(created.steps.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("workflows/registry.json").path
        ))

        // A create response alone is not a durable row: re-read the registry
        // from the same root and require the same record back. The run engine
        // was retired 2026-09-01, so there is nothing further to execute.
        let reloaded = try await client.getWorkflows()
        let confirmed = try #require(reloaded.first(where: { $0.id == created.id }))
        #expect(confirmed == created)
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
