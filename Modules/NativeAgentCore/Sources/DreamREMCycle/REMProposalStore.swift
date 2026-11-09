import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import MemoryV2
import PersonaEngine
import Transcripts

// Blueprint: | `REMProposalStore.swift` | `REMProposalStore`. |

// Use one proposal store for REM and approval decisions; derive pins from its rows.
// Hold the sibling lock for mutations; lock-free reads must tolerate appends and atomic rewrites.

// MARK: - REMProposalRow

/// Stamp approvalId only after a canonical card exists so a repeated pass cannot stage the same proposal twice.
public struct REMProposalRow: Codable, Sendable, Equatable {
    public var id: String
    public var targetDoc: String
    public var proposalText: String
    public var evidenceDates: [String]
    public var confidence: Double
    public var createdAt: String
    public var status: String
    public var approvalId: String?
    /// Keep only verifiable passages with their source evidence.
    public var supportingPassages: [REMSupportingPassage]?
    /// Count recurrence by source-lived dates, independently of dream dates.
    public var livedDates: [String]?
    /// Label dwelling explicitly so repeated dreams of one occasion cannot appear as independent recurrence.
    public var support: REMSupportKind?
    /// Keep circumstance out of authored GROWTH.
    public var whatChanged: String?
    /// Missing displaced-content evidence means unknown rather than no alternative.
    public var replaced: REMReplacement?

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
        whatChanged: String? = nil,
        replaced: REMReplacement? = nil
    ) {
        self.replaced = replaced
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
        // Folding changes recollection IDs; count canonical exchanges/messages once by stable identity.
        return passages.flatMap(\.sourceRefs).filter {
            $0.hasPrefix("exchange:") || $0.hasPrefix("message:")
        }
    }

    public func supportingExperienceCount(identities: [String: String]) -> Int? {
        supportingExperienceReferences.map { Set($0.compactMap { identities[$0] }).count }
    }

    public var dreamDateCount: Int { Set(evidenceDates).count }
}

/// Inject staging so this module does not depend on ApprovalInbox.
/// Nil is an explicit Trust block; thrown failures retain unstamped proposal identity and remain owed.
/// Nil support count means claim-bound evidence is unavailable.
public typealias REMApprovalStager = @Sendable (REMProposalRow, Int?) async throws -> String?

public enum REMProposalStoreError: Error, LocalizedError, Equatable {
    case notFound(String)
    case storeUnavailable(String)
    /// Restrict proposals to compact GROWTH reflexes; other persona documents remain read-only.
    case unsupportedTarget(String)
    /// Refuse transitions between distinct terminal states.
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

    // Fold terminal rows into a durable base before truncating; keep mutable pending rows in the feed.
    static let compactionThreshold = 512
    /// Retain a recent tail for recency and torn-read margin.
    static let compactionKeepTail = 256

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    public var proposalsURL: URL {
        dataRoot.appendingPathComponent("rem_proposals.jsonl")
    }

    /// Publish the base before truncation; reads union its identities with the feed.
    public var basePath: URL {
        dataRoot.appendingPathComponent("rem_proposals_base.json")
    }

    // MARK: Read

    /// Retain readable display evidence while naming every unreadable part.
    public func loadAllChecked() -> (rows: [REMProposalRow], unreadable: [String]) {
        let read = readChecked()
        return (Self.fold(feedRows: read.feed, baseRows: read.base), read.unreadable)
    }

    public func loadAllStrictly() throws -> [REMProposalRow] {
        let read = try readStrictly()
        return Self.fold(feedRows: read.feed, baseRows: read.base)
    }

    /// Read feed before base because compaction publishes base before truncation.
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

    /// Incomplete evidence grants no write authority; preserve damaged bytes.
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
            // Terminal base decisions outrank pending feed rows; newer terminal feed decisions take precedence.
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

    /// Name refused target documents in append receipts so the caller can identify the rejected authority.
    public struct AppendReceipt: Sendable, Equatable, Codable {
        public let appended: Int
        public let droppedByTarget: [String: Int]
        /// Refuse rather than truncate over-bound passages; carry the reason into the next REM pass.
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

        /// Clean passes stay quiet; dropped rows produce one named receipt.
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

    /// Deduplicate pending appends by canonical proposal ID.
    @discardableResult
    public func appendPending(_ proposals: [REMProposalRow]) async throws -> Int {
        try await appendPendingWithReceipt(proposals).appended
    }

    /// Name every refused target and passage bound.
    @discardableResult
    public func appendPendingWithReceipt(
        _ proposals: [REMProposalRow]
    ) async throws -> AppendReceipt {
        guard !proposals.isEmpty else { return AppendReceipt(appended: 0) }
        return try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            // Finish fallible compaction before committing new proposals.
            let feedRows = try await self.compactIfNeededLocked()
            var seen = Set(feedRows.map(\.id))
            var buffer = Data()
            var appended = 0
            var droppedByTarget: [String: Int] = [:]
            var droppedOverBound: [String: Int] = [:]
            for p in proposals where !seen.contains(p.id) {
                guard Self.supportsProposalTarget(p.targetDoc) else {
                    // Name refused targets so the person can act on the actual boundary.
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

    // MARK: Approval staging

    /// Hold one critical section across scan, stage and stamp so concurrent drivers cannot duplicate approval cards.
    @discardableResult
    public func stagePendingApprovals(_ stage: @escaping REMApprovalStager,
        resolver: ConversationHistory.ExperienceResolver? = nil, limit: Int = .max
    ) async throws -> Int {
        let resolver = resolver ?? ConversationHistory.ExperienceResolver(dataRoot: dataRoot)
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

    /// Clear a cancelled card's stamp so still-pending work can receive a fresh decision rather than remain stranded.
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

    public struct LessonApplication: Sendable {
        public let row: REMProposalRow
        public let growthAppended: Bool
        public let stale: Bool
    }

    /// Use matching completed effects as recovery progress; check eligibility before new effects rather than rejecting already-landed work.
    public func applyApprovedLesson(proposalId: String, expectedProposalText: String,
                                    context: MemoryWriteContext) async throws -> LessonApplication {
        try await SwiftNativePersistenceCore.withFileLock(proposalsURL.appendingPathExtension("application")) {
            guard let row = try self.loadAllStrictly().first(where: { $0.id == proposalId }) else {
                throw REMProposalStoreError.notFound(proposalId)
            }
            guard row.status == "pending" || row.status == "approved" else {
                throw REMProposalStoreError.conflict(id: proposalId, status: row.status)
            }
            guard !expectedProposalText.isEmpty, row.proposalText == expectedProposalText else {
                throw NSError(domain: "REMProposalApprove", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: """
                        The canonical lesson no longer matches the text reviewed on this approval. Review the changed proposal before applying it.
                        """
                ])
            }
            let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: self.dataRoot)
            let growth = try SwiftNativePersonaEngine.readPersonaDocument(at: personaRoot.appendingPathComponent("GROWTH.md"))
            let landed = REMGrowthWriter.containsEntryParagraph(growth, row.proposalText.trimmingCharacters(in: .whitespacesAndNewlines))
            let graduating = (row.support == .standing ? row.supportingPassages ?? [] : []).flatMap { passage in
                passage.sourceRefs.filter { $0.hasPrefix("memory:") }
                    .map { (id: String($0.dropFirst("memory:".count)), quote: passage.quote) }
            }
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: self.dataRoot)
            for item in graduating {
                let memory = try await storage.memory(id: item.id)
                let eligible = memory.map { $0.status == "active" && MemoryLifecycle.isRecallEligible($0.lifecycle) } == true
                let graduated = landed && memory?.lifecycle == MemoryLifecycle.graduated
                guard let memory, memory.content == item.quote, eligible || graduated else {
                    // A landed lesson cannot become stale denial during recovery; later source changes owe owner repair.
                    if landed || row.status == "approved" {
                        throw NSError(domain: "REMProposalApprove", code: 409, userInfo: [
                            NSLocalizedDescriptionKey: """
                                Lesson \(proposalId) has application evidence but source memory \(item.id) no longer matches. Preserve the lesson and repair \
                                its graduation before settling.
                                """
                        ])
                    }
                    let denied = try await self.applyDenial(proposalId: proposalId, reason: "stale", tombstone: false)
                    return LessonApplication(row: denied, growthAppended: false, stale: true)
                }
            }
            guard row.status != "approved" || landed else {
                throw NSError(domain: "REMProposalApprove", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "Approved lesson \(proposalId) is absent from GROWTH; review its canonical document before receipt repair."
                ])
            }
            let appended = try await REMGrowthWriter.appendApprovedLesson(personaRoot: personaRoot, proposalText: row.proposalText)
            for item in graduating {
                try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: self.dataRoot).graduateMemory(
                    id: item.id, reviewedContent: item.quote, context: context)
            }
            let approved = try await self.applyApproval(proposalId: proposalId)
            return LessonApplication(row: approved, growthAppended: appended, stale: false)
        }
    }

    /// Flip under the shared lock before rebuilding pins so the next turn observes approved authority.
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

    /// Persist tombstones before denial so a later failure cannot re-propose refused text.
    /// Stale-card closure skips tombstoning because it does not refuse the lesson.
    @discardableResult
    public func applyDenial(proposalId: String, reason: String, tombstone: Bool = true) async throws -> REMProposalRow {
        guard let current = try loadAllStrictly().first(where: { $0.id == proposalId }) else {
            throw REMProposalStoreError.notFound(proposalId)
        }
        if current.status == "denied" { return current }
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

    /// Make repeated identical decisions idempotent and refuse conflicting terminal transitions.
    private func setStatus(
        proposalId: String,
        to newStatus: String,
        requireSupportedTarget: Bool = false
    ) async throws -> REMProposalRow {
        try await SwiftNativePersistenceCore.withFileLock(proposalsURL) {
            // Base rows are already terminal; permit only matching idempotent decisions without rewriting the feed.
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
                // After creating a terminal row, compact older terminal rows only when the feed crosses its bound.
                try await self.compactIfNeededLocked()
                return row
            }
            throw REMProposalStoreError.notFound(proposalId)
        }
    }

    // MARK: Compaction (snapshot + tail)

    /// The caller must hold the feed lock.
    /// Keep mutable pending rows and a recent tail in the feed; fold only older terminal rows.
    /// Publish base before truncation so interruption and lock-free readers can replay safely.
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

    /// Bound each GROWTH passage to one line of 240 Unicode scalars.
    public static let growthPassageScalarCap = 240

    /// Share one bound sentence between prompts and refusals so policy wording cannot drift.
    public static let growthPassageBoundSentence =
        "one line, under \(growthPassageScalarCap) characters, a reference over a description"

    /// Refuse rather than truncate invalid passages; return the reason to the producing pass.
    public static func growthPassageRefusal(_ text: String) -> String? {
        if text.contains(where: { $0.isNewline }) { return "multi-line" }
        if text.unicodeScalars.count > growthPassageScalarCap {
            return "over \(growthPassageScalarCap) characters"
        }
        return nil
    }

    private static func decodeRow(_ line: Data) -> REMProposalRow? {
        return try? JSONDecoder().decode(REMProposalRow.self, from: line)
    }

    private static func encodeRow(_ row: REMProposalRow) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(row), as: UTF8.self)
    }

    /// Round-trip through Codable so snapshot and tail rows share the canonical encoded shape.
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

/// Preserve first-folded order when reading terminal proposals from the base.
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
