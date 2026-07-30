// U3 wave-2 item 7: known-answer probe set + runner tests.

import Foundation
import Testing
@testable import MemoryV2
import NativeAgentCore

// MARK: - Deterministic test embedder

/// Exact-text → vector table; unknown texts get an orthogonal fallback so
/// they match nothing. Total control, zero CoreML.
struct KeyedEmbedder: EmbeddingProvider {
    let table: [String: [Float]]
    var fallback: [Float] = [0, 0, 0, 1]
    let dimensions: Int = 4
    let modelId: String = "keyed-test"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { table[$0] ?? fallback }
    }
}

struct ThrowingEmbedder: EmbeddingProvider {
    struct Boom: Error {}
    let dimensions: Int = 4
    let modelId: String = "throwing-test"
    func embed(_ texts: [String]) async throws -> [[Float]] { throw Boom() }
}

@Suite("MemoryProbeRunner")
struct MemoryProbeRunnerTests {

    private func makeStore() throws -> MemoryStorage {
        try MemoryStorage()
    }

    @Test func scoresFixtureStoreWithPerMissDetail() async throws {
        let store = try makeStore()
        let memA = StoredMemory(
            content: "the user loves espresso shots in the morning",
            embedding: [1, 0, 0, 0]
        )
        let memB = StoredMemory(
            content: "NativeAgent is a native macOS agent system",
            embedding: [0, 1, 0, 0]
        )
        _ = try await store.insertMemory(memA)
        _ = try await store.insertMemory(memB)

        let probes = [
            MemoryProbe(id: "q1", question: "What does the user drink in the morning?",
                        expectAnySubstring: ["espresso shots"]),
            MemoryProbe(id: "q2", question: "What is NativeAgent?",
                        expectMemoryId: memB.id),
            MemoryProbe(id: "q3", question: "Any unicorn sightings on record?",
                        expectAnySubstring: ["unicorn sightings"]),
        ]
        let embedder = KeyedEmbedder(table: [
            "What does the user drink in the morning?": [1, 0, 0, 0],
            "What is NativeAgent?": [0, 1, 0, 0],
            "Any unicorn sightings on record?": [0, 0, 1, 0],
        ])
        let score = try await MemoryProbeRunner.run(
            probeSet: MemoryProbeSet(topK: 5, probes: probes),
            storage: store,
            embedder: embedder
        )
        #expect(score.total == 3)
        #expect(score.hits == 2)
        #expect(score.hitProbeIds == ["q1", "q2"])
        #expect(score.misses.count == 1)
        #expect(score.misses[0].probeId == "q3")
        #expect(!score.misses[0].topSummaries.isEmpty)
        #expect(score.summary == "2/3")
    }

    /// Review finding (2026-06-10): equal hit COUNTS can hide a regression —
    /// a candidate that loses a probe live answered while gaining another
    /// must read as a regression (per-probe superset rule, not >=).
    @Test func equalHitCountsWithLostProbeIsRegression() async throws {
        let live = try makeStore()
        let candidate = try makeStore()
        _ = try await live.insertMemory(
            StoredMemory(content: "the alpha fact lives here", embedding: [1, 0, 0, 0]))
        _ = try await candidate.insertMemory(
            StoredMemory(content: "the beta fact lives here", embedding: [0, 1, 0, 0]))
        let probes = [
            MemoryProbe(id: "pA", question: "alpha?", expectAnySubstring: ["alpha fact"]),
            MemoryProbe(id: "pB", question: "beta?", expectAnySubstring: ["beta fact"]),
        ]
        let embedder = KeyedEmbedder(table: [
            "alpha?": [1, 0, 0, 0],
            "beta?": [0, 1, 0, 0],
        ])
        let comparison = try await MemoryProbeRunner.compare(
            probeSet: MemoryProbeSet(topK: 3, probes: probes),
            live: live, candidate: candidate, embedder: embedder
        )
        // Equal counts (1 vs 1) — but pA was LOST while pB was gained.
        #expect(comparison.live.hits == 1)
        #expect(comparison.candidate.hits == 1)
        #expect(comparison.live.hitProbeIds == ["pA"])
        #expect(comparison.candidate.hitProbeIds == ["pB"])
        #expect(comparison.lostProbeIds == ["pA"])
        #expect(!comparison.candidateIsAtLeastLive)
    }

    /// Gaining probes with zero losses is NOT a regression.
    @Test func gainedProbesWithoutLossesIsNotRegression() async throws {
        let live = try makeStore()
        let candidate = try makeStore()
        _ = try await live.insertMemory(
            StoredMemory(content: "the alpha fact lives here", embedding: [1, 0, 0, 0]))
        _ = try await candidate.insertMemory(
            StoredMemory(content: "the alpha fact lives here", embedding: [1, 0, 0, 0]))
        _ = try await candidate.insertMemory(
            StoredMemory(content: "the beta fact lives here", embedding: [0, 1, 0, 0]))
        let probes = [
            MemoryProbe(id: "pA", question: "alpha?", expectAnySubstring: ["alpha fact"]),
            MemoryProbe(id: "pB", question: "beta?", expectAnySubstring: ["beta fact"]),
        ]
        let embedder = KeyedEmbedder(table: [
            "alpha?": [1, 0, 0, 0],
            "beta?": [0, 1, 0, 0],
        ])
        let comparison = try await MemoryProbeRunner.compare(
            probeSet: MemoryProbeSet(topK: 3, probes: probes),
            live: live, candidate: candidate, embedder: embedder
        )
        #expect(comparison.lostProbeIds.isEmpty)
        #expect(comparison.candidateIsAtLeastLive)
    }

    @Test func substringMatchIsCaseInsensitive() async throws {
        let store = try makeStore()
        let mem = StoredMemory(
            content: "the user values DIRECTNESS over excessive caution",
            embedding: [1, 0, 0, 0]
        )
        _ = try await store.insertMemory(mem)
        let probes = [
            MemoryProbe(id: "q1", question: "directness?",
                        expectAnySubstring: ["values directness over"]),
        ]
        let score = try await MemoryProbeRunner.run(
            probeSet: MemoryProbeSet(topK: 3, probes: probes),
            storage: store,
            embedder: KeyedEmbedder(table: ["directness?": [1, 0, 0, 0]])
        )
        #expect(score.hits == 1)
    }

    @Test func emptyProbeSetThrows() async throws {
        let store = try makeStore()
        await #expect(throws: MemoryProbeRunner.ProbeRunnerError.self) {
            _ = try await MemoryProbeRunner.run(
                probeSet: MemoryProbeSet(topK: 5, probes: []),
                storage: store,
                embedder: KeyedEmbedder(table: [:])
            )
        }
    }

    @Test func embedderFailurePropagates() async throws {
        let store = try makeStore()
        let probes = [MemoryProbe(id: "q1", question: "x", expectAnySubstring: ["x"])]
        await #expect(throws: Error.self) {
            _ = try await MemoryProbeRunner.run(
                probeSet: MemoryProbeSet(topK: 5, probes: probes),
                storage: store,
                embedder: ThrowingEmbedder()
            )
        }
    }

    @Test func probingNeverBumpsUseCounts() async throws {
        let store = try makeStore()
        let mem = StoredMemory(content: "probe target row", embedding: [1, 0, 0, 0])
        _ = try await store.insertMemory(mem)
        let probes = [MemoryProbe(id: "q1", question: "target?",
                                  expectAnySubstring: ["probe target"])]
        _ = try await MemoryProbeRunner.run(
            probeSet: MemoryProbeSet(topK: 3, probes: probes),
            storage: store,
            embedder: KeyedEmbedder(table: ["target?": [1, 0, 0, 0]])
        )
        let after = try await store.memory(id: mem.id)
        #expect(after?.useCount == 0)
        #expect(after?.lastUsedAt == nil)
    }
}

@Suite("MemoryProbeSet")
struct MemoryProbeSetTests {

    @Test func builtinSetHasValidProbes() {
        let set = MemoryProbeSet.builtin
        #expect(set.probes.count == 25)
        #expect(set.probes.allSatisfy { $0.isValid })
        // Stable unique ids for per-miss reporting.
        #expect(Set(set.probes.map(\.id)).count == set.probes.count)
    }

    @Test func dataRootOverrideWinsWhenValid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-set-override-\(UUID().uuidString)", isDirectory: true)
        let overridePath = MemoryProbeSet.overridePath(dataRoot: root)
        try FileManager.default.createDirectory(
            at: overridePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        { "version": 2, "top_k": 3,
          "probes": [
            { "id": "x1", "question": "who?", "expect_any_substring": ["someone"] },
            { "id": "bad", "question": "no expectation — must be dropped" }
          ] }
        """
        try Data(json.utf8).write(to: overridePath)
        let set = MemoryProbeSet.load(dataRoot: root)
        #expect(set.version == 2)
        #expect(set.topK == 3)
        #expect(set.probes.count == 1)
        #expect(set.probes[0].id == "x1")
    }

    @Test func corruptOverrideFallsBackToBuiltin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-set-corrupt-\(UUID().uuidString)", isDirectory: true)
        let overridePath = MemoryProbeSet.overridePath(dataRoot: root)
        try FileManager.default.createDirectory(
            at: overridePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: overridePath)
        let set = MemoryProbeSet.load(dataRoot: root)
        #expect(set.probes.count == MemoryProbeSet.builtin.probes.count)
    }
}
