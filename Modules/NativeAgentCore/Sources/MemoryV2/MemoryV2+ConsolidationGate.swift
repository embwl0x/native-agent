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

import Foundation
import GRDB
import ApprovalInbox
import KnowledgeGraph
import NativeAgentCore
import OSLog
import PersistenceCore

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

// MARK: - Gate

public enum MemoryConsolidationGate {

    public static let approvalAction = "memory.consolidation.swap"
    static let payloadKind = "memory.consolidation.swap"
    static let manifestSchema = 1
    static let defaultOrphanAge: TimeInterval = 24 * 60 * 60

    static let logger = Logger(
        subsystem: "com.nativeagent.app", category: "memory-consolidation-gate")

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
            // 2026-09-06: the candidate root holds a COPY of memory.sqlite and
            // nothing else — no trust/policy.json. Pass the REAL data root so
            // "Keep consolidated memories without asking" and "Memory hygiene"
            // are read from the policy the user actually edited.
            plan = try await MemoryConsolidator(
                storage: candidateStorage,
                now: now,
                policyRoot: dataRoot
            ).consolidateDestructively()
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
                guard let receipt = readReceipt(dataRoot: dataRoot, runId: runId) else {
                    // Presence alone is not terminal proof. Preserve the
                    // candidate and fail closed so a corrupt or cross-run
                    // receipt cannot silently settle an approved swap.
                    outcomes.append(.failed(
                        runId: runId,
                        reason: "terminal receipt unreadable or mismatched"
                    ))
                    continue
                }
                // Older binaries wrote the terminal consolidation receipt but
                // left hygiene_last_run.json at `staged`. Re-drive the
                // canonical health projection on every reconciliation so that
                // crash-window and upgrade recovery converge too.
                reconcileAppliedMaintenanceTruth(
                    dataRoot: dataRoot,
                    runId: runId,
                    status: receipt.status,
                    at: receipt.at
                )
                if record.status == "resolved", record.executedAction == nil {
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
                // User, 2026-09-06: a run whose swap committed is not
                // unrecoverable just because its candidate is gone — a crash
                // partway through `cleanupCandidate` leaves exactly that. The
                // applied marker in the live store settles it, and `applySwap`
                // takes the already-applied path and reconciles the pending
                // projections.
                guard candidateExists
                    || swapMarkerApplied(
                        livePath: liveStorePath(dataRoot: dataRoot), runId: runId
                    ) else {
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
        let livePath = liveStorePath(dataRoot: dataRoot)
        let candidatePath = candidateDBPath(dataRoot: dataRoot, runId: runId)
        do {
            // User, 2026-09-06: the applied marker is read BEFORE the candidate
            // is touched. Once the swap has committed the candidate's state
            // says nothing about this run — a half-finished cleanup or a
            // drifted candidate file must not turn a landed swap into a
            // terminal "failed" with its projections never reconciled.
            let markerApplied = swapMarkerApplied(livePath: livePath, runId: runId)
            // Integrity: the candidate on disk must be the one that was scored.
            let candidateFP = markerApplied
                ? manifest.candidateFingerprint
                : try fingerprint(ofDatabaseAt: candidatePath)
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
            // Crash-after-commit window: swap already landed. User, 2026-09-06:
            // the committed store matches the candidate's fingerprint only when
            // nothing changed it on the way in — the usage veto and the row-cap
            // prune both do — and a canonical write landing before this retry
            // moves it again. The marker the swap wrote INSIDE its transaction
            // is the authority, whatever the live fingerprint now says; without
            // it a swap that HAD committed fell through to `refuseStale` below,
            // discarding the candidate and reporting nothing applied. The
            // projection reconcile it re-runs is idempotent.
            if markerApplied || liveFP == manifest.candidateFingerprint {
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
                    expectedLiveFingerprint: manifest.liveFingerprint,
                    appliedRunId: runId)
                await MemoryStorage.recordBoundEvictions(
                    boundEvictions,
                    memoryPath: livePath,
                    reason: "approved_consolidation_swap"
                )
            } catch is SwapStaleError {
                return await refuseStale(dataRoot: dataRoot, runId: runId, approvalId: verified.id)
            }
            swapCommitted = true
            // No stamp here: the applied marker went in with the transaction
            // above, so a crash or a failed projection anywhere from this point
            // still leaves the next reconcile a consistent answer.
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
            sweepBackups(dataRoot: dataRoot)
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
        // Settings ▸ "Knowledge graph": approving a consolidation is not
        // consent to PRODUCE a graph. Off, the rebuild runs its removal half
        // only and retires the indexer-owned nodes — the same answer the
        // mutation hook and the startup backfill already give (User,
        // 2026-09-06: this seam was the one place that rebuilt the whole graph
        // from the store with the switch off). Read fresh on the reconcile.
        let graphReport = try await graph.rebuildMemoryDerivedGraphFromCanonicalStore(
            producing: MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot)
        )

        await environment.publishInvalidation(DerivedSourceChange(
            namespace: "memory-v2",
            stableID: "consolidation-\(runId)",
            operation: .reconcile,
            canonicalLocator: livePath.standardizedFileURL.path,
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


}
