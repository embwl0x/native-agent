import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import MemoryV2

private struct UnavailableRecordReadEmbedder: EmbeddingProvider {
    let dimensions = 2
    let modelId = "record-read-no-embedding"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        Issue.record("exact-ID lookup must not embed")
        throw MemoryV2Error.storageUnavailable
    }
}

@Suite("Canonical memory exact-record reads")
struct MemoryRecordReadTests {
    @Test func sqlitePointReadPreservesFullTextAndUsesCanonicalEligibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-record-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        let fullText = String(repeating: "The orchard watering plan is weekly. ", count: 90) + "End."
        _ = try await storage.insertMemory(StoredMemory(id: "full", content: fullText, personaId: "Agent"))
        let memory = SwiftNativeMemoryV2(embedder: UnavailableRecordReadEmbedder(), storage: MemoryStorageBridge(storage: storage))
        let found = try #require(try await memory.readMemoryRecord(id: "full", surface: "chat"))
        #expect(found.text == fullText)
        #expect(found.text.count > memoryRecallContentCap)
        #expect(try await memory.readMemoryRecord(id: "full", surface: "slack") == nil)
        #expect(try await memory.readMemoryRecord(id: "full", persona: "Other", surface: "chat") == nil)
        #expect(try await memory.readMemoryRecord(id: "unknown", surface: "chat") == nil)
        #expect(try await memory.readMemoryRecord(id: "full", surface: "unregistered") == nil)

        // The same ID is rechecked, not cached, after canonical supersession.
        #expect(try await storage.archiveSuperseded(id: "full", by: "replacement"))
        #expect(try await memory.readMemoryRecord(id: "full", surface: "chat") == nil)
    }

    @Test func terminalTombstonedAndLowQualityRowsCannotUsePointReadAsBypass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-record-gates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(dataRoot: root)
        for lifecycle in [MemoryLifecycle.corrected, MemoryLifecycle.contradicted, MemoryLifecycle.deleted] {
            _ = try await storage.insertMemory(StoredMemory(
                id: lifecycle, content: "The orchard watering plan is weekly for \(lifecycle).", lifecycle: lifecycle
            ))
        }
        _ = try await storage.insertMemory(StoredMemory(id: "rejected", content: "The orchard watering plan is rejected."))
        try await MemoryStorageBridge(storage: storage).recordTombstone(content: "The orchard watering plan is rejected.", reason: "fixture")
        _ = try await storage.insertMemory(StoredMemory(id: "noise", content: "Current session context is reset."))
        let memory = SwiftNativeMemoryV2(embedder: UnavailableRecordReadEmbedder(), storage: MemoryStorageBridge(storage: storage))
        for id in ["corrected", "contradicted", "deleted", "rejected", "noise"] {
            #expect(try await memory.readMemoryRecord(id: id, surface: "chat") == nil)
        }
    }
}
