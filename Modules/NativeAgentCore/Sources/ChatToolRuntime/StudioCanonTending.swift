import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonTending.swift` | `StudioCanonTendingReport`, `StudioCanonTending`: native evidence reads and transactional proposal staging retain pending/pass caps; unavailable sources throw; relation audits persist without repair or blocking |

/// One tending pass's evidence and proposals, returned for the caller's receipts.
public struct StudioCanonTendingReport: Sendable, Equatable {
    public var evaluatedWorks: Int
    public var proposalsConsidered: Int
    public var stagedApprovalIDs: [String]
    public var duplicatesSkipped: Int
    public var pendingCapReached: Bool
    public var nextAt: Date?
    /// The relation-provenance guard's verdict from the same pass.
    public var audit: StudioRelationAuditReport
}

public enum StudioCanonTending {
    /// Read journal, graph and pull evidence, project proposals and stage bounded cards.
    /// Tending cannot decide membership or write journal entries or graph edges.
    public static func run(
        dataRoot: URL,
        inbox: SwiftNativeApprovalInbox? = nil,
        now: Date = Date(),
        deadlineDate: @Sendable (String) -> Date? = { NativeTimestampFormat.parseISO8601FractionalFirst($0) },
        decide: @Sendable (JSONValue) async throws -> JSONValue
    ) async throws -> StudioCanonTendingReport {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        // Archived encounters remain part of canon evidence.
        let entries = try await store.journalEntriesIncludingArchive()
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: dataRoot
                .appendingPathComponent("memory/memory.sqlite")
                .standardizedFileURL
        )

        // Audit the evidence edges first; report mismatches without blocking the pass.
        let audit = entries.isEmpty ? .unavailable : (try? await indexer.auditStudioRelations(entries)) ?? .unavailable

        let recall = try await store.recallPullCounts()
        let evidence = try await indexer.studioCanonEvidence(
            entries: entries, recallCounts: recall
        )
        do {
            let membership = try await store.canonMembership()
            try Task.checkCancellation()
            let projection = try await StudioCanonLaw.project(
                evidence: evidence, membership: membership, now: now, deadlineDate: deadlineDate, decide: decide)
            try Task.checkCancellation()
            let drafts = entries.isEmpty ? [] : projection.drafts
            guard !drafts.isEmpty else {
                return StudioCanonTendingReport(
                    evaluatedWorks: evidence.count, proposalsConsidered: 0,
                    stagedApprovalIDs: [], duplicatesSkipped: 0,
                    pendingCapReached: false, nextAt: projection.nextAt, audit: audit
                )
            }
            let inbox = inbox ?? SwiftNativeApprovalInbox(root: dataRoot)
            var capReached = false
            var staged: [String] = []
            var duplicates = 0
            for draft in drafts {
                // Each candidate's fresh listing supplies both capacity and deduplication.
                let records = try await inbox.list(filter: ApprovalFilter(
                    status: nil, action: StudioCanonProposal.approvalAction
                ))
                guard records.filter({ $0.status == "pending" }).count < StudioCanonProposal.pendingProposalCap else {
                    capReached = true
                    break
                }
                if StudioCanonProposal.isAlreadyFiled(draft: draft, records: records) {
                    duplicates += 1
                    continue
                }
                guard staged.count < StudioCanonLaw.maximumProposalsPerPass else { break }
                guard let record = try? await StudioCanonProposal.stage(draft, inbox: inbox) else {
                    continue
                }
                staged.append(record.id)
            }
            return StudioCanonTendingReport(
                evaluatedWorks: evidence.count,
                proposalsConsidered: drafts.count,
                stagedApprovalIDs: staged,
                duplicatesSkipped: duplicates,
                pendingCapReached: capReached,
                nextAt: projection.nextAt,
                audit: audit
            )
        }
    }

    /// Cognition's receipt links this local JSON audit; no Doctor content reader.
    /// Off-disk backup only; no local backup/export/phone sync; PrivacyMap: studio.
    public static func auditHealthPath(dataRoot: URL) -> URL {
        SwiftNativeStudioStore(dataRoot: dataRoot).studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("relation_audit.json")
    }

    /// Persist the report linked by cognition's receipt and log mismatches.
    /// Never repair or block journal/recall work.
    public static func recordAudit(
        _ report: StudioRelationAuditReport,
        dataRoot: URL,
        now: Date = Date()
    ) async {
        guard report.graphAvailable else { return }
        let path = auditHealthPath(dataRoot: dataRoot)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload: [String: JSONValue] = ["checked_at": .string(NativeTimestampFormat.sixDigitUTCOffset(now))]
        if case .object(let fields) = report.toJSON() {
            for (key, value) in fields { payload[key] = value }
        }
        try? await SwiftNativePersistenceCore.writeJSON(.object(payload), to: path)
        guard !report.isConsistent else { return }
        nativeLog(
            "[studio] RELATIONS INCONSISTENT — %d relation(s) on the journal have no graph edge "
                + "citing them back. NOT repaired (a repair would invent a claim she never made). "
                + "First: %@",
            report.mismatches.count,
            report.mismatches.first.map { "\($0.entryID) \($0.relationKind) → \($0.toWork) (\($0.reason.rawValue))" }
                ?? "-"
        )
    }
}
