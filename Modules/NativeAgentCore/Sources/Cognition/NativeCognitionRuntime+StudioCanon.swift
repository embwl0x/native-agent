import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Studio
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+StudioCanon.swift` | Native source invalidations, background admission, throttle, audit receipts and exact deadline ownership; mind.canon satisfies the pass wait in the same retained flight, carries satisfy_wait into the editable silence policy and returns its actual report; proposals and next deadline share one read-constrained studio-canon projection |

// Source invalidations use the existing organism deadline, 30-minute throttle
// and background-cognition gate.
extension NativeCognitionRuntime {

    private func studioCanonAdmitted(explicit: Bool) -> Bool {
        let configuration = Self.loadConfiguration(
            defaults: preferenceDefaults, environment: configurationEnvironment)
        return !isFlushedForTermination && !Task.isCancelled && configuration.enabled
            && (explicit || configuration.backgroundMicrocyclesEnabled)
    }

    /// The pass reads the journal and the graph; the reschedule that calls it
    /// can fire many times a minute under load.
    static let studioCanonTendingMinimumInterval: TimeInterval = 30 * 60

    /// Called from the residual-repair reschedule.
    func considerStudioCanonTending(runNow: Bool = false, reply: MindClockReply? = nil) {
        guard studioCanonAdmitted(explicit: runNow), sourceWakes.canonReady, studioCanonTask == nil else {
            reply?(.init("held", "Canon admission is closed, sources are not ready, a tending pass is running, or the runtime is stopping.")); return
        }
        let at = now()
        if let due = sourceWakes.canonNextAt, due <= at { sourceWakes.canonDirty = true }
        guard runNow || sourceWakes.canonDirty else { return }
        if !runNow, let last = lastStudioCanonTendingAt,
           at.timeIntervalSince(last) < Self.studioCanonTendingMinimumInterval {
            return
        }
        lastStudioCanonTendingAt = at
        sourceWakes.canonDirty = false
        sourceWakes.canonNextAt = nil
        studioCanonTask = Task { [weak self] in
            guard let self else { reply?(.init("unavailable", "The runtime was released.")); return }
            let result = await self.runStudioCanonTending(satisfyWait: runNow)
            reply?(result)
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
    private func runStudioCanonTending(satisfyWait: Bool = false) async -> MindClockResult {
        guard studioCanonAdmitted(explicit: satisfyWait) else { return .init("held", "The tending pass stopped or canon admission is closed.") }
        let report: StudioCanonTendingReport
        do {
            let host = self.host, root = dataRoot
            report = try await StudioCanonTending.run(dataRoot: root, now: now(), deadlineDate: Self.deskDate,
                admitEffects: { [weak self] in
                    guard let self, await self.studioCanonAdmitted(explicit: satisfyWait) else { throw CancellationError() }
                }) { input in
                guard case .object(var facts) = input else {
                    throw PersistenceCoreError.ioFailure("Canon's native evidence is not an object.")
                }
                facts["satisfy_wait"] = .bool(satisfyWait)
                return try await host.callReadPart(id: "studio-canon", input: .object(facts), actions: [],
                    dataRoot: root, origin: "studio_canon:proposals")
            }
        } catch {
            nativeLog("[StudioCanon] Tending deferred: %@", error.localizedDescription)
            await substrate.recordReceipt(kind: "studio.canon_tending_unavailable", payload: .object([
                "reason": .string(error.localizedDescription), "proposals": .array([]),
            ]))
            return .init("unavailable", error.localizedDescription)
        }
        let stopped = isFlushedForTermination || Task.isCancelled
        let failures = report.failures
        let result = MindClockResult(!failures.isEmpty ? "unavailable" : stopped ? "held" : "evaluated",
            "\(report.stagedApprovalIDs.count) proposed of \(report.evaluatedWorks) works; canonization still requires her seat."
                + (failures.isEmpty ? "" : " " + failures.joined(separator: " ")), fields: [
            "proposals": .array(report.stagedApprovalIDs.map(JSONValue.string)),
            "evaluatedWorks": .int(Int64(report.evaluatedWorks)),
            "graphAvailable": .bool(report.audit.graphAvailable),
            "auditReadFailure": report.auditReadFailure.map(JSONValue.string) ?? .null,
            "auditPersistenceFailure": report.auditPersistenceFailure.map(JSONValue.string) ?? .null,
            "stagingFailure": report.stagingFailure.map(JSONValue.string) ?? .null,
            "proposalFailures": .array(report.proposalFailures.map(JSONValue.string)),
            "savedCardGaps": .array(report.savedCardGaps.map(JSONValue.string)),
            "satisfy_wait": .bool(satisfyWait)
        ])
        // The pass may have committed cards before cancellation or a later failure.
        // Always publish their receipt and carry their identities in the reply.
        sourceWakes.canonNextAt = report.nextAt
        OrganPulse.record("studio_canon", found: report.stagedApprovalIDs.count,
                          note: "\(report.stagedApprovalIDs.count) proposed of \(report.evaluatedWorks) works")
        if !failures.isEmpty {
            // Automatic passes have no reply callback. Their exact failures
            // and already-committed cards still need a durable receipt.
            await substrate.recordReceipt(kind: "studio.canon_tending_unavailable", payload: .object(result.fields))
        }
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
        guard report.audit.graphAvailable else { return result }
        let verdict = report.audit.isConsistent
            ? "consistent"
            : "inconsistent:\(report.audit.mismatches.count)"
        guard lastStudioRelationAuditVerdict != verdict else { return result }
        lastStudioRelationAuditVerdict = verdict
        guard !report.audit.isConsistent else { return result }
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
        return result
    }

}
