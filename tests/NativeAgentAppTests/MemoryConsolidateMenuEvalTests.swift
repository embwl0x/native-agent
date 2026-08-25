import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / ui.memory.menu.consolidate

@MainActor
@Suite("Memory Consolidate menu")
struct MemoryConsolidateMenuEvalTests {
    private func root(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-consolidate-menu-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a disabled consolidation envelope records an unavailable action outcome and visible disabled state")
    func disabledEnvelopeStaysVisibleInsteadOfLookingSuccessful() async throws {
        let root = try root("disabled")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let feedback = await app.applyMemoryConsolidationResult([
            "panelDisabled": true,
            "code": "not_implemented",
            "reason": "approval-backed consolidator unavailable",
        ])

        let expected = "Consolidate disabled — approval-backed consolidator unavailable"
        #expect(feedback == .unavailable(expected))
        #expect(app.memoryFeatureDisabledMessage == expected)
        let presentation = MemoryConsolidationPresentation.resolve(result: [
            "panelDisabled": true,
            "reason": "approval-backed consolidator unavailable",
        ])
        #expect(presentation.feedback == feedback)
        #expect(!presentation.shouldRefresh)
    }

    @Test("real consolidation outcomes clear an older disabled badge and keep an action-scoped receipt")
    func actionableOutcomeClearsStaleDisabledBadge() async throws {
        let root = try root("actionable")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        await app.applyMemoryConsolidationResult([
            "panelDisabled": true,
            "reason": "temporarily unavailable",
        ])
        let feedback = await app.applyMemoryConsolidationResult([
            "status": "pending_approval",
            "errors": [],
        ])

        #expect(app.memoryFeatureDisabledMessage == nil)
        #expect(feedback == .pendingApproval("Memory consolidation queued for approval"))
        #expect(MemoryConsolidationPresentation.resolve(result: [
            "status": "pending_approval",
            "errors": [],
        ]).shouldRefresh)
    }
}
