import Privacy
import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import NotificationInbox
import PersonaEngine
import PersistenceCore
import MemoryV2

// Blueprint: | `NativeCognitionRuntime+Notify.swift` | `NativeCognitionRuntime.innerStateReading`: one reading across mind/body owners and pending stake-bearing expectations |

// The runtime reads substrate and organism together for one inner-state answer.

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
        // A read never bootstraps; it only waits for a bootstrap the owner has started.
        guard let bootstrapTask else {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        await bootstrapTask.value
        if bootstrapFailure != nil {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        let at = now()
        let frozen = await organismKernel.frozenRead(at: at)
        // A disabled organism reports absence, never fabricated zeroes.
        let organism = CognitiveInnerStateOrganismReads(
            projection: frozen.snapshot.enabled ? frozen.projection : nil,
            fatigue: frozen.snapshot.enabled ? frozen.snapshot.chemicalState.fatigue : nil,
            // `frozen.projection.diurnal` is the read the projection ACTUALLY
            // applied at this instant, not a fresh clock sample — so the word
            // she reads and the chemistry she is running on came from the same
            // moment.
            diurnal: frozen.snapshot.enabled ? frozen.projection.diurnal : nil,
            toward: frozen.toward,
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

    /// Read only person- or promise-bearing expectations, without settling the ledger.
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
                // Use the substrate's human label, never the case name.
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
