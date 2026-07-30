import Foundation
import PersistenceCore

// Canonical REM proposal store — `<dataRoot>/rem_proposals.jsonl`, one
// camelCase row per line. This is THE store: REMConsolidator (full weekly
// pipeline), REMCycleLoop (legacy tick path), and the Mac app's
// approval-resolve executor all read and write through it; the pins emitter
// (`REMConsolidator.emitREMPinsIndex`) derives `rem_pins.json` from it. The
// snake_case file at `<dataRoot>/harness/rem_proposals.jsonl` is import-only
// (see `importLegacyHarnessFileIfNeeded`) — no production writer remains.
//
// Locking: every mutation is a read-modify-write inside ONE
// `withFileLock(proposalsURL)` critical section (cross-process flock on the
// sibling `<path>.lock`, the the retired daemon convention). Bare reads are
// lock-free: the file is only appended or atomically rewritten under the
// lock, so a reader can't observe a torn row.

// MARK: - REMProposalRow

/// One on-disk row. `status` lifecycle: pending → approved | denied.
/// `approvalId` is the staging stamp — set once an ApprovalInbox record
/// exists for the row, so a pipeline re-run can never double-stage the
/// same proposal id.
public struct REMProposalRow: Codable, Sendable, Equatable {
    public var id: String
    public var targetDoc: String
    public var proposalText: String
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String
    public var status: String
    public var approvalId: String?

    public init(
        id: String,
        targetDoc: String,
        proposalText: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String,
        status: String,
        approvalId: String? = nil
    ) {
        self.id = id
        self.targetDoc = targetDoc
        self.proposalText = proposalText
        self.evidenceDates = evidenceDates
        self.confidence = confidence
        self.createdAt = createdAt
        self.status = status
        self.approvalId = approvalId
    }

    /// Wire a pipeline proposal into a pending row. `targetDoc` is
    /// normalized to carry the `.md` suffix — the pins index and approval
    /// surfaces key on the doc FILENAME, and the legacy loop hands bare
    /// names like "GROWTH".
    public init(from proposal: REMProposal, status: String = "pending") {
        let raw = REMProposalStore.normalizedTargetDoc(proposal.targetDoc)
        self.init(
            id: proposal.id,
            targetDoc: raw.hasSuffix(".md") ? raw : raw + ".md",
            proposalText: proposal.proposalText,
            evidenceDates: proposal.evidenceDates,
            confidence: proposal.confidence,
            createdAt: proposal.createdAt,
            status: status
        )
    }

    /// Back to the pipeline shape (tombstone recording takes a REMProposal).
    public var asREMProposal: REMProposal {
        REMProposal(
            id: id,
            targetDoc: targetDoc,
            proposalText: proposalText,
            evidenceDates: evidenceDates,
            confidence: confidence,
            createdAt: createdAt
        )
    }
}

/// Stages one pending row into the approval queue; returns the created
/// approval record's id, or nil when staging failed (the row stays
/// unstamped and is retried on the next pipeline pass). Wired app-side
/// (SwiftNativeApprovalInbox + the notifications/inbox.jsonl card) so this
/// module never depends on ApprovalInbox — mirrors
/// WeeklySelfImprovementLoop's injected `stageProposal`.
public typealias REMApprovalStager = @Sendable (REMProposalRow) async -> String?

public enum REMProposalStoreError: Error, LocalizedError, Equatable {
    case notFound(String)
    /// REM proposals are production-supported only as compact GROWTH.md
    /// reflexes. SOUL/VOICE stay read-only REM context.
    case unsupportedTarget(String)
    /// Status flip refused: the row is already in a DIFFERENT terminal
    /// state (e.g. deny after approve).
    case conflict(id: String, status: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "REM proposal not found: \(id)"
        case .unsupportedTarget(let target):
            return "REM proposals can only target GROWTH.md, not \(target)"
        case .conflict(let id, let status):
            return "REM proposal \(id) is already \(status)"
        }
    }
}

// MARK: - REMProposalStore

public struct REMProposalStore: Sendable {
    public let dataRoot: URL
    private let lockCore = SwiftNativePersistenceCore()

    // P-L3 (tightness round 2): the feed was a raw op-log that only ever grew —
    // terminal (approved/denied) rows accumulate forever, and the pins emitter +
    // approval executor read them, so a naive newest-N line cap would VANISH a
    // live approved pin. Adopt the shared SnapshotTailOpLog snapshot+tail engine
    // (as DeskStore/GitHubCommandStore/TaskLedger did): once the feed crosses
    // `compactionThreshold`, old TERMINAL rows fold into an id-keyed base file
    // (`rem_proposals_base.json`), written BEFORE the feed truncate so a crash or
    // a lock-free reader racing the compaction never loses a terminal row. PENDING
    // rows are NEVER compacted — they still mutate in place, so they must stay in
    // the feed where the in-place status-flip rewrites can find them. Every read
    // (loadAll, the pins emitter) folds base + feed.
    /// Feed row count that triggers a snapshot+truncate on the next mutation.
    static let compactionThreshold = 512
    /// Newest feed rows always retained after a compaction (recency + torn-read
    /// margin); older terminal rows fold to the base.
    static let compactionKeepTail = 256
    private let compactionThreshold: Int
    private let keepTail: Int

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
        self.compactionThreshold = Self.compactionThreshold
        self.keepTail = Self.compactionKeepTail
    }

    /// Test-only: scale the compaction trim down so a handful of rows exercise
    /// the snapshot+tail path. `keepTail` clamps to ≥1 (an empty tail could lose
    /// the newest row); `compactionThreshold` to ≥2.
    init(dataRoot: URL, compactionThreshold: Int, keepTail: Int) {
        self.dataRoot = dataRoot
        self.compactionThreshold = max(2, compactionThreshold)
        self.keepTail = max(1, keepTail)
    }

    public var proposalsURL: URL {
        dataRoot.appendingPathComponent("rem_proposals.jsonl")
    }

    /// `<dataRoot>/rem_proposals_base.json` — the compaction snapshot the feed
    /// folds FROM (P-L3). Written atomically BEFORE the feed truncate; a crash
    /// between the two leaves the full feed intact and the id-union fold heals it.
    public var basePath: URL {
        dataRoot.appendingPathComponent("rem_proposals_base.json")
    }

    /// Retired snake_case side-store. Import-only; renamed to
    /// `rem_proposals.jsonl.migrated` after the one-time import.
    public var legacyHarnessURL: URL {
        dataRoot
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("rem_proposals.jsonl")
    }

    // MARK: Read

    /// Tolerant load of the FULL authoritative view: the compaction base folded
    /// under the live feed. Lines that don't decode are skipped here but
    /// preserved verbatim by every rewrite path below.
    ///
    /// Read order is FEED FIRST, base SECOND: the base is written BEFORE the feed
    /// truncate during compaction, so a lock-free reader racing it sees every
    /// terminal row in the full feed OR the just-written base — never neither.
    /// Feed wins on an id collision (in steady state feed and base ids are
    /// disjoint; a collision means the feed holds the newer copy).
    public func loadAll() -> [REMProposalRow] {
        let feedRows = Self.readLines(proposalsURL).compactMap(Self.decodeRow)
        let baseRows = loadBaseRows()
        guard !baseRows.isEmpty else { return feedRows }
        var byID: [String: REMProposalRow] = [:]
        var order: [String] = []
        for r in baseRows where byID[r.id] == nil { order.append(r.id); byID[r.id] = r }
        for r in feedRows {
            // A pending feed row must never shadow a TERMINAL base row with the
            // same id: a deterministic emitter can re-emit an id after its
            // approved copy folded to base, and letting the feed win would make
            // approved pins vanish (gpt-5.5 fix round, HIGH). Terminal-over-
            // terminal keeps feed-wins (the feed copy is the newer decision).
            if let existing = byID[r.id],
               existing.status == "approved" || existing.status == "denied",
               r.status == "pending" {
                continue
            }
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id] = r
        }
        return order.compactMap { byID[$0] }
    }

    /// The base's folded rows (empty when no base file exists — a genesis feed).
    /// Tolerant per-row like the feed; a base file that exists but is entirely
    /// undecodable is logged loudly (never silently blanking approved pins).
    func loadBaseRows() -> [REMProposalRow] {
        readBaseRows() ?? []
    }

    /// Distinguishes MISSING base (`[]` — genesis feed, safe to create) from
    /// CORRUPT base (`nil` — exists but undecodable). Read paths degrade to
    /// feed-only on nil; COMPACTION MUST ABORT on nil, because merging an
    /// "empty" base and rewriting would permanently discard every previously
    /// folded terminal row (gpt-5.5 fix round, MED).
    func readBaseRows() -> [REMProposalRow]? {
        guard FileManager.default.fileExists(atPath: basePath.path) else { return [] }
        guard let data = try? Data(contentsOf: basePath),
              let jv = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = jv,
              case .array(let rows)? = obj["rows"] else {
            NSLog("REMProposalStore: base at %@ exists but did not decode — folding feed only",
                  basePath.path)
            return nil
        }
        return rows.compactMap(Self.decodeRowJSON)
    }

    // MARK: Append (dedupe by id)

    /// Append proposals as pending rows, skipping ids already present.
    /// Returns the number of rows actually appended.
    @discardableResult
    public func appendPending(_ proposals: [REMProposal]) async throws -> Int {
        guard !proposals.isEmpty else { return 0 }
        return try await lockCore.withFileLock(proposalsURL) {
            // Dedupe against base AND feed: an id folded to base is a settled
            // decision, and re-appending it as pending would shadow it
            // (gpt-5.5 fix round, HIGH). Corrupt base (nil) degrades to
            // feed-only dedupe — loadAll's terminal-shadow refusal still holds.
            var seen = Set(Self.readLines(self.proposalsURL).compactMap(Self.decodeRow).map(\.id))
            seen.formUnion((self.readBaseRows() ?? []).map(\.id))
            var buffer = Data()
            var appended = 0
            for p in proposals where !seen.contains(p.id) && Self.supportsProposalTarget(p.targetDoc) {
                let row = REMProposalRow(from: p)
                buffer.append(Data((try Self.encodeRow(row) + "\n").utf8))
                seen.insert(p.id)
                appended += 1
            }
            if !buffer.isEmpty {
                try Self.appendData(buffer, to: self.proposalsURL)
            }
            try await self.compactIfNeededLocked()
            return appended
        }
    }

    // MARK: One-time legacy import

    /// Import the legacy `<dataRoot>/harness/rem_proposals.jsonl` snake_case
    /// rows into the canonical store: map to camelCase, force status
    /// "pending" (nothing legacy ever flipped one), dedupe by id, then
    /// rename the source to `.migrated`. Idempotent — skips silently when
    /// the legacy file is absent or `.migrated` already exists. Callers run
    /// this lazily at the pipeline's first store open, NOT at app boot.
    @discardableResult
    public func importLegacyHarnessFileIfNeeded() async throws -> Int {
        let legacy = legacyHarnessURL
        let migrated = legacy.appendingPathExtension("migrated")
        let fm = FileManager.default
        // Cheap pre-check outside the lock; re-checked inside because another
        // process may complete the import while we wait on the flock.
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: migrated.path) else { return 0 }
        return try await lockCore.withFileLock(proposalsURL) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: legacy.path),
                  !fm.fileExists(atPath: migrated.path) else { return 0 }
            // Legacy wire schema (REMCycleLoop pre-cutover): snake_case
            // except `createdAt` — that inconsistency was on-disk, mirror it.
            struct LegacyWire: Decodable {
                let id: String
                let target_doc: String
                let proposed_text: String
                let evidence_dates: [String]?
                let createdAt: String?
                let status: String?
            }
            // The legacy file is an append-only EVENT LOG: one id can appear
            // repeatedly as its status progressed (pending → applying →
            // applied). Collapse to the LAST row per id — the final status is
            // the truth — before deciding what imports.
            var order: [String] = []
            var finals: [String: LegacyWire] = [:]
            for line in Self.readLines(legacy) {
                guard let data = line.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(LegacyWire.self, from: data),
                      !wire.id.isEmpty else { continue }
                if finals[wire.id] == nil { order.append(wire.id) }
                finals[wire.id] = wire
            }
            let seen = Set(Self.readLines(self.proposalsURL).compactMap(Self.decodeRow).map(\.id))
            var buffer = Data()
            var imported = 0
            for id in order {
                guard let wire = finals[id], !seen.contains(id) else { continue }
                guard Self.supportsProposalTarget(wire.target_doc) else { continue }
                // Daemon-era "applied" finals were ALREADY actioned (the
                // content lives in the persona docs) — importing them as
                // pending would re-stage long-settled approvals. Skip; the
                // .migrated file preserves the history. "applying" never
                // completed (daemon died mid-apply) → human re-decides,
                // import as pending.
                if wire.status == "applied" { continue }
                let row = REMProposalRow(
                    id: wire.id,
                    targetDoc: Self.normalizedTargetDoc(wire.target_doc),
                    proposalText: wire.proposed_text,
                    evidenceDates: wire.evidence_dates ?? [],
                    confidence: 0, // legacy wire carried no confidence
                    createdAt: wire.createdAt ?? "",
                    status: "pending"
                )
                buffer.append(Data((try Self.encodeRow(row) + "\n").utf8))
                imported += 1
            }
            if !buffer.isEmpty {
                try Self.appendData(buffer, to: self.proposalsURL)
            }
            // Rename even when 0 rows survived the dedupe — the rename is
            // the one-time marker.
            try fm.moveItem(at: legacy, to: migrated)
            return imported
        }
    }

    // MARK: Approval staging

    /// Stage every pending, unstamped row through `stage`, stamping rows
    /// whose staging returned an approval id. Scan + stage + stamp run in
    /// ONE critical section so two concurrent drivers can't both see the
    /// same unstamped row. Returns the number staged.
    @discardableResult
    public func stagePendingApprovals(_ stage: @escaping REMApprovalStager) async throws -> Int {
        try await lockCore.withFileLock(proposalsURL) {
            var lines = Self.readLines(self.proposalsURL)
            guard !lines.isEmpty else { return 0 }
            var staged = 0
            for i in lines.indices {
                guard let row = Self.decodeRow(lines[i]),
                      row.status == "pending", row.approvalId == nil,
                      Self.supportsProposalTarget(row.targetDoc) else { continue }
                guard let approvalId = await stage(row) else { continue }
                var stamped = row
                stamped.approvalId = approvalId
                lines[i] = try Self.encodeRow(stamped)
                staged += 1
            }
            if staged > 0 {
                try Self.writeLines(lines, to: self.proposalsURL)
            }
            return staged
        }
    }

    /// Canceled decision: the approval record is terminal but the proposal
    /// was neither applied nor refused — clear the stamp so the next
    /// pipeline pass stages a fresh approval instead of leaving a dead row.
    public func clearApprovalStamp(proposalId: String) async throws {
        try await lockCore.withFileLock(proposalsURL) {
            var lines = Self.readLines(self.proposalsURL)
            for i in lines.indices {
                guard var row = Self.decodeRow(lines[i]), row.id == proposalId else { continue }
                row.approvalId = nil
                lines[i] = try Self.encodeRow(row)
                try Self.writeLines(lines, to: self.proposalsURL)
                return
            }
            throw REMProposalStoreError.notFound(proposalId)
        }
    }

    // MARK: Decision application

    /// Approve: flip pending→approved under one flock'd R-M-W, then rebuild
    /// rem_pins.json so the chat-turn injector sees the pin next turn.
    @discardableResult
    public func applyApproval(proposalId: String) async throws -> REMProposalRow {
        let row = try await setStatus(
            proposalId: proposalId,
            to: "approved",
            requireSupportedTarget: true
        )
        try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
        return row
    }

    /// Deny: tombstone FIRST (a denied text must never be re-proposed, even
    /// if the flip below fails — the caller's FAILED annotation surfaces
    /// that), then flip pending→denied, then rebuild the pins index.
    @discardableResult
    public func applyDenial(proposalId: String, reason: String) async throws -> REMProposalRow {
        guard let current = loadAll().first(where: { $0.id == proposalId }) else {
            throw REMProposalStoreError.notFound(proposalId)
        }
        if current.status == "denied" { return current } // re-fire: no-op
        guard current.status == "pending" else {
            throw REMProposalStoreError.conflict(id: proposalId, status: current.status)
        }
        let tombstones = REMTombstoneStore(dataRoot: dataRoot)
        try await tombstones.record(current.asREMProposal, reason: reason)
        let row = try await setStatus(proposalId: proposalId, to: "denied")
        try REMConsolidator.emitREMPinsIndex(dataRoot: dataRoot)
        return row
    }

    /// Flip a row's status inside one critical section. Idempotent when the
    /// row already holds `newStatus`; refuses to move between distinct
    /// terminal states.
    private func setStatus(
        proposalId: String,
        to newStatus: String,
        requireSupportedTarget: Bool = false
    ) async throws -> REMProposalRow {
        try await lockCore.withFileLock(proposalsURL) {
            // A row already folded into the base is TERMINAL (pending rows are
            // never compacted), so it can only be re-targeted idempotently. Match
            // the in-feed idempotency/conflict semantics without touching the feed.
            if let baseRow = self.loadBaseRows().first(where: { $0.id == proposalId }) {
                if baseRow.status == newStatus { return baseRow }
                throw REMProposalStoreError.conflict(id: proposalId, status: baseRow.status)
            }
            var lines = Self.readLines(self.proposalsURL)
            for i in lines.indices {
                guard var row = Self.decodeRow(lines[i]), row.id == proposalId else { continue }
                if row.status == newStatus { return row }
                if requireSupportedTarget, !Self.supportsProposalTarget(row.targetDoc) {
                    throw REMProposalStoreError.unsupportedTarget(row.targetDoc)
                }
                guard row.status == "pending" else {
                    throw REMProposalStoreError.conflict(id: proposalId, status: row.status)
                }
                row.status = newStatus
                lines[i] = try Self.encodeRow(row)
                try Self.writeLines(lines, to: self.proposalsURL)
                // The flip just created a terminal row — fold older terminal rows
                // into the base if the feed crossed the threshold.
                try await self.compactIfNeededLocked()
                return row
            }
            throw REMProposalStoreError.notFound(proposalId)
        }
    }

    // MARK: Compaction (snapshot + tail)

    /// Fold older TERMINAL feed rows into the base once the feed crosses
    /// `compactionThreshold`. PENDING rows are never folded (they still mutate in
    /// place, so they must stay in the feed); the newest `keepTail` feed rows are
    /// retained regardless of status (recency + a torn-read margin). Base is
    /// written BEFORE the feed truncate via `SnapshotTailOpLog.commitCompaction`,
    /// so a crash or lock-free reader in the gap replays safely. The caller MUST
    /// hold the feed flock. A feed of only pending rows never compacts — but
    /// pending rows resolve to terminal quickly, and terminal accumulation (not
    /// pending) was the unbounded-growth failure mode.
    private func compactIfNeededLocked() async throws {
        let feedRows = Self.readLines(proposalsURL).compactMap(Self.decodeRow)
        guard feedRows.count >= compactionThreshold, feedRows.count > keepTail else { return }
        let keepSuffixIDs = Set(feedRows.suffix(keepTail).map(\.id))
        var toBase: [REMProposalRow] = []
        var keepInFeed: [REMProposalRow] = []
        for row in feedRows {
            let terminal = row.status == "approved" || row.status == "denied"
            if terminal, !keepSuffixIDs.contains(row.id) {
                toBase.append(row)
            } else {
                keepInFeed.append(row)
            }
        }
        guard !toBase.isEmpty else { return }
        // FAIL CLOSED on a corrupt base: rewriting it from an "empty" merge
        // would permanently discard every previously folded terminal row.
        // Skipping compaction just leaves the feed longer until a human or a
        // repair pass restores the base (gpt-5.5 fix round, MED).
        guard let existingBase = readBaseRows() else {
            NSLog("REMProposalStore: base unreadable — compaction skipped to avoid overwriting folded terminal rows")
            return
        }
        // Merge into the existing base, id-keyed, newest (the just-folded row) wins.
        var byID: [String: REMProposalRow] = [:]
        var order: [String] = []
        for r in existingBase where byID[r.id] == nil { order.append(r.id); byID[r.id] = r }
        for r in toBase {
            if byID[r.id] == nil { order.append(r.id) }
            byID[r.id] = r
        }
        let mergedBase = order.compactMap { byID[$0] }
        let base = REMProposalCompactionBase(
            rows: mergedBase,
            compactedAt: ISO8601DateFormatter().string(from: Date()),
            compactedCount: mergedBase.count
        )
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: base.toJSON(),
            tailRows: try keepInFeed.map(Self.encodeRowJSON),
            basePath: basePath,
            opsPath: proposalsURL,
            persistence: lockCore
        )
    }

    // MARK: Line helpers

    public static func normalizedTargetDoc(_ targetDoc: String) -> String {
        let upper = targetDoc
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if upper == "GROWTH" || upper == "GROWTH.MD" { return "GROWTH.md" }
        if upper == "SOUL" || upper == "SOUL.MD" { return "SOUL.md" }
        if upper == "VOICE" || upper == "VOICE.MD" { return "VOICE.md" }
        return targetDoc
    }

    public static func supportsProposalTarget(_ targetDoc: String) -> Bool {
        normalizedTargetDoc(targetDoc) == "GROWTH.md"
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func decodeRow(_ line: String) -> REMProposalRow? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(REMProposalRow.self, from: data)
    }

    private static func encodeRow(_ row: REMProposalRow) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: try enc.encode(row), encoding: .utf8) ?? "{}"
    }

    /// A row as its JSONValue wire form (for the base snapshot + `commitCompaction`
    /// tail rewrite). Round-trips through the Codable encoder so the on-disk shape
    /// matches `encodeRow`.
    static func encodeRowJSON(_ row: REMProposalRow) throws -> JSONValue {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONValue.self, from: enc.encode(row))
    }

    /// Decode one base row from its JSONValue form (tolerant — a malformed row is
    /// skipped, mirroring the feed's per-line tolerance).
    static func decodeRowJSON(_ value: JSONValue) -> REMProposalRow? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(REMProposalRow.self, from: data)
    }

    private static func appendData(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static func writeLines(_ lines: [String], to url: URL) throws {
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(body.utf8).write(to: url, options: .atomic)
    }
}

/// The compaction snapshot (P-L3). `rows` is the id-keyed set of TERMINAL
/// proposals folded out of the feed, in first-folded order. ADDITIVE on disk: it
/// lives in a NEW file beside the feed, so an old feed with no base loads as pure
/// genesis (`loadBaseRows()` → `[]`).
struct REMProposalCompactionBase: Sendable, Equatable {
    let rows: [REMProposalRow]
    let compactedAt: String
    let compactedCount: Int

    func toJSON() -> JSONValue {
        .object([
            "version": .int(1),
            "compactedAt": .string(compactedAt),
            "compactedCount": .int(Int64(compactedCount)),
            "rows": .array(rows.compactMap { try? REMProposalStore.encodeRowJSON($0) }),
        ])
    }
}
