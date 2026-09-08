import Foundation
import Testing
import TrustCenter
import MemoryV2
@testable import NativeAgentApp

private func knowledgeGraphEnableTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("knowledge-graph-enable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Knowledge Graph enable action — checked policy boundary")
struct KnowledgeGraphEnableActionEvalTests {
    @Test("fresh defaults support opting out and back in through the canonical policy writer")
    @MainActor
    func enableActionPersistsThroughAFreshCanonicalReader() async throws {
        let root = try knowledgeGraphEnableTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let writer = SwiftNativeTrustCenter(dataRoot: root)
        _ = try await writer.updateTrust(.object(writer.defaultTrustPolicy()))
        let fresh = try await app.getTrustPolicy()
        #expect(fresh.memoryPolicy?.knowledge_graph_enabled == true)
        #expect(fresh.trainingPolicy?.dream_scheduler == true)
        #expect(TrustMemoryPolicy().knowledge_graph_enabled)
        #expect(try JSONDecoder().decode(TrustMemoryPolicy.self, from: Data("{}".utf8)).knowledge_graph_enabled)
        let memory = ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false })
        #expect(memory.snapshot().mode == ManagedEmbeddingProvider.performanceMode)
        #expect(memory.snapshot().idleUnloadSeconds == nil)
        try await memory.setMemoryMode(ManagedEmbeddingProvider.balancedMode)
        #expect(ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false }).snapshot().idleUnloadSeconds == 300)
        try await memory.setMemoryMode(ManagedEmbeddingProvider.lowMemoryMode)
        #expect(ManagedEmbeddingProvider(dataRoot: root, availabilityProbe: { false }).snapshot().idleUnloadSeconds == 45)
        if let artifact = ProcessInfo.processInfo.environment["F6_FRESH_POLICY_REPORT_PATH"] {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent("trust/policy.json"),
                to: URL(fileURLWithPath: artifact)
            )
        }

        let outcome = await KnowledgeGraphEnableAction.perform(using: app, enabled: false)

        let relaunched = NativeClient(baseURL: "http://unused", dataRootOverride: root)
        let persisted = try await relaunched.getTrustPolicy()
        #expect(outcome == .disabled)
        #expect(outcome.completionMessage
            == "Knowledge Graph disabled. New conversations will no longer contribute entity links.")
        #expect(persisted.memoryPolicy?.knowledge_graph_enabled == false)
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == false)
        #expect(await KnowledgeGraphEnableAction.perform(using: app, enabled: true) == .enabled)
        #expect(try await relaunched.getTrustPolicy().memoryPolicy?.knowledge_graph_enabled == true)
        _ = try await writer.updateTrust(.object(["trainingPolicy": .object(["dream_scheduler": .bool(false)])]))
        #expect(try await relaunched.getTrustPolicy().trainingPolicy?.dream_scheduler == false)
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
            == .failed("Knowledge Graph could not be disabled because the memory settings could not be saved."))
        #expect(KnowledgeGraphEnableActionPresentation.failure(statusText: "write denied").failureMessage
            == "Knowledge Graph could not be disabled. write denied")
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
        #expect(await KnowledgeGraphEnableAction.perform(using: app, enabled: false).failureMessage != nil)
        #expect(try Data(contentsOf: policyURL) == damaged)
    }
}
