import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Studio
import NativeAgentShared
// Blueprint: | `NativeCognitionRuntime+StudioCanon.swift` | NativeCognitionRuntime+StudioCanon owner. |

// Share the organism deadline, 30-minute throttle and background-cognition gate.
extension NativeCognitionRuntime {

    private func studioCanonAdmitted(explicit: Bool) -> Bool {
        let configuration = Self.loadConfiguration(
            defaults: preferenceDefaults, environment: configurationEnvironment)
        return !isFlushedForTermination && !Task.isCancelled && configuration.enabled
            && (explicit || configuration.backgroundMicrocyclesEnabled)
    }

    /// Throttle journal/graph reads because rescheduling can fire repeatedly under load.
    static let studioCanonTendingMinimumInterval: TimeInterval = 30 * 60

    func considerStudioCanonTending(runNow: Bool = false, reply: MindClockReply? = nil) {
        if !isFlushedForTermination, let off = clockOffReason(explicit: runNow) {
            if let reply { reply(.off(off)) } else { beat(.canon, .off(off)) }
            return
        }
        guard studioCanonAdmitted(explicit: runNow), sourceWakes.canonReady, studioCanonTask == nil else {
            reply?(.init("held", "Canon sources are not ready, a tending pass is running, or the runtime is stopping.")); return
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
            if let reply { reply(result) } else { await self.beat(.canon, result) }
            await self.finishStudioCanonTask()
        }
    }

    private func finishStudioCanonTask() async {
        studioCanonTask = nil
        await rescheduleResidualRepairDeadline()
    }

    /// Coalesce source invalidations on the existing deadline.
    /// Stage proposals only; appendCanonRow requires the agent's seat before any canonical write.
    private func runStudioCanonTending(satisfyWait: Bool = false) async -> MindClockResult {
        guard studioCanonAdmitted(explicit: satisfyWait) else { return .init("stopped", "The tending pass stopped or canon admission closed.") }
        let report: StudioCanonTendingReport
        do {
            let host = self.host, root = dataRoot
            // Tending is the mind's own background pass: no turn holds it, and it never hands back.
            report = try await StudioCanonTending.run(turn: nil, handsBack: false, dataRoot: root, now: now(), deadlineDate: Self.deskDate,
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
        let result = MindClockResult(!failures.isEmpty ? "unavailable" : stopped ? "stopped" : "evaluated",
            "\(report.stagedApprovalIDs.count) proposed of \(report.evaluatedWorks) works; canonization still requires the agent's seat."
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
        ], yield: report.stagedApprovalIDs.count)
        // Publish committed cards and receipts even if later work fails or is cancelled.
        sourceWakes.canonNextAt = report.nextAt
        if !failures.isEmpty {
            // Automatic passes lack reply callbacks, so persist exact failures and committed card identities.
            await substrate.recordReceipt(kind: "studio.canon_tending_unavailable", payload: .object(result.fields))
        }
        if !report.stagedApprovalIDs.isEmpty {
            await substrate.recordReceipt(
                kind: "studio.canon_proposed",
                payload: .object([
                    "proposals": .array(report.stagedApprovalIDs.map { .string($0) }),
                    "evaluatedWorks": .int(Int64(report.evaluatedWorks)),
                    "duplicatesSkipped": .int(Int64(report.duplicatesSkipped)),
                    // Identify each mint as a request rather than an act.
                    "soleApprover": .string(StudioCanonSeat.agent),
                    "autoCanonization": .bool(false),
                ])
            )
        }
        // Surface uncited relations without repairing them; announce only changes so unresolved mismatches cannot repeat every pass.
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
