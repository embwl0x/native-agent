import Foundation
import Testing
@testable import MemoryV2

// Skills-recall rework (2026-07-03): the skill-pointer index that makes
// skills surface through per-turn recall. Pins the full lifecycle: add,
// idempotent re-sync, body-change update, removal on archive (status flip,
// NO tombstone), and reappearance under the same id.
@Suite struct SkillIndexTests {

    private func makeMemory() throws -> (SwiftNativeMemoryV2, MemoryStorage) {
        let store = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: store)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(dimensions: 32),
            storage: bridge
        )
        return (memory, store)
    }

    private func makeBodiesDir(_ skills: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-index-tests-\(UUID().uuidString)/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in skills {
            try body.write(
                to: dir.appendingPathComponent("\(name).md"),
                atomically: true, encoding: .utf8
            )
        }
        return dir
    }

    @Test func syncAddsPointerRowsWithSkillKindAndNoDecayExposure() async throws {
        let (memory, _) = try makeMemory()
        let dir = try makeBodiesDir([
            "oauth-hard-check": "# OAuth Hard Check\n\nUse this when asked whether an OAuth integration is working.\n",
        ])
        let result = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(result.added == 1)
        let rows = try await memory.listMemory(kind: "skill")
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == "skill-pointer:oauth-hard-check")
        #expect(row.text.contains("Skill available: oauth-hard-check"))
        #expect(row.text.contains("Use this when asked whether an OAuth integration is working."))
        #expect(row.text.contains("read_skill"))
        #expect(row.status == "active")
    }

    @Test func resyncIsIdempotent() async throws {
        let (memory, _) = try makeMemory()
        let dir = try makeBodiesDir(["a-skill": "# A\n\nUse when testing idempotence.\n"])
        _ = try await memory.syncSkillPointers(bodiesDirs: [dir])
        let second = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(second.removed == 0)
        #expect(second.unchanged == 1)
        let rows = try await memory.listMemory(kind: "skill")
        #expect(rows.count == 1)
    }

    @Test func missingOptionalShelvesRemainHealthyAndVisibleInReceipt() async throws {
        let (memory, _) = try makeMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-index-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeBodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
        let personaBodies = root.appendingPathComponent("persona/skills/bodies", isDirectory: true)
        let receipt = root.appendingPathComponent("skills/.pointer_sync_receipt.json")

        let result = try await memory.syncSkillPointersRecordingReceipt(
            bodiesDirs: [runtimeBodies, personaBodies],
            receiptURL: receipt
        )
        #expect(result == .init(added: 0, updated: 0, removed: 0, unchanged: 0))

        let data = try Data(contentsOf: receipt)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(object["status"] == "ok")
        #expect(object["presentBodiesDirs"] == "")
        #expect(object["missingOptionalBodiesDirs"]?.contains(runtimeBodies.path) == true)
        #expect(object["missingOptionalBodiesDirs"]?.contains(personaBodies.path) == true)
    }

    @Test func disabledRuntimeRegistryRowSuppressesAutomaticRecallAcrossShelves() async throws {
        let (memory, _) = try makeMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-index-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeBodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
        let personaBodies = root.appendingPathComponent("persona/skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeBodies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personaBodies, withIntermediateDirectories: true)
        try "# Disabled\n\nUse when this should stay unavailable.\n".write(
            to: runtimeBodies.appendingPathComponent("disabled-skill.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Duplicate\n\nUse when the disabled runtime row must still win.\n".write(
            to: personaBodies.appendingPathComponent("disabled-skill.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Persona\n\nUse when a curated persona skill is available.\n".write(
            to: personaBodies.appendingPathComponent("persona-skill.md"),
            atomically: true,
            encoding: .utf8
        )
        let registry = root.appendingPathComponent("skills/registry.json")
        let registryData = try JSONSerialization.data(withJSONObject: [[
            "id": "disabled-skill",
            "name": "Disabled Skill",
            "status": "disabled",
        ]])
        try registryData.write(to: registry, options: .atomic)

        let result = try await memory.syncSkillPointers(
            bodiesDirs: [runtimeBodies, personaBodies],
            runtimeRegistryURL: registry
        )
        #expect(result.added == 1)
        let rows = try await memory.listMemory(kind: "skill")
        #expect(rows.map(\.id) == ["skill-pointer:persona-skill"])
    }

    @Test func malformedExistingRegistryFailsLoudAndRecordsFailure() async throws {
        let (memory, _) = try makeMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-index-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeBodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeBodies, withIntermediateDirectories: true)
        try "# Existing\n\nUse when corrupt authority must fail closed.\n".write(
            to: runtimeBodies.appendingPathComponent("existing.md"),
            atomically: true,
            encoding: .utf8
        )
        let registry = root.appendingPathComponent("skills/registry.json")
        try Data("{not-json".utf8).write(to: registry)
        let receipt = root.appendingPathComponent("skills/.pointer_sync_receipt.json")

        await #expect(throws: Error.self) {
            _ = try await memory.syncSkillPointersRecordingReceipt(
                bodiesDirs: [runtimeBodies],
                runtimeRegistryURL: registry,
                receiptURL: receipt
            )
        }
        let data = try Data(contentsOf: receipt)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(object["status"] == "failed")
        #expect(object["error"]?.isEmpty == false)
        #expect(try await memory.listMemory(kind: "skill").isEmpty)
    }

    @Test func bodyChangeUpdatesPointerInPlace() async throws {
        let (memory, _) = try makeMemory()
        let dir = try makeBodiesDir(["a-skill": "# A\n\nUse when the old hook applies.\n"])
        _ = try await memory.syncSkillPointers(bodiesDirs: [dir])
        try "# A\n\nUse when the NEW hook applies.\n".write(
            to: dir.appendingPathComponent("a-skill.md"),
            atomically: true, encoding: .utf8
        )
        let result = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(result.updated == 1)
        #expect(result.added == 0)
        let rows = try await memory.listMemory(kind: "skill")
        #expect(rows.count == 1)
        #expect(rows.first?.text.contains("NEW hook") == true)
    }

    @Test func removedSkillRetiresWithoutTombstoneAndReappears() async throws {
        let (memory, store) = try makeMemory()
        let dir = try makeBodiesDir(["gone-skill": "# G\n\nUse when testing removal.\n"])
        _ = try await memory.syncSkillPointers(bodiesDirs: [dir])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone-skill.md"))

        let removal = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(removal.removed == 1)
        // Retired = status deleted, NOT recall-eligible, and NO rejection
        // tombstone minted (deleteMemory would create one and block a
        // similar pointer forever).
        let stored = try await store.memory(id: "skill-pointer:gone-skill")
        #expect(stored?.status == "deleted")
        let tombstoned = try await store.isTombstoned(
            content: stored?.content ?? "impossible"
        )
        #expect(tombstoned == false)

        // Reappearance flips the SAME row back to active.
        try "# G\n\nUse when testing removal.\n".write(
            to: dir.appendingPathComponent("gone-skill.md"),
            atomically: true, encoding: .utf8
        )
        let back = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(back.updated == 1)
        #expect(back.added == 0)
        let revived = try await store.memory(id: "skill-pointer:gone-skill")
        #expect(revived?.status == "active")
    }

    @Test func pointerTextSkipsHeadingsAndStripsDecorations() {
        let text = SwiftNativeMemoryV2.skillPointerText(
            name: "x",
            body: "# Title\n\n**When to load:** any time a confident claim is coming.\n\nMore body.\n"
        )
        #expect(text.contains("any time a confident claim is coming."))
        #expect(!text.contains("# Title"))
        #expect(!text.contains("**When to load:**"))
    }

    @Test func pointerTextBoundsRogueHookLines() {
        let longHook = String(repeating: "very long hook text ", count: 40)
        let text = SwiftNativeMemoryV2.skillPointerText(name: "x", body: "# T\n\n\(longHook)\n")
        #expect(text.count < 400)
        #expect(text.contains("\u{2026}"))
    }

    @Test func syncWritesThroughActiveEmbeddingEpoch() async throws {
        // 2026-07-21 audit regression: the pointer write path forwarded
        // embeddingEpoch: nil, so requireWritableEpoch threw
        // embeddingEpochMismatch on EVERY sync after an epoch activation.
        let embedder = MockEmbeddingProvider(dimensions: 32)
        let store = try MemoryStorage(
            inMemoryName: "skill-index-epoch-\(UUID().uuidString)"
        )
        let bridge = MemoryStorageBridge(storage: store)
        let memory = SwiftNativeMemoryV2(embedder: embedder, storage: bridge)

        // Activate the embedder's epoch on an empty corpus.
        _ = try await store.activateEmbeddingEpoch(embedder.embeddingEpoch, staged: [])

        let dir = try makeBodiesDir([
            "epoch-skill": "# E\n\nUse when the epoch gate applies.\n",
        ])
        let first = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(first.added == 1)
        let stored = try #require(try await store.memory(id: "skill-pointer:epoch-skill"))
        #expect(stored.embeddingEpoch == embedder.embeddingEpoch.rawValue)

        // The in-place update path threads the epoch too (pre-fix this
        // threw embeddingEpochMismatch on updateMemory).
        try "# E\n\nUse when the epoch gate applies, revised.\n".write(
            to: dir.appendingPathComponent("epoch-skill.md"),
            atomically: true, encoding: .utf8
        )
        let second = try await memory.syncSkillPointers(bodiesDirs: [dir])
        #expect(second.updated == 1)
        let updated = try #require(try await store.memory(id: "skill-pointer:epoch-skill"))
        #expect(updated.embeddingEpoch == embedder.embeddingEpoch.rawValue)
    }
}
