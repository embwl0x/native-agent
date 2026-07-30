import Testing
import Foundation
@testable import CognitiveSubstrate

// Affect convergence: the organism's warmth and urgency DERIVE from the
// substrate's canonical affect instead of computing independent second copies.
// Since d0bcd775 both axes cross together via refreshBodySchema's
// `canonicalAffect` parameter (one actor admission) — the old per-axis
// integrateCanonical* pulls were deleted in the 2026-07-18 tightness round 2.
// These pin the LIVE path's invariants: adopt, nil-keeps-own, disabled-ignores,
// and clamping.
struct OrganismWarmthConvergenceTests {
    private func affect(warmth: Double, pressure: Double) -> CognitiveAffectState {
        CognitiveAffectState(
            taskPressure: pressure,
            socialWarmth: warmth,
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    @Test func adoptsCanonicalAffectWhenEnabled() async {
        let kernel = OrganismKernel(configuration: .enabled)
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: affect(warmth: 0.5, pressure: 0.6)
        )
        let snap = await kernel.snapshot()
        #expect(abs(snap.chemicalState.warmth - 0.5) < 0.000_001)
        #expect(abs(snap.chemicalState.urgency - 0.6) < 0.000_001)
    }

    @Test func nilCanonicalAffectKeepsOwnValues() async {
        // nil = affect disabled → no canonical source, so the organism keeps
        // whatever warmth/urgency it already holds (never zeroed out).
        let kernel = OrganismKernel(configuration: .enabled)
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: affect(warmth: 0.4, pressure: 0.3)
        )
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: nil
        )
        let snap = await kernel.snapshot()
        #expect(abs(snap.chemicalState.warmth - 0.4) < 0.000_001)
        #expect(abs(snap.chemicalState.urgency - 0.3) < 0.000_001)
    }

    @Test func disabledKernelIgnoresCanonicalAffect() async {
        let kernel = OrganismKernel(configuration: .disabled)
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: affect(warmth: 0.9, pressure: 0.9)
        )
        let snap = await kernel.snapshot()
        #expect(snap.chemicalState.warmth == 0)
        #expect(snap.chemicalState.urgency == 0)
    }

    @Test func canonicalAffectIsClamped() async {
        let kernel = OrganismKernel(configuration: .enabled)
        await kernel.refreshBodySchema(
            OrganismBodyRead(memoryHealthy: true),
            canonicalAffect: affect(warmth: 1.7, pressure: -0.4)
        )
        let snap = await kernel.snapshot()
        #expect(snap.chemicalState.warmth == 1.0)
        #expect(snap.chemicalState.urgency == 0.0)
    }
}
