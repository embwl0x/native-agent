// U3 wave-2 item 7 (2026-06-10): known-answer probe RUNNER.
//
// Evaluates a MemoryProbeSet against a MemoryStorage: each question is
// embedded (one batch call), recalled via the same hybrid MemoryStorage.recall
// shape production uses, and counted as a hit when the top-K window contains
// the expected memory id or any expected content substring (case-insensitive).
// Produces hits/total plus per-miss detail (probe id, question, what the top
// hits actually were).
//
// READ-PATH GUARANTEES:
//   - recall() only — recordRecallHits is deliberately NOT called, so
//     probing never pollutes use_count/last_used_at access signals.
//   - The runner only runs inside the consolidation gate (and tests); the
//     production recall read path gains zero latency from this feature.
//
// FAIL-CLOSED: any embed or recall error throws — the gate treats a probe
// run it could not complete as "no evidence", and refuses to stage.
//
// compare() embeds the questions ONCE and scores live + candidate with the
// SAME vectors, so the comparison can never be skewed by embedder
// nondeterminism between the two runs.

import Foundation
import NativeAgentCore

// MARK: - Score shapes

public struct MemoryProbeMiss: Sendable, Equatable {
    public let probeId: String
    public let question: String
    /// Compact "id: content-prefix" lines for what recall ACTUALLY returned
    /// (top-K order), so a miss is diagnosable from the approval card.
    public let topSummaries: [String]

    public init(probeId: String, question: String, topSummaries: [String]) {
        self.probeId = probeId
        self.question = question
        self.topSummaries = topSummaries
    }
}

public struct MemoryProbeScore: Sendable, Equatable {
    public let total: Int
    public let hits: Int
    public let misses: [MemoryProbeMiss]
    /// Probe ids that HIT, in probe order. The gate's regression rule is
    /// per-probe (set containment), not per-count: a candidate that loses
    /// one known answer while gaining another has equal `hits` but is
    /// still a regression (review finding, 2026-06-10).
    public let hitProbeIds: [String]

    public init(total: Int, hits: Int, misses: [MemoryProbeMiss], hitProbeIds: [String]) {
        self.total = total
        self.hits = hits
        self.misses = misses
        self.hitProbeIds = hitProbeIds
    }

    /// hits/total in 0...1; a zero-probe run scores 0 (never "perfect").
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(hits) / Double(total)
    }

    public var summary: String { "\(hits)/\(total)" }
}

/// Live-vs-candidate scores from one shared embedding pass.
public struct MemoryProbeComparison: Sendable, Equatable {
    public let live: MemoryProbeScore
    public let candidate: MemoryProbeScore

    public init(live: MemoryProbeScore, candidate: MemoryProbeScore) {
        self.live = live
        self.candidate = candidate
    }

    /// Probes live answered that the candidate LOST (live order). The gate
    /// rule is per-probe set containment — liveHitIds ⊆ candidateHitIds —
    /// not a hit-count comparison: equal counts can hide a lost answer
    /// offset by a gained one.
    public var lostProbeIds: [String] {
        let candidateHits = Set(candidate.hitProbeIds)
        return live.hitProbeIds.filter { !candidateHits.contains($0) }
    }

    /// The gate rule: a candidate may stage only when it does not lose a
    /// single known answer relative to live. Gaining answers is fine;
    /// losing any one — even while gaining another — is a regression.
    public var candidateIsAtLeastLive: Bool { lostProbeIds.isEmpty }
}

// MARK: - Runner

public enum MemoryProbeRunner {

    public enum ProbeRunnerError: Error, CustomStringConvertible {
        case emptyProbeSet
        case vectorCountMismatch(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .emptyProbeSet:
                return "probe set is empty — refusing to score (a 0/0 run is not evidence)"
            case .vectorCountMismatch(let expected, let got):
                return "embedder returned \(got) vectors for \(expected) questions"
            }
        }
    }

    /// Embed all probe questions in one batch. Throws on embedder failure
    /// (fail closed) and on count mismatch.
    public static func embedQuestions(
        _ probes: [MemoryProbe],
        embedder: any EmbeddingProvider
    ) async throws -> [[Float]] {
        try await embedQuestionsWithEpoch(probes, embedder: embedder).vectors
    }

    public static func embedQuestionsWithEpoch(
        _ probes: [MemoryProbe],
        embedder: any EmbeddingProvider
    ) async throws -> MemoryEmbeddingBatch {
        guard !probes.isEmpty else { throw ProbeRunnerError.emptyProbeSet }
        let batch = try await embedder.embedWithEpoch(probes.map(\.question))
        guard batch.vectors.count == probes.count else {
            throw ProbeRunnerError.vectorCountMismatch(expected: probes.count, got: batch.vectors.count)
        }
        return batch
    }

    /// Score one store with pre-embedded question vectors.
    public static func evaluate(
        storage: MemoryStorage,
        probes: [MemoryProbe],
        vectors: [[Float]],
        topK: Int,
        embeddingEpoch: MemoryEmbeddingEpoch? = nil
    ) async throws -> MemoryProbeScore {
        guard !probes.isEmpty else { throw ProbeRunnerError.emptyProbeSet }
        guard vectors.count == probes.count else {
            throw ProbeRunnerError.vectorCountMismatch(expected: probes.count, got: vectors.count)
        }
        var hits = 0
        var hitProbeIds: [String] = []
        var misses: [MemoryProbeMiss] = []
        for (i, probe) in probes.enumerated() {
            let results = try await storage.recall(
                embedding: vectors[i],
                embeddingEpoch: embeddingEpoch,
                queryText: probe.question,
                topK: max(1, topK),
                persona: nil
            )
            if isHit(probe: probe, results: results) {
                hits += 1
                hitProbeIds.append(probe.id)
            } else {
                misses.append(MemoryProbeMiss(
                    probeId: probe.id,
                    question: probe.question,
                    topSummaries: results.map { r in
                        "\(r.memory.id): \(String(r.memory.content.prefix(80)))"
                    }
                ))
            }
        }
        return MemoryProbeScore(
            total: probes.count, hits: hits, misses: misses, hitProbeIds: hitProbeIds)
    }

    /// Score the probe set against one store (embeds + evaluates).
    public static func run(
        probeSet: MemoryProbeSet,
        storage: MemoryStorage,
        embedder: any EmbeddingProvider
    ) async throws -> MemoryProbeScore {
        let batch = try await embedQuestionsWithEpoch(probeSet.probes, embedder: embedder)
        return try await evaluate(
            storage: storage, probes: probeSet.probes,
            vectors: batch.vectors, topK: probeSet.topK,
            embeddingEpoch: batch.epoch
        )
    }

    /// Score live and candidate with ONE shared embedding pass.
    public static func compare(
        probeSet: MemoryProbeSet,
        live: MemoryStorage,
        candidate: MemoryStorage,
        embedder: any EmbeddingProvider
    ) async throws -> MemoryProbeComparison {
        let batch = try await embedQuestionsWithEpoch(probeSet.probes, embedder: embedder)
        let liveScore = try await evaluate(
            storage: live, probes: probeSet.probes,
            vectors: batch.vectors, topK: probeSet.topK,
            embeddingEpoch: batch.epoch
        )
        let candidateScore = try await evaluate(
            storage: candidate, probes: probeSet.probes,
            vectors: batch.vectors, topK: probeSet.topK,
            embeddingEpoch: batch.epoch
        )
        return MemoryProbeComparison(live: liveScore, candidate: candidateScore)
    }

    // MARK: - Hit rule

    static func isHit(
        probe: MemoryProbe,
        results: [(memory: StoredMemory, similarity: Double)]
    ) -> Bool {
        for r in results {
            if let expectedId = probe.expectMemoryId, r.memory.id == expectedId {
                return true
            }
            for sub in probe.expectAnySubstring where !sub.isEmpty {
                if r.memory.content.range(of: sub, options: [.caseInsensitive]) != nil {
                    return true
                }
            }
        }
        return false
    }
}
