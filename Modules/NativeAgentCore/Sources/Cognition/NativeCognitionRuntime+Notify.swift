import Privacy
import AgentWorkspace
import ChatToolRuntime
import CognitiveSubstrate
import Foundation
import NativeAgentCore
import NotificationInbox
import PersonaEngine
import PersistenceCore
import MemoryV2

// Blueprint: | `NativeCognitionRuntime+Notify.swift` | `NativeCognitionRuntime.innerStateReading`. |

// Read substrate and organism together for one inner-state answer.

extension NativeCognitionRuntime: InnerStateProviding {

    /// Await only the existing bootstrap, then read warmth from the owner of the current felt nodes.
    public func moodWarmth() async -> Double {
        guard let bootstrapTask else { return 0 }
        await bootstrapTask.value
        guard bootstrapFailure == nil else { return 0 }
        return await substrate.moodWarmth()
    }

    /// Inner-state reads must not change feelings: peek substrate state and decay only a frozen body copy, never settle the live kernel.
    public func innerStateReading(
        windowHours: Double,
        detail: CognitiveInnerStateReading.Detail,
        surface: String = "chat"
    ) async -> CognitiveInnerStateReading {
        // A read may await an existing bootstrap but cannot start one.
        guard let bootstrapTask else {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        await bootstrapTask.value
        if bootstrapFailure != nil {
            return .unavailable(at: now(), windowHours: windowHours, detail: detail)
        }
        let at = now()
        let frozen = await organismKernel.frozenRead(at: at)
        // Disabled body state is absent, never fabricated zeroes.
        let organism = CognitiveInnerStateOrganismReads(
            projection: frozen.snapshot.enabled ? frozen.projection : nil,
            fatigue: frozen.snapshot.enabled ? frozen.snapshot.chemicalState.fatigue : nil,
            // Use the diurnal value the frozen projection actually applied so words and chemistry describe the same instant.
            diurnal: frozen.snapshot.enabled ? frozen.projection.diurnal : nil,
            toward: frozen.toward,
            expectations: await pendingStakeBearingExpectations(at: at),
            personDayTitle: AgentScreen.names(dataRoot).person + "'s day, as I know it",
            personDay: rhythm.value?.claims.map {
                $0.words(person: AgentScreen.names(dataRoot).person, day: at)
                    + ($0.confidence >= 0.7 ? " Sure." : " Fairly sure.")
            } ?? []
        )
        return await substrate.innerStateReading(
            windowHours: windowHours,
            detail: detail,
            organism: organism,
            surface: MemoryRecordDisclosurePolicy.canonicalSurface(surface),
            at: at
        )
    }

    /// Read only person- or promise-bearing expectations without settling the ledger.
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
                // Use the substrate's human label rather than the enum case name.
                label: kind.humanLabel,
                due: prediction.dueAt,
                // Use valence sign alone to distinguish anticipation from bracing, matching prospective-affect modulation.
                valenceSign: prediction.confidence >= 0.5 ? 1 : -1
            ))
        }
        return out.sorted { $0.due < $1.due }
    }
}
