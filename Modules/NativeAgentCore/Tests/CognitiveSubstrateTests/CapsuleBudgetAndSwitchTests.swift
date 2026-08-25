import Foundation
import Testing
import NativeAgentCore
@testable import CognitiveSubstrate

// Ledger rows `setting.config.maximumCapsuleCharacters` and
// `setting.config.capsuleInjectionEnabled` (core.substrate.affect).
//
// Both fail SILENTLY. Lowering the budget drops tail lines in order and sets
// only a `truncated` flag — the instrument reports capsule BYTES and asserts no
// budget, so a shrink reads as "she got quieter". Turning the switch off returns
// a `mode:.off` capsule with empty strings, `prepareCapsule` then returns nil,
// and the turn simply carries no inner state — indistinguishable in the chat
// from a quiet capsule.
//
// So: the cap is proven to be a HARD cap over a sweep, `truncated` is proven
// honest, and the off-switch is proven to actually be off rather than merely
// quiet.
@Suite("CapsuleBudgetAndSwitch")
struct CapsuleBudgetAndSwitchTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A substrate holding enough felt material that the capsule carries several
    /// lines — otherwise a budget sweep proves nothing.
    private func seededSubstrate(
        capsuleInjectionEnabled: Bool = true,
        maximumCapsuleCharacters: Int = 1_800
    ) async -> CognitiveSubstrate {
        let substrate = AffectFenceFixture.substrate(
            clock: AffectFenceClock(now),
            configuration: AffectFenceFixture.configuration(
                capsuleInjectionEnabled: capsuleInjectionEnabled,
                maximumCapsuleCharacters: maximumCapsuleCharacters))
        await substrate.ingest(CognitiveEvent(
            id: "budget-sting",
            kind: .userCorrection,
            subject: CognitiveSubjectReference(type: "topic", id: "budget", label: "budget"),
            sourceClass: .userStated,
            occurredAt: now,
            summary: "that approach was wrong and set us back a whole afternoon",
            importance: 1))
        await substrate.ingest(CognitiveEvent(
            id: "budget-warm",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat", id: "user", label: "User"),
            sourceClass: .userStated,
            occurredAt: now,
            summary: "miss you — how are you feeling about the rewrite?",
            importance: 0.8))
        return substrate
    }

    private func brittleProjection() -> OrganismProjection {
        OrganismProjection(
            generatedAt: now,
            bodyLine: "- Body: provider or tool path feels brittle; be careful before claiming completion.",
            chemicalState: ChemicalState(vigilance: 0.3, confidence: 0.44, urgency: 0.2),
            bodySchema: BodySchema(providersHealthy: false))
    }

    private func request(_ budget: Int?) -> CognitiveCapsuleRequest {
        CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "keep going please",
            sessionId: "budget-session",
            mode: .inject,
            maximumCharacters: budget,
            organismProjection: brittleProjection())
    }

    /// THE HARD CAP. Every budget in the sweep is respected exactly — the
    /// capsule never spends a byte it was not given — and shrinking the budget
    /// never grows the capsule.
    @Test func theBudgetIsAHardCapAndShrinkingItNeverGrowsTheCapsule() async {
        let substrate = await seededSubstrate()
        let full = await substrate.compileCapsule(request(nil))
        #expect(!full.dynamicContext.isEmpty, "the fixture must produce a non-empty capsule")

        var overruns: [(Int, Int)] = []
        var lengths: [Int] = []
        for budget in stride(from: full.combined.count + 40, through: 20, by: -10) {
            let capsule = await substrate.compileCapsule(request(budget))
            if capsule.combined.count > budget { overruns.append((budget, capsule.combined.count)) }
            lengths.append(capsule.combined.count)
        }
        #expect(overruns.isEmpty, "the capsule overran its budget at: \(overruns)")
        #expect(lengths.contains { $0 < full.combined.count },
                "the sweep never actually constrained anything — vacuous")
    }

    /// `truncated` is the ONLY signal that content was lost, so it has to be
    /// honest in both directions: false when everything fit, true whenever the
    /// capsule is shorter than the unconstrained one.
    @Test func theTruncatedFlagIsHonestInBothDirections() async {
        let substrate = await seededSubstrate()
        let full = await substrate.compileCapsule(request(nil))
        #expect(!full.truncated, "an unconstrained capsule must not claim truncation")

        var dishonest: [Int] = []
        for budget in stride(from: full.combined.count - 1, through: 24, by: -7) {
            let capsule = await substrate.compileCapsule(request(budget))
            let lostContent = capsule.dynamicContext != full.dynamicContext
                || capsule.stableKernel != full.stableKernel
            if lostContent && !capsule.truncated { dishonest.append(budget) }
        }
        #expect(dishonest.isEmpty, "content was dropped without setting truncated at budgets: \(dishonest)")
    }

    /// A budget of zero is the degenerate end of the same contract: nothing is
    /// emitted, and it says so.
    @Test func aZeroBudgetEmitsNothingAndAdmitsIt() async {
        let substrate = await seededSubstrate()
        let capsule = await substrate.compileCapsule(request(0))
        #expect(capsule.stableKernel.isEmpty)
        #expect(capsule.dynamicContext.isEmpty)
        #expect(capsule.truncated, "an empty capsule caused by the budget must be marked truncated")
    }

    /// THE DEAD SWITCH. Off means off — mode `.off`, no kernel, no lines — on the
    /// exact same substrate state that produces a full capsule when it is on.
    @Test func theInjectionSwitchIsOffNotMerelyQuiet() async {
        let on = await seededSubstrate(capsuleInjectionEnabled: true)
        let off = await seededSubstrate(capsuleInjectionEnabled: false)

        let live = await on.compileCapsule(request(nil))
        let dark = await off.compileCapsule(request(nil))

        #expect(!live.combined.isEmpty, "the on-state control produced nothing — the test is vacuous")
        #expect(dark.mode == .off, "the capsule must report itself off, not merely empty")
        #expect(dark.stableKernel.isEmpty)
        #expect(dark.dynamicContext.isEmpty)
        #expect(dark.combined.isEmpty)
        #expect(dark.provenanceNodeIds.isEmpty)
    }

    /// `mode: .off` on the REQUEST is the per-turn peer of the switch and must
    /// behave identically — a caller opting out cannot be told it is on.
    @Test func anOffRequestModeIsAlsoOff() async {
        let substrate = await seededSubstrate()
        let capsule = await substrate.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat",
            userMessage: "keep going please",
            sessionId: "budget-session",
            mode: .off,
            organismProjection: brittleProjection()))
        #expect(capsule.mode == .off)
        #expect(capsule.combined.isEmpty)
    }
}
