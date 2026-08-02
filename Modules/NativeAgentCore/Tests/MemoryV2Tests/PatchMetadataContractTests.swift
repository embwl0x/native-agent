import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// THE FIXTURE AND THE REAL STORE MUST AGREE ABOUT UNKNOWN PATCH KEYS
// (gpt-5.5 review, 2026-08-02).
//
// `InMemoryMemoryStorage` — the fixture behind most MemoryV2 tests — merged
// EVERY untyped patch key into `extras`, while `MemoryStorageBridge` (the real
// SQLite path) merges only `MemoryPatchContract.untypedPassthroughKeys` and
// drops the rest. So `patch(["foo": "bar"])` persisted in every test and
// vanished in production: a test could pass against behaviour production does
// not have. That is exactly how the `recall_count` no-op survived (2026-07-24).
//
// These tests run the SAME patch through BOTH backends and compare, so the
// contract cannot drift again in either direction. The SQLite side is the
// contract.

@Suite("PatchMetadataContract")
struct PatchMetadataContractTests {

    private func makeTempRoot(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchMetadataContract-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seed(_ storage: any MemoryStorageProtocol, id: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await storage.insert(
            record: MemoryRecord(
                id: id,
                text: "User keeps the release checklist in the workshop notes.",
                layer: "semantic",
                memoryKind: nil,
                createdAt: now,
                updatedAt: now,
                sourceRunId: "test:patch-contract",
                status: "active"
            ),
            embedding: nil
        )
    }

    private func extras(of record: MemoryRecord) -> [String: JSONValue] {
        if case .object(let meta)? = record.extras { return meta }
        return [:]
    }

    /// The patch under test: one allowlisted key, one typed key, one key
    /// nobody declared.
    private var patch: JSONValue {
        .object([
            "pinned": .bool(true),
            "recall_count": .int(3),
            "status": .string("active"),
            "foo": .string("bar"),
        ])
    }

    @Test func sqliteDropsUndeclaredPatchKeysAndKeepsTheAllowlist() async throws {
        let root = try makeTempRoot("sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        let id = UUID().uuidString
        try await seed(storage, id: id)

        let updated = try await storage.updateMemory(id: id, patch: patch, newEmbedding: nil)
        let meta = extras(of: updated)
        #expect(meta["recall_count"] == .int(3))
        #expect(meta["pinned"] == .bool(true))
        #expect(updated.pinned == true)
        #expect(meta["foo"] == nil, "an undeclared key must not reach metadata_json")
    }

    /// THE REGRESSION: before the fix this fixture kept "foo" and the SQLite
    /// bridge above dropped it, so the two disagreed.
    @Test func theInMemoryFixtureObeysTheSameContract() async throws {
        let storage = InMemoryMemoryStorage()
        let id = UUID().uuidString
        try await seed(storage, id: id)

        let updated = try await storage.updateMemory(id: id, patch: patch, newEmbedding: nil)
        let meta = extras(of: updated)
        #expect(meta["recall_count"] == .int(3))
        #expect(meta["pinned"] == .bool(true))
        #expect(updated.pinned == true)
        // The fixture used to keep undeclared keys that production SQLite
        // drops, so a test could pass on behaviour production does not have.
        #expect(meta["foo"] == nil)
    }

    /// Same patch, both backends, compared directly: the surviving metadata key
    /// set has to be IDENTICAL. This is the assertion that catches a future
    /// allowlist edit applied to only one side.
    @Test func bothBackendsKeepExactlyTheSameKeys() async throws {
        let root = try makeTempRoot("agreement")
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        let fixture = InMemoryMemoryStorage()

        let sqliteID = UUID().uuidString
        let fixtureID = UUID().uuidString
        try await seed(sqlite, id: sqliteID)
        try await seed(fixture, id: fixtureID)

        // Every allowlisted key plus two nobody declared.
        var object: [String: JSONValue] = [
            "kind": .string("semantic"),          // semantics-owned; deliberately NOT passthrough
            "totally_made_up": .string("nope"),
        ]
        for key in MemoryPatchContract.untypedPassthroughKeys {
            object[key] = .string("value-for-\(key)")
        }
        object["pinned"] = .bool(true)
        object["importance"] = .double(0.75)
        object["tags"] = .array([.string("workshop")])

        let fromSQLite = try await sqlite.updateMemory(id: sqliteID, patch: .object(object), newEmbedding: nil)
        let fromFixture = try await fixture.updateMemory(id: fixtureID, patch: .object(object), newEmbedding: nil)

        let sqliteKeys = Set(extras(of: fromSQLite).keys)
        let fixtureKeys = Set(extras(of: fromFixture).keys)
        #expect(sqliteKeys == fixtureKeys, "sqlite kept \(sqliteKeys.sorted()); fixture kept \(fixtureKeys.sorted())")
        #expect(sqliteKeys == MemoryPatchContract.untypedPassthroughKeys)
        #expect(!sqliteKeys.contains("kind"))
        #expect(!sqliteKeys.contains("totally_made_up"))

        // …and the typed slots they surface agree too, not just storage.
        #expect(fromSQLite.pinned == fromFixture.pinned)
        #expect(fromSQLite.importance == fromFixture.importance)
        #expect(fromSQLite.tags == fromFixture.tags)
    }
}
