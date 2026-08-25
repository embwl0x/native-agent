import Foundation
import MemoryV2
import Testing
@testable import NativeAgentApp

/// EVAL FENCE: app.background / app.background.launch.embeddingWarmupAndIndexSync
///
/// Drives the real launch reconciliation helper with a hermetic memory owner
/// and body shelves. The second pass changes the body set, so a green result
/// requires both adding the new pointer and retiring the stale one; its durable
/// receipt must prove how many bodies actually converged.
@Suite("Launch skill-pointer index sync")
struct LaunchEmbeddingWarmupAndIndexSyncEvalTests {
    @Test("launch sync converges added and removed bodies, with a durable reconciled count")
    func launchSyncReconcilesBodiesAndRecordsCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-skill-pointer-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeBodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let personaBodies = personaRoot.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeBodies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personaBodies, withIntermediateDirectories: true)
        try "# Old runtime\n\nUse when the old runtime skill applies.\n".write(
            to: runtimeBodies.appendingPathComponent("old-runtime.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Persona\n\nUse when the stable persona skill applies.\n".write(
            to: personaBodies.appendingPathComponent("persona-stable.md"),
            atomically: true,
            encoding: .utf8
        )

        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: InMemoryMemoryStorage()
        )
        let first = try #require(await syncSkillPointerIndex(
            memory: memory,
            dataRoot: root,
            personaRoot: personaRoot
        ))
        #expect(first.added == 2)

        try FileManager.default.removeItem(at: runtimeBodies.appendingPathComponent("old-runtime.md"))
        try "# New runtime\n\nUse when the replacement runtime skill applies.\n".write(
            to: runtimeBodies.appendingPathComponent("new-runtime.md"),
            atomically: true,
            encoding: .utf8
        )
        let second = try #require(await syncSkillPointerIndex(
            memory: memory,
            dataRoot: root,
            personaRoot: personaRoot
        ))
        #expect(second.added == 1)
        #expect(second.removed == 1)
        #expect(second.unchanged == 1)

        let rows = try await memory.listMemory(kind: "skill")
        let statusByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
        #expect(statusByID == [
            "skill-pointer:new-runtime": "active",
            "skill-pointer:old-runtime": "deleted",
            "skill-pointer:persona-stable": "active",
        ])

        let receiptURL = root.appendingPathComponent("skills/.pointer_sync_receipt.json")
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try #require(JSONSerialization.jsonObject(with: receiptData) as? [String: String])
        #expect(receipt["status"] == "ok")
        #expect(receipt["added"] == "1")
        #expect(receipt["removed"] == "1")
        #expect(receipt["unchanged"] == "1")
        #expect(receipt["reconciledPointerCount"] == "2")
    }
}
