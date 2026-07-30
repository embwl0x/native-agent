import Foundation
import Testing
@testable import CognitiveSubstrate

/// Round 3 Wave A1: the exhale is sized to the held breath. A satisfied
/// outcome the body was BRACED for (low path confidence, uncertain
/// prediction, fresh violation shadow) releases more vigilance/urgency and
/// restores more confidence than the same outcome on a calm path — and a
/// calm path stays byte-identical to the pre-relief release.
@Suite("Organism relief (braced release)")
struct OrganismReliefTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func signal(_ kind: SomaticSignalKind, at: Date, intensity: Double = 0.8) -> SomaticSignal {
        SomaticSignal(
            id: UUID(), kind: kind, sourceOrgan: "tool:swift_build",
            occurredAt: at, intensity: intensity
        )
    }

    /// Runs start → toolStarted → (tune) → toolSucceeded, returns the
    /// chemistry delta of the resolution step alone.
    private func resolutionDelta(
        toolPath: Double,
        predictionConfidence: Double,
        predictionUncertainty: Double,
        recentViolation: Bool
    ) -> (vigilanceDrop: Double, urgencyDrop: Double, confidenceRise: Double) {
        var ledger = OrganismPredictionLedger()
        ledger.bodyConfidence.toolPath = toolPath
        if recentViolation { ledger.lastViolationAt = t0.addingTimeInterval(-120) }
        var chemistry = ChemicalState()
        chemistry.vigilance = 0.7
        chemistry.urgency = 0.6
        chemistry.confidence = 0.3
        let body = BodySchema()

        let started = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: t0),
            to: ledger, chemicalState: chemistry, bodySchema: body
        )
        var tunedLedger = started.ledger
        for (id, var p) in tunedLedger.predictions where p.status == .pending {
            p.confidence = predictionConfidence
            p.uncertainty = predictionUncertainty
            tunedLedger.predictions[id] = p
        }

        let before = started.chemicalState
        let resolved = OrganismPredictiveBody.applying(
            signal: signal(.toolSucceeded, at: t0.addingTimeInterval(30)),
            to: tunedLedger, chemicalState: before, bodySchema: started.bodySchema
        )
        let after = resolved.chemicalState
        return (
            vigilanceDrop: before.vigilance - after.vigilance,
            urgencyDrop: before.urgency - after.urgency,
            confidenceRise: after.confidence - before.confidence
        )
    }

    @Test func calmPathReleaseIsExactlyThePreReliefAmount() {
        // Confident path, confident prediction, no shadow → bracing 0 →
        // multiplier 1: the historical constants, untouched.
        let delta = resolutionDelta(
            toolPath: 0.9, predictionConfidence: 0.9,
            predictionUncertainty: 0.1, recentViolation: false
        )
        let i = 0.8
        #expect(abs(delta.vigilanceDrop - 0.04 * i) < 0.0001, "calm vigilance release must stay byte-identical: \(delta)")
        #expect(abs(delta.urgencyDrop - 0.04 * i) < 0.0001)
        #expect(abs(delta.confidenceRise - 0.03 * i) < 0.0001)
    }

    @Test func bracedResolutionExhalesHarder() {
        let calm = resolutionDelta(
            toolPath: 0.9, predictionConfidence: 0.9,
            predictionUncertainty: 0.1, recentViolation: false
        )
        // Dreaded path: body has little faith in tools, the prediction is
        // uncertain, and a violation two minutes ago keeps the shadow fresh.
        let braced = resolutionDelta(
            toolPath: 0.15, predictionConfidence: 0.2,
            predictionUncertainty: 0.9, recentViolation: true
        )
        #expect(braced.vigilanceDrop > calm.vigilanceDrop * 1.5,
                "the braced exhale must be markedly larger: \(calm) vs \(braced)")
        #expect(braced.urgencyDrop > calm.urgencyDrop * 1.5)
        #expect(braced.confidenceRise > calm.confidenceRise * 1.5)
    }

    @Test func overdueSuccessGetsTheBiggestExhaleNotAPunishment() {
        // Review ccd2f13456f8 High: due at t0+90, resolves at t0+91 — the
        // outcome the body braced hardest for. Expiry must not steal it.
        var ledger = OrganismPredictionLedger()
        ledger.bodyConfidence.toolPath = 0.15
        var chemistry = ChemicalState()
        chemistry.vigilance = 0.7
        chemistry.urgency = 0.6
        chemistry.confidence = 0.3

        let started = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: t0),
            to: ledger, chemicalState: chemistry, bodySchema: BodySchema()
        )
        var tuned = started.ledger
        for (id, var p) in tuned.predictions where p.status == .pending {
            p.confidence = 0.2
            p.uncertainty = 0.9
            p.dueAt = t0.addingTimeInterval(90)
            tuned.predictions[id] = p
        }

        let before = started.chemicalState
        let resolved = OrganismPredictiveBody.applying(
            signal: signal(.toolSucceeded, at: t0.addingTimeInterval(91)),
            to: tuned, chemicalState: before, bodySchema: started.bodySchema
        )
        // Satisfied, never expired, no violation stamped by its own lateness.
        #expect(resolved.ledger.satisfiedCount == 1)
        #expect(resolved.ledger.expiredCount == 0, "the resolving row must not be expired first")
        #expect(resolved.ledger.lastViolationAt == nil, "a late SUCCESS is not a violation")
        // And the exhale is the braced-sized one, not the calm constant.
        let vigilanceDrop = before.vigilance - resolved.chemicalState.vigilance
        #expect(vigilanceDrop > 0.04 * 0.8 * 1.5, "overdue success must carry braced relief: \(vigilanceDrop)")
    }

    @Test func unanticipatedSuccessMintsNoSyntheticRelief() {
        // Review ccd2f13456f8 Medium: no pending row exists (nothing was
        // anticipated) — a dreaded path + fresh shadow must NOT fabricate a
        // held breath for an outcome nothing predicted.
        var ledger = OrganismPredictionLedger()
        ledger.bodyConfidence.toolPath = 0.15
        ledger.lastViolationAt = t0.addingTimeInterval(-120)
        var chemistry = ChemicalState()
        chemistry.vigilance = 0.7
        chemistry.urgency = 0.6
        chemistry.confidence = 0.3

        let resolved = OrganismPredictiveBody.applying(
            signal: signal(.toolSucceeded, at: t0),
            to: ledger, chemicalState: chemistry, bodySchema: BodySchema()
        )
        let i = 0.8
        #expect(abs((chemistry.vigilance - resolved.chemicalState.vigilance) - 0.04 * i) < 0.0001,
                "no pending row → calm-constant release only")
        #expect(abs((resolved.chemicalState.confidence - chemistry.confidence) - 0.03 * i) < 0.0001)
    }

    @Test func repeatedStartStillExpiresItsOverdueRow() {
        // Review 25de444129c7: a second toolStarted with the same identity
        // must NOT refresh its own overdue row past the expiry sweep — the
        // missed expectation is real and keeps its violation stamp.
        var ledger = OrganismPredictionLedger()
        let chemistry = ChemicalState()
        let started = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: t0),
            to: ledger, chemicalState: chemistry, bodySchema: BodySchema()
        )
        var tuned = started.ledger
        for (id, var p) in tuned.predictions where p.status == .pending {
            p.dueAt = t0.addingTimeInterval(60)
            tuned.predictions[id] = p
        }
        ledger = tuned

        let restarted = OrganismPredictiveBody.applying(
            signal: signal(.toolStarted, at: t0.addingTimeInterval(100)),
            to: ledger, chemicalState: started.chemicalState, bodySchema: started.bodySchema
        )
        #expect(restarted.ledger.expiredCount == 1, "the overdue first expectation must expire, not be silently refreshed")
        #expect(restarted.ledger.lastViolationAt != nil)
        #expect(restarted.ledger.predictions.values.contains { $0.status == .pending }, "the new start still arms a fresh pending row")
    }

    @Test func sharedBracingHelperMatchesProjectionInputs() {
        // The helper the resolution reads is the SAME math modulate() uses:
        // a dreaded near-due prediction yields bracing > 0; a confident one 0.
        var ledger = OrganismPredictionLedger()
        ledger.bodyConfidence.toolPath = 0.2
        let dread = OrganismPrediction(
            id: "p1", kind: .toolCompletion, sourceOrgan: "tool:swift_build",
            createdAt: t0, dueAt: t0.addingTimeInterval(5), status: .pending,
            confidence: 0.2, uncertainty: 0.9, evidenceCount: 0, lastUpdatedAt: t0
        )
        let dreadShare = OrganismProspectiveAffect.predictionBracingContribution(dread, ledger: ledger, at: t0)
        #expect(dreadShare.bracing > 0.3)
        #expect(dreadShare.lookingForward == 0)

        ledger.bodyConfidence.toolPath = 0.95
        let confident = OrganismPrediction(
            id: "p2", kind: .toolCompletion, sourceOrgan: "tool:swift_build",
            createdAt: t0, dueAt: t0.addingTimeInterval(5), status: .pending,
            confidence: 0.95, uncertainty: 0.1, evidenceCount: 0, lastUpdatedAt: t0
        )
        let confidentShare = OrganismProspectiveAffect.predictionBracingContribution(confident, ledger: ledger, at: t0)
        #expect(confidentShare.bracing == 0)
        #expect(confidentShare.lookingForward > 0)
    }
}
