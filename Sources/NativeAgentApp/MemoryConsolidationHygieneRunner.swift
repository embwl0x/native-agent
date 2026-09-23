// U3 wave-1 item 6 (2026-06-10): the REAL weekly memory-consolidation loop.
//
// Cutover-residue retirement: the old `memory_consolidation` scheduler slot
// ticked MemoryConsolidationLoop over a JSONL adapter reading
// <dataRoot>/memory_embeddings.jsonl — a file that no longer exists (the
// live store has been memory.sqlite since the daemon kill). Every weekly
// NSBackgroundActivityScheduler wake was a guaranteed no-op.
//
// This runner keeps the SAME loopId ("memory_consolidation") so the
// NativeAgentApp scheduler slot and BackgroundLoopsManager.runTickOnce
// routing are untouched.
//
// REVIEW BLOCKER FIX (gpt-5.5, 2026-06-10): the weekly tick must NOT run
// the consolidator directly — MemoryConsolidator.consolidate() auto-accepts
// (durability ≥ 0.85), merges, and archives stale/superseded rows, all
// store MUTATIONS, and the u3-memory-quality plan's law is that every
// store mutation is approval-gated. The tick now STAGES one
// `self_improvement.apply` approval card with op `run_memory_hygiene`
// (mirroring WeeklySelfImprovementLoop's staging shape — see
// BackgroundLoopsAssembly.makeWeeklySelfImprovementLoop). Approving the
// card fires the existing executor
// (NativeClient.applyApprovedSelfImprovement → runMemoryHygiene), which is
// the only thing that actually consolidates and writes
// <dataRoot>/memory/hygiene_last_run.json. Staging is idempotent: a second
// card is never staged while one is pending.
//
// The direct-consolidate path (runOnce) stays available ONLY behind the
// explicit `approvedDirectRun` parameter, asserted by the two
// already-approval-gated callers: the MemoryView manual "Run hygiene"
// button and the approved `run_memory_hygiene` op (both via
// NativeClient.runMemoryHygiene).
//
// The retired JSONL loop type and its isolated tests are gone; this runner is
// the only implementation behind the canonical scheduler slot.
//
// 2026-09-22 (User: "run hygiene weekly on its own"): the weekly tick now calls
// runOnce directly instead of filing a "hygiene is due" card, and approves
// the gate's probe-checked swap card itself (weekly tick only; the manual
// button still leaves the swap card for User). Hygiene still only archives.

import Foundation
import ApprovalInbox
import BackgroundLoops
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Shared hygiene implementation

/// One implementation for BOTH the manual hygiene path
/// (NativeClient.runMemoryHygiene) and the weekly background tick, so the
/// two can never drift on report shape or on what a "hygiene run" means.
enum MemoryConsolidationHygiene {

    /// Thrown when a caller reaches the direct-consolidate path without
    /// asserting it carries an approval.
    struct DirectRunNotApprovedError: Error, CustomStringConvertible {
        var description: String {
            "MemoryConsolidationHygiene.runOnce requires approvedDirectRun=true — "
            + "consolidation mutates the memory store and must ride an explicit "
            + "approval (manual Run-hygiene button or an approved "
            + "self_improvement.apply run_memory_hygiene card)."
        }
    }

    /// Run the consolidator and persist the report to
    /// <dataRoot>/memory/hygiene_last_run.json. Throws when storage can't
    /// open or the consolidation pass itself fails.
    ///
    /// `approvedDirectRun` is the review-blocker gate (2026-06-10): this
    /// path MUTATES the store (auto-accept / merge / archive), so the only
    /// legal callers are the ones that already carry an explicit approval —
    /// NativeClient.runMemoryHygiene (MemoryView manual button + the
    /// approved run_memory_hygiene op) and, since 2026-09-22, the weekly
    /// tick on User's standing word.
    @discardableResult
    static func runOnce(
        dataRoot: URL,
        approvedDirectRun: Bool,
        autoApproveSwap: Bool = false
    ) async throws -> MemoryHygieneReport {
        guard approvedDirectRun else { throw DirectRunNotApprovedError() }
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let before = (try? await storage.listMemories(persona: nil, status: nil, limit: nil).count) ?? 0
        let consolidator = MemoryConsolidator(storage: storage)
        // Honest-status fix (2026-07-24): consolidation is GATED — it builds a
        // candidate store and stages an approval card; the live store is never
        // mutated here. The old `consolidate()` adapter collapsed that outcome
        // into plan counters, so the report (and the "Memory hygiene complete:
        // merged 3" toast built from it) claimed applied work while the truth
        // was "pending card in Activity" — observed live 2026-07-24 11:06: DB
        // unchanged, card fafc9705 pending. Switch on the real outcome and say
        // what actually happened.
        let outcome = try await consolidator.consolidateGated()
        let result: ConsolidationReport
        var status: String
        let reason: String?
        var consolidationRunId: String?
        // 2026-09-22 (User: "run hygiene weekly on its own"): the weekly tick
        // approves its own swap card and applies it through the gate's
        // reconcile, which still stale-refuses, backs up, and only archives.
        func autoApply(_ approvalId: String) async -> (applied: Bool, detail: String)? {
            guard autoApproveSwap else { return nil }
            do {
                _ = try await SwiftNativeApprovalInbox(root: dataRoot).resolve(
                    approvalId, decision: .approved,
                    provenance: .local(decidedBy: "weekly_memory_hygiene"))
            } catch {
                return (false, "auto-approve of swap card \(approvalId.prefix(8)) failed: \(error)")
            }
            let outcomes = await MemoryConsolidationGate.reconcile(dataRoot: dataRoot)
            let applied = outcomes.contains {
                switch $0 {
                case .applied, .alreadyApplied: return true
                default: return false
                }
            }
            return (applied, "weekly swap auto-approved: "
                + (outcomes.isEmpty ? "no outcome" : outcomes.map { "\($0)" }.joined(separator: "; ")))
        }
        // gpt-5.5 review (2026-07-24 MED): candidate-run errors must survive
        // every outcome path — MemoryHygieneReport has no errors field, so
        // they ride the reason string.
        func withPlanErrors(_ base: String, _ plan: ConsolidationReport) -> String {
            plan.errors.isEmpty
                ? base
                : base + "; candidate-run errors: " + plan.errors.prefix(5).joined(separator: "; ")
        }
        switch outcome {
        case .staged(let approvalId, _, _, let plan):
            result = plan
            status = "staged"
            if let approval = try? await SwiftNativeApprovalInbox(root: dataRoot).get(approvalId) {
                consolidationRunId = MemoryConsolidationGate.runId(of: approval.payload)
            }
            if let auto = await autoApply(approvalId) {
                status = auto.applied ? (plan.errors.isEmpty ? "ok" : "partial") : "failed"
                reason = withPlanErrors(auto.detail, plan)
            } else {
                reason = withPlanErrors(
                    "changes staged for approval (card \(approvalId.prefix(8))) — nothing applied until approved in Activity",
                    plan)
            }
        case .alreadyStaged(let approvalId):
            result = ConsolidationReport(
                processed: 0, autoAccepted: 0, duplicatesMerged: 0,
                pendingForReview: 0, staleArchived: 0, errors: [])
            status = "staged"
            if let approval = try? await SwiftNativeApprovalInbox(root: dataRoot).get(approvalId) {
                consolidationRunId = MemoryConsolidationGate.runId(of: approval.payload)
            }
            // Never auto-approve a card this run did not stage: it may be a
            // manual run's card waiting on User.
            reason = "a consolidation card is already pending approval (card \(approvalId.prefix(8))) — no new run"
        case .refusedRegression(let scores, let plan):
            result = plan
            status = "refused"
            reason = withPlanErrors(
                "probe gate refused to stage: candidate lost probes vs live "
                + "(live \(scores.live.summary), candidate \(scores.candidate.summary)); candidate discarded",
                plan)
        case .noChanges(let plan):
            result = plan
            status = plan.errors.isEmpty ? "ok" : "partial"
            reason = plan.errors.isEmpty ? nil : plan.errors.prefix(5).joined(separator: "; ")
        }
        // NOTE: the KG reconcile/orphan-GC below deliberately runs on EVERY
        // outcome, including staged/refused — it is live-store bookkeeping
        // against rows whose memories are already gone, independent of the
        // staged candidate, and the human action authorizing it is the same
        // approvedDirectRun click/approval that reached this function
        // (2026-07-21 audit decision). It cannot touch the pending candidate.
        // 2026-07-02 audit: reconcile the KG dedupe index on the same
        // approved cadence. Pure bookkeeping (rows whose memory no longer
        // exists) — the full GC only runs on the rare swap path, so leaked
        // index rows otherwise sit forever. Best-effort: a reconcile failure
        // never fails the hygiene run.
        // Settings ▸ "Memory hygiene": off skips this cleanup block (index
        // reconcile, backfill, orphan sweep) too. Consolidation above is
        // untouched. Read fresh on the run.
        // ...and Settings ▸ "Knowledge graph": the backfill below PRODUCES
        // graph rows, so off means it does not run either (reviewer, 2026-09-05).
        if MemoryPolicyGate.hygieneEnabled(dataRoot: dataRoot),
           MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) {
        do {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
            let reconciled = try await indexer.reconcileStaleMemoryIndexRows()
            if reconciled > 0 {
                FileHandle.standardError.write(Data(
                    "MemoryConsolidationHygiene: reconciled \(reconciled) stale kg_memory_index row(s)\n".utf8))
            }
            // B4 (2026-08-28): the reconcile above only DELETES index rows whose
            // memory is gone; nothing put back the rows for memories whose
            // fire-and-forget indexing Task died with the process. That drift is
            // stable rather than growing-and-self-healing (47 active memories on
            // the live store), and an unindexed memory is invisible to every
            // graph-derived surface. Runs immediately after the reconcile so the
            // two halves of index bookkeeping share one approved cadence, and
            // batch-capped so a large backlog drains over runs. Additive: a
            // memory that already has a row is never touched.
            let backfilled = try await indexer.backfillMissingMemoryIndexRows()
            if backfilled > 0 {
                FileHandle.standardError.write(Data(
                    "MemoryConsolidationHygiene: backfilled \(backfilled) missing kg_memory_index row(s)\n".utf8))
            }
            // 2026-07-21 audit: the full KG orphan sweep fired ONLY on the
            // manual KG-maintenance button or the rare approved
            // consolidation swap, so deleted-memory entities/edges piled up
            // in between. Run it on THIS approved cadence — the human gate
            // is the approval card / manual button that authorized this
            // runOnce (approvedDirectRun == true above), so no new ungated
            // mutation path is created; approvedOverThreshold is honest
            // because the approval IS the threshold confirmation.
            let facts = try await listGCFacts(storage)
            let gc = try await indexer.collectGarbage(
                liveFacts: facts, apply: true, approvedOverThreshold: true)
            if gc.entitiesDeleted > 0 || gc.edgesDeleted > 0 || gc.staleIndexRowsDeleted > 0 {
                FileHandle.standardError.write(Data(
                    "MemoryConsolidationHygiene: KG sweep deleted \(gc.entitiesDeleted) orphan entit(ies), \(gc.edgesDeleted) edge(s), \(gc.staleIndexRowsDeleted) stale index row(s)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "MemoryConsolidationHygiene: KG reconcile/sweep failed: \(error)\n".utf8))
        }
        }
        let after = (try? await storage.listMemories(persona: nil, status: nil, limit: nil).count) ?? before
        let now = Date()
        let report = MemoryHygieneReport(
            id: "hygiene-\(UUID().uuidString.lowercased())",
            status: status,
            reason: reason,
            version: "swift-memory-v2-consolidator",
            createdAt: Self.iso(now),
            beforeCount: before,
            afterCount: after,
            normalized: result.processed,
            archivedDuplicates: result.duplicatesMerged,
            archivedReflections: result.staleArchived,
            distilledFactsAdded: result.autoAccepted,
            decayedMemories: nil,
            proposalHygiene: MemoryProposalHygiene(
                rejectedLowValue: nil,
                nearDuplicates: result.pendingForReview
            ),
            consolidationRunId: consolidationRunId,
            // Weekly, matching MemoryConsolidationHygieneRunner's card-staging
            // cadence — the old +24h value made every audit of this file read
            // the (approval-gated, weekly) system as days overdue. Display-only
            // (the weekly loop runs off its BackgroundLoops interval, never this
            // stamp) — and a staged/refused run completed nothing, so it gets
            // no "next" stamp (gpt-5.5 review 2026-07-24: a staged run must not
            // read as a reached cadence boundary).
            nextScheduled: (status == "ok" || status == "partial")
                ? Self.iso(now.addingTimeInterval(7 * 24 * 3600))
                : nil
        )
        try write(report, dataRoot: dataRoot)
        return report
    }

    static func lastRunPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("hygiene_last_run.json")
    }

    /// Live-memory fact list the KG GC reconciles against — same shape
    /// KnowledgeGraphView+Maintenance.listGCFacts builds for the manual
    /// sweep, so the hygiene-path GC and the button-path GC can never
    /// drift on what "live" means.
    static func listGCFacts(_ storage: MemoryStorage) async throws -> [KnowledgeGraphMemoryFact] {
        let mems = try await storage.listMemories(persona: nil, status: nil, limit: nil)
        return mems.map {
            KnowledgeGraphMemoryFact(
                id: $0.id,
                content: $0.content,
                source: $0.source,
                status: $0.status,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                metadata: $0.projectionMetadata
            )
        }
    }

    static func write(_ report: MemoryHygieneReport, dataRoot: URL) throws {
        let path = lastRunPath(dataRoot: dataRoot)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: path, options: .atomic)
    }

    /// Whole-second internet datetime — parseable by the plain
    /// ISO8601DateFormatter() that readHygieneLastRun uses to compute
    /// nextScheduled (fractional seconds would make that parse fail).
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

// MARK: - LoopRunner

/// Weekly slow-path consolidation tick. Same loopId as the retired JSONL
/// loop so NSBackgroundActivityScheduler's "memory_consolidation" slot and
/// runTickOnce keep routing here; the in-app cadence matches the weekly
/// design (the OS scheduler slot is the primary driver).
///
/// The tick runs MemoryConsolidationHygiene.runOnce directly. See the file
/// header.
struct MemoryConsolidationHygieneRunner: LoopRunner {
    let loopId: String = "memory_consolidation"
    let interval: TimeInterval
    let dataRoot: URL

    /// U5 W-D fix-round (gpt-5.5 NEEDS_FIX): the 3600s budget must live on
    /// THIS type — it is what assembleAllLoops actually registers for the
    /// "memory_consolidation" slot. The override previously existed only on
    /// the retired JSONL loop rather than this registered type, so the live
    /// slot silently rode the scheduler's 300s default. The weekly tick runs the
    /// full hygiene pass — give it the same wide weekly-loop budget as its
    /// siblings rather than gambling on the default.
    var tickTimeoutOverride: TimeInterval? { 3600 }

    init(dataRoot: URL, interval: TimeInterval = 7 * 24 * 60 * 60) {
        self.dataRoot = dataRoot
        self.interval = interval
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        // Settings ▸ "Nightly memory consolidation": off means this tick does
        // not run. Read fresh on the tick, so a flip lands on the next run.
        guard MemoryPolicyGate.consolidationEnabled(dataRoot: dataRoot) else {
            return .skipped(reason:
                "Memory consolidation is turned off in Settings, so hygiene did not run.")
        }
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                tool: "self_improvement.apply",
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_consolidation_background",
                    isRemote: false
                )
            )
        // User, 2026-09-04: only an EXPLICIT block stops the tick. 8eccf9a1
        // (Full Mac, prompt-free) also skipped whenever Full Mac was admitted,
        // and on a Mac that never expires that meant weekly hygiene never ran
        // again after 08-28, silently: the skip stamped the loop as run and
        // wrote no failure.
        if yolo.state == .explicitlyBlocked {
            let now = Date()
            let report = MemoryHygieneReport(
                id: "hygiene-\(UUID().uuidString.lowercased())",
                status: "refused",
                reason: "Memory consolidation is explicitly blocked; hygiene did not run.",
                version: "swift-memory-v2-consolidator",
                createdAt: ISO8601DateFormatter().string(from: now),
                beforeCount: nil,
                afterCount: nil,
                normalized: nil,
                archivedDuplicates: nil,
                archivedReflections: nil,
                distilledFactsAdded: nil,
                decayedMemories: nil,
                proposalHygiene: nil,
                consolidationRunId: nil,
                nextScheduled: nil
            )
            try? MemoryConsolidationHygiene.write(report, dataRoot: dataRoot)
            return .skipped(reason: report.reason ?? "memory hygiene deferred")
        }
        do {
            let report = try await MemoryConsolidationHygiene.runOnce(
                dataRoot: dataRoot, approvedDirectRun: true, autoApproveSwap: true)
            if report.status == "failed" {
                return .failed(error: "memory hygiene: \(report.reason ?? "swap not applied")")
            }
            if report.status == "staged" {
                return .skipped(reason: report.reason ?? "a consolidation card is already pending")
            }
            return .completed(result: "memory hygiene \(report.status ?? "done")"
                + (report.reason.map { ": \($0)" } ?? ""))
        } catch {
            return .failed(error: "memory hygiene failed: \(error)")
        }
    }
}
