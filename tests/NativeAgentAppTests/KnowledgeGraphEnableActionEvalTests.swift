import Foundation
import Testing
@testable import NativeAgentApp

private func knowledgeGraphEnableTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("knowledge-graph-enable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Knowledge Graph enable action — checked policy boundary")
struct KnowledgeGraphEnableActionEvalTests {
    @Test("the Enable Knowledge Graph action commits the injected policy before graph loading")
    @MainActor
    func enableActionPersistsThroughAFreshCanonicalReader() async throws {
        let root = try knowledgeGraphEnableTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: false))

        let outcome = await KnowledgeGraphEnableAction.perform(using: app)

        let relaunched = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let persisted = try await relaunched.getTrustPolicy()
        #expect(outcome == .enabled)
        #expect(outcome.completionMessage
            == "Knowledge Graph enabled. New conversations can now contribute entity links.")
        #expect(persisted.memoryPolicy?.knowledge_graph_enabled == true)
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == true)
    }

    @Test("the action presentation preserves disabled, unreadable, and completed meanings")
    @MainActor
    func enableActionStatesStayDistinct() {
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false, error: nil, entityCount: 0, displayedEntityCount: 0,
            isEnabled: nil, viewMode: .list
        ) == .policyUnavailable)
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false, error: nil, entityCount: 0, displayedEntityCount: 0,
            isEnabled: false, viewMode: .list
        ) == .disabled)
        #expect(KnowledgeGraphEnableActionPresentation.enabled.completionMessage
            == "Knowledge Graph enabled. New conversations can now contribute entity links.")
        #expect(KnowledgeGraphEnableActionPresentation.failure(statusText: "")
            == .failed("Knowledge Graph could not be enabled because the Memory Policy write failed."))
        #expect(KnowledgeGraphEnableActionPresentation.failure(statusText: "write denied").failureMessage
            == "Knowledge Graph could not be enabled. write denied")
    }

    @Test("an unreadable policy is visibly unavailable and never exposes an Enable action")
    @MainActor
    func unreadablePolicyIsNotPresentedAsAGraphOffState() async throws {
        let root = try knowledgeGraphEnableTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trustDirectory = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true)
        let policyURL = trustDirectory.appendingPathComponent("policy.json")
        let damaged = Data("{ damaged policy".utf8)
        try damaged.write(to: policyURL)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let detail: String
        do {
            _ = try await app.getTrustPolicy()
            Issue.record("damaged policy unexpectedly decoded")
            return
        } catch {
            detail = error.localizedDescription
        }
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false, error: nil, entityCount: 0, displayedEntityCount: 0,
            isEnabled: app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled,
            viewMode: .list, policyReadError: detail
        ) == .policyUnreadable(detail))
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false, error: nil, entityCount: 0, displayedEntityCount: 0,
            isEnabled: nil, viewMode: .list, policyReadError: detail
        ) != .disabled)
        let deniedOutcome = await KnowledgeGraphEnableAction.perform(using: app)
        #expect(deniedOutcome.failureMessage != nil,
                "a damaged authority store must reject direct enable attempts as well")
        #expect(try Data(contentsOf: policyURL) == damaged)
    }
}
