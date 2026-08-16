import Testing
import Foundation
import NativeAgentCore
@testable import MemoryV2

@Suite("MemoryV2Migrator")
struct MigrationTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memv2-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(at root: URL) throws {
        let fm = FileManager.default
        let memDir = root.appendingPathComponent("memory", isDirectory: true)
        let propDir = root.appendingPathComponent("memory_proposals", isDirectory: true)
        try fm.createDirectory(at: memDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: propDir, withIntermediateDirectories: true)

        let memJSON = """
        [
          {"id":"m1","text":"the user prefers terse responses","createdAt":"2026-05-01T00:00:00Z","layer":"user"},
          {"id":"m2","text":"NativeAgent persists data under <dataRoot>","createdAt":"2026-05-02T00:00:00Z","layer":"project"}
        ]
        """.data(using: .utf8)!
        try memJSON.write(to: memDir.appendingPathComponent("memory.json"))

        let p1 = #"{"proposal_id":"p1","fact_text":"first approved fact","status":"approved","source":"legacy"}"#.data(using: .utf8)!
        let p2 = #"{"proposal_id":"p2","fact_text":"second rejected fact","status":"rejected"}"#.data(using: .utf8)!
        let p3 = #"{"proposal_id":"p3","fact_text":"third pending fact","status":"pending"}"#.data(using: .utf8)!
        try p1.write(to: propDir.appendingPathComponent("candidate-p1.json"))
        try p2.write(to: propDir.appendingPathComponent("candidate-p2.json"))
        try p3.write(to: propDir.appendingPathComponent("candidate-p3.json"))

        let tombs = "tomb:alpha\ntomb:beta\n# comment line\n\n".data(using: .utf8)!
        try tombs.write(to: root.appendingPathComponent(".rejected_tombstones"))
    }

    private func seedLegacyNotes(at root: URL) throws {
        let notesDir = root
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("Female", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notes = """
        {"id":"fixture-note","ts":"2026-05-08T17:00:00Z","persona":"Female","kind":"test","text":"parity probe","tags":["parity"],"source_run":"fixture","confidence":0.8,"importance":0.5,"_test_fixture":true}
        {"id":"approved-note","ts":"2026-05-08T18:00:00Z","persona":"Female","kind":"reflection","text":"approved note survives","tags":["phase"],"source_run":"run-1","confidence":0.95,"importance":0.9}
        """
        try Data(notes.utf8).write(to: notesDir.appendingPathComponent("notes.jsonl"))
    }

    @Test func migrates_memories_and_only_approved_legacy_proposals() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(at: root)

        let storage = InMemoryMemoryStorageStub()
        let migrator = MemoryV2Migrator(
            dataRoot: root,
            storage: storage,
            embedder: MockEmbeddingProvider()
        )
        let report = await migrator.migrate()

        #expect(!report.skippedAlreadyMigrated)
        #expect(report.memoriesImported == 3)
        #expect(report.proposalsImported == 0)
        #expect(report.tombstonesImported == 2)
        #expect(report.errors.isEmpty)

        let snap = await storage.snapshot()
        #expect(snap.memories == 3)
        #expect(snap.proposals == 0)
        #expect(snap.tombstones == 2)
        let approved = await storage.memorySnapshot(id: "p1")
        #expect(approved?.text == "first approved fact")
        #expect(approved?.status == "active")

        // Marker file written.
        let marker = root.appendingPathComponent("memory/.migrated_to_sqlite_v2_approved_only")
        #expect(FileManager.default.fileExists(atPath: marker.path))

        // Original files preserved (30-day backup window).
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory/memory.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory_proposals/candidate-p1.json").path))
    }

    @Test func migrates_approved_legacy_notes_jsonl_and_skips_test_fixtures() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyNotes(at: root)

        let storage = InMemoryMemoryStorageStub()
        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: storage,
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(report.memoriesImported == 1)
        #expect(report.errors.isEmpty)
        let snap = await storage.snapshot()
        #expect(snap.memories == 1)
        #expect(await storage.memorySnapshot(id: "fixture-note") == nil)
        let approved = await storage.memorySnapshot(id: "approved-note")
        #expect(approved?.text == "approved note survives")
        #expect(approved?.memoryKind == "reflection")
        #expect(approved?.confidence == 0.95)
        #expect(approved?.importance == 0.9)
        #expect(approved?.tags == ["phase"])
    }

    @Test func second_run_is_idempotent_via_marker() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(at: root)

        let storage = InMemoryMemoryStorageStub()
        _ = await MemoryV2Migrator(dataRoot: root, storage: storage).migrate()

        // Second run hits the marker fast-path.
        let report2 = await MemoryV2Migrator(dataRoot: root, storage: storage).migrate()
        #expect(report2.skippedAlreadyMigrated)
        #expect(report2.memoriesImported == 0)
    }

    @Test func malformed_legacy_wrapper_never_stamps_completion() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let memoryDir = root.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try Data(#"{"unexpected":[]}"#.utf8).write(
            to: memoryDir.appendingPathComponent("memory.json")
        )

        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: InMemoryMemoryStorageStub(),
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(report.requiredFailures == 1)
        #expect(!FileManager.default.fileExists(
            atPath: memoryDir.appendingPathComponent(".migrated_to_sqlite_v2_approved_only").path
        ))
    }

    @Test func malformed_legacy_note_row_never_stamps_completion() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notesDir = root.appendingPathComponent("memory/persona", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        try Data(#"{"id":"missing-text"}"#.utf8).write(
            to: notesDir.appendingPathComponent("notes.jsonl")
        )

        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: InMemoryMemoryStorageStub(),
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(report.requiredFailures == 1)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("memory/.migrated_to_sqlite_v2_approved_only").path
        ))
    }

    @Test func marker_with_empty_store_still_skips_completed_migration() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyNotes(at: root)
        let marker = root.appendingPathComponent("memory/.migrated_to_sqlite_v2_approved_only")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: marker)

        let storage = InMemoryMemoryStorageStub()
        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: storage,
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(report.skippedAlreadyMigrated)
        #expect(report.memoriesImported == 0)
        #expect(await storage.memorySnapshot(id: "approved-note") == nil)
    }

    @Test func second_run_without_marker_still_dedupes_via_storage() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(at: root)

        let storage = InMemoryMemoryStorageStub()
        _ = await MemoryV2Migrator(dataRoot: root, storage: storage).migrate()

        // Nuke the marker to simulate a partial first run.
        try FileManager.default.removeItem(at: root.appendingPathComponent("memory/.migrated_to_sqlite_v2_approved_only"))

        let report2 = await MemoryV2Migrator(dataRoot: root, storage: storage).migrate()
        #expect(report2.memoriesImported == 0)
        #expect(report2.proposalsImported == 0)
        #expect(report2.tombstonesImported == 0)

        let snap = await storage.snapshot()
        #expect(snap.memories == 3)
        #expect(snap.proposals == 0)
        #expect(snap.tombstones == 2)
    }

    @Test func rerun_repairs_blank_sqlite_proposal_import() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let propDir = root.appendingPathComponent("memory_proposals", isDirectory: true)
        try fm.createDirectory(at: propDir, withIntermediateDirectories: true)
        let approved = #"{"proposal_id":"approved-legacy","fact_text":"approved fact survives","status":"approved","source":"legacy"}"#.data(using: .utf8)!
        let rejected = #"{"proposal_id":"rejected-legacy","fact_text":"rejected fact is dropped","status":"rejected"}"#.data(using: .utf8)!
        let pending = #"{"proposal_id":"pending-legacy","fact_text":"pending fact is dropped","status":"pending"}"#.data(using: .utf8)!
        try approved.write(to: propDir.appendingPathComponent("candidate-approved-legacy.json"))
        try rejected.write(to: propDir.appendingPathComponent("candidate-rejected-legacy.json"))
        try pending.write(to: propDir.appendingPathComponent("candidate-pending-legacy.json"))

        let store = try MemoryStorage(dataRoot: root)
        _ = try await store.insertProposal(StoredProposal(id: "candidate-approved-legacy", content: ""))
        _ = try await store.insertProposal(StoredProposal(id: "candidate-rejected-legacy", content: ""))
        _ = try await store.insertProposal(StoredProposal(id: "candidate-pending-legacy", content: ""))

        let storage = RealMemoryStorage(storage: store)
        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: storage,
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(report.memoriesImported == 1)
        #expect(report.proposalsImported == 0)
        #expect(report.errors.isEmpty)

        let mem = try await store.memory(id: "approved-legacy")
        #expect(mem?.content == "approved fact survives")
        #expect(mem?.status == "active")

        let proposals = try await store.listProposals(status: nil)
        #expect(proposals.isEmpty)
        let memories = try await store.listMemories(persona: nil, status: "active", limit: nil)
        #expect(memories.count == 1)
    }

    @Test func approved_legacy_proposal_refreshes_existing_memory() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let propDir = root.appendingPathComponent("memory_proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: propDir, withIntermediateDirectories: true)
        let approved = #"{"proposal_id":"approved-legacy","fact_text":"approved fact refreshed","status":"approved","source":"legacy"}"#.data(using: .utf8)!
        try approved.write(to: propDir.appendingPathComponent("candidate-approved-legacy.json"))

        let store = try MemoryStorage(dataRoot: root)
        _ = try await store.insertMemory(StoredMemory(
            id: "approved-legacy",
            content: "stale approved fact",
            embedding: [0, 0, 0]
        ))

        let report = await MemoryV2Migrator(
            dataRoot: root,
            storage: RealMemoryStorage(storage: store),
            embedder: MockEmbeddingProvider(dimensions: 4)
        ).migrate()

        #expect(report.memoriesImported == 0)
        #expect(report.errors.isEmpty)
        let mem = try await store.memory(id: "approved-legacy")
        #expect(mem?.content == "approved fact refreshed")
        #expect(mem?.embedding?.count == 4)
    }
}
