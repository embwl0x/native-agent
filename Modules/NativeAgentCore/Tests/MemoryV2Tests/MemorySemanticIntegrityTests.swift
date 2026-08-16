import Foundation
import GRDB
import Testing
@testable import MemoryV2

@Suite("MemoryV2 semantic integrity")
struct MemorySemanticIntegrityTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-semantic-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func malformedMetadataFailsClosedWithoutRewritingCanonicalBytes() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let memory = try await storage.insertMemory(StoredMemory(
            content: "fact with evidence",
            evidence: .object(["source": .string("test")]),
            metadata: .object(["kind": .string("user_fact")])
        ))
        let path = await storage.path
        let queue = try DatabaseQueue(path: path.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE memories SET evidence_json = '{' WHERE id = ?",
                arguments: [memory.id]
            )
        }

        await #expect(throws: MemoryStorageError.self) {
            try await storage.requireSemanticIntegrity()
        }
        #expect(throws: MemoryStorageError.self) {
            _ = try MemoryStorage(dataRoot: dataRoot)
        }
        let damaged: String? = try await queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT evidence_json FROM memories WHERE id = ?", arguments: [memory.id]
            )
        }
        #expect(damaged == "{")
    }

    @Test func malformedEmbeddingBytesFailClosed() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let memory = try await storage.insertMemory(StoredMemory(content: "vector fact"))
        let path = await storage.path
        let queue = try DatabaseQueue(path: path.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE memories SET embedding = x'010203' WHERE id = ?",
                arguments: [memory.id]
            )
        }
        await #expect(throws: MemoryStorageError.self) {
            try await storage.requireSemanticIntegrity()
        }
    }

    @Test func mixedDimensionsInsideOneEmbeddingEpochFailClosed() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let first = try await storage.insertMemory(StoredMemory(content: "first vector fact"))
        let second = try await storage.insertMemory(StoredMemory(content: "second vector fact"))
        let path = await storage.path
        let queue = try DatabaseQueue(path: path.path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE memories SET embedding = x'00000000', embedding_epoch = 'epoch-a' WHERE id = ?",
                arguments: [first.id]
            )
            try db.execute(
                sql: "UPDATE memories SET embedding = x'0000000000000000', embedding_epoch = 'epoch-a' WHERE id = ?",
                arguments: [second.id]
            )
        }

        await #expect(throws: MemoryStorageError.self) {
            try await storage.requireSemanticIntegrity()
        }
    }

    @Test func consistentBackupIsReadableAndSemanticallyVerified() async throws {
        let dataRoot = try root()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let memory = try await storage.insertMemory(StoredMemory(content: "backup fact"))
        let destinationRoot = try root()
        defer { try? FileManager.default.removeItem(at: destinationRoot) }
        let destination = destinationRoot.appendingPathComponent("memory.sqlite")

        try await storage.createConsistentBackup(destinationDatabaseURL: destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: destination.path + "-shm"))
        let queue = try DatabaseQueue(path: destination.path)
        let copied: String? = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT content FROM memories WHERE id = ?", arguments: [memory.id])
        }
        #expect(copied == "backup fact")
    }
}
