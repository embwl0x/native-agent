import Foundation
import NativeAgentCore
import Testing
@testable import KnowledgeGraph

@Test func growthDistillationUsesAuthoritativeSQLiteAndIsIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kg-growth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoryDirectory = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

    let legacyJSON = memoryDirectory.appendingPathComponent("knowledge_graph.json")
    let legacyBytes = Data("""
        {"_commit_seq":7,"version":1,"entities":{"legacy":{"id":"legacy","name":"Legacy","type":"concept"}},"edges":[]}
        """.utf8)
    try legacyBytes.write(to: legacyJSON)

    // An existing SQLite file establishes authoritative ownership. The KG
    // pool creates its schema and performs the guarded one-time JSON import.
    let sqlite = memoryDirectory.appendingPathComponent("memory.sqlite")
    try Data().write(to: sqlite)
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqlite)
    try await indexer.upsertGrowthDistillation(
        id: "growth_stable",
        summary: "first summary",
        sourceLines: 12,
        createdAt: "2026-07-13T12:00:00Z",
        legacyJSONPath: legacyJSON
    )
    try await indexer.upsertGrowthDistillation(
        id: "growth_stable",
        summary: "corrected retry summary",
        sourceLines: 12,
        createdAt: "2026-07-13T12:01:00Z",
        legacyJSONPath: legacyJSON
    )

    let store = try await KnowledgeGraphStore.loadFromMemoryV2(
        memoryDir: memoryDirectory,
        jsonImportPath: legacyJSON
    )
    #expect(store.entities["legacy"] != nil)
    guard case .object(let growth)? = store.entities["growth_stable"] else {
        Issue.record("expected one authoritative growth-distillation entity")
        return
    }
    #expect(growth["summary"] == .string("corrected retry summary"))
    #expect(growth["mention_count"] == .int(12))
    #expect(store.entities.keys.filter { $0 == "growth_stable" }.count == 1)
    #expect(try Data(contentsOf: legacyJSON) == legacyBytes)
}
