import ChatOrchestration
import CognitiveSubstrate
import Foundation
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore
import Studio

// Desk 903 phase 4 — the canon's tending pass, hung off the deadline the
// organism already owns. It used to ride the encounter lane, which was cut in
// Phase 5 F (105 seeds minted 09-02/03, none filed, no intake since): no new
// timer, no new budget, the same 30-minute disk-read throttle and the same
// background-cognition gate every other background lane passes.
extension NativeCognitionRuntime {

    /// The pass reads the journal and the graph; the reschedule that calls it
    /// can fire many times a minute under load.
    static let studioCanonTendingMinimumInterval: TimeInterval = 30 * 60

    /// Called from the residual-repair reschedule.
    func considerStudioCanonTending() {
        guard !isFlushedForTermination, studioCanonTask == nil else { return }
        let at = now()
        if let last = lastStudioCanonTendingAt,
           at.timeIntervalSince(last) < Self.studioCanonTendingMinimumInterval {
            return
        }
        lastStudioCanonTendingAt = at
        studioCanonTask = Task { [weak self] in
            guard let self else { return }
            if case .allowed = await self.backgroundCognitionGate(reason: "studio_canon:reflection") {
                await self.runStudioCanonTending()
            }
            await self.finishStudioCanonTask()
        }
    }

    private func finishStudioCanonTask() {
        studioCanonTask = nil
    }

    /// Desk 903 phase 4, on the same low-frequency pass.
    ///
    /// Canon-tending has no event of its own — silence, the demotion trigger, is
    /// by definition the absence of one — so it rides the lane that already
    /// wakes on the body's own rhythm. It can only STAGE cards: the law returns
    /// proposals, this stages them, and the single path that writes a canon row
    /// (`appendCanonRow`) throws unless the row carries HER seat.
    private func runStudioCanonTending() async {
        let report: StudioCanonTendingReport
        do {
            report = try await StudioCanonTending.run(dataRoot: dataRoot, now: now())
        } catch {
            nativeLog("[StudioCanon] Tending deferred: %@", error.localizedDescription)
            return
        }
        await StudioCanonTending.recordAudit(report.audit, dataRoot: dataRoot, now: now())
        if !report.stagedApprovalIDs.isEmpty {
            await substrate.recordReceipt(
                kind: "studio.canon_proposed",
                payload: .object([
                    "proposals": .array(report.stagedApprovalIDs.map { .string($0) }),
                    "evaluatedWorks": .int(Int64(report.evaluatedWorks)),
                    "duplicatesSkipped": .int(Int64(report.duplicatesSkipped)),
                    // Said out loud on every mint: this is a request, not an act.
                    "soleApprover": .string(StudioCanonSeat.agent),
                    "autoCanonization": .bool(false),
                ])
            )
        }
        // Agent's addendum: a relation with no edge citing it back is surfaced,
        // never repaired. Change-only — an unfixed mismatch would otherwise
        // re-announce itself on every pass.
        guard report.audit.graphAvailable else { return }
        let verdict = report.audit.isConsistent
            ? "consistent"
            : "inconsistent:\(report.audit.mismatches.count)"
        guard lastStudioRelationAuditVerdict != verdict else { return }
        lastStudioRelationAuditVerdict = verdict
        guard !report.audit.isConsistent else { return }
        await substrate.recordReceipt(
            kind: "studio.relations_inconsistent",
            payload: .object([
                "checked": .int(Int64(report.audit.relationsChecked)),
                "mismatches": .array(report.audit.mismatches.map { $0.toJSON() }),
                "unresolvedRelations": .int(Int64(report.audit.unresolvedRelations)),
                "repaired": .bool(false),
                "health": .string(
                    StudioCanonTending.auditHealthPath(dataRoot: dataRoot).path
                ),
            ])
        )
    }
}
