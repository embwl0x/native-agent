import Testing
import Foundation
@testable import CognitiveSubstrate

// Felt body-line refinement: the positive/steady region now grades by intensity
// and blends the top two active dimensions, instead of one frozen sentence for
// any warmth >= 0.22. Stress/warning lines stay first-match (their phrasing is
// the behavioral signal).
struct OrganismBodyLineTests {
    @Test func warmthGradesByIntensity() {
        #expect(OrganismChemistry.positiveBodyLine(ChemicalState(warmth: 0.30)) == "- Body: quietly warm and steady.")
        #expect(OrganismChemistry.positiveBodyLine(ChemicalState(warmth: 0.50)) == "- Body: warm and steady.")
        #expect(OrganismChemistry.positiveBodyLine(ChemicalState(warmth: 0.70)) == "- Body: warm and open.")
    }

    @Test func blendsTopTwoDimensionsLeadFirst() {
        // warmth 0.50 is the stronger signal (lead), curiosity 0.30 rides second.
        let line = OrganismChemistry.positiveBodyLine(ChemicalState(warmth: 0.50, curiosity: 0.30))
        #expect(line == "- Body: warm and steady, faintly curious.")
    }

    @Test func nilWhenNothingFeltStrongly() {
        // Neutral: warmth/curiosity 0, coherence/confidence 0.5 (< the 0.65/0.62 gate).
        #expect(OrganismChemistry.positiveBodyLine(.neutral) == nil)
    }

    @Test func deterministicOnEqualWeights() {
        // warmth == curiosity == 0.50: equal weight → tie breaks on phrase text,
        // so "curious" sorts before "warm and steady" and leads. Stable every run.
        let line = OrganismChemistry.positiveBodyLine(ChemicalState(warmth: 0.50, curiosity: 0.50))
        #expect(line == "- Body: curious, warm and steady.")
    }

    @Test func stressLineStillWinsOverPositive() {
        // Regression: a stress signal (high vigilance) must still pre-empt the
        // positive region even when warmth is high — the warning is load-bearing.
        let c = ChemicalState(warmth: 0.60, vigilance: 0.30)
        let p = OrganismChemistry.projection(at: Date(timeIntervalSince1970: 0), chemicalState: c, bodySchema: .neutral)
        #expect(p.bodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
    }

    @Test func unknownProviderEvidenceDoesNotClaimABrittlePath() {
        // The compatibility Bool maps unknown provider evidence to false. The
        // chemistry already declines to treat that as a failure; the prompt
        // line must agree, or sparse evidence writes "brittle" into the turn.
        let now = Date(timeIntervalSince1970: 0)
        let uncertain = ProviderPathBeliefProjection(
            generatedAt: now,
            estimate: 0.5,
            freshness: 0.8,
            uncertainty: 0.7,
            evidenceCount: 2,
            newestEvidenceAt: now,
            state: .uncertain,
            bodySchemaProvidersHealthy: nil
        )
        #expect(uncertain.bodySchemaProvidersHealthy == nil)
        let body = BodySchema(providersHealthy: false, providerPathBelief: uncertain)
        let p = OrganismChemistry.projection(at: now, chemicalState: .neutral, bodySchema: body)
        #expect(p.bodyLine != "- Body: provider or tool path feels brittle; be careful before claiming completion.")
    }

    @Test func observedBrittleProviderStillWarns() {
        // Regression guard: a belief that actually reads brittle must keep the
        // warning. Only unknown was ever the bug.
        let now = Date(timeIntervalSince1970: 0)
        let brittle = ProviderPathBeliefProjection(
            generatedAt: now,
            estimate: 0.1,
            freshness: 0.8,
            uncertainty: 0.2,
            evidenceCount: 6,
            newestEvidenceAt: now,
            state: .brittle,
            bodySchemaProvidersHealthy: false
        )
        #expect(brittle.bodySchemaProvidersHealthy == false)
        let body = BodySchema(providersHealthy: false, providerPathBelief: brittle)
        let p = OrganismChemistry.projection(at: now, chemicalState: .neutral, bodySchema: body)
        #expect(p.bodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
    }

    @Test func coherenceAndConfidenceGradeWithinHighBand() {
        // The gate is coherence>=0.65 && confidence>=0.62, so it only ever fires in
        // the high range; grade within it: 0.62–0.8 → "settled and clear", >=0.8 →
        // "clear and sure". (Both reachable — no dead strings.)
        #expect(OrganismChemistry.positiveBodyLine(ChemicalState(coherence: 0.70, confidence: 0.70)) == "- Body: settled and clear.")
        #expect(OrganismChemistry.positiveBodyLine(ChemicalState(coherence: 0.85, confidence: 0.85)) == "- Body: clear and sure.")
    }
}
