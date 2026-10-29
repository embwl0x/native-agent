import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import Transcripts

// Blueprint: | `REMProposalStore.swift` | `REMProposalStore`: canonical proposal JSONL, checked reads, legacy import, approval transitions and bounded compaction |

// Canonical REM proposal store — `<dataRoot>/rem_proposals.jsonl`, one
// camelCase row per line. This is THE store: REMConsolidator (full weekly
// pipeline), REMCycleLoop (legacy tick path), and the Mac app's
// approval-resolve executor all read and write through it; the pins emitter
// (`REMConsolidator.emitREMPinsIndex`) derives `rem_pins.json` from it. The
// snake_case file at `<dataRoot>/harness/rem_proposals.jsonl` is import-only
// (see `importLegacyHarnessFileIfNeeded`) — no production writer remains.
//
// Mutations hold the sibling `<path>.lock` flock; lock-free reads see appends or atomic rewrites.

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
    /// The passages the proposal rests on, verbatim, with the sources behind
    /// each. Optional on the wire: rows written before this shape decode
    /// unchanged, and a proposal with nothing verifiable carries none.
    public var supportingPassages: [REMSupportingPassage]?
    /// The distinct dates the material actually HAPPENED on — what recurrence
    /// is counted in, as opposed to `evidenceDates`, which are dream dates.
    public var livedDates: [String]?
    /// `recurring` / `dwelt_on` / `provenance_unavailable`. The approval card
    /// reads this: a thing dwelt on is offered deliberately, under its own
    /// name, and is never presented as a pattern.
    public var support: REMSupportKind?
    /// The circumstance behind the lesson, never written to GROWTH.
    public var whatChanged: String?

    public init(
        id: String,
        targetDoc: String,
        proposalText: String,
        evidenceDates: [String],
        confidence: Double,
        createdAt: String,
        status: String = "pending",
        approvalId: String? = nil,
        supportingPassages: [REMSupportingPassage]? = nil,
        livedDates: [String]? = nil,
        support: REMSupportKind? = nil,
        whatChanged: String? = nil
    ) {
        self.whatChanged = whatChanged
        self.id = id
        self.targetDoc = targetDoc
        self.proposalText = proposalText
        self.evidenceDates = evidenceDates
        self.confidence = confidence
        self.createdAt = createdAt
        self.status = status
        self.approvalId = approvalId
        self.supportingPassages = supportingPassages
        self.livedDates = livedDates
        self.support = support
    }

    public var supportingExperienceReferences: [String]? {
        let passages = supportingPassages ?? []
        guard !passages.isEmpty, passages.allSatisfy({ $0.claimBound == true }) else { return nil }
        // Recollection row IDs change on folding; only canonical exchanges and
        // messages count, each once by its identity.
        return passages.flatMap(\.sourceRefs).filter {
            $0.hasPrefix("exchange:") || $0.hasPrefix("message:") || UUID(uuidString: $0) != nil
                || $0.hasPrefix("chat.user_turn:") || $0.hasPrefix("chat.assistant_turn:")
        }
    }

    public func supportingExperienceCount(identities: [String: String]) -> Int? {
        supportingExperienceReferences.map { Set($0.compactMap { identities[$0] }).count }
    }

    /// Distinct dream dates — how many nights she dreamt about it.
    public var dreamDateCount: Int { Set(evidenceDates).count }
}

/// Stages one pending row into the approval queue; returns the created
/// approval record's id, or nil for an explicit Trust block. Failures throw
/// and remain owed; unstamped rows keep their identity. Wired app-side
/// (SwiftNativeApprovalInbox + the notifications/inbox.jsonl card) so this
/// module never depends on ApprovalInbox — mirrors
/// WeeklySelfImprovementLoop's injected `stageProposal`.
/// The count is resolved for this pass; nil means claim-bound support is unavailable.
public typealias REMApprovalStager = @Sendable (REMProposalRow, Int?) async throws -> String?

public enum REMProposalStoreError: Error, LocalizedError, Equatable {
    case notFound(String)
    case storeUnavailable(String)
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
        case .storeUnavailable(let detail):
            return "REM proposal store unavailable: \(detail)"
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

    // SnapshotTailOpLog folds terminal rows into a base before truncating; pending rows stay in the feed.
    /// Feed row count that triggers a snapshot+truncate on the next mutation.
    static let compactionThreshold = 512
    /// Newest feed rows always retained after a compaction (recency + torn-read
    /// margin); older terminal rows fold to the base.
    static let compactionKeepTail = 256

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public var proposalsURL: URL {
        dataRoot.appendingPathComponent("rem_proposals.jsonl")
    }

    /// Compaction base, written before truncation; reads fold its id-union with the feed.
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

    /// Display reads retain partial evidence and name every unreadable part.
    public func loadAll() -> [REMProposalRow] { loadAllChecked().rows }

    public func loadAllChecked() -> (rows: [REMProposalRow], unreadable: [String]) {
        let read = readChecked()
        return (Self.fold(feedRows: read.feed, baseRows: read.base), read.unreadable)
    }

    public func loadAllStrictly() throws -> [REMProposalRow] {
        let read = try readStrictly()
        return Self.fold(feedRows: read.feed, baseRows: read.base)
    }

    /// Feed first, then base: compaction publishes the base before truncating the feed.
    private func readChecked() -> (lines: [Data], feed: [REMProposalRow], base: [REMProposalRow], unreadable: [String]) {
        var unreadable: [String] = []
        func read(_ url: URL) -> Data? {
            do { return try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            catch { unreadable.append("\(url.lastPathComponent): \(error.localizedDescription)"); return nil }
        }
        let lines = (read(proposalsURL) ?? Data()).split(separator: 0x0A).map { Data($0) }
        let feed = lines.compactMap(Self.decodeRow)
        if feed.count < lines.count {
            unreadable.append("\(proposalsURL.lastPathComponent): \(lines.count - feed.count) malformed row(s)")
        }
        var base: [REMProposalRow] = []
        if let data = read(basePath) {
            do { base = try JSONDecoder().decode(REMProposalCompactionBase.self, from: data).rows }
            catch { unreadable.append("\(basePath.lastPathComponent): \(error.localizedDescription); feed folded alone") }
        }
        return (lines, feed, base, unreadable)
    }

    /// Incomplete evidence grants no write authority; damaged bytes remain untouched.
    private func readStrictly() throws -> (lines: [Data], feed: [REMProposalRow], base: [REMProposalRow], unreadable: [String]) {
        let read = readChecked()
        guard read.unreadable.isEmpty else {
            throw REMProposalStoreError.storeUnavailable(read.unreadable.joined(separator: "; ") + "; bytes were preserved")
        }
        return read
    }

    private static func fold(feedRows: [REMProposalRow], baseRows: [REMProposalRow]) -> [REMProposalRow] {
        guard !baseRows.isEmpty else { return feedRows }
        var byID: [String: REMProposalRow] = [:]
        var order: [String] = []
        for r in baseRows where byID[r.id] == nil { order.append(r.id); byID[r.id] = r }
        for r in feedRows {
            // Terminal base decisions outrank pending feed rows; newer terminal feed decisions win.
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

    // MARK: Append (dedupe by id)

    /// What one append actually did — including what it REFUSED to write.
    /// `droppedByTarget` is keyed by normalized doc name ("SOUL.md"), so the
    /// REM receipt can say which persona doc the pass tried to reach.
    public struct AppendReceipt: Sendable, Equatable, Codable {
        public let appended: Int
        public let droppedByTarget: [String: Int]
        /// Proposals REFUSED for breaking the GROWTH.md passage bound, keyed
        /// by refusal reason. Refused, never truncated: a trimmed essay is
        /// still an essay, and the model gets the reason next pass.
        public let droppedOverBound: [String: Int]

        public init(
            appended: Int,
            droppedByTarget: [String: Int] = [:],
            droppedOverBound: [String: Int] = [:]
        ) {
            self.appended = appended
            self.droppedByTarget = droppedByTarget
            self.droppedOverBound = droppedOverBound
        }

        public var droppedCount: Int {
            droppedByTarget.values.reduce(0, +) + droppedOverBound.values.reduce(0, +)
        }

        /// The single line written to stderr on any drop. nil when nothing
        /// was dropped — a clean pass stays quiet.
        public var droppedLogLine: String? {
            guard !droppedByTarget.isEmpty || !droppedOverBound.isEmpty else { return nil }
            var parts: [String] = []
            if !droppedByTarget.isEmpty {
                let detail = droppedByTarget
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                parts.append("by target — \(detail)"
                    + " — only GROWTH.md proposals are accepted;"
                    + " the other persona docs are the owner's.")
            }
            if !droppedOverBound.isEmpty {
                let detail = droppedOverBound
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                parts.append("over bound — \(detail) — \(REMProposalStore.growthPassageBoundSentence)")
            }
            return "REMProposalStore: dropped \(droppedCount) proposal(s) "
                + parts.joined(separator: " ")
        }
    }

    /// Append proposals as pending rows, skipping ids already present.
    /// Returns the number of rows actually appended.
    @discardableResult
    public func appendPending(_ proposals: [REMProposalRow]) async throws -> Int {
        try await appendPendingWithReceipt(proposals).appended
    }

    /// Append only GROWTH reflexes; every refused target or passage bound is named.
    @discardableResult
    public func appendPendingWithReceipt(
        _ proposals: [REMProposalRow]
    ) async throws -> AppendReceipt {
        guard !proposals.isEmpty else { return AppendReceipt(appended: 0) }
        return try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            // Compaction can throw; finish it before committing new proposals.
            let feedRows = try await self.compactIfNeededLocked()
            var seen = Set(feedRows.map(\.id))
            var buffer = Data()
            var appended = 0
            var droppedByTarget: [String: Int] = [:]
            var droppedOverBound: [String: Int] = [:]
            for p in proposals where !seen.contains(p.id) {
                guard Self.supportsProposalTarget(p.targetDoc) else {
                    // NAME the target. "1 proposal dropped" is a shrug; "1
                    // dropped for SOUL.md" is a fact User can act on.
                    droppedByTarget[Self.normalizedTargetDoc(p.targetDoc), default: 0] += 1
                    continue
                }
                if let reason = Self.growthPassageRefusal(p.proposalText) {
                    droppedOverBound[reason, default: 0] += 1
                    continue
                }
                var row = p
                row.targetDoc = Self.normalizedTargetDoc(p.targetDoc)
                row.status = "pending"
                row.approvalId = nil
                buffer.append(Data((try Self.encodeRow(row) + "\n").utf8))
                seen.insert(p.id)
                appended += 1
            }
            if !buffer.isEmpty {
                try SwiftNativePersistenceCore.appendLines(buffer, to: self.proposalsURL)
            }
            let receipt = AppendReceipt(
                appended: appended,
                droppedByTarget: droppedByTarget,
                droppedOverBound: droppedOverBound)
            if let line = receipt.droppedLogLine {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            return receipt
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
        return try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
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
                guard let wire = try? JSONDecoder().decode(LegacyWire.self, from: line),
                      !wire.id.isEmpty else { continue }
                if finals[wire.id] == nil { order.append(wire.id) }
                finals[wire.id] = wire
            }
            let seen = Set(try self.loadAllStrictly().map(\.id))
            var buffer = Data()
            var imported = 0
            for id in order {
                guard let wire = finals[id], !seen.contains(id) else { continue }
                guard Self.supportsProposalTarget(wire.target_doc) else { continue }
                // Imported lessons obey the same passage bound as fresh proposals.
                guard Self.growthPassageRefusal(wire.proposed_text) == nil else { continue }
                // Applied rows stay in migrated history; unfinished rows import as pending for human approval.
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
                try SwiftNativePersistenceCore.appendLines(buffer, to: self.proposalsURL)
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
    public func stagePendingApprovals(_ stage: @escaping REMApprovalStager,
        resolver: ChatSessionRecollections.ExperienceResolver? = nil, limit: Int = .max
    ) async throws -> Int {
        let resolver = resolver ?? ChatSessionRecollections.ExperienceResolver(dataRoot: dataRoot)
        do {
        let staged = try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            let read = try self.readStrictly()
            var lines = read.lines
            guard !lines.isEmpty else { return 0 }
            let pending = read.feed.enumerated().compactMap { i, row -> (Int, REMProposalRow)? in
                guard row.status == "pending", row.approvalId == nil,
                      Self.supportsProposalTarget(row.targetDoc) else { return nil }
                return (i, row)
            }
            var staged = 0
            for (i, row) in pending.prefix(max(0, limit)) {
                let identities = try await resolver.resolve(
                    for: row.supportingExperienceReferences ?? [], includingSourceRows: false).identities
                guard let approvalId = try await stage(row, row.supportingExperienceCount(identities: identities)) else { continue }
                var stamped = row
                stamped.approvalId = approvalId
                lines[i] = Data(try Self.encodeRow(stamped).utf8)
                staged += 1
            }
            if staged > 0 {
                try Self.writeLines(lines, to: self.proposalsURL)
            }
            return staged
        }
        if try loadAllStrictly().allSatisfy({ $0.status != "pending" || $0.approvalId != nil }) {
            await RepairOwed.settle(dataRoot, operation: "rem.stage",
                evidence: .init(source: "rem_proposals.jsonl", id: "approval stamps")).value
        }
        return staged
        } catch {
            try Task.checkCancellation()
            await RepairOwed.owe(dataRoot, id: "rem-stage-repair:" + UUID().uuidString, kind: .run,
                operation: "rem.stage", owner: "rem_proposals.jsonl approval stamps",
                words: "REM approval staging failed: \(error.localizedDescription)",
                nextCall: ToolFailureError.call("app", ["action": .string("mind.rem"), "args": .object(["repair": .bool(true)])])).value
            throw error
        }
    }

    /// Canceled decision: the approval record is terminal but the proposal
    /// was neither applied nor refused — clear the stamp so the next
    /// pipeline pass stages a fresh approval instead of leaving a dead row.
    public func clearApprovalStamp(proposalId: String) async throws {
        try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            let read = try self.readStrictly()
            var lines = read.lines
            for (i, original) in read.feed.enumerated() where original.id == proposalId {
                var row = original
                row.approvalId = nil
                lines[i] = Data(try Self.encodeRow(row).utf8)
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
    /// that), then flip pending→denied, then rebuild the pins index. A stale
    /// card is closed with `tombstone: false`: its lesson was not refused.
    @discardableResult
    public func applyDenial(proposalId: String, reason: String, tombstone: Bool = true) async throws -> REMProposalRow {
        guard let current = try loadAllStrictly().first(where: { $0.id == proposalId }) else {
            throw REMProposalStoreError.notFound(proposalId)
        }
        if current.status == "denied" { return current } // re-fire: no-op
        guard current.status == "pending" else {
            throw REMProposalStoreError.conflict(id: proposalId, status: current.status)
        }
        if tombstone {
            try await REMTombstoneStore(dataRoot: dataRoot).record(current, reason: reason)
        }
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
        try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            // A row already folded into the base is TERMINAL (pending rows are
            // never compacted), so it can only be re-targeted idempotently. Match
            // the in-feed idempotency/conflict semantics without touching the feed.
            let read = try self.readStrictly()
            if let baseRow = read.base.first(where: { $0.id == proposalId }) {
                if baseRow.status == newStatus { return baseRow }
                throw REMProposalStoreError.conflict(id: proposalId, status: baseRow.status)
            }
            var lines = read.lines
            for (i, original) in read.feed.enumerated() where original.id == proposalId {
                var row = original
                if row.status == newStatus { return row }
                if requireSupportedTarget, !Self.supportsProposalTarget(row.targetDoc) {
                    throw REMProposalStoreError.unsupportedTarget(row.targetDoc)
                }
                guard row.status == "pending" else {
                    throw REMProposalStoreError.conflict(id: proposalId, status: row.status)
                }
                row.status = newStatus
                lines[i] = Data(try Self.encodeRow(row).utf8)
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
    @discardableResult
    private func compactIfNeededLocked() async throws -> [REMProposalRow] {
        let read = try readStrictly()
        let feedRows = read.feed
        let rows = Self.fold(feedRows: feedRows, baseRows: read.base)
        guard feedRows.count >= Self.compactionThreshold,
              feedRows.count > Self.compactionKeepTail else { return rows }
        let keepSuffixIDs = Set(feedRows.suffix(Self.compactionKeepTail).map(\.id))
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
        guard !toBase.isEmpty else { return rows }
        let mergedBase = Self.fold(feedRows: toBase, baseRows: read.base)
        let base = REMProposalCompactionBase(rows: mergedBase)
        try await SnapshotTailOpLog.commitCompaction(
            baseJSON: base.toJSON(compactedAt: ISO8601DateFormatter().string(from: Date())),
            tailRows: try keepInFeed.map(Self.encodeRowJSON),
            basePath: basePath,
            opsPath: proposalsURL
        )
        return Self.fold(feedRows: keepInFeed, baseRows: mergedBase)
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

    // MARK: GROWTH.md passage bound

    /// A GROWTH.md passage is one line of at most 240 Unicode scalars.
    public static let growthPassageScalarCap = 240

    /// The bound in one sentence — the prompt and every refusal say the same
    /// thing, so there is only one number to change.
    public static let growthPassageBoundSentence =
        "one line, under \(growthPassageScalarCap) characters, a reference over a description"

    /// Why `text` may not be written into GROWTH.md, or nil when it fits.
    /// REFUSES; it never truncates — a cut-off essay is still an essay, and
    /// the reason travels back to the REM pass in the append receipt.
    public static func growthPassageRefusal(_ text: String) -> String? {
        if text.contains(where: { $0.isNewline }) { return "multi-line" }
        if text.unicodeScalars.count > growthPassageScalarCap {
            return "over \(growthPassageScalarCap) characters"
        }
        return nil
    }

    private static func readLines(_ url: URL) -> [Data] {
        guard let body = try? Data(contentsOf: url) else { return [] }
        // Decode each physical row independently: a torn UTF-8 scalar must
        // neither hide later rows nor be replaced when another row changes.
        return body.split(separator: 0x0A).map { Data($0) }
    }

    private static func decodeRow(_ line: Data) -> REMProposalRow? {
        return try? JSONDecoder().decode(REMProposalRow.self, from: line)
    }

    private static func encodeRow(_ row: REMProposalRow) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(row), as: UTF8.self)
    }

    /// A row as its JSONValue wire form (for the base snapshot + `commitCompaction`
    /// tail rewrite). Round-trips through the Codable encoder so the on-disk shape
    /// matches `encodeRow`.
    static func encodeRowJSON(_ row: REMProposalRow) throws -> JSONValue {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(JSONValue.self, from: enc.encode(row))
    }

    private static func writeLines(_ lines: [Data], to url: URL) throws {
        var body = Data()
        for line in lines {
            body.append(line)
            body.append(0x0A)
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(body, to: url)
    }
}

/// Terminal proposals folded out of the feed, in first-folded order.
struct REMProposalCompactionBase: Sendable, Equatable {
    let rows: [REMProposalRow]

    func toJSON(compactedAt: String) -> JSONValue {
        .object([
            "version": .int(1),
            "compactedAt": .string(compactedAt),
            "compactedCount": .int(Int64(rows.count)),
            "rows": .array(rows.compactMap { try? REMProposalStore.encodeRowJSON($0) }),
        ])
    }
}

extension REMProposalCompactionBase: Decodable {
    private enum CodingKeys: String, CodingKey { case rows }

    init(from decoder: any Decoder) throws {
        var container: any UnkeyedDecodingContainer
        do {
            container = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .rows)
        } catch {
            throw PersistenceCoreError.ioFailure("REM proposal base has an invalid shape")
        }
        var rows: [REMProposalRow] = []
        do {
            while !container.isAtEnd {
                rows.append(try container.decode(REMProposalRow.self))
            }
        } catch {
            throw PersistenceCoreError.ioFailure("REM proposal base has an invalid row")
        }
        self.init(rows: rows)
    }
}
