import Foundation
import Testing
import NativeAgentCore
import MemoryV2
@testable import NativeAgentApp

@Suite("Memory note persistence", .serialized)
struct MemoryNotePersistenceTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-note-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func legacyNoteFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.lastPathComponent == "notes.jsonl" else {
                return nil
            }
            return url
        }
    }

    private func seedLegacyNote(at root: URL) throws {
        let directory = root
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let note = """
        {"id":"private-note","ts":"2026-07-09T12:00:00Z","persona":"Agent","kind":"user_note","text":"User keeps this private note canonical.","source_run":"legacy","confidence":0.8,"importance":0.5}
        """
        try Data(note.utf8).write(to: directory.appendingPathComponent("notes.jsonl"))
    }

    @Test func macAndTelegramNotesPersistOnlyCanonicalRecords() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = InMemoryMemoryStorage()
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(),
            storage: storage
        )
        let client = NativeClient(baseURL: "http://127.0.0.1")

        let macResponse = try await client.postNote(
            text: "User prefers concise release notes.",
            kind: "user_note",
            tags: ["release"],
            memory: memory
        )
        let macID = try #require(macResponse["id"] as? String)
        #expect(macResponse["path"] == nil)

        let telegramID = try await TelegramMemoryWriterBridge(
            dataRoot: root,
            memory: memory
        ).note(
            text: "User keeps private notes in canonical memory.",
            kind: "telegram_note",
            source: "telegram:/note"
        )

        let records = try await storage.listMemory(kind: nil)
        #expect(Set(records.map(\.id)) == Set([macID, telegramID]))
        #expect(records.allSatisfy { record in
            guard case .object(let metadata)? = record.extras else { return false }
            return metadata["note_id"] == nil && metadata["note_path"] == nil
        })
        #expect(legacyNoteFiles(under: root).isEmpty)
    }

    @Test func memoryV2FailureLeavesNoLegacyNoteOrCanonicalRow() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = InMemoryMemoryStorage()
        let failingMemory = SwiftNativeMemoryV2(
            embedder: FailClosedEmbeddingProvider(),
            storage: storage
        )
        let client = NativeClient(baseURL: "http://127.0.0.1")

        await #expect(throws: (any Error).self) {
            _ = try await client.postNote(
                text: "User prefers private notes to fail closed.",
                memory: failingMemory
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await TelegramMemoryWriterBridge(
                dataRoot: root,
                memory: failingMemory
            ).note(
                text: "User keeps Telegram notes private on write failure.",
                kind: "telegram_note",
                source: "telegram:/note"
            )
        }

        #expect(try await storage.listMemory(kind: nil).isEmpty)
        #expect(legacyNoteFiles(under: root).isEmpty)
    }

    @Test func deletingLastImportedNoteThenRelaunchingDoesNotResurrectIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyNote(at: root)

        let firstStore = try MemoryStorage(dataRoot: root)
        let firstReport = await MemoryV2Migrator(
            dataRoot: root,
            storage: RealMemoryStorage(storage: firstStore),
            embedder: MockEmbeddingProvider()
        ).migrate()
        #expect(firstReport.memoriesImported == 1)
        #expect(try await firstStore.memory(id: "private-note") != nil)

        #expect(try await firstStore.deleteMemory(id: "private-note"))
        #expect(try await firstStore.listMemories(persona: nil, status: nil, limit: nil).isEmpty)

        let relaunchedStore = try MemoryStorage(dataRoot: root)
        let relaunchReport = await MemoryV2Migrator(
            dataRoot: root,
            storage: RealMemoryStorage(storage: relaunchedStore),
            embedder: MockEmbeddingProvider()
        ).migrate()

        #expect(relaunchReport.skippedAlreadyMigrated)
        #expect(relaunchReport.memoriesImported == 0)
        #expect(try await relaunchedStore.memory(id: "private-note") == nil)
        #expect(legacyNoteFiles(under: root).count == 1)
    }
}
