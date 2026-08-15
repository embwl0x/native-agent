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
