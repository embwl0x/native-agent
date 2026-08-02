import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore
import PersistenceCore

// LANE RETENTION PRIMITIVES (gpt-5.5 review A2/A4, 2026-08-02).
//
// `memoryHandles` is the bounded read a self-bounding writing lane does after
// every write — it replaced "list every active memory, decode all of it, filter
// on metadata in Swift". `archiveMemory` is the tombstone-free retirement that
// replaced `deleteMemory` on that same path.
//
// These run against the REAL SQLite store: the bounded query is SQL, and the
// tombstone the archive avoids is written inside `MemoryV2+Storage.deleteMemory`.

@Suite("LaneRetentionHandles")
struct LaneRetentionHandlesTests {

    private func makeTempRoot(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaneRetentionHandles-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sqliteMemory(root: URL) throws -> SwiftNativeMemoryV2 {
        SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(),
            storage: MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        )
    }

    /// Memory + the bridge behind it, so a test can ask the STORAGE whether a
    /// tombstone was minted (the bridge is the only holder of that question).
    private func sqliteMemoryWithBridge(
        root: URL
    ) throws -> (memory: SwiftNativeMemoryV2, bridge: MemoryStorageBridge) {
        let bridge = MemoryStorageBridge(storage: try MemoryStorage(dataRoot: root))
        return (SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(), storage: bridge), bridge)
    }

    @Test func handlesAreLaneScopedNewestFirstAndBounded() async throws {
        let root = try makeTempRoot("scoped")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = try sqliteMemory(root: root)

        for index in 0..<5 {
            _ = try await memory.store(
                content: "Workshop mission number \(index) completed and its outcome was verified.",
                source: "workshop:mission-\(index)",
                metadata: .object(["kind": .string("operational")])
            )
        }
        // A different lane, and a bare fact: neither belongs to this sweep.
        _ = try await memory.store(
            content: "Dream cycle number one folded three views into a settled principle.",
            source: "dream:cycle-1",
            metadata: .object(["kind": .string("operational")])
        )

        let all = try await memory.memoryHandles(sourcePrefix: "workshop:", limit: nil)
        #expect(all.count == 5, "only this lane's rows")
        #expect(all.allSatisfy { ($0.source ?? "").hasPrefix("workshop:") })
        #expect(all.map(\.createdAt) == all.map(\.createdAt).sorted(by: >), "newest first")

        let bounded = try await memory.memoryHandles(sourcePrefix: "workshop:", limit: 2)
        #expect(bounded.count == 2)
        #expect(bounded.map(\.id) == Array(all.map(\.id).prefix(2)))
    }

    /// The property retention leans on: an archived row leaves the lane's
    /// ACTIVE set, so the sweep converges instead of re-archiving forever.
    @Test func archivedRowsLeaveTheLaneWithoutLeavingTheStore() async throws {
        let root = try makeTempRoot("archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let (memory, bridge) = try sqliteMemoryWithBridge(root: root)

        let content = "Workshop mission \"Rotate the credentials\" completed and was verified."
        let record = try await memory.store(
            content: content, source: "workshop:mission-alpha",
            metadata: .object(["kind": .string("operational")]))

        _ = try await memory.archiveMemory(id: record.id)

        #expect(try await memory.memoryHandles(sourcePrefix: "workshop:", limit: nil).isEmpty)
        let stored = try #require(
            (try await memory.listMemory(kind: nil)).first { $0.id == record.id })
        #expect(stored.status == "archived")

        // AND — the whole point of A2 — no rejection tombstone was minted, so
        // the same prose can be written again.
        #expect(try await bridge.isTombstoned(content: content) == false)
        let rerun = try await memory.store(
            content: content, source: "workshop:mission-alpha-rerun",
            metadata: .object(["kind": .string("operational")]))
        #expect(rerun.id != record.id, "the archived row is not resurrected; a fresh one lands")
    }

    /// Contrast case, so the tombstone claim is not vacuous: DELETE still
    /// tombstones. Archiving is a different primitive on purpose.
    @Test func deleteStillTombstonesWhichIsWhyRetentionMustNotUseIt() async throws {
        let root = try makeTempRoot("delete-contrast")
        defer { try? FileManager.default.removeItem(at: root) }
        let (memory, bridge) = try sqliteMemoryWithBridge(root: root)

        let content = "Workshop mission \"Sweep the artifacts\" completed and was verified."
        let record = try await memory.store(
            content: content, source: "workshop:mission-alpha",
            metadata: .object(["kind": .string("operational")]))
        _ = try await memory.deleteMemory(id: record.id)

        #expect(try await bridge.isTombstoned(content: content))
        await #expect(throws: (any Error).self) {
            _ = try await memory.store(
                content: content, source: "workshop:mission-alpha-rerun",
                metadata: .object(["kind": .string("operational")]))
        }
    }
}
