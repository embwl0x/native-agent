import Testing
import Foundation
@testable import CognitiveSubstrate

// Wave R2-D acceptance (2026-07-09): anticipatory affect — the body braces before
// the future arrives. Pending predictions modulate the PROJECTED chemistry only;
// empty ledger = byte-identical; caps hold under any load; pure/deterministic.
@Suite("ProspectiveAffect")
struct ProspectiveAffectTests {

    private func prediction(
        _ kind: OrganismPredictionKind,
        dueIn: TimeInterval,
        confidence: Double,
        uncertainty: Double = 0.5,
        now: Date
    ) -> OrganismPrediction {
        OrganismPrediction(
            id: UUID().uuidString, kind: kind, sourceOrgan: "test",
            createdAt: now.addingTimeInterval(-60), dueAt: now.addingTimeInterval(dueIn),
            status: .pending, confidence: confidence, uncertainty: uncertainty,
            evidenceCount: 3, lastUpdatedAt: now)
    }

    private let base = ChemicalState(vigilance: 0.2, curiosity: 0.3, confidence: 0.6, urgency: 0.2)

    /// No pending predictions, no violation shadow → byte-identical chemistry.
    @Test func emptyLedgerIsByteIdentical() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let out = OrganismProspectiveAffect.modulate(base, ledger: .empty, at: now)
        #expect(out == base)
    }

    /// A near-due, low-confidence expectation on a weak path → BRACING: vigilance
    /// up, confidence down, urgency up.
    @Test func shakyNearDuePredictionBraces() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        let p = prediction(.toolCompletion, dueIn: 60, confidence: 0.2, uncertainty: 0.8, now: now)
        ledger.predictions[p.id] = p
        ledger.bodyConfidence = OrganismBodyConfidence(toolPath: 0.2)

        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(out.vigilance > base.vigilance, "bracing raises vigilance: \(out.vigilance)")
        #expect(out.confidence < base.confidence, "bracing dips confidence: \(out.confidence)")
        #expect(out.urgency > base.urgency)
    }

    /// A confident expectation on a strong path → LOOKING-FORWARD: curiosity lifts,
    /// no bracing.
    @Test func confidentPredictionLooksForward() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        let p = prediction(.workflowAdvance, dueIn: 120, confidence: 0.9, uncertainty: 0.1, now: now)
        ledger.predictions[p.id] = p
        ledger.bodyConfidence = OrganismBodyConfidence(workflowPath: 0.9)

        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(out.curiosity > base.curiosity, "looking-forward lifts curiosity: \(out.curiosity)")
        #expect(out.vigilance == base.vigilance, "no bracing from a good expectation")
    }

    /// A far-future prediction (outside the anticipation window) weighs nothing yet.
    @Test func farFuturePredictionIsInertForNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        let p = prediction(.toolCompletion, dueIn: 3 * 60 * 60, confidence: 0.1, uncertainty: 0.9, now: now)
        ledger.predictions[p.id] = p
        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(out == base, "3h-out dread would be neurosis, not anticipation")
    }

    /// An OVERDUE pending prediction weighs fully — the outcome is late.
    @Test func overduePredictionWeighsFully() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        let p = prediction(.providerCompletion, dueIn: -120, confidence: 0.2, now: now)
        ledger.predictions[p.id] = p
        ledger.bodyConfidence = OrganismBodyConfidence(providerPath: 0.25)
        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(out.vigilance > base.vigilance, "late + shaky = braced")
    }

    /// Caps hold under a flood: 25 shaky near-due predictions can't move any dim
    /// past maxDelta.
    @Test func capsHoldUnderPredictionFlood() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        for _ in 0..<25 {
            let p = prediction(.toolCompletion, dueIn: 30, confidence: 0.1, uncertainty: 0.9, now: now)
            ledger.predictions[p.id] = p
        }
        ledger.bodyConfidence = OrganismBodyConfidence(toolPath: 0.1)
        let out = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(out.vigilance - base.vigilance <= OrganismProspectiveAffect.maxDelta + 0.0001)
        #expect(base.confidence - out.confidence <= OrganismProspectiveAffect.maxDelta + 0.0001)
        #expect(out.urgency - base.urgency <= OrganismProspectiveAffect.maxDelta + 0.0001)
    }

    /// A recent violation leaves a fading shadow of wariness — and it decays.
    @Test func violationShadowFades() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        ledger.lastViolationAt = now.addingTimeInterval(-60)
        let fresh = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(fresh.vigilance > base.vigilance, "a fresh miss keeps the body wary")

        ledger.lastViolationAt = now.addingTimeInterval(-4 * 60 * 60)
        let old = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(old == base, "a 4h-old miss has honestly faded")
    }

    /// Pure: same inputs → same output.
    @Test func modulationIsDeterministic() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var ledger = OrganismPredictionLedger.empty
        let p = prediction(.phoneDelivery, dueIn: 90, confidence: 0.3, now: now)
        ledger.predictions[p.id] = p
        let a = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        let b = OrganismProspectiveAffect.modulate(base, ledger: ledger, at: now)
        #expect(a == b)
    }
}
