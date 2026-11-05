import ApprovalInbox
import Context
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
import TrustCenter
// Blueprint: | `StudioCanonTending.swift` | `StudioCanonTendingReport`, `StudioCanonTending`: Commit cards independently; retain evidence. |

public struct StudioCanonTendingReport: Sendable, Equatable {
    public var evaluatedWorks: Int
    public var proposalsConsidered: Int
    public var stagedApprovalIDs: [String]
    public var duplicatesSkipped: Int
    public var pendingCapReached: Bool
    public var nextAt: Date?
    public var audit: StudioRelationAuditReport
    public var auditReadFailure: String? = nil
    public var auditPersistenceFailure: String? = nil
    public var stagingFailure: String? = nil
    public var proposalFailures: [String] = []
    public var savedCardGaps: [String] = []

    public var failures: [String] {
        [auditReadFailure, auditPersistenceFailure, stagingFailure].compactMap { $0 }
            + proposalFailures + savedCardGaps
    }
}

public enum StudioCanonTending {
    /// Tending stages proposals only; canon membership, journal entries and graph edges require their deciding owners.
    public static func run(
        turn: Turn?, handsBack: Bool,
        dataRoot: URL,
        inbox: SwiftNativeApprovalInbox? = nil,
        now: Date = Date(),
        deadlineDate: @Sendable (String) -> Date? = { NativeTimestampFormat.parseISO8601FractionalFirst($0) },
        admitEffects: @Sendable () async throws -> Void,
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
        let audit: StudioRelationAuditReport
        var auditReadFailure: String?
        do {
            audit = try await indexer.auditStudioRelations(entries)
            if !audit.graphAvailable { auditReadFailure = "Studio relation audit unavailable: memory graph does not exist." }
        } catch {
            audit = .unavailable
            auditReadFailure = "Studio relation audit read failed: \(error.localizedDescription)"
        }
        var auditPersistenceFailure: String?
        try await admitEffects()
        do {
            try await recordAudit(audit, failure: auditReadFailure, dataRoot: dataRoot, now: now)
        }
        catch { auditPersistenceFailure = """
            Studio relation audit persistence failed at \(auditHealthPath(dataRoot: dataRoot).path): \(error.localizedDescription)
            """ }

        do {
            let recall = try await store.recallPullCounts()
            let evidence = try await indexer.studioCanonEvidence(entries: entries, recallCounts: recall)
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
                    pendingCapReached: false, nextAt: projection.nextAt, audit: audit,
                    auditReadFailure: auditReadFailure, auditPersistenceFailure: auditPersistenceFailure
                )
            }
            let inbox = inbox ?? SwiftNativeApprovalInbox(root: dataRoot)
            var capReached = false
            var staged: [String] = []
            var duplicates = 0
            var stagingFailure: String?
            var proposalFailures: [String] = []
            var savedCardGaps: [String] = []
            for draft in drafts {
                do {
                    try Task.checkCancellation()
                    // Each candidate's fresh listing supplies both capacity and deduplication.
                    let records = try await inbox.list(filter: ApprovalFilter(
                        status: nil, action: StudioCanonProposal.approvalAction
                    ))
                    guard records.filter({ $0.status == "pending" }).count < StudioCanonProposal.pendingProposalCap else {
                        capReached = true
                        break
                    }
                    let alreadyFiled: Bool
                    do {
                        alreadyFiled = try StudioCanonProposal.isAlreadyFiled(
                            draft: draft, records: records, gaps: &savedCardGaps)
                    } catch {
                        proposalFailures.append("Studio canon proposal blocked for \(draft.key): \(error.localizedDescription). This proposal was not staged.")
                        continue
                    }
                    if alreadyFiled {
                        duplicates += 1
                        continue
                    }
                    guard staged.count < StudioCanonLaw.maximumProposalsPerPass else { break }
                    do { try await admitEffects() }
                    catch {
                        stagingFailure = "Canon admission closed before staging \(draft.key); this and remaining proposals were not staged."
                        break
                    }
                    let record = try await StudioCanonProposal.stage(turn: turn, handsBack: handsBack, draft, inbox: inbox)
                    staged.append(record.id)
                } catch {
                    stagingFailure = """
                        Studio canon staging stopped for \(draft.key): \(error.localizedDescription). Inspect existing approvals before repeating; \
                        the failed card's write outcome may be unconfirmed.
                        """
                    break
                }
            }
            return StudioCanonTendingReport(
                evaluatedWorks: evidence.count,
                proposalsConsidered: drafts.count,
                stagedApprovalIDs: staged,
                duplicatesSkipped: duplicates,
                pendingCapReached: capReached,
                nextAt: projection.nextAt,
                audit: audit,
                auditReadFailure: auditReadFailure, auditPersistenceFailure: auditPersistenceFailure,
                stagingFailure: stagingFailure,
                proposalFailures: proposalFailures, savedCardGaps: savedCardGaps
            )
        } catch {
            let failures = [auditReadFailure, auditPersistenceFailure].compactMap { $0 }
            guard !failures.isEmpty else { throw error }
            throw PersistenceCoreError.ioFailure(([error.localizedDescription] + failures).joined(separator: " "))
        }
    }

    /// The receipt links a local report without exposing Doctor content reads. Off-disk backup only; no local backup/export/phone sync; PrivacyMap: studio.
    public static func auditHealthPath(dataRoot: URL) -> URL {
        SwiftNativeStudioStore(dataRoot: dataRoot).studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("relation_audit.json")
    }

    /// Report mismatches through cognition's receipt without repairing or blocking journal and recall work.
    public static func recordAudit(
        _ report: StudioRelationAuditReport,
        failure: String? = nil,
        dataRoot: URL,
        now: Date = Date()
    ) async throws {
        let path = auditHealthPath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var payload: [String: JSONValue] = ["checked_at": .string(NativeTimestampFormat.sixDigitUTCOffset(now))]
        if case .object(let fields) = report.toJSON() {
            for (key, value) in fields { payload[key] = value }
        }
        if let failure { payload["failure"] = .string(failure) }
        if !report.graphAvailable { payload["consistent"] = .null }
        try await SwiftNativePersistenceCore.writeJSON(.object(payload), to: path)
        guard report.graphAvailable else { return }
        guard !report.isConsistent else { return }
        nativeLog(
            "[studio] RELATIONS INCONSISTENT — %d relation(s) on the journal have no graph edge "
                + "citing them back. NOT repaired (a repair would invent a claim the agent never made). "
                + "First: %@",
            report.mismatches.count,
            report.mismatches.first.map { "\($0.entryID) \($0.relationKind) → \($0.toWork) (\($0.reason.rawValue))" }
                ?? "-"
        )
    }
}
