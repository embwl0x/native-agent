import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Studio
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+StudioCanon.swift` | Native source invalidations, background admission, throttle, audit receipts and exact deadline ownership; proposals and next deadline share one read-constrained studio-canon projection; no new timer or schedule activation |

// Source invalidations use the existing organism deadline, 30-minute throttle
// and background-cognition gate.
extension NativeCognitionRuntime {

    /// The pass reads the journal and the graph; the reschedule that calls it
    /// can fire many times a minute under load.
    static let studioCanonTendingMinimumInterval: TimeInterval = 30 * 60

    /// Called from the residual-repair reschedule.
    func considerStudioCanonTending() {
        guard !isFlushedForTermination, sourceWakes.canonReady, studioCanonTask == nil else { return }
        let at = now()
        if let due = sourceWakes.canonNextAt, due <= at { sourceWakes.canonDirty = true }
        guard sourceWakes.canonDirty else { return }
        if let last = lastStudioCanonTendingAt,
           at.timeIntervalSince(last) < Self.studioCanonTendingMinimumInterval {
            return
        }
        lastStudioCanonTendingAt = at
        sourceWakes.canonDirty = false
        sourceWakes.canonNextAt = nil
        studioCanonTask = Task { [weak self] in
            guard let self else { return }
            await self.runStudioCanonTending()
            await self.finishStudioCanonTask()
        }
    }

    private func finishStudioCanonTask() async {
        studioCanonTask = nil
        await rescheduleResidualRepairDeadline()
    }

    /// Journal, graph, recall and approval invalidations request a pass. The
    /// existing deadline carries the part's next silence boundary. It can only STAGE cards: the part returns
    /// proposals, this stages them, and the single path that writes a canon row
    /// (`appendCanonRow`) throws unless the row carries HER seat.
    private func runStudioCanonTending() async {
        let report: StudioCanonTendingReport
        do {
            let host = self.host, root = dataRoot
            report = try await StudioCanonTending.run(dataRoot: root, now: now(), deadlineDate: Self.deskDate) { input in
                try await host.callReadPart(id: "studio-canon", input: input, actions: [],
                    dataRoot: root, origin: "studio_canon:proposals")
            }
        } catch {
            nativeLog("[StudioCanon] Tending deferred: %@", error.localizedDescription)
            return
        }
        await StudioCanonTending.recordAudit(report.audit, dataRoot: dataRoot, now: now())
        guard !isFlushedForTermination, !Task.isCancelled else { return }
        sourceWakes.canonNextAt = report.nextAt
        OrganPulse.record("studio_canon", found: report.stagedApprovalIDs.count,
                          note: "\(report.stagedApprovalIDs.count) proposed of \(report.evaluatedWorks) works")
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
        // A relation with no edge citing it back is surfaced,
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
