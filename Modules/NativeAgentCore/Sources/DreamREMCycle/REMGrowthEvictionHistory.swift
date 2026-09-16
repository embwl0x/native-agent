import Foundation
import PersistenceCore

// MARK: - GROWTH eviction history (item 5)
//
// GROWTH.md eviction used to be a one-way door: the oldest ~5,000 characters of
// her own approved growth were distilled to a <=400-character summary and the
// original was deleted. The summary is a compression of something she agreed
// to; the words themselves were gone, and with them any way to ask what the
// compressed node actually came from.
//
// SAME SHAPE AS THE STUDIO JOURNAL AMENDMENT (`studio/journal/amendments.jsonl`,
// StudioStore.swift): an append-only sidecar beside the store, never a rewrite,
// with the ORIGINAL kept visible next to what now stands. Here the compressed
// KG node is what stands and this file is the original, expandable behind it —
// keyed by the SAME id the node carries, which is how the node points at it.
//
// OUTSIDE ACTIVE PERSONA CONTEXT, deliberately: this lives under the DATA root,
// never under the persona root, so it cannot be re-read into GROWTH.md and
// cannot reach the compiled persona packet. The eviction exists to reclaim
// prompt budget — retaining the passage must not hand the budget back.

/// Where one history row stands. The record is written BEFORE the KG insert
/// and the GROWTH splice (fail-closed retention: the passage must be on disk
/// before anything can destroy it), so at write time the eviction has not
/// happened yet and the row must not claim it did.
public enum REMGrowthEvictionState: String, Sendable, Codable, Equatable {
    /// Passage retained, eviction NOT yet performed. If the pass dies here,
    /// GROWTH.md still holds the text and this row is the only trace.
    case pending
    /// The splice succeeded: the passage really did leave GROWTH.md.
    case committed
}

/// One evicted GROWTH.md passage, kept whole.
public struct REMGrowthEvictionRecord: Sendable, Codable, Equatable {
    /// The compressed node's id (`growth_<sha256 of the passage>`). The node and
    /// this record share it — that identity IS the pointer.
    public var id: String
    public var evictedAt: String
    /// The compressed node's summary — what stands in GROWTH's place.
    public var summary: String
    /// THE EXACT EVICTED PASSAGE, byte for byte as it left GROWTH.md.
    public var passage: String
    public var sourceLines: Int
    /// The approved proposals whose text is in this passage: where the evicted
    /// growth came from, so the history expands into its own provenance.
    public var proposalRefs: [REMGrowthEvictionProposalRef]
    /// `pending` while only the retention has happened; `committed` once the
    /// GROWTH splice succeeded. Absent on rows written before this field
    /// existed — fixed history, read as committed rather than rewritten.
    public var state: REMGrowthEvictionState?
    /// Set on a `committed` row that was written by RECONCILIATION rather than
    /// by the pass that did the splice: the passage is demonstrably gone from
    /// GROWTH.md, but the process died before it could say so. Marks the row as
    /// inferred after the fact, never as observed.
    public var reconciled: Bool?

    public init(
        id: String,
        evictedAt: String,
        summary: String,
        passage: String,
        sourceLines: Int,
        proposalRefs: [REMGrowthEvictionProposalRef] = [],
        state: REMGrowthEvictionState? = nil,
        reconciled: Bool? = nil
    ) {
        self.id = id
        self.evictedAt = evictedAt
        self.summary = summary
        self.passage = passage
        self.sourceLines = sourceLines
        self.proposalRefs = proposalRefs
        self.state = state
        self.reconciled = reconciled
    }

    /// True unless the row is explicitly `pending`. A pending row with no
    /// committed row after it means the passage is RETAINED, NOT EVICTED.
    public var isCommitted: Bool { state != .pending }
}

/// The approval this stretch of GROWTH entered by.
public struct REMGrowthEvictionProposalRef: Sendable, Codable, Equatable {
    public var proposalId: String
    public var targetDoc: String
    public var createdAt: String
    public var approvalId: String?
    /// The dream dates the proposal cited when it was drafted.
    public var evidenceDates: [String]

    public init(
        proposalId: String,
        targetDoc: String,
        createdAt: String,
        approvalId: String? = nil,
        evidenceDates: [String] = []
    ) {
        self.proposalId = proposalId
        self.targetDoc = targetDoc
        self.createdAt = createdAt
        self.approvalId = approvalId
        self.evidenceDates = evidenceDates
    }
}

/// Append-only store at `<dataRoot>/growth_history/evictions.jsonl`.
/// One JSON object per line, flock'd on write, id-deduped.
public enum REMGrowthEvictionHistory {
    public static func fileURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("growth_history", isDirectory: true)
            .appendingPathComponent("evictions.jsonl")
    }

    /// The pointer a compressed node carries so a reader can find the original.
    /// Bounded, and stable across passes because the id is the passage hash.
    public static func pointer(id: String) -> String {
        "(full passage retained: growth_history/evictions.jsonl#\(id))"
    }

    /// Append one record. Re-appending the same id AND state is a no-op, so a
    /// pass that wrote the history and then failed at the KG merge retries
    /// cleanly — while the later `committed` row for that same id still lands.
    /// THROWS on any write failure — the caller must not splice GROWTH.md
    /// unless the passage is safely on disk.
    public static func append(
        _ record: REMGrowthEvictionRecord,
        dataRoot: URL
    ) async throws {
        let url = fileURL(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(url) {
            if try existingKeys(url: url).contains(dedupeKey(record)) { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(record)
            line.append(contentsOf: Data("\n".utf8))
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        }
    }

    /// Every retained passage, oldest first. Malformed lines are skipped rather
    /// than failing the read — one bad line must not hide the rest of her past.
    public static func loadAll(dataRoot: URL) -> [REMGrowthEvictionRecord] {
        let url = fileURL(dataRoot: dataRoot)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            guard let line = String($0).data(using: .utf8) else { return nil }
            return try? decoder.decode(REMGrowthEvictionRecord.self, from: line)
        }
    }

    /// The passage behind one compressed node — what "expand" reads. Returns
    /// the row whatever its state: a retained-but-not-evicted passage is still
    /// the passage.
    public static func record(id: String, dataRoot: URL) -> REMGrowthEvictionRecord? {
        loadAll(dataRoot: dataRoot).last { $0.id == id }
    }

    /// THE EVICTIONS THAT ACTUALLY HAPPENED. An id whose only row is `pending`
    /// was retained and then the pass died before the splice — GROWTH.md still
    /// holds that text, so counting it as evicted would be a false record in an
    /// append-only file nobody can correct.
    ///
    /// THE COMMITTED ROW, NOT THE FIRST ROW. An id normally has two rows —
    /// `pending` then `committed` — and returning the first match handed back
    /// the pending one, so every caller read the state (and any later field) of
    /// a row that says the eviction had not happened. The LATEST committed row
    /// per id is the one that stands.
    public static func committedRecords(dataRoot: URL) -> [REMGrowthEvictionRecord] {
        var latest: [String: REMGrowthEvictionRecord] = [:]
        var order: [String] = []
        for row in loadAll(dataRoot: dataRoot) where row.isCommitted {
            if latest[row.id] == nil { order.append(row.id) }
            latest[row.id] = row
        }
        return order.compactMap { latest[$0] }
    }

    /// REPAIR THE INTERRUPTED SPLICE. The passage leaves GROWTH.md before the
    /// `committed` row is appended, so a crash (or a failed append) between the
    /// two leaves an id whose only row says `pending` while the text is already
    /// gone — a permanent under-claim that no later pass fixed, because eviction
    /// returns early whenever the file is under the cap.
    ///
    /// Run on every REM pass with the CURRENT GROWTH.md body: a pending id with
    /// no committed row whose exact passage is no longer in that body gets its
    /// `committed` row appended, marked `reconciled`. A passage still present is
    /// left alone — that is the retained-not-evicted case the state exists for.
    /// Returns the number of rows repaired.
    ///
    /// ABSENCE FROM THE BODY IS NOT PROOF ON ITS OWN. "Not in this string" is
    /// also what an empty or truncated read looks like, and that would mark
    /// EVERY pending row committed in one pass — a permanent false record.
    /// `kgNodeExists` is the corroborating witness: the distilled node carries
    /// the same id, and the splice only ever runs after the KG merge, so a
    /// missing passage WITH its node present is a real interrupted splice.
    /// Without the node, the row stays pending.
    @discardableResult
    public static func reconcilePending(
        growthBody: String,
        dataRoot: URL,
        kgNodeExists: @Sendable (String) async -> Bool
    ) async -> Int {
        let rows = loadAll(dataRoot: dataRoot)
        guard !rows.isEmpty else { return 0 }
        let committed = Set(rows.filter(\.isCommitted).map(\.id))
        var repaired = 0
        var handled = Set<String>()
        for row in rows where row.state == .pending
            && !committed.contains(row.id)
            && !handled.contains(row.id)
            && !row.passage.isEmpty
            && !growthBody.contains(row.passage)
        {
            handled.insert(row.id)
            guard await kgNodeExists(row.id) else { continue }
            var fixed = row
            fixed.state = .committed
            fixed.reconciled = true
            do {
                try await append(fixed, dataRoot: dataRoot)
                repaired += 1
            } catch {
                // Nothing is destroyed by a failed repair: the pending row still
                // stands and the next pass tries again.
                continue
            }
        }
        return repaired
    }

    private static func dedupeKey(_ record: REMGrowthEvictionRecord) -> String {
        "\(record.id)|\(record.state?.rawValue ?? "legacy")"
    }

    private static func existingKeys(url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        struct KeyOnly: Decodable {
            let id: String
            let state: REMGrowthEvictionState?
        }
        let decoder = JSONDecoder()
        var keys = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = String(line).data(using: .utf8),
                  let row = try? decoder.decode(KeyOnly.self, from: d) else { continue }
            keys.insert("\(row.id)|\(row.state?.rawValue ?? "legacy")")
        }
        return keys
    }
}
