import Foundation
import PersistenceCore

// Blueprint: | `REMGrowthEvictionHistory.swift` | `REMGrowthEvictionHistory`. |

// MARK: - GROWTH eviction history (item 5)
// Retain exact evicted writing beside its compressed graph node under the same identity so the summary remains expandable.
// Keep history outside the persona root so retention cannot return reclaimed prompt weight.

/// Write retention before graph insertion and GROWTH removal; pending history cannot claim eviction.
public enum REMGrowthEvictionState: String, Sendable, Codable, Equatable {
    /// Pending means retained only; the source may still be in GROWTH.
    case pending
    /// Committed certifies a successful splice.
    case committed
}

public struct REMGrowthEvictionRecord: Sendable, Codable, Equatable {
    /// Share the exact source-hash identity between compressed node and retained passage so it serves as the expansion pointer.
    public var id: String
    public var evictedAt: String
    public var summary: String
    /// Preserve the evicted passage byte-for-byte.
    public var passage: String
    public var sourceLines: Int
    /// Keep originating approval IDs so retained growth remains traceable to its authorization.
    public var proposalRefs: [REMGrowthEvictionProposalRef]
    /// Unknown state cannot certify removal; only committed history can.
    public var state: REMGrowthEvictionState
    /// Mark reconciliation explicitly so inferred interrupted completion cannot masquerade as directly observed splice.
    public var reconciled: Bool?

    public init(
        id: String,
        evictedAt: String,
        summary: String,
        passage: String,
        sourceLines: Int,
        proposalRefs: [REMGrowthEvictionProposalRef] = [],
        state: REMGrowthEvictionState,
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

    /// Pending alone means retention, never eviction; require observed or corroborated commit.
    public var isCommitted: Bool { state == .committed }
}

public struct REMGrowthEvictionProposalRef: Sendable, Codable, Equatable {
    public var proposalId: String
    public var targetDoc: String
    public var createdAt: String
    public var approvalId: String?
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

/// Append and deduplicate under the file lock so retained history remains ordered and durable.
public enum REMGrowthEvictionHistory {
    public static func fileURL(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("growth_history", isDirectory: true)
            .appendingPathComponent("evictions.jsonl")
    }

    /// Use a bounded source-hash pointer so expansion identity remains stable across retries.
    public static func pointer(id: String) -> String {
        "(full passage retained: growth_history/evictions.jsonl#\(id))"
    }

    /// Deduplicate by ID and state so failed merges can retry while later commit records still append.
    /// Any failed retention write must prevent destructive GROWTH splice.
    public static func append(
        _ record: REMGrowthEvictionRecord,
        dataRoot: URL
    ) async throws {
        let url = fileURL(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await SwiftNativePersistenceCore.withFileLock(url) {
            if try existingKeys(url: url).contains(dedupeKey(record)) { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try await SwiftNativePersistenceCore.appendJSONL(JSONValue.parse(encoder.encode(record)), to: url)
        }
    }

    /// Integrity failures block dependent decisions while preserving source bytes for repair.
    public static func loadAll(dataRoot: URL) throws -> [REMGrowthEvictionRecord] {
        try read(fileURL(dataRoot: dataRoot))
    }

    /// Expansion returns retained writing regardless of eviction state.
    public static func record(id: String, dataRoot: URL) throws -> REMGrowthEvictionRecord? {
        try loadAll(dataRoot: dataRoot).last { $0.id == id }
    }

    /// Reconcile pending history on every pass before size checks can skip repair.
    /// A missing passage alone cannot prove eviction; require the matching graph node as independent corroboration.
    /// Keep present passages and uncorroborated absence pending; mark proven interrupted splices reconciled.
    @discardableResult
    public static func reconcilePending(
        growthBody: String,
        dataRoot: URL,
        kgNodeExists: @Sendable (String) async throws -> Bool
    ) async throws -> Int {
        let rows = try loadAll(dataRoot: dataRoot)
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
            guard try await kgNodeExists(row.id) else { continue }
            var fixed = row
            fixed.state = .committed
            fixed.reconciled = true
            try await append(fixed, dataRoot: dataRoot)
            repaired += 1
        }
        return repaired
    }

    private static func dedupeKey(_ record: REMGrowthEvictionRecord) -> String {
        "\(record.id)|\(record.state.rawValue)"
    }

    private static func existingKeys(url: URL) throws -> Set<String> {
        Set(try read(url).map(dedupeKey))
    }

    private static func read(_ url: URL) throws -> [REMGrowthEvictionRecord] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        guard data.isEmpty || data.last == 0x0A else {
            throw PersistenceCoreError.ioFailure("GROWTH eviction history has an unfinished row at \(url.path); preserve and repair the ledger before retrying")
        }
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).enumerated().map { index, line in
            do { return try decoder.decode(REMGrowthEvictionRecord.self, from: Data(line)) }
            catch {
                throw PersistenceCoreError.ioFailure(
                    """
                        GROWTH eviction history row \(index + 1) at \(url.path) is unreadable: \(error.localizedDescription). Preserve and repair the ledger \
                        before retrying
                        """)
            }
        }
    }
}
