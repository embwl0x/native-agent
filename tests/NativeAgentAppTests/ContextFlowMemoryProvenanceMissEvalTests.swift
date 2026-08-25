import Context
import Foundation
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

private struct MemoryProvenanceMissEmbeddingProvider: EmbeddingProvider {
    let dimensions = 8
    let modelId = "context-provenance-miss-eval"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            vector[text.utf8.reduce(0) { ($0 + Int($1)) % dimensions }] = 1
            return vector
        }
    }
}

private func provenanceMissRecord(id: String, text: String) -> MemoryV2.MemoryRecord {
    MemoryV2.MemoryRecord(
        id: id,
        text: text,
        layer: "semantic",
        memoryKind: "fact",
        createdAt: "2026-08-24T12:00:00Z",
        sourceRunId: "context-provenance-miss-eval",
        status: "active",
        confidence: 0.9
    )
}

@Suite("app.runtimes · Context Flow memory provenance miss", .serialized)
struct ContextFlowMemoryProvenanceMissEvalTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-provenance-miss-\(UUID().uuidString)", isDirectory: true)
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "# SOUL\nProvenance fixture.".write(
            to: persona.appendingPathComponent("SOUL.md"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @Test("a partial memory reverse-index miss emits one turn-correlated trace receipt")
    func partialMissIsTurnTraceEvidence() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = InMemoryMemoryStorage()
        _ = try await storage.insert(
            record: provenanceMissRecord(
                id: "provenance-a",
                text: "The greenhouse irrigation schedule runs at dawn and needs calibration."
            ),
            embedding: nil
        )
        _ = try await storage.insert(
            record: provenanceMissRecord(
                id: "provenance-b",
                text: "The greenhouse humidity sensor reports before dawn calibration."
            ),
            embedding: nil
        )
        let index = MemoryAtomRecordIndex()
        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: NativeContextFlowConfiguration(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(
                embedder: MemoryProvenanceMissEmbeddingProvider(),
                storage: storage
            ),
            memoryProvenanceIndex: index
        )
        let request = ContextTurnRequest(
            surface: .chat,
            origin: .localAuthenticated,
            userMessage: "What should I know about greenhouse dawn calibration?"
        )

        let complete = try await runtime.prepareContextTurn(request)
        let selectedAtomIDs = complete.packet.selectedItems.compactMap { item -> ContextAtomID? in
            switch item.pointer.kind {
            case .memory, .correction: return item.pointer.atomID
            default: return nil
            }
        }
        #expect(selectedAtomIDs.count >= 2)
        let retainedAtomID = try #require(selectedAtomIDs.first)
        let retainedRecordID = try #require(complete.selectedMemoryRecordIDs.first)
        index.replaceAll([retainedAtomID: retainedRecordID])

        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subscription = await bus.subscribe(capacity: 8)
        let turnID = "context-provenance-miss-turn"
        let receipt = Task { () -> TurnTraceEvent? in
            for await event in subscription.stream
            where event.kind == "context.memory_provenance_miss" && event.turnId == turnID {
                return event
            }
            return nil
        }

        _ = try await TurnTraceContext.$bus.withValue(bus) {
            try await TurnTraceContext.$turnId.withValue(turnID) {
                try await runtime.prepareContextTurn(request)
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await bus.unsubscribe(subscription.id)
        }
        let event = try #require(await receipt.value, "no memory provenance miss trace within 3s")
        timeout.cancel()
        await bus.unsubscribe(subscription.id)

        let resolution = try #require(await runtime.memoryProvenanceResolution())
        #expect(resolution.resolvedMemoryAtomCount == 1)
        #expect(resolution.unresolvedMemoryAtomCount > 0)
        guard case .object(let payload) = event.payload else {
            Issue.record("memory provenance trace must carry its bounded count payload")
            return
        }
        #expect(payload["requestedMemoryAtomCount"] == .int(Int64(resolution.requestedMemoryAtomCount)))
        #expect(payload["resolvedMemoryAtomCount"] == .int(Int64(resolution.resolvedMemoryAtomCount)))
        #expect(payload["unresolvedMemoryAtomCount"] == .int(Int64(resolution.unresolvedMemoryAtomCount)))
        #expect(payload["provenanceIndexCount"] == .int(1))
        await runtime.stop()
    }
}
