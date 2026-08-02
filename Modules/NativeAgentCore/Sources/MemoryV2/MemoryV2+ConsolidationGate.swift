// U3 wave-2 item 7 (2026-06-10): NON-DESTRUCTIVE, probe-gated consolidation
// with swap-on-approve (the Dreams pattern).
//
// THE LAW (u3-memory-quality plan): nothing touches the live store without
// an approved card. This file is the enforcement point for the consolidator:
//
//   1. CANDIDATE: a transactionally-consistent copy of the live sqlite
//      (SQLite online-backup via GRDB) lands under
//      <dataRoot>/memory/consolidation/candidates/<runId>/memory/memory.sqlite.
//      The legacy consolidation pipeline (MemoryConsolidator.
//      consolidateDestructively) runs against the CANDIDATE only.
//   2. PROBE GATE: the known-answer probe set (MemoryV2+ProbeSet.swift) is
//      scored against BOTH live and candidate with one shared embedding
//      pass. A candidate that loses even one known answer vs live REFUSES
//      to stage (log + cleanup) — a regression is never proposed.
//   3. CARD: an approval (action `memory.consolidation.swap`) + an inbox
//      card carry both scores and the rows-merged/dropped diff summary.
//      Mirrors the wave-1 `memory.repair` staging shape (idempotent:
//      pending-scan before create; card append under the inbox flock).
//   4. SWAP-ON-APPROVE: applying replaces the live store's memory tables
//      with the candidate's inside ONE immediate SQLite transaction
//      (ATTACH + DELETE/INSERT) — atomic and crash-safe by SQLite's
//      journal. use_count/last_used_at access signals that accrued after
//      staging are carried over (MAX of live/candidate), and the
//      fingerprint deliberately excludes them so recalls never stale a
//      staged card. The live store is backed up (online-backup API) before
//      the swap. After commit, USER.md, Spotlight, MemoryV2-owned KG rows,
//      and Fluid Context are rebuilt from canonical memory. A projection
//      failure leaves the candidate/manifest and no terminal receipt, so
//      crash-window reconcile retries until every projection converges.
//   5. CRASH WINDOW: every stage leaves a manifest next to the candidate;
//      reconcile (run at the START of every gated consolidation, and
//      callable at app launch) re-drives approved-but-unexecuted swaps,
//      detects already-applied swaps by fingerprint, cleans up denied/
//      canceled candidates, and sweeps orphaned candidate dirs.
//
// STALENESS: the manifest pins the live fingerprint at stage time. If live
// drifted by the time the card is approved (new/edited rows), the swap
// REFUSES (receipt `stale_refused`) — post-stage writes are never clobbered.
// The next consolidation run stages a fresh candidate.
//
// SECURITY: applySwap NEVER trusts its caller-supplied record. It re-reads
// the approval from the inbox by id and refuses unless status == resolved,
// decision == approved, action == memory.consolidation.swap, and the
// payload's kind + run_id match the run being applied — a forged in-process
// ApprovalRecord cannot drive the executor past the human gate.
//
// SERIALIZATION: every public entry point (run / reconcile) takes ONE
// cross-process flock (<dataRoot>/memory/consolidation/gate.lock — the
// PersistenceCore+FileLock convention) around its whole critical section,
// so two concurrent consolidateGated() calls cannot both stage, and two
// reconcile passes (launch + resolveApproval, or another process / test
// runner) cannot double-apply the same run. The *Locked internals never
// re-acquire (same-process flock re-acquisition on a fresh fd deadlocks).

import CryptoKit
import Foundation
import GRDB
import ApprovalInbox
import KnowledgeGraph
import NativeAgentCore
import OSLog
import PersistenceCore

// MARK: - Outcome shapes

/// Rows merged/dropped summary carried on the card and the receipt.
public struct MemoryConsolidationDiff: Sendable, Equatable {
    public let memoriesActiveBefore: Int
    public let memoriesActiveAfter: Int
    public let proposalsPendingBefore: Int
    public let proposalsPendingAfter: Int
    public let accepted: Int
    public let merged: Int
    public let archived: Int

    public init(
        memoriesActiveBefore: Int, memoriesActiveAfter: Int,
        proposalsPendingBefore: Int, proposalsPendingAfter: Int,
        accepted: Int, merged: Int, archived: Int
    ) {
        self.memoriesActiveBefore = memoriesActiveBefore
        self.memoriesActiveAfter = memoriesActiveAfter
        self.proposalsPendingBefore = proposalsPendingBefore
        self.proposalsPendingAfter = proposalsPendingAfter
        self.accepted = accepted
        self.merged = merged
        self.archived = archived
    }

    public var summary: String {
        "memories \(memoriesActiveBefore)→\(memoriesActiveAfter) active; "
            + "proposals pending \(proposalsPendingBefore)→\(proposalsPendingAfter); "
            + "\(accepted) accepted, \(merged) merged, \(archived) archived"
    }
}

public enum GatedConsolidationOutcome: Sendable {
    /// A pending swap card already exists — nothing new staged.
    case alreadyStaged(approvalId: String)
    /// Consolidation found nothing to change; no card staged.
    case noChanges(plan: ConsolidationReport)
    /// Candidate scored below live on the probe set — refused to stage.
    case refusedRegression(scores: MemoryProbeComparison, plan: ConsolidationReport)
    /// Candidate staged for approval; live store untouched.
    case staged(
        approvalId: String,
        scores: MemoryProbeComparison,
        diff: MemoryConsolidationDiff,
        plan: ConsolidationReport
    )
}

public enum MemoryConsolidationSwapOutcome: Sendable, Equatable {
    case applied(runId: String, backupPath: String)
    case alreadyApplied(runId: String)
    case staleRefused(runId: String)
    case cleanedUpDenied(runId: String)
    case pendingApproval(runId: String)
    case failed(runId: String, reason: String)
}

struct MemoryConsolidationProjectionEnvironment: Sendable {
    let personaRoot: URL
    let spotlightClient: any SpotlightIndexClient
    let publishInvalidation: @Sendable (DerivedSourceChange) async -> Void

    static func live(dataRoot: URL) -> Self {
        let client: any SpotlightIndexClient
        if dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL {
            #if canImport(CoreSpotlight) && !os(Linux)
            client = SystemSpotlightIndexClient()
            #else
            client = MockSpotlightIndexClient()
            #endif
        } else {
            // Alternate/test roots must never erase or populate the user's
            // system Spotlight index.
            client = MockSpotlightIndexClient()
        }
        return Self(
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot),
            spotlightClient: client,
            publishInvalidation: { change in
                await DerivedStateInvalidationCenter.shared.publish(change)
                await DerivedStateInvalidationCenter.shared.flush()
            }
        )
    }
}

private struct MemoryProjectionReconciliationSummary: Sendable {
    let userMDPath: String
    let spotlightRecords: Int
    let knowledgeGraph: KnowledgeGraphMemoryRebuildReport
    let invalidationPublished: Bool

    var json: JSONValue {
        .object([
            "user_md_path": .string(userMDPath),
            "spotlight_records": .int(Int64(spotlightRecords)),
            "fluid_context_invalidation": .bool(invalidationPublished),
            "knowledge_graph": .object([
                "facts_indexed": .int(Int64(knowledgeGraph.factsIndexed)),
                "entities_removed": .int(Int64(knowledgeGraph.entitiesRemoved)),
                "relationships_removed": .int(Int64(knowledgeGraph.relationshipsRemoved)),
                "index_rows_removed": .int(Int64(knowledgeGraph.indexRowsRemoved)),
            ]),
        ])
    }

    var detail: String {
        "memory projections reconciled: USER.md regenerated, \(spotlightRecords) Spotlight records rebuilt, "
            + "KG rebuilt from \(knowledgeGraph.factsIndexed) canonical facts, Fluid Context invalidated"
    }
}

public enum MemoryConsolidationGateError: Error, CustomStringConvertible {
    case probeGateUnavailable(String)
    case candidateBuildFailed(String)
    case stagingFailed(String)
    case reconcileFailed(String)

    public var description: String {
        switch self {
        case .probeGateUnavailable(let why):
            return "probe gate unavailable — consolidation refused (fail closed): \(why)"
        case .candidateBuildFailed(let why):
            return "candidate store build failed: \(why)"
        case .stagingFailed(let why):
            return "approval staging failed (live store untouched): \(why)"
        case .reconcileFailed(let why):
            return "pre-stage reconcile failed — staging refused (fail closed): \(why)"
        }
    }
}

// MARK: - Gate

public enum MemoryConsolidationGate {

    public static let approvalAction = "memory.consolidation.swap"
    static let payloadKind = "memory.consolidation.swap"
    static let manifestSchema = 1
    static let defaultOrphanAge: TimeInterval = 24 * 60 * 60

    private static let logger = Logger(
        subsystem: "com.nativeagent.app", category: "memory-consolidation-gate")

    // MARK: paths

    static func consolidationDir(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("consolidation", isDirectory: true)
    }

    static func candidatesDir(dataRoot: URL) -> URL {
        consolidationDir(dataRoot: dataRoot)
            .appendingPathComponent("candidates", isDirectory: true)
    }

    static func candidateRoot(dataRoot: URL, runId: String) -> URL {
        candidatesDir(dataRoot: dataRoot).appendingPathComponent(runId, isDirectory: true)
    }

    /// The candidate is a full MemoryStorage data root so the storage actor
    /// opens it with its own public init: <candidateRoot>/memory/memory.sqlite.
    static func candidateDBPath(dataRoot: URL, runId: String) -> URL {
        candidateRoot(dataRoot: dataRoot, runId: runId)
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
    }

    static func manifestPath(dataRoot: URL, runId: String) -> URL {
        candidateRoot(dataRoot: dataRoot, runId: runId).appendingPathComponent("manifest.json")
    }

    static func receiptsDir(dataRoot: URL) -> URL {
        consolidationDir(dataRoot: dataRoot).appendingPathComponent("receipts", isDirectory: true)
    }

    static func receiptPath(dataRoot: URL, runId: String) -> URL {
        receiptsDir(dataRoot: dataRoot).appendingPathComponent("\(runId).json")
    }

    /// Derive the data root from a MemoryStorage's sqlite path. The public
    /// init pins <root>/memory/memory.sqlite, so a parent dir named
    /// "memory" means root is one level above it. The in-memory test init
    /// puts the sqlite in a unique temp dir — treat THAT dir as the root so
    /// gate side-files stay self-contained.
    static func deriveDataRoot(storagePath: URL) -> URL {
        let parent = storagePath.deletingLastPathComponent()
        if parent.lastPathComponent == "memory" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    // MARK: - Gate lock (cross-process critical section)

    /// Sentinel path for the gate-wide flock. withFileLock locks
    /// "<path>.lock", so the actual lock file is
    /// <dataRoot>/memory/consolidation/gate.lock.
    static func gateLockTarget(dataRoot: URL) -> URL {
        consolidationDir(dataRoot: dataRoot).appendingPathComponent("gate")
    }

    /// SERIALIZATION CHOICE (review finding 4, 2026-06-10): the repo's
    /// cross-process flock convention (PersistenceCore+FileLock.swift), not
    /// a module-level actor. flock serializes BOTH concurrent tasks in this
    /// process (each acquisition opens its own fd; BSD flock treats fds
    /// independently, so the second acquisition waits) AND other processes
    /// (launch-reconcile vs resolveApproval-reconcile vs the test runner).
    /// Acquired ONCE per public entry point; the *Locked internals never
    /// re-acquire — same-process re-acquisition on a fresh fd would
    /// deadlock against ourselves.
    static func withGateLock<T: Sendable>(
        dataRoot: URL, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await SwiftNativePersistenceCore()
            .withFileLock(gateLockTarget(dataRoot: dataRoot), body)
    }

    // MARK: - Gated run (the only consolidation entry point)

    /// Full pipeline: reconcile prior approvals → snapshot → candidate →
    /// destructive run on candidate → diff → probe gate → stage card.
    /// NEVER mutates the live store. The whole pipeline holds the gate
    /// flock: pending-scan + approval-create are one critical section, so
    /// two concurrent calls cannot both stage (review finding 4).
    public static func run(
        liveStorage: MemoryStorage,
        dataRoot: URL,
        embedder: (any EmbeddingProvider)?,
        probeSet: MemoryProbeSet?,
        now: @escaping @Sendable () -> Date
    ) async throws -> GatedConsolidationOutcome {
        try await withGateLock(dataRoot: dataRoot) {
            try await runLocked(
                liveStorage: liveStorage, dataRoot: dataRoot,
                embedder: embedder, probeSet: probeSet, now: now
            )
        }
    }

    /// Caller MUST hold the gate lock.
    private static func runLocked(
        liveStorage: MemoryStorage,
        dataRoot: URL,
        embedder: (any EmbeddingProvider)?,
        probeSet: MemoryProbeSet?,
        now: @escaping @Sendable () -> Date
    ) async throws -> GatedConsolidationOutcome {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)

        // 0) Self-heal first — and FAIL CLOSED (review finding 6): if the
        //    approval scan cannot conclusively account for approved-but-
        //    unexecuted swaps, fresh staging must not proceed on top of an
        //    unknown swap state. That includes TRANSIENT apply failures
        //    (gpt-5.5 delta re-review, 2026-06-10): a `.failed` outcome means
        //    an approved swap is still OWED — staging a new candidate on top
        //    of it would fork the approval state, so abort; the next run
        //    retries the owed swap first.
        do {
            let outcomes = try await reconcileLocked(dataRoot: dataRoot, orphanAge: defaultOrphanAge)
            let owed = outcomes.compactMap { outcome -> String? in
                if case .failed(let runId, let reason) = outcome { return "\(runId) (\(reason))" }
                return nil
            }
            guard owed.isEmpty else {
                logger.error("consolidation gate: approved swap(s) still unexecuted after reconcile — staging aborted: \(owed.joined(separator: "; "), privacy: .public)")
                throw MemoryConsolidationGateError.reconcileFailed(
                    "approved swap(s) still unexecuted after reconcile: \(owed.joined(separator: "; "))")
            }
        } catch let err as MemoryConsolidationGateError {
            throw err
        } catch {
            logger.error("consolidation gate: pre-stage reconcile failed — staging aborted: \(String(describing: error), privacy: .public)")
            throw MemoryConsolidationGateError.reconcileFailed("\(error)")
        }

        // 1) Idempotence: one pending swap card at a time. Fail closed on a
        //    scan error (we can't know → we don't stage).
        let pending: [ApprovalRecord]
        do {
            pending = try await inbox.list(
                filter: ApprovalFilter(status: "pending", action: approvalAction))
        } catch {
            throw MemoryConsolidationGateError.stagingFailed(
                "pending-approval scan failed: \(error)")
        }
        if let existing = pending.first(where: { Self.payloadKind(of: $0.payload) == payloadKind }) {
            logger.info("consolidation gate: pending card \(existing.id, privacy: .public) exists — not staging")
            return .alreadyStaged(approvalId: existing.id)
        }

        // 2) Snapshot the live fingerprint, then build the candidate.
        let livePath = liveStorage.path
        let liveFingerprint = try fingerprint(ofDatabaseAt: livePath)
        let runId = Self.makeRunId(now: now())
        let candidateDB = candidateDBPath(dataRoot: dataRoot, runId: runId)
        do {
            try FileManager.default.createDirectory(
                at: candidateDB.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.onlineBackup(from: livePath, to: candidateDB)
        } catch {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            throw MemoryConsolidationGateError.candidateBuildFailed("\(error)")
        }

        // 3) Destructive consolidation — against the CANDIDATE only.
        let candidateRootURL = candidateRoot(dataRoot: dataRoot, runId: runId)
        let plan: ConsolidationReport
        let candidateStorage: MemoryStorage
        do {
            candidateStorage = try MemoryStorage(dataRoot: candidateRootURL)
            plan = try await MemoryConsolidator(storage: candidateStorage, now: now)
                .consolidateDestructively()
        } catch {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            throw error
        }

        // 4) Anything actually change?
        let candidateFingerprint = try fingerprint(ofDatabaseAt: candidateDB)
        if candidateFingerprint == liveFingerprint {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            logger.info("consolidation gate: no changes — nothing to stage")
            return .noChanges(plan: plan)
        }

        // 5) Probe gate — fail closed on every error path.
        let effectiveProbes = probeSet ?? MemoryProbeSet.load(dataRoot: dataRoot)
        guard !effectiveProbes.probes.isEmpty else {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            throw MemoryConsolidationGateError.probeGateUnavailable("empty probe set")
        }
        let effectiveEmbedder: any EmbeddingProvider =
            embedder ?? ManagedEmbeddingProvider(dataRoot: dataRoot)
        let scores: MemoryProbeComparison
        do {
            scores = try await MemoryProbeRunner.compare(
                probeSet: effectiveProbes,
                live: liveStorage,
                candidate: candidateStorage,
                embedder: effectiveEmbedder
            )
        } catch {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            throw MemoryConsolidationGateError.probeGateUnavailable("\(error)")
        }
        let diff = try computeDiff(livePath: livePath, candidatePath: candidateDB, plan: plan)
        guard scores.candidateIsAtLeastLive else {
            logger.error(
                "consolidation gate: REFUSED — candidate lost probes [\(scores.lostProbeIds.joined(separator: ", "), privacy: .public)] (live \(scores.live.summary, privacy: .public), candidate \(scores.candidate.summary, privacy: .public)); candidate discarded"
            )
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            return .refusedRegression(scores: scores, plan: plan)
        }

        // 6) Manifest BEFORE the approval (a candidate without a card is a
        //    sweepable orphan; a card without a manifest would dead-end an
        //    approval). Then card; card failure → cleanup, nothing staged.
        do {
            try writeManifest(
                dataRoot: dataRoot, runId: runId,
                liveFingerprint: liveFingerprint,
                candidateFingerprint: candidateFingerprint,
                scores: scores, diff: diff, stagedAt: now()
            )
            let approvalId = try await stageApproval(
                inbox: inbox, dataRoot: dataRoot, runId: runId,
                scores: scores, diff: diff
            )
            logger.info("consolidation gate: staged swap card \(approvalId, privacy: .public) run \(runId, privacy: .public)")
            return .staged(approvalId: approvalId, scores: scores, diff: diff, plan: plan)
        } catch {
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            throw MemoryConsolidationGateError.stagingFailed("\(error)")
        }
    }

    // MARK: - Reconcile (launch + pre-stage self-heal)

    /// Drive every non-pending swap approval to a terminal state:
    ///   approved + candidate present  → apply (or stale-refuse) + cleanup
    ///   approved + already applied    → cleanup
    ///   denied/canceled               → cleanup
    ///   pending                       → leave alone
    /// Also sweeps candidate dirs older than `orphanAge` that no approval
    /// references (stage crashed between manifest and card).
    @discardableResult
    public static func reconcile(
        dataRoot: URL,
        orphanAge: TimeInterval = 24 * 60 * 60
    ) async -> [MemoryConsolidationSwapOutcome] {
        await reconcile(
            dataRoot: dataRoot,
            orphanAge: orphanAge,
            projectionEnvironment: nil
        )
    }

    static func reconcile(
        dataRoot: URL,
        orphanAge: TimeInterval = 24 * 60 * 60,
        projectionEnvironment: MemoryConsolidationProjectionEnvironment?
    ) async -> [MemoryConsolidationSwapOutcome] {
        // Launch / resolveApproval callers stay best-effort (non-throwing);
        // only consolidateGated() needs the throwing shape to fail closed.
        do {
            return try await withGateLock(dataRoot: dataRoot) {
                try await reconcileLocked(
                    dataRoot: dataRoot,
                    orphanAge: orphanAge,
                    projectionEnvironment: projectionEnvironment
                )
            }
        } catch {
            logger.error("consolidation reconcile: failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Caller MUST hold the gate lock. Throws ONLY when the approval scan
    /// fails (no conclusive picture of approved/unexecuted swaps); every
    /// per-record problem is handled inline as a terminal outcome.
    static func reconcileLocked(
        dataRoot: URL,
        orphanAge: TimeInterval,
        projectionEnvironment: MemoryConsolidationProjectionEnvironment? = nil
    ) async throws -> [MemoryConsolidationSwapOutcome] {
        var outcomes: [MemoryConsolidationSwapOutcome] = []
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let records: [ApprovalRecord]
        do {
            records = try await inbox.list(filter: ApprovalFilter(status: nil, action: approvalAction))
        } catch {
            logger.error("consolidation reconcile: approval scan failed: \(String(describing: error), privacy: .public)")
            throw MemoryConsolidationGateError.reconcileFailed("approval scan failed: \(error)")
        }
        var referencedRunIds = Set<String>()
        for record in records {
            guard Self.payloadKind(of: record.payload) == payloadKind,
                  let runId = Self.runId(of: record.payload) else { continue }
            referencedRunIds.insert(runId)
            // A receipt means this run is terminal. CRASH-WINDOW REPAIR
            // (gpt-5.5 delta re-review, 2026-06-10): terminal paths write
            // the receipt before the annotation, so a crash between the two
            // leaves a resolved approval with no executedAction that this
            // short-circuit would otherwise skip forever. Re-annotate from
            // the receipt's contents when the annotation is missing.
            if FileManager.default.fileExists(atPath: receiptPath(dataRoot: dataRoot, runId: runId).path) {
                if record.status == "resolved", record.executedAction == nil,
                   let receipt = readReceipt(dataRoot: dataRoot, runId: runId) {
                    await annotateApproval(
                        dataRoot: dataRoot, id: record.id,
                        executedAction: .object([
                            "op": .string("memory_consolidation_swap"),
                            "status": .string(receipt.status),
                            "run_id": .string(runId),
                            "backup_path": receipt.backupPath.map { .string($0) } ?? .null,
                            "repaired_from_receipt": .bool(true),
                        ]),
                        detail: "consolidation swap \(receipt.status) — annotation repaired "
                            + "from receipt by reconcile (crash window between receipt and "
                            + "annotation)" + (receipt.reason.map { "; reason: \($0)" } ?? ""))
                }
                cleanupCandidate(dataRoot: dataRoot, runId: runId)
                continue
            }
            let candidateExists = FileManager.default.fileExists(
                atPath: candidateDBPath(dataRoot: dataRoot, runId: runId).path)
            switch (record.status, record.decision) {
            case ("pending", _):
                outcomes.append(.pendingApproval(runId: runId))
            case (_, .some("approved")):
                guard candidateExists else {
                    // Approved but the candidate is gone and no receipt —
                    // unrecoverable; write a terminal failure receipt so we
                    // never loop on it.
                    writeReceipt(dataRoot: dataRoot, runId: runId, status: "failed",
                                 approvalId: record.id, backupPath: nil,
                                 reason: "candidate store missing at apply time")
                    await annotateApproval(
                        dataRoot: dataRoot, id: record.id,
                        executedAction: .object([
                            "op": .string("memory_consolidation_swap"),
                            "status": .string("failed"),
                            "run_id": .string(runId),
                            "error": .string("candidate store missing at apply time"),
                        ]),
                        detail: "consolidation swap FAILED: the approved candidate store is "
                            + "missing — nothing was applied; re-run consolidation to stage a fresh card")
                    outcomes.append(.failed(runId: runId, reason: "candidate store missing"))
                    continue
                }
                let outcome = await applySwap(
                    dataRoot: dataRoot,
                    runId: runId,
                    approval: record,
                    projectionEnvironment: projectionEnvironment
                )
                outcomes.append(outcome)
            default:
                // denied / canceled / orphaned → discard the candidate.
                let label = record.decision ?? record.status
                if candidateExists {
                    cleanupCandidate(dataRoot: dataRoot, runId: runId)
                    logger.info("consolidation reconcile: cleaned up candidate \(runId, privacy: .public) (decision \(label, privacy: .public))")
                }
                // Terminal receipt + annotation: a denied/canceled card must
                // never read as silently swallowed, and the next reconcile
                // short-circuits on the receipt instead of re-annotating.
                writeReceipt(dataRoot: dataRoot, runId: runId,
                             status: "\(label)_cleanup",
                             approvalId: record.id, backupPath: nil,
                             reason: "decision \(label) — candidate discarded")
                await annotateApproval(
                    dataRoot: dataRoot, id: record.id,
                    executedAction: .object([
                        "op": .string("memory_consolidation_swap"),
                        "status": .string("\(label)_cleanup"),
                        "run_id": .string(runId),
                    ]),
                    detail: "consolidation swap \(label) — candidate discarded; "
                        + "live memories untouched")
                outcomes.append(.cleanedUpDenied(runId: runId))
            }
        }
        sweepOrphans(dataRoot: dataRoot, referenced: referencedRunIds, olderThan: orphanAge)
        return outcomes
    }

    // MARK: - Swap (apply-on-approve)

    /// Replace the live store's memories/proposals/tombstones with the
    /// candidate's in ONE immediate transaction.
    ///
    /// SECURITY (review finding 1): the caller-supplied record is used for
    /// its id ONLY. The record is re-read from the inbox and must be
    /// resolved + approved + the right action + a payload naming THIS run —
    /// a forged in-process ApprovalRecord cannot mutate live.
    ///
    /// INTERNAL on purpose (review finding 1): the only production caller
    /// is reconcileLocked, under the gate lock. Tests reach it via
    /// @testable.
    static func applySwap(
        dataRoot: URL,
        runId: String,
        approval: ApprovalRecord,
        projectionEnvironment: MemoryConsolidationProjectionEnvironment? = nil
    ) async -> MemoryConsolidationSwapOutcome {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let verified: ApprovalRecord
        var swapCommitted = false
        do {
            verified = try await inbox.get(approval.id)
        } catch {
            // No receipt / annotation: nothing about the RUN is terminal —
            // we simply could not read the queue. Reconcile retries.
            return .failed(runId: runId,
                           reason: "approval \(approval.id) could not be re-read from the inbox: \(error)")
        }
        guard verified.status == "resolved",
              verified.decision == "approved",
              verified.action == approvalAction,
              Self.payloadKind(of: verified.payload) == payloadKind,
              Self.runId(of: verified.payload) == runId
        else {
            // No annotation here either — the REAL record may still be
            // pending; stamping executedAction on it would corrupt a live
            // card. Refusal is the whole point.
            logger.error("consolidation swap \(runId, privacy: .public): REFUSED — approval \(approval.id, privacy: .public) failed re-verification (status \(verified.status, privacy: .public), decision \(verified.decision ?? "nil", privacy: .public), action \(verified.action, privacy: .public))")
            return .failed(runId: runId,
                           reason: "approval \(approval.id) failed re-verification against the inbox "
                               + "(status \(verified.status), decision \(verified.decision ?? "nil"), "
                               + "action \(verified.action)) — refusing to swap")
        }
        let manifest: SwapManifest
        do {
            manifest = try readManifest(dataRoot: dataRoot, runId: runId)
        } catch {
            writeReceipt(dataRoot: dataRoot, runId: runId, status: "failed",
                         approvalId: verified.id, backupPath: nil,
                         reason: "manifest unreadable: \(error)")
            await annotateApproval(
                dataRoot: dataRoot, id: verified.id,
                executedAction: .object([
                    "op": .string("memory_consolidation_swap"),
                    "status": .string("failed"),
                    "run_id": .string(runId),
                    "error": .string("manifest unreadable: \(error)"),
                ]),
                detail: "consolidation swap FAILED: staging manifest unreadable — nothing applied")
            return .failed(runId: runId, reason: "manifest unreadable: \(error)")
        }
        let livePath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let candidatePath = candidateDBPath(dataRoot: dataRoot, runId: runId)
        do {
            // Integrity: the candidate on disk must be the one that was scored.
            let candidateFP = try fingerprint(ofDatabaseAt: candidatePath)
            guard candidateFP == manifest.candidateFingerprint else {
                writeReceipt(dataRoot: dataRoot, runId: runId, status: "failed",
                             approvalId: verified.id, backupPath: nil,
                             reason: "candidate fingerprint drifted since staging")
                await annotateApproval(
                    dataRoot: dataRoot, id: verified.id,
                    executedAction: .object([
                        "op": .string("memory_consolidation_swap"),
                        "status": .string("failed"),
                        "run_id": .string(runId),
                        "error": .string("candidate fingerprint drifted since staging"),
                    ]),
                    detail: "consolidation swap FAILED: the candidate on disk is not the one that "
                        + "was scored — candidate discarded, nothing applied")
                cleanupCandidate(dataRoot: dataRoot, runId: runId)
                return .failed(runId: runId, reason: "candidate fingerprint drifted since staging")
            }
            let liveFP = try fingerprint(ofDatabaseAt: livePath)
            // Crash-after-commit window: swap already landed.
            if liveFP == manifest.candidateFingerprint {
                swapCommitted = true
                let projections = try await reconcileDerivedProjections(
                    dataRoot: dataRoot,
                    livePath: livePath,
                    runId: runId,
                    environment: projectionEnvironment ?? .live(dataRoot: dataRoot)
                )
                writeReceipt(dataRoot: dataRoot, runId: runId, status: "applied_prior",
                             approvalId: verified.id, backupPath: nil, reason: nil)
                await annotateApproval(
                    dataRoot: dataRoot, id: verified.id,
                    executedAction: .object([
                        "op": .string("memory_consolidation_swap"),
                        "status": .string("applied_prior"),
                        "run_id": .string(runId),
                        "memory_projections": projections.json,
                    ]),
                    detail: "consolidation swap had already landed (crash-window reconcile) — "
                        + "candidate cleaned up, store left as applied; \(projections.detail)")
                cleanupCandidate(dataRoot: dataRoot, runId: runId)
                logger.info("consolidation swap \(runId, privacy: .public): already applied (crash-window reconcile)")
                return .alreadyApplied(runId: runId)
            }
            // Fast-path staleness: live drifted since staging → never
            // clobber. (Cheap early exit; the AUTHORITATIVE check re-runs
            // inside the swap transaction below — review finding 2.)
            guard liveFP == manifest.liveFingerprint else {
                return await refuseStale(dataRoot: dataRoot, runId: runId, approvalId: verified.id)
            }
            // Backup, then the atomic table swap. The swap re-checks the
            // live fingerprint INSIDE its immediate transaction and throws
            // SwapStaleError if a write slipped in after the check above.
            let backupPath = try backupLiveStore(livePath: livePath, dataRoot: dataRoot)
            do {
                let boundEvictions = try transactionalTableSwap(
                    livePath: livePath, candidatePath: candidatePath,
                    expectedLiveFingerprint: manifest.liveFingerprint)
                await MemoryStorage.recordBoundEvictions(
                    boundEvictions,
                    memoryPath: livePath,
                    reason: "approved_consolidation_swap"
                )
            } catch is SwapStaleError {
                return await refuseStale(dataRoot: dataRoot, runId: runId, approvalId: verified.id)
            }
            swapCommitted = true
            let projections = try await reconcileDerivedProjections(
                dataRoot: dataRoot,
                livePath: livePath,
                runId: runId,
                environment: projectionEnvironment ?? .live(dataRoot: dataRoot)
            )
            writeReceipt(dataRoot: dataRoot, runId: runId, status: "applied",
                         approvalId: verified.id, backupPath: backupPath, reason: nil)
            await annotateApproval(
                dataRoot: dataRoot, id: verified.id,
                executedAction: .object([
                    "op": .string("memory_consolidation_swap"),
                    "status": .string("applied"),
                    "run_id": .string(runId),
                    "backup_path": .string(backupPath),
                    "memory_projections": projections.json,
                ]),
                detail: "consolidation swap applied — live store replaced by the approved "
                    + "candidate; pre-swap backup at \(backupPath); \(projections.detail)")
            cleanupCandidate(dataRoot: dataRoot, runId: runId)
            logger.info("consolidation swap \(runId, privacy: .public): APPLIED (backup at \(backupPath, privacy: .public))")
            return .applied(runId: runId, backupPath: backupPath)
        } catch {
            // No receipt on a transient failure — reconcile retries next
            // run. Annotate anyway so the card never reads as silently
            // executed; a later successful retry overwrites this.
            logger.error("consolidation swap \(runId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await annotateApproval(
                dataRoot: dataRoot, id: verified.id,
                executedAction: .object([
                    "op": .string("memory_consolidation_swap"),
                    "status": .string("failed"),
                    "run_id": .string(runId),
                    "error": .string("\(error)"),
                ]),
                detail: swapCommitted
                    ? "consolidation swap COMMITTED but derived projection reconciliation FAILED: \(error) — candidate retained and reconcile retries USER.md/Spotlight/KG/Fluid Context on the next pass"
                    : "consolidation swap FAILED (transient): \(error) — nothing applied; reconcile retries on the next pass")
            return .failed(runId: runId, reason: "\(error)")
        }
    }

    private static func reconcileDerivedProjections(
        dataRoot: URL,
        livePath: URL,
        runId: String,
        environment: MemoryConsolidationProjectionEnvironment
    ) async throws -> MemoryProjectionReconciliationSummary {
        let storage = try MemoryStorage(dataRoot: dataRoot)
        let generator = UserMDGenerator(
            storage: storage,
            dataRoot: dataRoot,
            personaRoot: environment.personaRoot,
            debounceInterval: 0
        )
        // USER.md generation is gated until onboarding completes
        // (fix-blank-install-onboarding, 2026-08-02) — writing it earlier
        // fabricates the identity anchor onboarding itself is about to create.
        // The rest of the reconcile (Spotlight, knowledge graph, invalidation)
        // is independent of the persona doc, so a pre-onboarding install
        // reconciles everything else rather than failing the whole run.
        let userMD: URL
        do {
            userMD = try await generator.regenerate(persona: MemoryV2Defaults.personaID)
        } catch UserMDGeneratorError.onboardingIncomplete {
            userMD = generator.userMDPath(persona: MemoryV2Defaults.personaID)
        }

        let memories = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        let spotlightRecords = memories.filter {
            $0.status == "active"
                && MemoryLifecycle.isRecallEligible($0.lifecycle)
                && !$0.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix)
        }
        let spotlight = SwiftNativeMemoryIndexer(client: environment.spotlightClient)
        try await spotlight.removeAll()
        try await spotlight.indexBatch(spotlightRecords.map {
            (id: $0.id, text: $0.content, kind: $0.status)
        })

        let graph = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: livePath)
        let graphReport = try await graph.rebuildMemoryDerivedGraphFromCanonicalStore()

        await environment.publishInvalidation(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "consolidation-\(runId)",
            operation: .reconcile,
            reason: "memory_consolidation_projection_rebuild"
        ))
        return MemoryProjectionReconciliationSummary(
            userMDPath: userMD.path,
            spotlightRecords: spotlightRecords.count,
            knowledgeGraph: graphReport,
            invalidationPublished: true
        )
    }

    /// Shared stale-refusal terminal path (pre-check AND in-transaction).
    private static func refuseStale(
        dataRoot: URL, runId: String, approvalId: String
    ) async -> MemoryConsolidationSwapOutcome {
        writeReceipt(dataRoot: dataRoot, runId: runId, status: "stale_refused",
                     approvalId: approvalId, backupPath: nil,
                     reason: "live store changed after staging; re-run consolidation")
        await annotateApproval(
            dataRoot: dataRoot, id: approvalId,
            executedAction: .object([
                "op": .string("memory_consolidation_swap"),
                "status": .string("stale_refused"),
                "run_id": .string(runId),
            ]),
            detail: "consolidation swap refused as STALE: live memories changed after the card "
                + "was staged — nothing applied, candidate discarded; the next consolidation "
                + "run stages a fresh card")
        cleanupCandidate(dataRoot: dataRoot, runId: runId)
        logger.error("consolidation swap \(runId, privacy: .public): STALE — live drifted since staging; refused")
        return .staleRefused(runId: runId)
    }

    /// Thrown by transactionalTableSwap when the IN-TRANSACTION fingerprint
    /// check finds live drifted from the staged manifest. The transaction
    /// rolls back; the caller turns it into a stale_refused terminal.
    struct SwapStaleError: Error {}

    /// ONE immediate transaction: replace memories/proposals/tombstones
    /// with the candidate's rows. Derived tables stay in place here, then the
    /// post-commit projection reconciler regenerates USER.md, Spotlight, the
    /// MemoryV2-owned KG rows, and Fluid Context. use_count/last_used_at accrued
    /// on live after staging are
    /// preserved as MAX(live, candidate) per row. ATTACH must happen outside
    /// the transaction (SQLite forbids ATTACH inside one).
    ///
    /// TOCTOU FIX (review finding 2, 2026-06-10): the AUTHORITATIVE
    /// staleness check runs INSIDE the .immediate transaction, under the
    /// same write lock that performs the table replacement. A chat turn
    /// that writes a memory between the caller's pre-check and this
    /// transaction changes the in-transaction fingerprint → SwapStaleError
    /// → rollback. No window remains in which a fresh write can be deleted
    /// by the swap.
    static func transactionalTableSwap(
        livePath: URL,
        candidatePath: URL,
        expectedLiveFingerprint: String,
        memoryLimit: Int = memoryStoredRowCap
    ) throws -> [StoredMemory] {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: livePath.path, configuration: config)
        defer { try? queue.close() }
        var boundEvictions: [StoredMemory] = []
        try queue.inDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS cand", arguments: [candidatePath.path])
            do {
                try db.inTransaction(.immediate) {
                    // .immediate acquired the write lock — no other writer
                    // can slip in past this point. Re-check NOW.
                    let liveFP = try fingerprint(in: db)
                    guard liveFP == expectedLiveFingerprint else {
                        throw SwapStaleError()
                    }
                    try db.execute(sql: """
                        CREATE TEMP TABLE _live_usage AS
                          SELECT id, use_count, last_used_at FROM memories;
                        DELETE FROM memories;
                        INSERT INTO memories
                          (id, content, persona_id, source, confidence,
                           created_at, updated_at, embedding, status, metadata_json,
                           use_count, last_used_at, lifecycle, embedding_epoch,
                           valid_from, valid_to, observed_at, evidence_json)
                        SELECT c.id, c.content, c.persona_id, c.source, c.confidence,
                               c.created_at, c.updated_at, c.embedding, c.status, c.metadata_json,
                               MAX(c.use_count, COALESCE(lu.use_count, 0)),
                               COALESCE(MAX(c.last_used_at, lu.last_used_at),
                                        c.last_used_at, lu.last_used_at),
                               c.lifecycle, c.embedding_epoch,
                               c.valid_from, c.valid_to, c.observed_at, c.evidence_json
                        FROM cand.memories c
                        LEFT JOIN _live_usage lu ON lu.id = c.id;
                        DELETE FROM proposals;
                        INSERT INTO proposals
                          (id, content, persona_id, source, staged_at, status,
                           resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch)
                        SELECT id, content, persona_id, source, staged_at, status,
                               resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch
                        FROM cand.proposals;
                        DELETE FROM tombstones;
                        INSERT INTO tombstones
                          (content_hash, content, rejected_at, reason, embedding, embedding_epoch)
                        SELECT content_hash, content, rejected_at, reason, embedding, embedding_epoch
                        FROM cand.tombstones;
                        DROP TABLE _live_usage;
                    """)
                    boundEvictions = try MemoryStorage.pruneMemoriesToBound(
                        in: db,
                        limit: memoryLimit
                    )
                    return .commit
                }
            } catch {
                try? db.execute(sql: "DETACH DATABASE cand")
                throw error
            }
            try db.execute(sql: "DETACH DATABASE cand")
        }
        return boundEvictions
    }

    /// Transactionally-consistent pre-swap backup via the SQLite online
    /// backup API (robust against concurrent WAL writers — the fix wave-1's
    /// checkpoint+copy comment wished for).
    static func backupLiveStore(livePath: URL, dataRoot: URL) throws -> String {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let dir = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("pre-consolidation-\(Self.timestamp())-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("memory.sqlite")
        try onlineBackup(from: livePath, to: dest)
        return dir.path
    }

    /// SQLite online backup source → dest (full copy, consistent snapshot).
    static func onlineBackup(from source: URL, to dest: URL) throws {
        var sourceConfig = Configuration()
        sourceConfig.busyMode = .timeout(5)
        sourceConfig.readonly = true
        let sourceQueue = try DatabaseQueue(path: source.path, configuration: sourceConfig)
        defer { try? sourceQueue.close() }
        var destConfig = Configuration()
        destConfig.busyMode = .timeout(5)
        let destQueue = try DatabaseQueue(path: dest.path, configuration: destConfig)
        defer { try? destQueue.close() }
        try sourceQueue.backup(to: destQueue)
    }

    // MARK: - Fingerprint
    //
    // SHA256 over the content-bearing columns of memories + proposals +
    // tombstones, sorted by id. DELIBERATELY EXCLUDES use_count and
    // last_used_at: recall access bumps must not invalidate a staged
    // candidate (the swap carries those signals over instead).
    // 2026-07-21 audit fix: INCLUDES embedding_epoch per row and the
    // memory_embedding_state row. An epoch ACTIVATION between stage and
    // approve rewrites embedding/embedding_epoch WITHOUT touching updated_at
    // and advances active_epoch — the old fingerprint stayed green, the swap
    // installed old-epoch vectors under the new active_epoch, and recall's
    // epoch filter matched zero rows (silent total recall blackout). With
    // these columns hashed, the in-transaction re-check throws SwapStaleError
    // instead of installing mismatched vectors (fail-closed).

    static func fingerprint(ofDatabaseAt path: URL) throws -> String {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in try fingerprint(in: db) }
    }

    /// Fingerprint from an ALREADY-OPEN connection — the shape the swap
    /// transaction needs for its in-lock staleness re-check. Tables are
    /// `main.`-qualified so the result is unaffected by the attached
    /// candidate database during the swap.
    static func fingerprint(in db: Database) throws -> String {
        var hasher = SHA256()
        let memories = try Row.fetchAll(db, sql: """
            SELECT id, updated_at, status, content, COALESCE(metadata_json, '') AS meta,
                   COALESCE(embedding_epoch, '') AS epoch
            FROM main.memories ORDER BY id
        """)
        for row in memories {
            let line = "M|\(row["id"] as String? ?? "")|\(row["updated_at"] as String? ?? "")|"
                + "\(row["status"] as String? ?? "")|\(row["content"] as String? ?? "")|"
                + "\(row["meta"] as String? ?? "")|\(row["epoch"] as String? ?? "")\n"
            hasher.update(data: Data(line.utf8))
        }
        let epochState = try Row.fetchAll(db, sql: """
            SELECT id, COALESCE(active_epoch, '') AS active,
                   COALESCE(previous_epoch, '') AS previous,
                   COALESCE(activated_at, '') AS activated, rollback_available
            FROM main.memory_embedding_state ORDER BY id
        """)
        for row in epochState {
            let line = "E|\(row["id"] as Int? ?? 0)|\(row["active"] as String? ?? "")|"
                + "\(row["previous"] as String? ?? "")|\(row["activated"] as String? ?? "")|"
                + "\(row["rollback_available"] as Int? ?? 0)\n"
            hasher.update(data: Data(line.utf8))
        }
        let proposals = try Row.fetchAll(db, sql: """
            SELECT id, status, COALESCE(resolved_at, '') AS resolved, content
            FROM main.proposals ORDER BY id
        """)
        for row in proposals {
            let line = "P|\(row["id"] as String? ?? "")|\(row["status"] as String? ?? "")|"
                + "\(row["resolved"] as String? ?? "")|\(row["content"] as String? ?? "")\n"
            hasher.update(data: Data(line.utf8))
        }
        let tombstones = try Row.fetchAll(
            db, sql: "SELECT content_hash FROM main.tombstones ORDER BY content_hash")
        for row in tombstones {
            hasher.update(data: Data("T|\(row["content_hash"] as String? ?? "")\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Diff

    static func computeDiff(
        livePath: URL, candidatePath: URL, plan: ConsolidationReport
    ) throws -> MemoryConsolidationDiff {
        func counts(_ path: URL) throws -> (activeMemories: Int, pendingProposals: Int) {
            var config = Configuration()
            config.busyMode = .timeout(5)
            config.readonly = true
            let queue = try DatabaseQueue(path: path.path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                let mem = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM memories WHERE status = 'active'") ?? 0
                let prop = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM proposals WHERE status = 'pending'") ?? 0
                return (mem, prop)
            }
        }
        let live = try counts(livePath)
        let cand = try counts(candidatePath)
        return MemoryConsolidationDiff(
            memoriesActiveBefore: live.activeMemories,
            memoriesActiveAfter: cand.activeMemories,
            proposalsPendingBefore: live.pendingProposals,
            proposalsPendingAfter: cand.pendingProposals,
            accepted: plan.autoAccepted,
            merged: plan.duplicatesMerged,
            archived: plan.staleArchived
        )
    }

    // MARK: - Manifest + receipt

    struct SwapManifest {
        let runId: String
        let liveFingerprint: String
        let candidateFingerprint: String
    }

    static func writeManifest(
        dataRoot: URL, runId: String,
        liveFingerprint: String, candidateFingerprint: String,
        scores: MemoryProbeComparison, diff: MemoryConsolidationDiff,
        stagedAt: Date
    ) throws {
        let manifest: JSONValue = .object([
            "schema": .int(Int64(manifestSchema)),
            "run_id": .string(runId),
            "action": .string(approvalAction),
            "staged_at": .string(Self.iso8601(stagedAt)),
            "live_fingerprint": .string(liveFingerprint),
            "candidate_fingerprint": .string(candidateFingerprint),
            "scores": .object([
                "live": .string(scores.live.summary),
                "candidate": .string(scores.candidate.summary),
            ]),
            "diff": .string(diff.summary),
        ])
        try manifest.serializedData(pretty: true)
            .write(to: manifestPath(dataRoot: dataRoot, runId: runId), options: .atomic)
    }

    static func readManifest(dataRoot: URL, runId: String) throws -> SwapManifest {
        let data = try Data(contentsOf: manifestPath(dataRoot: dataRoot, runId: runId))
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed,
              case .string(let live)? = obj["live_fingerprint"],
              case .string(let cand)? = obj["candidate_fingerprint"],
              case .string(let run)? = obj["run_id"]
        else {
            throw MemoryConsolidationGateError.stagingFailed("manifest shape invalid for run \(runId)")
        }
        return SwapManifest(runId: run, liveFingerprint: live, candidateFingerprint: cand)
    }

    /// Receipt fields needed by reconcile's annotation repair. nil when the
    /// receipt is absent or unparseable (repair is best-effort).
    static func readReceipt(
        dataRoot: URL, runId: String
    ) -> (status: String, backupPath: String?, reason: String?)? {
        guard let data = try? Data(contentsOf: receiptPath(dataRoot: dataRoot, runId: runId)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return nil }
        return (
            status: status,
            backupPath: obj["backup_path"] as? String,
            reason: obj["reason"] as? String
        )
    }

    static func writeReceipt(
        dataRoot: URL, runId: String, status: String,
        approvalId: String?, backupPath: String?, reason: String?
    ) {
        let receipt: JSONValue = .object([
            "run_id": .string(runId),
            "status": .string(status),
            "at": .string(Self.iso8601(Date())),
            "approval_id": approvalId.map { .string($0) } ?? .null,
            "backup_path": backupPath.map { .string($0) } ?? .null,
            "reason": reason.map { .string($0) } ?? .null,
        ])
        do {
            try FileManager.default.createDirectory(
                at: receiptsDir(dataRoot: dataRoot), withIntermediateDirectories: true)
            try receipt.serializedData(pretty: true)
                .write(to: receiptPath(dataRoot: dataRoot, runId: runId), options: .atomic)
        } catch {
            logger.error("consolidation receipt write failed for \(runId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Staging (approval + inbox card; wave-1 memory.repair shape)

    static func stageApproval(
        inbox: SwiftNativeApprovalInbox, dataRoot: URL, runId: String,
        scores: MemoryProbeComparison, diff: MemoryConsolidationDiff
    ) async throws -> String {
        let title = "Memory consolidation ready — probe \(scores.live.summary) → \(scores.candidate.summary)"
        let reason = "The consolidator built a candidate store (\(diff.summary)) and the "
            + "known-answer probe set scored it at or above live. Approve to atomically swap "
            + "the live store to the candidate (live store backed up first), then reconcile "
            + "the KG/index tables against the current memory rows; deny to discard the "
            + "candidate and leave your memories exactly as they are."
        let missLines = scores.candidate.misses.prefix(10).map {
            "• [\($0.probeId)] \($0.question)"
        }
        let detail = "Diff: \(diff.summary)\n"
            + "Probe score live: \(scores.live.summary); candidate: \(scores.candidate.summary)\n"
            + "Post-approval: the approved card also authorizes bounded KG hygiene to remove orphan graph/index rows caused by archived memories.\n"
            + (missLines.isEmpty
                ? "No probe misses on the candidate."
                : "Candidate probe misses:\n" + missLines.joined(separator: "\n"))
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(approvalAction),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": .object([
                "kind": .string(payloadKind),
                "run_id": .string(runId),
                "candidate_path": .string("memory/consolidation/candidates/\(runId)/memory/memory.sqlite"),
                "scores": .object([
                    "live_hits": .int(Int64(scores.live.hits)),
                    "candidate_hits": .int(Int64(scores.candidate.hits)),
                    "total": .int(Int64(scores.live.total)),
                    // Per-probe regression info (review finding 3). Empty by
                    // the gate rule on every STAGED card; carried so the
                    // payload shape documents the per-probe contract.
                    "lost_probe_ids": .array(scores.lostProbeIds.map { .string($0) }),
                ]),
                "diff": .object([
                    "memories_active_before": .int(Int64(diff.memoriesActiveBefore)),
                    "memories_active_after": .int(Int64(diff.memoriesActiveAfter)),
                    "proposals_pending_before": .int(Int64(diff.proposalsPendingBefore)),
                    "proposals_pending_after": .int(Int64(diff.proposalsPendingAfter)),
                    "accepted": .int(Int64(diff.accepted)),
                    "merged": .int(Int64(diff.merged)),
                    "archived": .int(Int64(diff.archived)),
                ]),
            ]),
            "payloadPreview": .string("[\(payloadKind)] \(diff.summary)"),
        ])
        let record = try await inbox.create(body)
        do {
            try await ensureInboxCard(
                dataRoot: dataRoot, approvalId: record.id,
                title: title, summary: "\(diff.summary) — probe \(scores.live.summary) → \(scores.candidate.summary)",
                detail: detail,
                relatedPath: dataRoot.appendingPathComponent("memory/memory.sqlite").path
            )
        } catch {
            // Review finding 5: the approval exists but its card never made
            // it to the inbox — a pending approval no one can see. Resolve
            // it as canceled BEFORE the caller deletes the candidate, so no
            // orphan pending approval survives. Best-effort: if even the
            // cancel fails we still propagate the original card error.
            logger.error("consolidation gate: inbox card creation failed for \(record.id, privacy: .public) — canceling the approval: \(String(describing: error), privacy: .public)")
            if (try? await inbox.resolve(
                record.id, decision: .canceled, decidedBy: "consolidation-gate")) != nil {
                await annotateApproval(
                    dataRoot: dataRoot, id: record.id,
                    executedAction: .object([
                        "op": .string("memory_consolidation_swap"),
                        "status": .string("canceled_cleanup"),
                        "run_id": .string(runId),
                        "error": .string("inbox card creation failed: \(error)"),
                    ]),
                    detail: "consolidation swap canceled: the inbox card could not be created, "
                        + "so the approval was auto-canceled and the candidate discarded — "
                        + "nothing applied")
                writeReceipt(dataRoot: dataRoot, runId: runId, status: "canceled_cleanup",
                             approvalId: record.id, backupPath: nil,
                             reason: "inbox card creation failed: \(error)")
            }
            throw error
        }
        return record.id
    }

    // MARK: - Approval annotation (memory.repair convention)

    /// Stamp `executedAction` + a human `detail` onto an approval record so
    /// a terminal swap decision never reads as silently executed — the
    /// exact convention NativeClient.annotateApprovalExecution uses for
    /// memory.repair. There is NO inbox-protocol method for this
    /// (NativeClient writes requests.json directly under the persistence
    /// flock); ApprovalInbox is outside this slice's fence, so the gate
    /// carries the same file-level write. Best-effort: an annotation
    /// failure is logged, never fatal to the swap outcome.
    static func annotateApproval(
        dataRoot: URL, id: String, executedAction: JSONValue, detail: String
    ) async {
        let path = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")
        let persistence = SwiftNativePersistenceCore()
        do {
            try await persistence.withFileLock(path) {
                let raw = await persistence.readJSON(path, defaultValue: .array([]))
                guard case .array(var rows) = raw else { return }
                for idx in rows.indices {
                    guard case .object(var obj) = rows[idx],
                          case .string(let rowID)? = obj["id"],
                          rowID == id else {
                        continue
                    }
                    obj["executedAction"] = executedAction
                    obj["detail"] = .string(detail)
                    rows[idx] = .object(obj)
                    break
                }
                try await persistence.writeJSON(.array(rows), to: path)
            }
        } catch {
            logger.error("consolidation gate: approval annotation failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Card id == approval id so InboxView's approve/reject routes through
    /// resolveApproval(id). Idempotent whole-file scan inside the flock —
    /// the same shape as the REM and memory.repair stagers.
    static func ensureInboxCard(
        dataRoot: URL, approvalId: String, title: String,
        summary: String, detail: String, relatedPath: String
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(Self.iso8601(Date())),
            "source": .string("memory_consolidation"),
            "severity": .string("actionable"),
            "title": .string(title),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([.string(relatedPath)]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Swap the live store to the candidate (backed up first)")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Discard the candidate; memories stay untouched")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        // Idempotent append via the shared bounded-scan helper (replaces the
        // per-append whole-inbox slurp; same shape as the REM/memory.repair stagers).
        try await appendUniqueById(card, to: inboxPath, using: SwiftNativePersistenceCore())
    }

    // MARK: - Cleanup helpers

    static func cleanupCandidate(dataRoot: URL, runId: String) {
        try? FileManager.default.removeItem(at: candidateRoot(dataRoot: dataRoot, runId: runId))
    }

    /// Candidate dirs no approval references, older than `olderThan` —
    /// staging crashed between manifest and card. Sweep them.
    static func sweepOrphans(dataRoot: URL, referenced: Set<String>, olderThan: TimeInterval) {
        let dir = candidatesDir(dataRoot: dataRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for entry in entries {
            let runId = entry.lastPathComponent
            guard !referenced.contains(runId) else { continue }
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: entry)
                logger.info("consolidation sweep: removed orphan candidate \(runId, privacy: .public)")
            }
        }
    }

    // MARK: - Payload helpers

    static func payloadKind(of payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let kind)? = obj["kind"] else { return nil }
        return kind
    }

    static func runId(of payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .string(let runId)? = obj["run_id"] else { return nil }
        return runId
    }

    static func makeRunId(now: Date) -> String {
        "\(timestamp(now))-\(UUID().uuidString.lowercased().prefix(8))"
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
    }
}
