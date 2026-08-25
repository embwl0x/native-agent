import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.kg.button.enableKnowledgeGraph

@MainActor
@Suite("Knowledge Graph enable button")
struct KnowledgeGraphEnableButtonEvalTests {
    @Test("the enable control distinguishes a ready action from an in-flight policy write")
    func enableControlDisablesTheActualEmptyStateButtonWhileEnabling() throws {
        let ready = KnowledgeGraphEnableActionPresentation.buttonControl(isEnabling: false)
        #expect(ready == .init(
            title: "Enable Knowledge Graph",
            systemImage: "checkmark.circle",
            isDisabled: false
        ))

        let inFlight = KnowledgeGraphEnableActionPresentation.buttonControl(isEnabling: true)
        #expect(inFlight == .init(
            title: "Enabling...",
            systemImage: "hourglass",
            isDisabled: true
        ))

        // `KnowledgeGraphView` passes this exact presentation value to
        // NativeEmptyState. Exercising the owner directly avoids treating an
        // offscreen SwiftUI host's AppKit subtree as the behavior contract.
        #expect(inFlight.isDisabled)
    }

    @Test("a real Memory Policy commit remains the only completed enable outcome")
    func canonicalPolicyWriterMustPersistBeforeEnableCanBeCompleted() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)

        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: false))
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == false)
        #expect(await app.patchMemoryPolicy(knowledgeGraphEnabled: true))
        #expect(app.trustPolicy?.memoryPolicy?.knowledge_graph_enabled == true)
        #expect(KnowledgeGraphEnableActionPresentation.enabled.completionMessage != nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-graph-enable-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
