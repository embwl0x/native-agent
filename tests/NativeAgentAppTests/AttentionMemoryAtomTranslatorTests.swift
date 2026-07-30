import Context
import Foundation
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// (d) The record-id → atom-id translator exposed for mind-into-circulation must
/// produce the EXACT ContextAtomID the memory projection assigns the same record.
/// We prove equality against the projection's REAL derivation path
/// (NativeMemoryContextProjection.compiledProjection), not a copied constant.
private actor TranslatorProjectionMemoryMock: NativeMemoryContextProjectionMemory {
    private let records: [NativeMemoryProjectionRecord]
    init(records: [NativeMemoryProjectionRecord]) { self.records = records }

    func listContextProjectionRecords() async throws -> [NativeMemoryProjectionRecord] {
        records
    }
    func contextProjectionEmbeddingModelFingerprint() async throws -> String {
        "translator-test:3"
    }
    func embedForDerivedContext(_ texts: [String]) async throws -> [[Float]] {
        texts.map { [Float($0.utf8.count), Float($0.unicodeScalars.count), 1] }
    }
}

struct AttentionMemoryAtomTranslatorTests {
    private func projectionRecord(id: String) -> NativeMemoryProjectionRecord {
        NativeMemoryProjectionRecord(
            id: id,
            text: "User prefers concise technical summaries.",
            layer: "semantic",
            memoryKind: "preference",
            createdAt: "2026-07-09T12:00:00Z",
            updatedAt: "2026-07-09T12:01:00Z",
            sourceRunId: "test-run",
            status: "active",
            pinned: nil,
            confidence: 0.9,
            importance: 0.5,
            tags: nil,
            sourceQuality: nil,
            decay: nil,
            correction: nil,
            provenance: nil,
            extras: nil
        )
    }

    /// The atom id the REAL projection assigns to a single-record store.
    private func projectionAtomID(forRecordID id: String) async throws -> ContextAtomID {
        let result = try await NativeMemoryContextProjection(
            memory: TranslatorProjectionMemoryMock(records: [projectionRecord(id: id)])
        ).compiledProjection(previousSources: [:])
        let atom = try #require(result.changedSources.flatMap(\.atoms).first)
        return atom.id
    }

    @Test func translatorMatchesProjectionAtomID() async throws {
        let recordID = "mem-record-abc-123"
        let projectionID = try await projectionAtomID(forRecordID: recordID)
        let translated = try #require(
            NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: recordID)
        )
        #expect(translated == projectionID)
    }

    @Test func translatorMatchesAcrossDistinctRecords() async throws {
        for id in ["r1", "another-record", "1e5c-uuid-shaped-id"] {
            let projectionID = try await projectionAtomID(forRecordID: id)
            let translated = NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: id)
            #expect(translated == projectionID)
        }
    }

    @Test func translatorRejectsEmptyRecordID() {
        #expect(NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: "") == nil)
        #expect(NativeContextFlowRuntime.memoryRecordAtomID(forRecordID: "   ") == nil)
    }
}
