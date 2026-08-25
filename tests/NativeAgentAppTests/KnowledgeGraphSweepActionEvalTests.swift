// EVAL COVERAGE — fence `app.mind`, reports-only action hardening (2026-08-24).
//
// These execute the same app-owned executor invoked by KnowledgeGraphView's
// "Sweep orphans…" preview and destructive confirmation actions. No source
// inspection and no view/model helper is used as the proof.
//
// Rows exercised (not in behavior-coverage-wave1):
//   ui.kg.action.sweepOrphansPreview
//   ui.kg.action.applyGCSweep

import Foundation
import KnowledgeGraph
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

private func kgSweepRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("KnowledgeGraphSweepAction-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func kgSweepFact(_ id: String, _ content: String) -> KnowledgeGraphMemoryFact {
    KnowledgeGraphMemoryFact(
        id: id, content: content,
        createdAt: "2026-08-24T00:00:00Z", updatedAt: "2026-08-24T00:00:00Z"
    )
}

@Suite("Knowledge Graph orphan sweep — app action boundary", .serialized)
struct KnowledgeGraphSweepActionEvalTests {
    @Test("preview finds an orphan but does not mutate it; apply removes only the still-orphaned current state")
    func previewAndApplyReReadTheCanonicalStoreAcrossMutationDrift() async throws {
        let root = try kgSweepRoot("drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let live = kgSweepFact("live", "NativeAgent release proof")
        let restored = kgSweepFact("restored", "TradingView dashboard")
        _ = try await storage.insertMemory(StoredMemory(id: live.id, content: live.content))
        _ = try await storage.insertMemory(StoredMemory(id: restored.id, content: restored.content))
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        try await indexer.indexMemory(live)
        try await indexer.indexMemory(restored)
        _ = try await storage.deleteMemory(id: restored.id)
        try await indexer.indexMemory(restored, deleted: true)

        let actions = KnowledgeGraphMaintenanceActions(dataRoot: root)
        let preview = try await actions.previewOrphanSweep()
        #expect(preview.candidates.map(\.name) == ["TradingView"],
                "the button's preview must expose a real candidate before confirmation")
        let unchanged = try await actions.previewOrphanSweep()
        #expect(unchanged.candidates == preview.candidates,
                "preview is read-only; calling it must not become a hidden deletion")

        // A new orphan after the preview is not covered by the user's
        // confirmation. The action must surface the larger set untouched.
        // Use an extractor-owned term. An arbitrary title-case word is
        // deliberately not enough evidence to become a graph entity, whereas
        // OpenAI is a durable, indexer-owned candidate identity.
        let newcomer = kgSweepFact("newcomer", "OpenAI provider migration")
        _ = try await storage.insertMemory(StoredMemory(id: newcomer.id, content: newcomer.content))
        try await indexer.indexMemory(newcomer)
        _ = try await storage.deleteMemory(id: newcomer.id)
        try await indexer.indexMemory(newcomer, deleted: true)
        let expandedPreview = try await actions.previewOrphanSweep()
        let expandedCandidateIDs = Set(expandedPreview.candidates.map(\.id))
        #expect(Set(expandedPreview.candidates.map(\.name)) == Set(["TradingView", "OpenAI"]),
                "both deleted source facts must have durable graph-entity candidates before apply")
        #expect(
            expandedCandidateIDs.isSuperset(of: Set(preview.candidates.map(\.id))),
            "the original preview identity must remain part of the current candidate set"
        )
        let expanded = try await actions.applyOrphanSweep(
            expectedCandidateIDs: Set(preview.candidates.map(\.id)))
        guard case let .previewDiverged(currentCandidates) = expanded else {
            Issue.record("an unpreviewed orphan must force reconfirmation")
            return
        }
        #expect(Set(currentCandidates.map(\.id)) == expandedCandidateIDs,
                "confirmation identity is the graph entity id, never the source-memory id")
        _ = try await storage.insertMemory(StoredMemory(id: newcomer.id, content: newcomer.content))
        try await indexer.indexMemory(newcomer)

        // The memory reappears after preview but before confirmation. Apply
        // must derive its live facts now, not delete from the stale preview.
        _ = try await storage.insertMemory(StoredMemory(id: restored.id, content: restored.content))
        try await indexer.indexMemory(restored)
        let applyAfterRestore = try await actions.applyOrphanSweep(
            expectedCandidateIDs: Set(preview.candidates.map(\.id)))
        #expect(applyAfterRestore == .previewDiverged(currentCandidates: []),
                "a shrinking candidate set needs a fresh user review, not a quiet no-op")
        #expect((try await actions.previewOrphanSweep()).candidates.isEmpty,
                "a restored source must survive a confirmation based on an older preview")

        _ = try await storage.deleteMemory(id: restored.id)
        try await indexer.indexMemory(restored, deleted: true)
        let refreshedPreview = try await actions.previewOrphanSweep()
        let applied = try await actions.applyOrphanSweep(
            expectedCandidateIDs: Set(refreshedPreview.candidates.map(\.id)))
        guard case let .applied(report) = applied else {
            Issue.record("unchanged preview must be eligible for apply")
            return
        }
        #expect(report.entitiesDeleted > 0,
                "a still-orphaned entity must be removed only by the confirmed apply action")
        #expect((try await actions.previewOrphanSweep()).candidates.isEmpty)
    }

    @Test("a malformed action root fails loudly instead of reporting no orphaned entities")
    func unreadableRootDoesNotFabricateAnEmptyPreview() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeGraphSweepAction-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: (any Error).self) {
            _ = try await KnowledgeGraphMaintenanceActions(dataRoot: file).previewOrphanSweep()
        }
        await #expect(throws: (any Error).self) {
            _ = try await KnowledgeGraphMaintenanceActions(dataRoot: file).applyOrphanSweep(expectedCandidateIDs: [])
        }
    }

    @Test("the preview action reduces an unreadable root to a visible failure, never a healthy empty result")
    func previewActionPublishesFailureInsteadOfAHealthyNoOrphansResult() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeGraphSweepAction-control-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = await KnowledgeGraphMaintenancePresentation.previewState(
            actions: KnowledgeGraphMaintenanceActions(dataRoot: file)
        )
        #expect(result.errorMessage?.hasPrefix("Orphan sweep failed:") == true)
        #expect(result.status == nil)
        #expect(result.candidates.isEmpty)
        #expect(result.candidateIDs.isEmpty)
        #expect(result.presentsConfirmation == false)
    }

    // app.mind / ui.kg.button.sweepOrphans
    @Test("the sweep action exposes canonical candidates, then clears them when a fresh retry is unreadable")
    func previewActionKeepsKnownOrphansDistinctFromAnUnreadableStore() async throws {
        let root = try kgSweepRoot("button-preview")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let live = kgSweepFact("live", "NativeAgent release proof")
        let orphan = kgSweepFact("orphan", "TradingView dashboard")
        _ = try await storage.insertMemory(StoredMemory(id: live.id, content: live.content))
        _ = try await storage.insertMemory(StoredMemory(id: orphan.id, content: orphan.content))
        let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
        try await indexer.indexMemory(live)
        try await indexer.indexMemory(orphan)
        _ = try await storage.deleteMemory(id: orphan.id)
        try await indexer.indexMemory(orphan, deleted: true)

        let preview = await KnowledgeGraphMaintenancePresentation.previewState(
            actions: KnowledgeGraphMaintenanceActions(dataRoot: root)
        )
        #expect(preview.candidates.map(\.name) == ["TradingView"])
        #expect(preview.candidateIDs == Set(preview.candidates.map(\.id)))
        #expect(preview.status == nil)
        #expect(preview.presentsConfirmation)
        #expect(preview.errorMessage == nil)

        let unreadable = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeGraphSweepAction-button-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: unreadable)
        defer { try? FileManager.default.removeItem(at: unreadable) }
        let retry = await KnowledgeGraphMaintenancePresentation.previewState(
            actions: KnowledgeGraphMaintenanceActions(dataRoot: unreadable)
        )

        #expect(retry.errorMessage?.hasPrefix("Orphan sweep failed:") == true)
        #expect(retry.status == nil,
                "a failed preview must not claim that no orphaned entities exist")
        #expect(retry.candidates.isEmpty)
        #expect(retry.candidateIDs.isEmpty)
        #expect(retry.presentsConfirmation == false,
                "a candidate list from an older successful preview must not remain deletable")
    }
}
