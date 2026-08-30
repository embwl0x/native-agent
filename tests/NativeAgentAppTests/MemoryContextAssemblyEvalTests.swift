import ChatOrchestration
import Context
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

private struct AssemblyEmbedding: EmbeddingProvider {
    let dimensions = 3
    let modelId = "assembly-fixture"
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

/// Frozen, nonpersonal assembly proof. Uses the APP's real projection,
/// coordinator, source competition, disclosure, and renderer. The vectors are
/// fixtures, so this is not advertised as live semantic answer-quality proof.
@Suite("Memory/context production assembly", .serialized)
struct MemoryContextAssemblyEvalTests {
    @Test func topicCorrectionsStayRelevantAcrossSurfacesAndFeedbackIsExact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-assembly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("persona")
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "# SOUL\nBe a thoughtful companion.\n".write(to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)
        try "# VOICE\nSpeak naturally.\n".write(to: persona.appendingPathComponent("VOICE.md"), atomically: true, encoding: .utf8)
        try (0..<6).map { "## Greenhouse note \($0)\nGreenhouse maintenance has a separate record.\n" }
            .joined(separator: "\n").write(to: persona.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)
        let storage = InMemoryMemoryStorage()
        for record in [
            MemoryV2.MemoryRecord(id: "global", text: "Only remind the user about work when explicitly requested.",
                memoryKind: "correction", createdAt: "2026-08-01T00:00:00Z", status: "active"),
            MemoryV2.MemoryRecord(id: "greenhouse", text: "The greenhouse watering time is dusk, not dawn.",
                memoryKind: "correction", createdAt: "2026-08-01T00:00:00Z", status: "active",
                extras: .object(["context_topics": .array([.string("greenhouse")])])),
            MemoryV2.MemoryRecord(id: "color", text: "The user's favorite color is teal.",
                memoryKind: "preference", createdAt: "2026-08-01T00:00:00Z", status: "active"),
            MemoryV2.MemoryRecord(id: "old", text: "The user's favorite color is orange.",
                memoryKind: "preference", lifecycle: "corrected", createdAt: "2026-07-01T00:00:00Z", status: "active"),
        ] { _ = try await storage.insert(record: record, embedding: nil) }
        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: .init(mode: .active, budget: .mib32),
            memoryOverride: SwiftNativeMemoryV2(embedder: AssemblyEmbedding(), storage: storage),
            environmentOverride: [:], publicSafeModeOverride: false, personaOverride: { nil }
        )
        await runtime.start()
        do {
            for surface in [ContextSurface.chat, .telegram] {
                let casual = try await runtime.prepareFrozenContextTurn(.init(
                    surface: surface, origin: .localAuthenticated,
                    userMessage: "What is my favorite color?", characterBudget: 32_000
                ))
                let rendered = SwiftNativeTurnEngine.renderContextPacket(casual)
                #expect(rendered.contains("favorite color is teal"))
                #expect(!rendered.contains("favorite color is orange"))
                #expect(!rendered.contains("watering time is dusk"))
                #expect(rendered.contains("Only remind the user"))

                let work = try await runtime.prepareFrozenContextTurn(.init(
                    surface: surface, origin: .localAuthenticated,
                    userMessage: "What did we decide about the greenhouse?", characterBudget: 32_000
                ))
                #expect(SwiftNativeTurnEngine.renderContextPacket(work).contains("watering time is dusk"))
                #expect(work.packet.receipt.mandatoryCoverage == 1)
                #expect(work.packet.characterCount <= 32_000)

                let followup = try await runtime.prepareFrozenContextTurn(.init(
                    surface: surface, origin: .localAuthenticated, userMessage: "Continue that",
                    recentTurns: ["We are discussing the greenhouse."], characterBudget: 32_000
                ))
                #expect(SwiftNativeTurnEngine.renderContextPacket(followup).contains("watering time is dusk"))
            }

            // The live preparation path carries exact selected-record mapping.
            let prepared = try await runtime.prepareContextTurn(.init(
                surface: .chat, origin: .localAuthenticated, userMessage: "favorite color teal"
            ))
            #expect(prepared.selectedMemoryRecordIDs.contains("color"))
            await prepared.recordAppliedMemoryCorrection(recordID: "unknown", replacementID: "replacement")
            await prepared.recordAppliedMemoryCorrection(recordID: "color", replacementID: "replacement")
            await prepared.recordAppliedMemoryCorrection(recordID: "color", replacementID: "replacement")
            await prepared.recordOutcome(.completed)
            let contextStore = try ContextSQLiteStore(dataRoot: root)
            let corrections = try await contextStore.recentFeedbackEvents().filter {
                $0.signal == .correction(.contradicts)
            }
            #expect(corrections.count == 1)
            #expect(corrections.first?.atomIDs.count == 1)
            #expect(corrections.first?.evidenceIDs == ["memory-correction:replacement"])
            await runtime.stop()
        } catch {
            await runtime.stop()
            throw error
        }
    }
}
