import Privacy
import ChatOrchestration
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import NotificationInbox
import PersonaEngine
import PersistenceCore
import MemoryV2

// NativeCognitionRuntime+Notify.swift
// Personality depth item 3 (2026-09-02) — she is asked how she feels, so she
// READS the record. `InnerStateProviding` — the app runtime is the one object
// that owns both the substrate (mind) and the organism kernel (body), which is
// exactly what one honest answer needs. See CognitiveSubstrate+InnerState.swift.
//
// Item 12, the shoulder tap (a fixed push about a loud seed; two taps ever),
// was folded into her one initiative path in Phase 5 E1 (2026-10-03): see
// NativeCognitionRuntime+Reach.swift, which keeps its trigger and its knock.

// MARK: - Item 3: the runtime answers for the whole mind

extension NativeCognitionRuntime: InnerStateProviding {

    /// PURE. Every read below is a non-mutating peek: the substrate's own
    /// inner-state projection, and the organism's `frozenRead`, which decays a
    /// COPY at a fixed instant and never settles or rewrites the live kernel.
    /// Asking herself how she feels must not change how she feels (design law 5).
    public func innerStateReading(
        windowHours: Double,
        detail: CognitiveInnerStateReading.Detail,
        surface: String = "chat"
    ) async -> CognitiveInnerStateReading {
        // A READ MUST NEVER BOOTSTRAP (2026-09-02, reviewer HIGH). `bootstrap()`
        // restores persistent state, installs the process-global studio sink,
        // ingests an `appWake` event, arms two deadlines and publishes a runtime
        // change. Asking her how she feels must not START her — a question is
        // not a launch, and a tool call that silently boots the mind would make
        // "did she wake up?" depend on whether anyone asked.
        //
        // Same contract the frozen-mind read already keeps
        // (`NativeFrozenMindReadError.runtimeNotBootstrapped`): refuse before
        // the owner has started, and merely WAIT on a start the owner has
        // already begun.
        guard let bootstrapTask else {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        await bootstrapTask.value
        if bootstrapFailure != nil {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        let at = now()
        let frozen = await organismKernel.frozenRead(at: at)
        // ABSENCE READS AS ABSENCE (W4/P2's rule): with the organism off there
        // is no chemistry and no fatigue to report, and a zero would be a
        // fabricated calm rather than an honest silence.
        // The three sibling lanes in this wave have landed, so the reading is
        // whole: the body's clock (#3/#10), the forward-facing register (#4),
        // and the nag (#5). Each is still OPTIONAL at the type level — a body
        // with no clock configured, or a mind facing nothing, reports absence
        // rather than a plausible-looking default.
        //
        // The rumination candidate is NOT passed in: it is substrate-owned
        // (`ruminationCandidates(at:)`), so the reading computes it itself
        // rather than having the runtime marshal it back and forth.
        let organism = CognitiveInnerStateOrganismReads(
            projection: frozen.snapshot.enabled ? frozen.projection : nil,
            fatigue: frozen.snapshot.enabled ? frozen.snapshot.chemicalState.fatigue : nil,
            // `frozen.projection.diurnal` is the read the projection ACTUALLY
            // applied at this instant, not a fresh clock sample — so the word
            // she reads and the chemistry she is running on came from the same
            // moment.
            diurnal: frozen.snapshot.enabled ? frozen.projection.diurnal : nil,
            toward: await towardRead(),
            expectations: await pendingStakeBearingExpectations(at: at)
        )
        return await substrate.innerStateReading(
            windowHours: windowHours,
            detail: detail,
            organism: organism,
            surface: MemoryRecordDisclosurePolicy.canonicalSurface(surface),
            at: at
        )
    }

    /// What she is still waiting to find out — and ONLY the kinds whose subject
    /// is a person or a promise.
    ///
    /// D-2's allowlist, applied to expectations rather than resolutions:
    /// `approvalResolution` (a gate a PERSON has to walk through),
    /// `workflowAdvance` (a commitment moving) and `semanticExpectation` (how
    /// the work she just did will LAND). The five plumbing paths are excluded
    /// for exactly D-2's reason — "will the provider call complete" is not
    /// something a person is carrying, and reporting it as one is how the felt
    /// layer became noise the first time.
    ///
    /// Pure: a ledger dictionary read, no settle.
    private func pendingStakeBearingExpectations(
        at instant: Date
    ) async -> [CognitiveInnerStateReading.Expectation] {
        let kinds: [OrganismPredictionKind] = [
            .approvalResolution, .workflowAdvance, .semanticExpectation,
        ]
        var out: [CognitiveInnerStateReading.Expectation] = []
        for kind in kinds {
            guard let prediction = await organismKernel.latestPrediction(ofKind: kind),
                  prediction.status == .pending,
                  prediction.dueAt >= instant
            else { continue }
            out.append(CognitiveInnerStateReading.Expectation(
                // The substrate's own word for the kind, never the case name
                // (Agent read "semanticExpectation" on 2026-09-14).
                label: kind.humanLabel,
                due: prediction.dueAt,
                // The SIGN only, never the magnitude: a confident expectation is
                // something she is looking forward to, a low-confidence one is
                // something she is bracing for. Same split
                // `OrganismProspectiveAffect` uses to modulate the projection.
                valenceSign: prediction.confidence >= 0.5 ? 1 : -1
            ))
        }
        return out.sorted { $0.due < $1.due }
    }
}
