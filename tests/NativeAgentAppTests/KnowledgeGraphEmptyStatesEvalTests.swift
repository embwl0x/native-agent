import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.emptyStates

@MainActor
@Suite("Knowledge Graph empty states")
struct KnowledgeGraphEmptyStatesEvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kg-empty-states-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("an unread Memory Policy is checking, never a graph-off state with an Enable action")
    func unreadPolicyIsDistinctFromDisabledGraph() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        #expect(app.trustPolicy == nil)

        let checking = KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled,
            viewMode: .list
        )
        #expect(checking == .policyUnavailable)
        #expect(checking != .disabled)
        #expect(checking != .empty)
    }

    @Test("unavailable, disabled, empty, and filtered-empty states remain separate render contracts")
    func emptyStateClassifierNeverTurnsAbsenceIntoZero() {
        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: "database unreadable",
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .unavailable("database unreadable"))

        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: false,
            viewMode: .list
        ) == .disabled)

        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: 0,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .empty)

        #expect(KnowledgeGraphPresentation.content(
            isLoading: false,
            error: nil,
            entityCount: 3,
            displayedEntityCount: 0,
            isEnabled: true,
            viewMode: .list
        ) == .filteredEmpty)
    }
}
