// EmbeddingRecallTestFixtures.swift
//
// Relocated verbatim from MemoryV2+Embedding.swift (simplification sweep,
// 2026-08-14). JSONLEmbeddingStore + SwiftNativeMemoryRecaller had zero
// production callers — the live recall path is SwiftNativeMemoryV2RecallingAdapter
// via makeChatMemoryRecaller. These remain solely as recall fixtures for
// TurnEngine/MemoryIntegration tests in this target.

import Foundation
import NativeAgentCore
import PersistenceCore
@testable import MemoryV2
@testable import ChatOrchestration

// MARK: - EmbeddingStore protocol

public protocol EmbeddingStore: Sendable {
    func upsert(id: String, embedding: [Float], text: String) async throws
    func get(id: String) async throws -> (embedding: [Float], text: String)?
    func delete(id: String) async throws
    func search(query: [Float], topK: Int) async throws -> [(id: String, score: Float, text: String)]
}

// MARK: - JSONLEmbeddingStore (on-disk linear-scan backend)
//
// One JSONL line per record: {"id": ..., "text": ..., "embedding": [Float...]}.
// upsert dedupes by id via an in-memory map and rewrites the file on overwrite.
// search() computes cosine similarity against every record; suitable for the
// ~10k-record scale Phase B needs. Phase C will replace search() with a Core
// Spotlight query backend; the protocol is the seam.
public actor JSONLEmbeddingStore: EmbeddingStore {
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var text: String
        public var embedding: [Float]
    }

    private let path: URL
    private var records: [String: Record] = [:]
    private var loaded = false
    /// U5 W-G corrupt-preserve fix (2026-06-11): raw lines that failed to
    /// decode on load. Previously these were silently skipped on load AND
    /// then permanently destroyed by the next `flush()` full-file rewrite.
    /// Now they're carried verbatim and re-written at the end of the file
    /// so a decode bug or torn write never silently deletes data.
    private var preservedUndecodableLines: [Data] = []
    private let persistence: SwiftNativePersistenceCore

    public init(path: URL, persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()) {
        self.path = path
        self.persistence = persistence
    }

    // MARK: per-path coordination
    //
    // Two-layer locking (lock-unification fix, 2026-05-31):
    //
    //   Layer 1 (in-process, PathLockRegistry): serializes two
    //     JSONLEmbeddingStore actors in THIS process that point at the
    //     same file. Without it each would load a stale in-memory snapshot,
    //     mutate it, and last-writer-wins truncate the other on flush.
    //
    //   Layer 2 (cross-process, SwiftNativePersistenceCore.withFileLock):
    //     serializes against other Swift processes that write
    //     <dataRoot>/memory_embeddings.jsonl. Without it a write that lands
    //     between our read and our atomic replace would be silently truncated.
    //     Same `<path>.lock` sibling convention the
    //     JSONLMemoryConsolidationRecaller (now thinly wrapping this
    //     store) use.
    //
    // Order matters: in-process FIRST, flock SECOND. Reversing would risk
    // an unbounded queue of process-local tasks all racing for one flock,
    // and flock(2) on macOS is per open-file-description (NOT reentrant
    // across fds in the same process) — so nesting two withFileLock calls
    // on the same path would deadlock. The recaller therefore CALLS this
    // store's public methods rather than holding its own flock.
    //
    // Implementation of Layer 1: an actor-based async semaphore keyed by
    // standardized path string. NSLock is unsuitable because NSLock.lock()
    // is unavailable from async contexts under Swift 6 concurrency.
    fileprivate actor PathLockRegistry {
        static let shared = PathLockRegistry()
        private var held: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(_ key: String) async {
            if !held.contains(key) {
                held.insert(key)
                return
            }
            await withCheckedContinuation { cont in
                waiters[key, default: []].append(cont)
            }
            // On resume, ownership is handed off directly — `held` already
            // contains `key`, the releaser did not clear it.
        }

        func release(_ key: String) {
            if var queue = waiters[key], !queue.isEmpty {
                let next = queue.removeFirst()
                if queue.isEmpty {
                    waiters.removeValue(forKey: key)
                } else {
                    waiters[key] = queue
                }
                next.resume()
            } else {
                held.remove(key)
            }
        }
    }

    private func withPathLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let key = path.standardizedFileURL.path
        await PathLockRegistry.shared.acquire(key)
        do {
            // In-process lock held; now take the cross-process flock around
            // the actual I/O so the daemon (or any peer Swift process) using
            // the same `<path>.lock` convention serializes with us.
            let r = try await persistence.withFileLock(path) {
                try await body()
            }
            await PathLockRegistry.shared.release(key)
            return r
        } catch {
            await PathLockRegistry.shared.release(key)
            throw error
        }
    }

    private func loadIfNeeded() throws {
        if loaded { return }
        loaded = true
        records.removeAll()
        preservedUndecodableLines.removeAll()
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        for line in lines {
            guard !line.isEmpty else { continue }
            if let rec = try? decoder.decode(Record.self, from: Data(line)) {
                records[rec.id] = rec
            } else {
                // U5 W-G corrupt-preserve: keep the undecodable bytes so the
                // next flush() rewrite doesn't destroy them. Loud, not silent.
                preservedUndecodableLines.append(Data(line))
            }
        }
        if !preservedUndecodableLines.isEmpty {
            NSLog("JSONLEmbeddingStore: preserved %d undecodable line(s) in %@ (will be re-written verbatim on flush)",
                  preservedUndecodableLines.count, path.lastPathComponent)
        }
    }

    private func flush() throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var buf = Data()
        for rec in records.values {
            let line = try encoder.encode(rec)
            buf.append(line)
            buf.append(0x0A)
        }
        // U5 W-G corrupt-preserve: carry lines we couldn't decode at load
        // time through the rewrite instead of dropping them.
        for line in preservedUndecodableLines {
            buf.append(line)
            buf.append(0x0A)
        }
        try buf.write(to: path, options: .atomic)
    }

    public func upsert(id: String, embedding: [Float], text: String) async throws {
        try await withPathLock {
            try await self._upsertLocked(id: id, embedding: embedding, text: text)
        }
    }

    public func get(id: String) async throws -> (embedding: [Float], text: String)? {
        try await withPathLock {
            try await self._getLocked(id: id)
        }
    }

    public func delete(id: String) async throws {
        try await withPathLock {
            try await self._deleteLocked(id: id)
        }
    }

    public func search(query: [Float], topK: Int) async throws -> [(id: String, score: Float, text: String)] {
        try await withPathLock {
            try await self._searchLocked(query: query, topK: topK)
        }
    }

    /// Read-only snapshot of every record currently on disk, force-reloading
    /// from the file under the same two-layer lock used by writers.
    /// Added (2026-05-31) for JSONLMemoryConsolidationRecaller so the
    /// MemoryConsolidationLoop can enumerate records WITHOUT doing raw file
    /// I/O outside the store — that was the duplicate-impl drift this
    /// unification fixes. Exposes the immutable `Record` struct rather
    /// than tuples so the recaller's ConsolidationCandidate mapping stays
    /// strongly typed.
    public func allRecords() async throws -> [Record] {
        try await withPathLock {
            try await self._allRecordsLocked()
        }
    }

    // MARK: actor-isolated work bodies
    //
    // The withPathLock body must be @Sendable (it crosses into
    // persistence.withFileLock's detached open/flock task), so it can't
    // capture actor-isolated state directly. These _xxxLocked helpers ARE
    // actor-isolated and called via `await self?._xxxLocked(...)`; the
    // outer @Sendable closure only retains a weak self and re-enters the
    // actor for the actual work.

    private func _upsertLocked(id: String, embedding: [Float], text: String) throws {
        // Force a re-read so we observe writes from any peer instance (or
        // peer process) on the same path before mutating + flushing.
        loaded = false
        try loadIfNeeded()
        records[id] = Record(id: id, text: text, embedding: embedding)
        try flush()
    }

    private func _getLocked(id: String) throws -> (embedding: [Float], text: String)? {
        loaded = false
        try loadIfNeeded()
        guard let r = records[id] else { return nil }
        return (r.embedding, r.text)
    }

    private func _deleteLocked(id: String) throws {
        loaded = false
        try loadIfNeeded()
        guard records.removeValue(forKey: id) != nil else { return }
        try flush()
    }

    private func _searchLocked(query: [Float], topK: Int) throws -> [(id: String, score: Float, text: String)] {
        loaded = false
        try loadIfNeeded()
        guard topK > 0, !query.isEmpty else { return [] }
        var scored: [(id: String, score: Float, text: String)] = []
        scored.reserveCapacity(records.count)
        for rec in records.values {
            // Surface dimension mismatches loudly instead of silently
            // truncating to the shorter prefix — a 3-d stored vector vs
            // a 5-d query is a model/version skew, not a valid comparison.
            if rec.embedding.count != query.count {
                throw EmbeddingError.dimensionMismatch(expected: rec.embedding.count, got: query.count)
            }
            let s = Self.cosine(query, rec.embedding)
            scored.append((rec.id, s, rec.text))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK))
    }

    private func _allRecordsLocked() throws -> [Record] {
        loaded = false
        try loadIfNeeded()
        // Map.values is unordered; sort by id for deterministic output so
        // the consolidation loop's union-find walk is reproducible.
        return records.values.sorted { $0.id < $1.id }
    }

    // Single source of truth: VectorMath.cosine (Double, finiteness-guarded,
    // equal-length required). This surface historically returned a NaN-unguarded
    // Float over min(count) — same-model embeddings are always equal length, so
    // the guard only hardens the pathological cases. Score stays Float.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        Float(VectorMath.cosine(a, b))
    }
}

// MARK: - SwiftNativeMemoryRecaller
//
// Composes an EmbeddingProvider + EmbeddingStore into a recall surface that
// mirrors the daemon's `/v1/memory/recall` return shape (MemoryRecallHit).
//
// The production SQLite-backed MemoryV2 path now does hybrid dense+BM25
// retrieval. This older JSONL recaller remains the bare embedding-only surface
// for fixture/framework tests and callers that explicitly wire an EmbeddingStore.
public actor SwiftNativeMemoryRecaller {
    private let embedder: any EmbeddingProvider
    private let store: any EmbeddingStore

    public init(embedder: any EmbeddingProvider, store: any EmbeddingStore) {
        self.embedder = embedder
        self.store = store
    }

    public func index(id: String, text: String) async throws {
        let vecs = try await embedder.embed([text])
        guard let v = vecs.first else {
            throw EmbeddingError.modelNotLoaded(reason: "embedder returned no vectors")
        }
        try await store.upsert(id: id, embedding: v, text: text)
    }

    public func remove(id: String) async throws {
        try await store.delete(id: id)
    }

    public func recall(_ query: String, k: Int = 10) async throws -> [MemoryRecallHit] {
        let vecs = try await embedder.embed([query])
        guard let q = vecs.first else { return [] }
        let results = try await store.search(query: q, topK: k)
        return results.map { row in
            let displayText = MemoryTextClip.memoryDisplayText(row.text)
            // U3 wave-1 item 1: sentence-clipped preview (no mid-word chop)
            // + full text on `content`. Output shaping only — row selection
            // and scores are unchanged.
            return MemoryRecallHit(
                score: Double(row.score),
                sessionId: nil,
                role: nil,
                ts: nil,
                preview: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallPreviewCap),
                content: MemoryTextClip.sentenceClip(displayText, cap: memoryRecallContentCap),
                source: "swift-native",
                rankingSignals: nil,
                extras: .object(["id": .string(row.id)])
            )
        }
    }
}

// Orphan production conformance relocated from ChatOrchestration+TurnEngine.swift:155.
extension SwiftNativeMemoryRecaller: MemoryRecalling {}
