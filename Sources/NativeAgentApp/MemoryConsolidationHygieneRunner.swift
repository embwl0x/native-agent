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

import Foundation
import ApprovalInbox
import BackgroundLoops
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore

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
    /// approved run_memory_hygiene op). The weekly tick stages an approval
    /// card instead (see MemoryConsolidationHygieneRunner.tick).
    @discardableResult
    static func runOnce(dataRoot: URL, approvedDirectRun: Bool) async throws -> MemoryHygieneReport {
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
        let status: String
        let reason: String?
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
            reason = withPlanErrors(
                "changes staged for approval (card \(approvalId.prefix(8))) — nothing applied until approved in Activity",
                plan)
        case .alreadyStaged(let approvalId):
            result = ConsolidationReport(
                processed: 0, autoAccepted: 0, duplicatesMerged: 0,
                pendingForReview: 0, staleArchived: 0, errors: [])
            status = "staged"
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
        do {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
            let reconciled = try await indexer.reconcileStaleMemoryIndexRows()
            if reconciled > 0 {
                FileHandle.standardError.write(Data(
                    "MemoryConsolidationHygiene: reconciled \(reconciled) stale kg_memory_index row(s)\n".utf8))
            }
            // 2026-07-21 audit: the full KG orphan sweep fired ONLY on the
            // manual KG-maintenance button or the rare approved
            // consolidation swap, so deleted-memory entities/edges piled up
            // in between. Run it on THIS approved cadence — the human gate
            // is the approval card / manual button that authorized this
            // runOnce (approvedDirectRun == true above), so no new ungated
            // mutation path is created; approvedOverThreshold is honest
            // because the approval IS the threshold confirmation. The
            // weekly staged card carries the dry-run counts (see
            // MemoryConsolidationHygieneRunner.stageHygieneApprovalIfNeeded).
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

    private static func write(_ report: MemoryHygieneReport, dataRoot: URL) throws {
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
/// The tick NEVER consolidates — it stages one approval card whose
/// approve-executor (NativeClient.applyApprovedSelfImprovement, op
/// `run_memory_hygiene`) runs the consolidator. See the file header.
struct MemoryConsolidationHygieneRunner: LoopRunner {
    let loopId: String = "memory_consolidation"
    let interval: TimeInterval
    let dataRoot: URL

    /// U5 W-D fix-round (gpt-5.5 NEEDS_FIX): the 3600s budget must live on
    /// THIS type — it is what assembleAllLoops actually registers for the
    /// "memory_consolidation" slot. The override previously existed only on
    /// the retired JSONL loop rather than this registered type, so the live
    /// slot silently rode the scheduler's 300s default. The weekly tick is normally a cheap
    /// approval-card staging pass, but it takes the inbox file lock and
    /// scans the pending set — give it the same wide weekly-loop budget as
    /// its siblings rather than gambling on the default.
    var tickTimeoutOverride: TimeInterval? { 3600 }

    /// The op the staged card applies on approval — must stay inside
    /// NativeClient.applyApprovedSelfImprovement's 3-op allow-list (and
    /// WeeklySelfImprovementLoop.applyOps).
    static let applyOp = "run_memory_hygiene"
    static let approvalAction = "self_improvement.apply"

    init(dataRoot: URL, interval: TimeInterval = 7 * 24 * 60 * 60) {
        self.dataRoot = dataRoot
        self.interval = interval
    }

    func tick() async {
        _ = await tickOutcome()
    }

    func tickOutcome() async -> LoopTickOutcome {
        guard let approvalID = await Self.stageHygieneApprovalIfNeeded(dataRoot: dataRoot) else {
            return .failed(error: "memory hygiene approval scan or staging failed")
        }
        return .completed(result: "memory hygiene approval ready: \(approvalID)")
    }

    /// Stage ONE `self_improvement.apply` card carrying op
    /// `run_memory_hygiene`, mirroring the body shape
    /// makeWeeklySelfImprovementLoop's stageProposal writes (so the
    /// existing approve-executor and approval UI treat it identically).
    ///
    /// Idempotent: when a pending self_improvement.apply card with this op
    /// already exists, its id is returned and nothing is staged. A failed
    /// pending-scan stages NOTHING (fail closed — we can't know, so we
    /// don't risk a duplicate; the next weekly tick retries). Returns the
    /// approval id when a card exists after this call, nil otherwise.
    @discardableResult
    static func stageHygieneApprovalIfNeeded(dataRoot: URL) async -> String? {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let pending: [ApprovalRecord]
        do {
            pending = try await inbox.list(
                filter: ApprovalFilter(status: "pending", action: approvalAction))
        } catch {
            FileHandle.standardError.write(Data(
                "MemoryConsolidationHygieneRunner: pending-scan failed; staging nothing: \(error)\n".utf8))
            return nil
        }
        if let existing = pending.first(where: { Self.applyOpOf($0.payload) == applyOp }) {
            return existing.id
        }
        // 2026-07-21 audit: dry-run KG orphan-sweep preview rides in the
        // card text so User approves with the counts in view — the approved
        // apply (MemoryConsolidationHygiene.runOnce) runs the real GC.
        // Best-effort: a preview failure stages the card without counts
        // rather than skipping the weekly hygiene stage entirely. Skipped
        // outright when no memory store exists yet — a READ-ONLY preview
        // must never mint memory/memory.sqlite as a side effect of a tick.
        var kgPreviewNote = ""
        let memoryStorePath = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: memoryStorePath.path),
           let storage = try? await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot),
           let indexer = try? SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path),
           let facts = try? await MemoryConsolidationHygiene.listGCFacts(storage),
           let preview = try? await indexer.collectGarbage(liveFacts: facts, apply: false) {
            kgPreviewNote = " KG sweep preview on approval: \(preview.candidates.count) orphan "
                + "entit\(preview.candidates.count == 1 ? "y" : "ies") would be swept."
        }
        let proposedChange = "Run the MemoryV2 consolidation/hygiene pass over "
            + "memory/memory.sqlite: merge duplicate proposals, auto-accept "
            + "high-durability facts, archive stale/superseded memories, "
            + "clean broken or duplicate active semantic memories, and sweep "
            + "orphaned knowledge-graph entities/edges."
            + kgPreviewNote
            + " Nothing changes until you approve."
        let body: JSONValue = .object([
            "title": .string("Weekly memory hygiene is due"),
            "action": .string(approvalAction),
            "reason": .string(
                "The weekly memory_consolidation tick fired. Memory hygiene "
                + "mutates the store, so it stages this card instead of running "
                + "silently — approve to run it now, deny to skip this week."),
            "payload": .object([
                "kind": .string("self_improvement"),
                "evidence": .string(
                    "Weekly memory_consolidation background tick (every store "
                    + "mutation is approval-gated per the u3-memory-quality plan)."),
                "proposedChange": .string(proposedChange),
                "apply": .object([
                    "op": .string(applyOp),
                    "target": .string(""),
                ]),
            ]),
            "payloadPreview": .string("[\(applyOp)] " + String(proposedChange.prefix(180))),
        ])
        do {
            let rec = try await inbox.create(body)
            FileHandle.standardError.write(Data(
                "MemoryConsolidationHygieneRunner: staged weekly hygiene approval \(rec.id)\n".utf8))
            return rec.id
        } catch {
            // tick() must not throw (LoopRunner contract) — log and let the
            // next scheduled tick retry.
            FileHandle.standardError.write(Data(
                "MemoryConsolidationHygieneRunner: stage failed: \(error)\n".utf8))
            return nil
        }
    }

    private static func applyOpOf(_ payload: JSONValue) -> String? {
        guard case .object(let obj) = payload,
              case .object(let apply)? = obj["apply"],
              case .string(let op)? = apply["op"] else { return nil }
        return op
    }
}
