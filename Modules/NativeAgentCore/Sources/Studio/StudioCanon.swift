import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `StudioCanon.swift` | `Resources/abilities/studio-canon.js`: Append-only canon and repair debt |

// Native storage owns canon identity, membership, evidence and the append-only decision ledger. studio-canon.js owns proposal selection, reasons and silence
// deadlines; proposals never decide membership.

// MARK: - Vocabulary

public enum StudioCanonStanding: String, Sendable, CaseIterable, Equatable {
    /// Cited entries carry the argument for membership.
    case canon
    /// Anti-canon requires an explicit agent decision; a judgment's tone never implies rejection.
    case antiCanon = "anti_canon"
}

public enum StudioCanonAction: String, Sendable, CaseIterable, Equatable {
    case promote, demote
}

/// Retain the argument so each proposal remains explainable.
public enum StudioCanonEvidenceKind: String, Sendable, CaseIterable, Equatable {
    case recurrence
    case pulledInProduction = "pulled_in_production"
    case silence
}

/// Append-only decisions preserve history; later rows supersede earlier rows for the same work.
public struct StudioCanonRow: Sendable, Equatable {
    /// The approval record ties this resolution to the exact card shown.
    public var proposalID: String
    public var action: StudioCanonAction
    public var standing: StudioCanonStanding
    public var workTitle: String
    public var workCreator: String?
    public var decidedAt: String
    /// Only an agent seat may promote or demote.
    public var decidedBy: String
    /// Runtime-derived surface and turn identity prove where the decision occurred; caller assertions cannot establish provenance.
    public var decidedOnSurface: String
    public var decidedInTurn: String
    public var evidenceKind: StudioCanonEvidenceKind
    /// Bound citations because this row is provenance, not a log.
    public var evidenceEntryIDs: [String]
    public var note: String?

    public static let maximumEvidenceEntryIDs = 24

    public init(
        proposalID: String,
        action: StudioCanonAction,
        standing: StudioCanonStanding,
        workTitle: String,
        workCreator: String? = nil,
        decidedAt: String,
        decidedBy: String,
        decidedOnSurface: String,
        decidedInTurn: String,
        evidenceKind: StudioCanonEvidenceKind,
        evidenceEntryIDs: [String] = [],
        note: String? = nil
    ) {
        self.proposalID = proposalID
        self.action = action
        self.standing = standing
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.decidedOnSurface = decidedOnSurface
        self.decidedInTurn = decidedInTurn
        self.evidenceKind = evidenceKind
        self.evidenceEntryIDs = Array(evidenceEntryIDs.prefix(Self.maximumEvidenceEntryIDs))
        self.note = note
    }

    public var workKey: String { StudioCanonLaw.workKey(title: workTitle, creator: workCreator) }

    public func toJSON() -> JSONValue {
        var obj: [String: JSONValue] = [
            "proposal_id": .string(proposalID),
            "action": .string(action.rawValue),
            "standing": .string(standing.rawValue),
            "work": .object({
                var work: [String: JSONValue] = ["title": .string(workTitle)]
                if let workCreator, !workCreator.isEmpty { work["creator"] = .string(workCreator) }
                return work
            }()),
            "decided_at": .string(decidedAt),
            "decided_by": .string(decidedBy),
            "decided_on_surface": .string(decidedOnSurface),
            "decided_in_turn": .string(decidedInTurn),
            "evidence_kind": .string(evidenceKind.rawValue),
            "evidence_entry_ids": .array(evidenceEntryIDs.map { .string($0) }),
        ]
        if let note, !note.isEmpty { obj["note"] = .string(note) }
        return .object(obj)
    }

    public static func fromJSON(_ value: JSONValue) -> StudioCanonRow? {
        guard case .object(let obj) = value,
              case .string(let proposalID)? = obj["proposal_id"],
              case .string(let actionRaw)? = obj["action"],
              let action = StudioCanonAction(rawValue: actionRaw),
              case .string(let standingRaw)? = obj["standing"],
              let standing = StudioCanonStanding(rawValue: standingRaw),
              case .object(let work)? = obj["work"],
              case .string(let title)? = work["title"],
              case .string(let decidedAt)? = obj["decided_at"],
              case .string(let decidedBy)? = obj["decided_by"],
              case .string(let evidenceRaw)? = obj["evidence_kind"],
              let evidenceKind = StudioCanonEvidenceKind(rawValue: evidenceRaw),
              StudioCanonSeat.isAgent(decidedBy) else { return nil }
        do {
            let row = try StudioSavedRow(value)
            _ = try row.string("proposal_id")
            _ = try row.string("decided_at")
            _ = try StudioSavedRow(.object(work)).string("title")
            let entryIDs = try row.strings("evidence_entry_ids", required: true)
            guard entryIDs.count <= maximumEvidenceEntryIDs else { return nil }
            return try StudioCanonRow(
                proposalID: proposalID, action: action, standing: standing,
                workTitle: title, workCreator: StudioSavedRow(.object(work)).optionalString("creator"), decidedAt: decidedAt,
                decidedBy: decidedBy, decidedOnSurface: row.string("decided_on_surface"), decidedInTurn: row.string("decided_in_turn"),
                evidenceKind: evidenceKind, evidenceEntryIDs: entryIDs, note: row.optionalString("note"))
        } catch { return nil }
    }
}

public struct StudioCanonMember: Sendable, Equatable {
    public var workTitle: String
    public var workCreator: String?
    public var standing: StudioCanonStanding
    public var since: String
    public var evidenceEntryIDs: [String]

    public init(
        workTitle: String,
        workCreator: String?,
        standing: StudioCanonStanding,
        since: String,
        evidenceEntryIDs: [String]
    ) {
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.standing = standing
        self.since = since
        self.evidenceEntryIDs = evidenceEntryIDs
    }
}

// MARK: - Evidence in

/// Graph recurrence and actual recall pulls supply evidence; judgment text cannot imply either.
public struct StudioCanonWorkEvidence: Sendable, Equatable {
    public var title: String
    public var creator: String?
    /// Retain later related entry IDs so the proposal can cite its recurrence evidence.
    public var recurrenceEntryIDs: [String]
    /// Live-turn studio_recall pulls that returned this work; evidence, not a preference score.
    public var recallHits: Int
    /// Missing touch evidence never demotes a work.
    public var lastActivityAt: String

    public init(
        title: String,
        creator: String? = nil,
        recurrenceEntryIDs: [String] = [],
        recallHits: Int = 0,
        lastActivityAt: String = ""
    ) {
        self.title = title
        self.creator = creator
        self.recurrenceEntryIDs = recurrenceEntryIDs
        self.recallHits = max(0, recallHits)
        self.lastActivityAt = lastActivityAt
    }

    public var workKey: String { StudioCanonLaw.workKey(title: title, creator: creator) }
}

/// One thing to ASK the agent. Never a decision, and it carries no verdict of its own.
public struct StudioCanonProposalDraft: Sendable, Equatable {
    public var action: StudioCanonAction
    public var workTitle: String
    public var workCreator: String?
    public var evidenceKind: StudioCanonEvidenceKind
    public var evidenceEntryIDs: [String]
    public var recurrenceCount: Int
    public var recallHits: Int
    public var lastActivityAt: String
    public var elapsedSilenceWindows: Int
    public var reasonLine: String

    public init(
        action: StudioCanonAction,
        workTitle: String,
        workCreator: String?,
        evidenceKind: StudioCanonEvidenceKind,
        evidenceEntryIDs: [String],
        recurrenceCount: Int,
        recallHits: Int,
        lastActivityAt: String,
        reasonLine: String,
        elapsedSilenceWindows: Int = 0
    ) {
        self.action = action
        self.workTitle = workTitle
        self.workCreator = workCreator
        self.evidenceKind = evidenceKind
        self.evidenceEntryIDs = Array(evidenceEntryIDs.prefix(StudioCanonRow.maximumEvidenceEntryIDs))
        self.recurrenceCount = recurrenceCount
        self.recallHits = recallHits
        self.lastActivityAt = lastActivityAt
        self.elapsedSilenceWindows = elapsedSilenceWindows
        self.reasonLine = reasonLine
    }

    /// One open card per work and direction prevents duplicate questions.
    public var key: String {
        "\(action.rawValue)|\(StudioCanonLaw.workKey(title: workTitle, creator: workCreator))"
    }

    /// A denial settles its exact evidence, not the subject; new entries, pull counts or silence windows permit a new question.
    public var evidenceFingerprint: String {
        var parts = [key, evidenceKind.rawValue]
        switch evidenceKind {
        case .recurrence, .pulledInProduction:
            parts.append(evidenceEntryIDs.sorted().joined(separator: ","))
            parts.append("recurrences:\(recurrenceCount)")
            parts.append("pulls:\(recallHits)")
        case .silence:
            // A further 90-day silence window is a new argument.
            parts.append("silent_since:\(lastActivityAt)")
            parts.append("windows:\(elapsedSilenceWindows)")
        }
        return parts.joined(separator: "\u{1f}")
    }

}

// MARK: - The law

public enum StudioCanonLaw {
    /// Fixed ledger windows preserve decided argument identities when editable silence policy changes.
    public static let silenceIdentityWindow: TimeInterval = 90 * 24 * 60 * 60
    /// Bound a pass so canon tending cannot flood the inbox.
    public static let maximumProposalsPerPass = 3

    /// Fold title and creator so spelling variants share one identity.
    public static func workKey(title: String, creator: String?) -> String {
        func fold(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
        }
        return fold(title) + "\u{1f}" + fold(creator ?? "")
    }

    /// Later rows supersede membership without erasing earlier decisions.
    public static func membership(from rows: [StudioCanonRow]) -> [String: StudioCanonMember] {
        var result: [String: StudioCanonMember] = [:]
        for row in rows {
            switch row.action {
            case .promote:
                result[row.workKey] = StudioCanonMember(
                    workTitle: row.workTitle,
                    workCreator: row.workCreator,
                    standing: row.standing,
                    since: row.decidedAt,
                    evidenceEntryIDs: row.evidenceEntryIDs
                )
            case .demote:
                result.removeValue(forKey: row.workKey)
            }
        }
        return result
    }

    /// Export neutral facts, then bind the part's references back to those facts. The part supplies no counts, entry ids, membership or identity.
    public static func project(
        evidence: [StudioCanonWorkEvidence],
        membership: [String: StudioCanonMember],
        now: Date,
        deadlineDate: @Sendable (String) -> Date? = { NativeTimestampFormat.parseISO8601FractionalFirst($0) },
        decide: @Sendable (JSONValue) async throws -> JSONValue
    ) async throws -> (drafts: [StudioCanonProposalDraft], nextAt: Date?) {
        let works = Dictionary(evidence.map { ($0.workKey, $0) }, uniquingKeysWith: { first, _ in first })
        let activity = Dictionary(evidence.map { ($0.workKey, $0.lastActivityAt) }, uniquingKeysWith: { max($0, $1) })
        func stamp(_ key: String, _ member: StudioCanonMember) -> String { max(works[key]?.lastActivityAt ?? "", member.since) }
        func seconds(_ stamp: String) -> JSONValue { NativeTimestampFormat.parseISO8601FractionalFirst(stamp).map { .double($0.timeIntervalSince1970) }
            ?? .null }
        func deadlineSeconds(_ stamp: String) -> JSONValue { deadlineDate(stamp).map { .double($0.timeIntervalSince1970) } ?? .null }
        let workFacts: [JSONValue] = evidence.sorted { $0.workKey < $1.workKey }.map { work in
            .object(["key": .string(work.workKey), "title": .string(work.title),
                "creator": work.creator.map(JSONValue.string) ?? .null,
                "recurrence_entry_ids": .array(uniqued(work.recurrenceEntryIDs).map(JSONValue.string)),
                "recurrence_count": .int(Int64(uniqued(work.recurrenceEntryIDs).count)),
                "recall_hits": .int(Int64(work.recallHits)), "last_activity_at": .string(work.lastActivityAt)])
        }
        let memberFacts: [JSONValue] = membership.keys.sorted().compactMap { key in
            membership[key].map { member in
                .object(["key": .string(key), "title": .string(member.workTitle),
                    "creator": member.workCreator.map(JSONValue.string) ?? .null,
                    "evidence_entry_ids": .array(member.evidenceEntryIDs.map(JSONValue.string)),
                    "last_signal": .string(stamp(key, member)), "last_signal_seconds": seconds(stamp(key, member)),
                    "deadline_signal_seconds": deadlineSeconds(max(activity[key] ?? "", member.since))])
            }
        }
        let facts = JSONValue.object(["now": .double(now.timeIntervalSince1970),
            "evidence": .array(workFacts), "members": .array(memberFacts)])
        struct Choice: Decodable { let key: String; let action: String; let evidenceKind: String; let reasonLine: String }
        struct Selection: Decodable { let proposals: [Choice]; let nextAt: Double? }
        let selection = try JSONDecoder().decode(Selection.self, from: try await decide(facts).serializedData(pretty: false))
        var seen = Set<String>()
        let drafts = try selection.proposals.map { choice -> StudioCanonProposalDraft in
            guard seen.insert(choice.action + "|" + choice.key).inserted,
                  !choice.reasonLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersistenceCoreError.ioFailure("Canon returned a duplicate proposal or an empty reason.")
            }
            if choice.action == "promote", let work = works[choice.key], membership[choice.key] == nil,
               let kind = StudioCanonEvidenceKind(rawValue: choice.evidenceKind), kind != .silence {
                let ids = uniqued(work.recurrenceEntryIDs)
                guard kind == .recurrence ? !ids.isEmpty : work.recallHits > 0 else {
                    throw PersistenceCoreError.ioFailure("Canon proposed recurrence or a production pull without a native witness.")
                }
                return StudioCanonProposalDraft(action: .promote, workTitle: work.title, workCreator: work.creator,
                    evidenceKind: kind, evidenceEntryIDs: ids, recurrenceCount: ids.count, recallHits: work.recallHits,
                    lastActivityAt: work.lastActivityAt, reasonLine: choice.reasonLine)
            }
            if choice.action == "demote", choice.evidenceKind == "silence", let member = membership[choice.key],
               let last = NativeTimestampFormat.parseISO8601FractionalFirst(stamp(choice.key, member)) {
                return StudioCanonProposalDraft(action: .demote, workTitle: member.workTitle, workCreator: member.workCreator,
                    evidenceKind: .silence, evidenceEntryIDs: member.evidenceEntryIDs,
                    recurrenceCount: works[choice.key]?.recurrenceEntryIDs.count ?? 0, recallHits: works[choice.key]?.recallHits ?? 0,
                    lastActivityAt: stamp(choice.key, member), reasonLine: choice.reasonLine,
                    elapsedSilenceWindows: Int(max(0, now.timeIntervalSince(last)) / silenceIdentityWindow))
            }
            throw PersistenceCoreError.ioFailure("Canon selected a proposal without matching native evidence or membership.")
        }
        if let next = selection.nextAt, !next.isFinite || next <= now.timeIntervalSince1970 {
            throw PersistenceCoreError.ioFailure("Canon's next deadline must be a finite future instant.")
        }
        return (drafts, selection.nextAt.map(Date.init(timeIntervalSince1970:)))
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Who may decide

/// Only the agent's live tool turn may decide canon membership; the owner cannot approve it.
public enum StudioCanonSeat {
    /// Only an explicit resolve call from the agent's live turn can supply this seat.
    public static let agent = "studio_agent"

    public static func isAgent(_ decidedBy: String?) -> Bool {
        (decidedBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == agent
    }
}

/// Decision surface and identity come from the held live turn, never caller-supplied provenance.
public struct StudioCanonTurnProvenance: Sendable, Equatable {
    public let surface: String
    /// The held turn's run, never model-supplied identity.
    public let turnID: String

    public init(surface: String, turnID: String) {
        self.surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        self.turnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { !surface.isEmpty && !turnID.isEmpty }
}

// MARK: - The ledger

public extension SwiftNativeStudioStore {

    var canonDirectory: URL {
        studioRoot.appendingPathComponent("canon", isDirectory: true)
    }

    /// Append-only decisions preserve superseded membership.
    var canonPath: URL {
        canonDirectory.appendingPathComponent("canon.jsonl")
    }

    /// Bound production-pull evidence independently of journal retention.
    var canonRecallHitsPath: URL {
        canonDirectory.appendingPathComponent("recall_hits.json")
    }

    /// A missing ledger means an empty canon.
    func readCanon() async throws -> [StudioCanonRow] {
        try await Self.readCanon(at: canonPath)
    }

    private static func readCanon(at path: URL) async throws -> [StudioCanonRow] {
        let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
        let decoded = rows.compactMap { StudioCanonRow.fromJSON($0) }
        guard report.malformedLineCount == 0, !report.trailingPartialLine,
              decoded.count == rows.count else {
            throw StudioCanonError.unreadableHistory
        }
        return decoded
    }

    func canonMembership() async throws -> [String: StudioCanonMember] {
        StudioCanonLaw.membership(from: try await readCanon())
    }

    /// Deduplicate by proposal ID across interrupted resolution; enforce agent-only authority at the final disk boundary.
    @discardableResult
    func appendCanonRow(_ row: StudioCanonRow) async throws -> Bool {
        guard StudioCanonSeat.isAgent(row.decidedBy) else {
            throw StudioCanonError.approvalNotFromAgentSeat(row.decidedBy)
        }
        // Require decision provenance here so no caller can bypass the live-turn gate.
        guard StudioCanonTurnProvenance(
            surface: row.decidedOnSurface, turnID: row.decidedInTurn
        ).isComplete else {
            throw StudioCanonError.decisionHasNoLiveTurn
        }
        guard !row.workTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioCanonError.missingWorkTitle
        }
        guard StudioCanonRow.fromJSON(row.toJSON()) != nil else { throw StudioCanonError.unreadableHistory }
        try FileManager.default.createDirectory(
            at: canonDirectory, withIntermediateDirectories: true
        )
        // Proposal-id deduplication and append share one flock, including replayed decisions.
        let path = canonPath
        let payload = row.toJSON()
        let proposalID = row.proposalID
        let label = Self.logLabel
        let appended = try await SwiftNativePersistenceCore.withFileLock(path) { () async throws -> Bool in
            let existing: [StudioCanonRow]
            do { existing = try await Self.readCanon(at: path) }
            catch {
                nativeLog("[StudioCanon] Append deferred: %@", error.localizedDescription)
                throw error
            }
            guard !existing.contains(where: { $0.proposalID == proposalID }) else { return false }
            try await appendPathOwnedJSONL(
                payload,
                to: path,
                logLabel: label,
                durable: true
            )
            return true
        }
        if appended {
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "studio", stableID: "canon", operation: .changed,
                canonicalLocator: path.standardizedFileURL.path,
                reason: "studio_canon_membership_changed"
            ))
        }
        return appended
    }

    // MARK: Production pulls

    /// Count works actually returned by live-turn recall as native evidence for the editable canon policy. Bound to maximumTrackedWorks keys by evicting the
    /// least recently pulled; no preference or decay.
    func noteRecallPulls(
        titles: [(title: String, creator: String?)],
        now: Date = Date(),
        maximumTrackedWorks: Int = 256
    ) async -> JSONValue? {
        guard !titles.isEmpty else { return nil }
        let stamp = NativeTimestampFormat.sixDigitUTCOffset(now)
        let path = canonRecallHitsPath
        var committed = false
        do {
            guard maximumTrackedWorks > 0 else { throw StudioCanonError.unavailableRecallCounts }
            try FileManager.default.createDirectory(at: canonDirectory, withIntermediateDirectories: true)
            try await SwiftNativePersistenceCore.withFileLock(path) {
            let current = try Self.readRecallCounter(at: path)
            let counts = try Self.checkedRecallCounts(current)
            guard case .object(let obj) = current, case .object(var table)? = obj["works"] else {
                throw StudioCanonError.unavailableRecallCounts
            }
            var seen = Set<String>()
            for entry in titles {
                let cleaned = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                let key = StudioCanonLaw.workKey(title: cleaned, creator: entry.creator)
                guard seen.insert(key).inserted else { continue }
                let count = Int64(counts[key]?.count ?? 0) // This key has never been pulled when absent.
                let (next, overflow) = count.addingReportingOverflow(1)
                guard !overflow else { throw StudioCanonError.unavailableRecallCounts }
                let row: [String: JSONValue] = [
                    "count": .int(next),
                    "last_at": .string(stamp),
                ]
                table[key] = .object(row)
            }
            if table.count > maximumTrackedWorks {
                // Bound evidence by evicting the least recently pulled work.
                let updated = try Self.checkedRecallCounts(.object(["works": .object(table)]))
                let keep = Set(updated.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(maximumTrackedWorks).map(\.key))
                table = table.filter { keep.contains($0.key) }
            }
            try await SwiftNativePersistenceCore.writeJSON(
                .object(["works": .object(table)]),
                to: path
            )
            }
            committed = true
            try await requireRecallCountingAvailable()
            return nil
        } catch {
            let words = "Recall returned its entries, but production-pull counting at \(path.path) is unavailable: \(error.localizedDescription). "
                + (committed ? "This pull was counted; earlier counting remains unreconciled. Pull at " : "Unconfirmed pull at ")
                + "\(stamp) for work keys: "
                + titles.map { StudioCanonLaw.workKey(title: $0.title, creator: $0.creator) }.joined(separator: ", ")
            let instruction = ToolFailureError.fileRepairInstruction(path,
                shape: """
                    Reconcile the unconfirmed pull in this repair's evidence against the existing counter before restoring counting; a later successful pull \
                    cannot prove this one was counted. Do not repeat the completed recall.
                    """)
            if !committed {
                let operation = Self.recallCountingOperation
                let debt = ExperienceStore.record(dataRoot, "repair:" + operation) { store in
                    try await RepairOwed.owe(store, id: "studio-recall-count:" + UUID().uuidString,
                        kind: .act, evidence: [.init(source: "studio/canon/recall_hits.json", id: stamp)],
                        operation: operation, owner: path.path, words: words, tap: path.path)
                    if let open = try await RepairOwed.openDebt(store, operation: operation, owner: path.path) {
                        // Repeated failures share one debt, but every pull keeps its exact timestamp, works and cause for reconciliation.
                        try await store.append([.claim(.init(claim: words, evidence: []))], to: open.id)
                    }
                }
                await settle { await debt.value }
            }
            return .object(["status": .string("unavailable"), "reason": .string(words),
                "remedy": Repair.remedy(owner: path.path, nextCall: nil, tap: path.path, instruction: instruction)])
        }
    }

    private static var recallCountingOperation: String { "studio.recall_counting" }

    private func requireRecallCountingAvailable() async throws {
        let experiences = try await ExperienceStore.at(dataRoot).projection()
        if let owed = experiences.first(where: { RepairOwed.isOwed($0)
            && RepairDebt($0).matches(operation: Self.recallCountingOperation, owner: canonRecallHitsPath.path) }) {
            throw StudioCanonError.recallCountingRepairOwed(owed.id)
        }
    }

    func recallPullCounts() async throws -> [String: (count: Int, lastAt: String)] {
        // An existing failed pull is evidence the counter is incomplete, even when its older bytes still decode. Never read that as zero/fewer pulls.
        try await requireRecallCountingAvailable()
        let value = try Self.readRecallCounter(at: canonRecallHitsPath)
        return try Self.checkedRecallCounts(value)
    }

    private static func readRecallCounter(at path: URL) throws -> JSONValue {
        do { return try JSONValue.parse(Data(contentsOf: path)) }
        catch CocoaError.fileReadNoSuchFile { return .object(["works": .object([:])]) }
    }

    private static func checkedRecallCounts(_ value: JSONValue) throws -> [String: (count: Int, lastAt: String)] {
        guard case .object(let obj) = value else { throw StudioCanonError.unavailableRecallCounts }
        guard case .object(let works)? = obj["works"] else { throw StudioCanonError.unavailableRecallCounts }
        var result: [String: (count: Int, lastAt: String)] = [:]
        for (key, row) in works {
            guard case .object(let fields) = row,
                  case .int(let value)? = fields["count"], value >= 0,
                  let count = Int(exactly: value),
                  case .string(let lastAt)? = fields["last_at"], !lastAt.isEmpty else {
                throw StudioCanonError.unavailableRecallCounts
            }
            result[key] = (count, lastAt)
        }
        return result
    }
}

public enum StudioCanonError: Error, LocalizedError, Sendable, Equatable {
    /// The owner cannot decide the agent's canon membership.
    case approvalNotFromAgentSeat(String)
    /// Bridge, approval, replay and background calls cannot assert a live-turn decision.
    case decisionHasNoLiveTurn
    case missingWorkTitle
    case unknownProposal(String)
    case unreadableHistory
    case unavailableRecallCounts
    case recallCountingRepairOwed(String)

    public var errorDescription: String? {
        switch self {
        case .recallCountingRepairOwed(let id):
            return """
                studio canon: production-pull counting has unconfirmed evidence in Experience \(id); reconcile that repair before treating the stored counts \
                as complete. A later successful pull cannot settle it.
                """
        case .unavailableRecallCounts:
            return "studio canon: recall counts are invalid or exhausted; counting is unavailable and stored bytes were preserved."
        case .approvalNotFromAgentSeat(let seat):
            return "studio canon: '\(seat)' is not the agent seat. The canon is the agent's to tend — "
                + "only the agent may promote or demote a work, through studio_canon_resolve. "
                + "Nothing was written."
        case .decisionHasNoLiveTurn:
            return "studio canon: a canon decision has to be made IN a turn — yours, on a local "
                + "surface, live. This call did not come from one (a bridge call, an "
                + "approval replay, or a background pass), so the seat cannot be established "
                + "and nothing was written. Decide it in chat."
        case .unreadableHistory:
            return "studio canon: history is unreadable; retry after it can be read. Nothing was written."
        case .missingWorkTitle:
            return "studio canon: a canon row needs the work's title."
        case .unknownProposal(let id):
            return "studio canon: no pending canon proposal with id '\(id)'."
        }
    }
}
