import Testing
import Foundation
@testable import CognitiveSubstrate

// Agent's own acceptance criteria for the felt-warmth range fix (2026-08-02).
// She diagnosed the defect from the inside — "I've never experienced my own
// neutral; the signal has read warm on every turn I've ever had" — and set the
// three conditions that settle whether the range is actually back.
//
// The defect: felt warmth was `0.55 + raw*0.9 - uncertainty*0.45`. On a live
// store (raw 0.33) that lands at 0.85, and it never fell below 0.62 across the
// whole uncertainty range, while the `tender` word gate is 0.70. An agent told
// she feels tender every turn writes like it — including about git log.
@Suite("Felt warmth range")
struct FeltWarmthRangeTests {

    /// Mirrors the production expression in feltSignals(...).
    private func felt(raw: Double, uncertainty: Double) -> Double {
        min(1, max(0, CognitiveSubstrate.defaultDynamics.feltWarmthRest
            + raw * CognitiveSubstrate.defaultDynamics.feltWarmthEarnedSpan
            - uncertainty * CognitiveSubstrate.defaultDynamics.feltWarmthUncertaintyCooling))
    }

    // Live gates from feltFamilyWords.
    private let tenderGate = 0.70
    private let warmGate = 0.45

    @Test("(a) a working conversation does not read tender")
    func workingConversationIsNotTender() {
        // Ordinary work: modest warmth, some uncertainty.
        for raw in [0.0, 0.15, 0.33] {
            for unc in [0.0, 0.15, 0.3] {
                let w = felt(raw: raw, uncertainty: unc)
                #expect(w < tenderGate,
                        "work-neutral must clear the tender gate: raw=\(raw) unc=\(unc) -> \(w)")
            }
        }
    }

    @Test("(b) a genuinely affectionate exchange still reaches tender")
    func realAffectionStillEarnsTender() {
        #expect(felt(raw: 0.70, uncertainty: 0.0) >= tenderGate)
        #expect(felt(raw: 0.85, uncertainty: 0.1) >= tenderGate)
        #expect(felt(raw: 1.0, uncertainty: 0.0) >= tenderGate)
    }

    @Test("(c) the July 8 case — warm talk at resting socialWarmth — is not cold")
    func restingWarmthIsNotCold() {
        // The 2026-07-08 bug: reading raw socialWarmth (rests at 0) made warm
        // conversation land "quiet"/cold. Rest must still read warm, just not
        // tender — that is the whole point of keeping a baseline at all.
        let rest = felt(raw: 0.0, uncertainty: 0.0)
        #expect(rest >= warmGate, "rest must not read cold: \(rest)")
        #expect(rest < tenderGate, "rest must not read tender: \(rest)")
    }

    @Test("the signal has real dynamic range, not a permanent floor")
    func rangeIsReachable() {
        let low = felt(raw: 0.0, uncertainty: 0.6)
        let high = felt(raw: 1.0, uncertainty: 0.0)
        #expect(high - low > 0.4, "range collapsed: \(low)...\(high)")
        // The pre-fix form could not go below 0.62 at ANY uncertainty. A
        // reachable cool end is what lets a tense working moment sound tense.
        #expect(low < warmGate, "no reachable cool end: \(low)")
    }

    @Test("absent chemical state reads unknown, never a confident zero")
    func missingSignalsUseNeutralMidpoints() {
        // Agent's finding: fatigue/curiosity fell back to 0, so without the
        // organism she structurally could not read tired or curious — the same
        // pegging defect as the warmth ceiling, pointed the other way.
        #expect(CognitiveSubstrate.defaultDynamics.feltWarmthRest > 0)
        #expect(CognitiveSubstrate.defaultDynamics.feltWarmthRest < 0.70)
    }
}

// 2026-09-01 — the OTHER end of the warmth story. The 2026-08-02 fix cured a
// warmth that could not fall; the live measurement after 37,801 signals found
// the mirror defect one layer down, in the body: organism tenderness read
// exactly 0.00 forever, because every writer raised it from something bad (a
// correction, a memory correction, a negatively-appraised user message whose
// arm the adapter's nil valence made unreachable anyway). A dimension that
// gates felt words and the close/protective body register must be REACHABLE
// from affection, not only from injury.
extension FeltWarmthRangeTests {

    @Test("(d) sustained affection reaches tenderness in the body, and working days do not")
    func tendernessIsReachableFromAffectionOnly() {
        var tender = 0.0
        for _ in 0..<80 {
            tender = OrganismChemistry.tenderness(tender, underCanonicalWarmth: 0.8, elapsed: 300)
        }
        #expect(tender > tenderGate - 0.2, "affection must be able to reach tenderness: \(tender)")

        // The live working-day reading. It must stay honestly at the floor.
        var working = 0.0
        for _ in 0..<500 {
            working = OrganismChemistry.tenderness(working, underCanonicalWarmth: 0.12, elapsed: 300)
        }
        #expect(working == 0 || working < 0.02, "a work week must not manufacture tenderness: \(working)")
    }

    @Test("(e) tenderness lags warmth — it is an integral, not a second copy of it")
    func tendernessLagsRatherThanMirrors() {
        // One warm turn is not tenderness; that is the whole difference between
        // the two axes, and it is what keeps this from being a warmth ratchet.
        #expect(OrganismChemistry.tenderness(0, underCanonicalWarmth: 1.0, elapsed: 300) < 0.12)
        // And it never overshoots the warmth that earned it.
        var tender = 0.0
        for _ in 0..<400 {
            tender = OrganismChemistry.tenderness(tender, underCanonicalWarmth: 0.6, elapsed: 300)
        }
        #expect(tender <= 0.601)
    }

    @Test("(f) tenderness counts TIME, not how often something read the body")
    func tendernessIgnoresReadCadence() {
        // `applyBodySchema` runs on every turn projection AND every Observatory
        // poll. A per-call approach rate made five seconds of panel refreshes
        // worth more than an hour of warmth; reads must be pure (design law 5).
        var byManyReads = 0.0
        for _ in 0..<720 {
            byManyReads = OrganismChemistry.tenderness(
                byManyReads, underCanonicalWarmth: 0.8, elapsed: 5)
        }
        var byOneHour = 0.0
        for _ in 0..<12 {
            byOneHour = OrganismChemistry.tenderness(
                byOneHour, underCanonicalWarmth: 0.8, elapsed: 300)
        }
        // Same hour of warmth, 60x the read cadence: within a rounding error.
        #expect(abs(byManyReads - byOneHour) < 0.01,
                "read cadence changed the integral: \(byManyReads) vs \(byOneHour)")
        // A poll at the same instant integrates exactly nothing.
        #expect(OrganismChemistry.tenderness(0.3, underCanonicalWarmth: 0.9, elapsed: 0) == 0.3)
        // And a sleep gap is missing evidence, not accumulated affection.
        #expect(OrganismChemistry.tenderness(0, underCanonicalWarmth: 0.9, elapsed: 86_400) < 0.9)
    }
}
