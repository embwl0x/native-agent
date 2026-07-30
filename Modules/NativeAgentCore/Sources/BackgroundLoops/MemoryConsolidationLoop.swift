import Foundation
import PersistenceCore

// MARK: - MemoryConsolidationLoop
//
// Periodic dedup pass: find near-duplicate memory records (cosine ≥ 0.95),
// keep the most-recent representative of each cluster, remove the older
// siblings. Intentionally protocol-driven so this loop file does not pull
// MemoryV2 as a module dependency — callers wire a thin adapter that bridges
// SwiftNativeMemoryRecaller (or whatever recall surface is in flight) to the
// `MemoryConsolidationRecaller` seam defined here.
//
// Wiring note: when SwiftNativeMemoryRecaller grows a `list()` accessor over
// its underlying EmbeddingStore (Phase B+), an adapter type in the wiring
// layer makes it conform to `MemoryConsolidationRecaller` in a single small
// extension — no MemoryV2 / Package.swift surgery needed from this file.

/// A single record visible to the consolidation pass.
public struct ConsolidationCandidate: Sendable, Equatable {
    public let id: String
    public let embedding: [Float]
    public let text: String
    /// Last-touched timestamp; the newest wins inside a near-duplicate cluster.
    public let updatedAt: Date

    public init(id: String, embedding: [Float], text: String, updatedAt: Date) {
        self.id = id
        self.embedding = embedding
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// The minimal recall surface MemoryConsolidationLoop needs. Defined here
/// instead of as a method on SwiftNativeMemoryRecaller so this module does
/// not need to import MemoryV2.
public protocol MemoryConsolidationRecaller: Sendable {
    func listAllForConsolidation() async throws -> [ConsolidationCandidate]
    func remove(id: String) async throws
}

public struct MemoryConsolidationLoop: LoopRunner {
    public let loopId: String = "memory_consolidation"
    public let interval: TimeInterval
    /// U5 W-D (2026-06-11): a tick walks the FULL memory store (embedding
    /// pairwise pass + per-record removals) and grows with store size. The
    /// scheduler's default 300s budget cancels long passes mid-flight with
    /// no user-visible trace (audit 2026-06-09 — same lesson as
    /// telegram_poll / mission_executor).
    public var tickTimeoutOverride: TimeInterval? { 3600 }
    /// Cosine similarity at or above this threshold marks two records as
    /// near-duplicates. 0.95 is the Phase B default; raise to reduce false
    /// positives, lower to dedupe more aggressively.
    public let similarityThreshold: Float
    private let recaller: any MemoryConsolidationRecaller
    private let dataRoot: URL

    public init(
        interval: TimeInterval = 3600,
        recaller: any MemoryConsolidationRecaller,
        dataRoot: URL = defaultDataRoot(),
        similarityThreshold: Float = 0.95
    ) {
        self.interval = interval
        self.recaller = recaller
        self.dataRoot = dataRoot
        self.similarityThreshold = similarityThreshold
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let candidates: [ConsolidationCandidate]
        do {
            candidates = try await recaller.listAllForConsolidation()
        } catch {
            FileHandle.standardError.write(Data("MemoryConsolidationLoop: list failed: \(error)\n".utf8))
            return .failed(error: "memory consolidation list: \(error)")
        }
        guard candidates.count >= 2 else {
            return .skipped(reason: "fewer than two consolidation candidates")
        }

        // Union-Find over near-duplicate edges.
        let n = candidates.count
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = Self.cosine(candidates[i].embedding, candidates[j].embedding)
                if s >= similarityThreshold {
                    union(i, j)
                }
            }
        }

        // Group by cluster root; in each cluster, keep the newest by updatedAt
        // (ties → keep the lexicographically smaller id for determinism).
        var clusters: [Int: [Int]] = [:]
        for i in 0..<n {
            clusters[find(i), default: []].append(i)
        }
        var removed = 0
        var removalErrors: [String] = []
        for (_, members) in clusters where members.count > 1 {
            let sorted = members.sorted { a, b in
                let ca = candidates[a], cb = candidates[b]
                if ca.updatedAt != cb.updatedAt { return ca.updatedAt > cb.updatedAt }
                return ca.id < cb.id
            }
            let losers = sorted.dropFirst()
            for idx in losers {
                let id = candidates[idx].id
                do {
                    try await recaller.remove(id: id)
                    removed += 1
                } catch {
                    FileHandle.standardError.write(Data("MemoryConsolidationLoop: remove(\(id)) failed: \(error)\n".utf8))
                    removalErrors.append("\(id): \(error)")
                }
            }
        }
        if removed > 0 {
            FileHandle.standardError.write(Data("MemoryConsolidationLoop: consolidated \(removed) duplicates across \(candidates.count) records (dataRoot=\(dataRoot.path))\n".utf8))
        }
        if !removalErrors.isEmpty {
            return .failed(error: "memory consolidation removal failures: "
                + removalErrors.prefix(5).joined(separator: "; "))
        }
        return .completed(result: "removed \(removed) duplicate memories")
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrtf(na) * sqrtf(nb)
        return denom > 0 ? dot / denom : 0
    }
}
