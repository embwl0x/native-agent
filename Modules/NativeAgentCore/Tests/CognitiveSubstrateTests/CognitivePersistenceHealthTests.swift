import Foundation
import GRDB
import PersistenceCore
import Testing
@testable import CognitiveSubstrate

@Suite("CognitivePersistenceHealth")
struct CognitivePersistenceHealthTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-cognition-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func node(_ summary: String, at now: Date) -> CognitiveNode {
        CognitiveNode(
            id: UUID(),
            kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "topic", id: summary, label: summary),
            activation: 0.8,
            salience: 0.8,
            confidence: 0.9,
            sourceClass: .userStated,
            createdAt: now,
            lastActivatedAt: now,
            decayHalfLife: 10_000,
            summary: summary,
            metadata: [:]
        )
    }

    @Test func sqliteReadsRejectMalformedRowsInsteadOfDroppingThem() async throws {
        let store = try CognitiveSQLiteStore(dataRoot: try temporaryRoot())
        let now = Date(timeIntervalSince1970: 40_000_000)
        let storedNode = node("durable node", at: now)
        try await store.saveNodes([storedNode], at: now)

        let databaseURL = await store.databaseURL
        let direct = try DatabaseQueue(path: databaseURL.path)
        try await direct.write { db in
            try db.execute(
                sql: "UPDATE cognitive_nodes SET metadata_json = ? WHERE id = ?",
                arguments: ["{not-json", storedNode.id.uuidString]
            )
        }
        await #expect(throws: CognitiveSQLiteReadError.self) {
            try await store.loadNodes()
        }

        let artifactID = UUID()
        try await store.upsertArtifact(
            kind: "affect",
            id: artifactID,
            status: "current",
            score: 0.5,
            payload: CognitiveAffectState(updatedAt: now).toJSON(),
            at: now
        )
        try await direct.write { db in
            try db.execute(
                sql: "UPDATE cognitive_artifacts SET payload_json = ? WHERE id = ?",
                arguments: ["[broken", artifactID.uuidString]
            )
        }
        await #expect(throws: CognitiveSQLiteReadError.self) {
            try await store.loadArtifacts(kindPrefix: "affect", limit: 1)
        }
    }

    @Test func partialRestoreDegradesWithoutClobberAndCleanRetryRecovers() async throws {
        let root = try temporaryRoot()
        let now = Date(timeIntervalSince1970: 41_000_000)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let durableNode = node("disk continuity", at: now)
        try await store.saveNodes([durableNode], at: now)

        let experimentID = UUID()
        try await store.upsertArtifact(
            kind: "experiment",
            id: experimentID,
            status: "recorded",
            score: 0.5,
            payload: .object(["id": .string(experimentID.uuidString)]),
            at: now
        )

        var memoryOnlyConfiguration = CognitiveConfiguration.allPhasesEnabled
        memoryOnlyConfiguration.persistenceEnabled = false
        let substrate = CognitiveSubstrate(
            configuration: memoryOnlyConfiguration,
            dependencies: CognitiveSubstrateDependencies(now: { now }),
            store: store
        )
        await substrate.ingest(CognitiveEvent(
            id: "memory-only",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "session:1", label: "turn"),
            sourceClass: .userStated,
            occurredAt: now,
            summary: "in-memory continuity",
            importance: 0.8
        ))
        await substrate.configure(.allPhasesEnabled)

        await #expect(throws: CognitivePersistenceError.self) {
            try await substrate.restorePersistentState()
        }

        let failedSnapshot = await substrate.snapshot()
        #expect(failedSnapshot.nodes.contains { $0.summary == "in-memory continuity" })
        #expect(!failedSnapshot.nodes.contains { $0.summary == "disk continuity" })
        #expect(failedSnapshot.persistenceHealth.status == .degraded)
        #expect(failedSnapshot.persistenceHealth.writesBlocked)
        #expect(failedSnapshot.persistenceHealth.failureStage == "artifact.experiment")

        await #expect(throws: CognitivePersistenceError.self) {
            try await substrate.persistSnapshot()
        }
        let diskAfterFailure = try await store.loadNodes()
        #expect(diskAfterFailure.map(\.summary) == ["disk continuity"])

        let degradedReceipts = try await store.loadReceiptRecords(
            kindPrefix: "lifecycle.restore_degraded",
            limit: 10
        )
        #expect(degradedReceipts.count == 1)

        try await store.upsertArtifact(
            kind: "experiment",
            id: experimentID,
            status: "recorded",
            score: 0.5,
            payload: CognitiveExperimentResult(
                id: experimentID,
                kind: .continuity,
                seed: "recovery",
                score: 0.5,
                metrics: [:],
                notes: [],
                reproducibilityKey: "recovery-key",
                generatedAt: now
            ).toJSON(),
            at: now
        )

        try await substrate.restorePersistentState()
        let recovered = await substrate.snapshot()
        #expect(recovered.nodes.contains { $0.summary == "disk continuity" })
        #expect(recovered.persistenceHealth.status == .healthy)
        #expect(!recovered.persistenceHealth.writesBlocked)
        #expect(recovered.persistenceHealth.lastSuccessfulRestoreAt != nil)

        await substrate.ingest(CognitiveEvent(
            id: "after-recovery",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "session:2", label: "turn"),
            sourceClass: .userStated,
            occurredAt: now,
            summary: "persistence resumed",
            importance: 0.8
        ))
        try await substrate.persistSnapshot()
        #expect(try await store.loadNodes().contains { $0.summary == "persistence resumed" })

        let restoreReceipts = try await store.loadReceiptRecords(kindPrefix: "lifecycle.restore", limit: 10)
        #expect(restoreReceipts.contains { receipt in
            guard case .object(let payload) = receipt.payload else { return false }
            return payload["status"] == .string("recovered")
        })
    }
}
