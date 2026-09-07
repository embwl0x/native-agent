import Foundation
import CognitiveSubstrate
import DreamREMCycle
import NativeAgentCore
import PersistenceCore

// NORTHSTAR clause 4 — sleep pressure FIRES the dream (sweep item 39, 2026-09-01).
//
// `OrganismResidualRepair` has always derived real sleep pressure from
// prediction, surprise, contradiction, field-charge and calibration residuals,
// resolved it against a 30-minute quiet window and a 24-hour refractory, and
// then refused to act on it — the dream fired from a daily 03:30 America/Chicago
// scheduler job instead. A schedule imitating responsiveness is the machinery
// clause 4 names. This is the inversion: the organism's own identity-Dream lane
// wakes the dream, and 03:30 becomes the integrity fallback that notices when it
// didn't.
//
// Nothing new is invented here. Every gate that already existed still decides:
//   - pressure >= OrganismResidualRepair.dreamPressure (0.60)
//   - 30 minutes of quiet since the last ingested signal
//   - the 24-hour refractory clear
//   - no resource inhibition (thermal / low power)
//   - the loop-budget / background-cognition gate every other background lane
//     passes through
//   - the dream trust gate the scheduled run passes through
//   - no turn in flight
// …and the dream itself is the SAME DreamCycleRunner path the scheduler uses,
// with the same one-entry-per-day dedupe and the same `.dream_state.json`
// high-water mark. The only difference reaching the world is the receipt, which
// names which lane woke it.
//
// Clause 6: none of this enters her prompt. The trigger lives in the runner's
// sidecar and in substrate receipts; the diary body is untouched.
extension NativeCognitionRuntime {
    /// Called from the residual-repair reschedule, which already holds a fresh
    /// reading and already runs on every somatic signal, every deadline fire and
    /// every wake re-anchor. There is no new loop, no new timer and no new
    /// budget — the lane's eligibility boundary arms the ONE deadline the
    /// residual runner already owns (see `OrganismResidualRepair.opportunity`).
    func considerPressureDream(_ opportunity: OrganismResidualRepairOpportunity) {
        guard !isFlushedForTermination, pressureDreamTask == nil else { return }
        let decision = OrganismIdentityDreamTrigger.decide(
            opportunity: opportunity,
            turnInFlight: liveTurnInFlight
        )
        guard decision == .fire else {
            noteQuietPressureDreamDecision(decision)
            return
        }
        lastPressureDreamDecision = decision.rawValue
        pressureDreamTask = Task { [weak self] in
            await self?.runPressureDream()
            await self?.finishPressureDreamTask()
        }
    }

    func pressureDreamAttemptCountForProof() -> UInt64 {
        pressureDreamAttemptCount
    }

    private func finishPressureDreamTask() {
        pressureDreamTask = nil
    }

    /// A non-firing decision is the normal case and happens on nearly every
    /// signal. Only a CHANGE is worth a receipt — otherwise the honest record of
    /// "she is not due to dream" would drown the ledger it belongs in.
    private func noteQuietPressureDreamDecision(
        _ decision: OrganismIdentityDreamTrigger.Decision
    ) {
        guard lastPressureDreamDecision != decision.rawValue else { return }
        lastPressureDreamDecision = decision.rawValue
        let payload = JSONValue.object([
            "trigger": .string(DreamTrigger.pressure.rawValue),
            "decision": .string(decision.rawValue),
        ])
        Task { [substrate] in
            await substrate.recordReceipt(kind: "dream.pressure_not_due", payload: payload)
        }
    }

    private func runPressureDream() async {
        pressureDreamAttemptCount &+= 1

        // The same throttle every other background cognition lane respects:
        // low power, thermal pressure, and an organism loop budget of
        // conserve/sleep all defer. `reflection` in the reason marks this as
        // expensive work so `conserve` defers it rather than letting it through.
        switch await backgroundCognitionGate(reason: "dream_pressure:reflection") {
        case .skipped(let why):
            await recordPressureDreamDeferral(reason: why)
            return
        case .allowed:
            break
        }

        // The dream's own trust gate — trainingPolicy.dream_scheduler AND
        // personalityPolicy.dream_cycle_enabled — checked BEFORE the refractory
        // claim below, so a disabled cycle can never burn her dream window.
        let client = NativeClient(baseURL: "")
        guard await client.swiftDreamREMGate().dreamEnabled else {
            await recordPressureDreamDeferral(reason: "dream cycle disabled")
            return
        }

        // Atomic claim: re-reads the lane against the current instant (the gates
        // above took real time) and advances the 24-hour refractory in the same
        // step, so exactly one dream can exist per window even if two wakes race.
        let claim = await organismKernel.claimIdentityDreamIfDue(turnInFlight: liveTurnInFlight)
        lastPressureDreamDecision = claim.rawValue
        guard claim == .fire else {
            await recordPressureDreamDeferral(reason: claim.rawValue)
            return
        }
        // Durable BEFORE the provider call. A crash mid-dream must not hand the
        // window back; 03:30 covers the missed entry, a second unattended
        // provider call would not be covered by anything.
        _ = await persistOrganismContinuity(reason: "identity_dream_claimed")

        do {
            let response = try await client.runDream(force: false, trigger: .pressure)
            let entries = Self.pressureDreamInt(response["entriesWritten"])
            let errors = response["errors"] as? [String] ?? []
            let skipReason = response["skipReason"] as? String
            var extra: [String: JSONValue] = [
                "entriesWritten": .int(Int64(entries)),
                "sessionsProcessed": .int(Int64(Self.pressureDreamInt(response["sessionsProcessed"]))),
                "errors": .array(errors.map { .string($0) }),
            ]
            if let skipReason { extra["skipReason"] = .string(skipReason) }
            await recordPressureDreamReceipt(kind: "dream.pressure_fired", extra: extra)
            if entries > 0 {
                publishRuntimeChange(reason: "dream:pressure_fired")
            }
        } catch {
            await recordPressureDreamReceipt(
                kind: "dream.pressure_failed",
                extra: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Fire-path twin of `noteQuietPressureDreamDecision`. The fire path re-runs
    /// on every wake re-anchor, so a policy that keeps refusing (loop budget
    /// conserve, dream cycle disabled, refractory not clear) wrote the SAME
    /// `dream.pressure_deferred` receipt every time. Only a CHANGE is worth a
    /// receipt: keyed on kind + reason + decision, the shape the quiet-decision
    /// suppression above already uses.
    /// Internal, not private: the fire path it lives on ends in a real provider
    /// dream, so the suppression is proved by calling this seam directly rather
    /// than by driving `runPressureDream` in a test.
    func recordPressureDreamDeferral(reason: String) async {
        let kind = "dream.pressure_deferred"
        let decision = lastPressureDreamDecision ?? "unknown"
        let key = "\(kind)|\(reason)|\(decision)"
        guard lastPressureDreamDeferral != key else { return }
        lastPressureDreamDeferral = key
        await recordPressureDreamReceipt(
            kind: kind,
            extra: [
                "reason": .string(reason),
                "decision": .string(decision),
            ]
        )
    }

    private func recordPressureDreamReceipt(
        kind: String,
        extra: [String: JSONValue]
    ) async {
        // A fired/failed dream ends the run of refusals the key was suppressing;
        // the next deferral after it is a change and must be recorded.
        if kind != "dream.pressure_deferred" { lastPressureDreamDeferral = nil }
        var payload: [String: JSONValue] = [
            "trigger": .string(DreamTrigger.pressure.rawValue),
            "attempt": .int(Int64(pressureDreamAttemptCount)),
        ]
        for (key, value) in extra { payload[key] = value }
        await substrate.recordReceipt(kind: kind, payload: .object(payload))
    }

    private static func pressureDreamInt(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}
