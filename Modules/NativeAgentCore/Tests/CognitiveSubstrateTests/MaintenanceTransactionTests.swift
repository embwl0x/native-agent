import Foundation
import GRDB
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

@Suite("Cognition maintenance transaction", .serialized)
struct MaintenanceTransactionTests {
    private func makeStore(_ label: String) throws -> (CognitiveSQLiteStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cognition-maintenance-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try CognitiveSQLiteStore(dataRoot: root), root)
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
            decayHalfLife: 86_400,
            summary: summary,
            metadata: [:]
        )
    }

    private func artifactID(_ value: JSONValue) -> String? {
        guard case .object(let object) = value,
              case .string(let id)? = object["id"] else { return nil }
        return id
    }

    @Test("one commit replaces every maintenance family and appends correlated receipts")
    func successfulCommitIsComplete() async throws {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let (store, root) = try makeStore("success")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldNode = node("old", at: now)
        let newNode = node("new", at: now)
        let oldSeedID = UUID()
        let newSeedID = UUID()
        let staleViewID = UUID()
        try await store.saveNodes([oldNode], at: now)
        try await store.upsertArtifact(
            kind: "thought_seed", id: oldSeedID, status: "open", score: 0.8,
            payload: .object(["id": .string(oldSeedID.uuidString)]), at: now
        )
        try await store.upsertArtifact(
            kind: "standing_view", id: staleViewID, status: "proposed", score: 0.5,
            payload: .object(["id": .string(staleViewID.uuidString)]), at: now
        )
        let affectID = UUID()

        try await store.commitMaintenance(
            nodes: [newNode],
            thoughtSeeds: [CognitiveArtifactReplacement(
                id: newSeedID,
                status: "open",
                score: 0.4,
                payload: .object(["id": .string(newSeedID.uuidString)])
            )],
            artifacts: [CognitiveArtifactWrite(
                kind: "affect", id: affectID, status: "current", score: 0.2,
                payload: .object(["updatedAt": .double(now.timeIntervalSince1970)])
            )],
            deletedArtifactIDs: [staleViewID],
            receipts: [
                CognitiveReceiptWrite(kind: "emotional_consolidation", payload: .object(["calmed": .int(1)])),
                CognitiveReceiptWrite(kind: "maintenance", payload: .object(["nodeCount": .int(1)])),
            ],
            maxNodes: 256,
            maxArtifacts: 516,
            at: now
        )

        #expect(try await store.loadNodes().map(\.summary) == ["new"])
        let seeds = try await store.loadArtifacts(kindPrefix: "thought_seed", limit: 10)
        #expect(seeds.count == 1)
        #expect(seeds.contains { artifactID($0) == newSeedID.uuidString })
        #expect(try await store.loadArtifacts(kindPrefix: "standing_view", limit: 10).isEmpty)
        #expect(try await store.loadArtifacts(kindPrefix: "affect", limit: 10).count == 1)
        let receiptKinds = try await store.loadReceiptRecords(limit: 10).map(\.kind)
        #expect(receiptKinds.contains("emotional_consolidation"))
        #expect(receiptKinds.contains("maintenance"))
    }

    @Test("receipt failure rolls node artifact deletion and family replacement back together")
    func lateFailureRollsBackEverything() async throws {
        let now = Date(timeIntervalSince1970: 21_000_000)
        let (store, root) = try makeStore("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldNode = node("old", at: now)
        let newNode = node("new", at: now)
        let oldSeedID = UUID()
        let newSeedID = UUID()
        let staleViewID = UUID()
        let affectID = UUID()
        try await store.saveNodes([oldNode], at: now)
        try await store.upsertArtifact(
            kind: "thought_seed", id: oldSeedID, status: "open", score: 0.8,
            payload: .object(["id": .string(oldSeedID.uuidString)]), at: now
        )
        try await store.upsertArtifact(
            kind: "standing_view", id: staleViewID, status: "proposed", score: 0.5,
            payload: .object(["id": .string(staleViewID.uuidString)]), at: now
        )
        let injector = try DatabaseQueue(path: await store.databaseURL.path)
        try await injector.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_maintenance_receipt
                BEFORE INSERT ON cognitive_receipts
                WHEN NEW.kind = 'maintenance'
                BEGIN
                    SELECT RAISE(ABORT, 'injected maintenance failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await store.commitMaintenance(
                nodes: [newNode],
                thoughtSeeds: [CognitiveArtifactReplacement(
                    id: newSeedID,
                    status: "open",
                    score: 0.4,
                    payload: .object(["id": .string(newSeedID.uuidString)])
                )],
                artifacts: [CognitiveArtifactWrite(
                    kind: "affect", id: affectID, status: "current", score: 0.2,
                    payload: .object(["updatedAt": .double(now.timeIntervalSince1970)])
                )],
                deletedArtifactIDs: [staleViewID],
                receipts: [CognitiveReceiptWrite(
                    kind: "maintenance", payload: .object(["nodeCount": .int(1)])
                )],
                maxNodes: 256,
                maxArtifacts: 516,
                at: now
            )
        }

        #expect(try await store.loadNodes().map(\.summary) == ["old"])
        let seeds = try await store.loadArtifacts(kindPrefix: "thought_seed", limit: 10)
        #expect(seeds.count == 1)
        #expect(seeds.contains { artifactID($0) == oldSeedID.uuidString })
        #expect(try await store.loadArtifacts(kindPrefix: "standing_view", limit: 10).count == 1)
        #expect(try await store.loadArtifacts(kindPrefix: "affect", limit: 10).isEmpty)
        #expect(try await store.loadReceiptRecords(limit: 10).isEmpty)
    }
}
