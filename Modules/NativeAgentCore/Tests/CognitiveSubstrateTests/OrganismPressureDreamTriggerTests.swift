import Foundation
import Testing
@testable import CognitiveSubstrate

/// NORTHSTAR clause 4 (sweep item 39, 2026-09-01): sleep pressure FIRES the
/// dream. These cover the decision itself — every gate that used to only
/// describe a dream now has to gate a real one — and the wake the lane is now
/// allowed to arm because it finally has a production consumer.
@Suite("Sleep pressure fires the dream")
struct OrganismPressureDreamTriggerTests {
    @Test func pressureDueWithQuietHeldAndRefractoryClearFiresOnce() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reading = dreamPressureReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))

        #expect(reading.pressure >= OrganismResidualRepair.dreamPressure)
        #expect(dreamLane(reading).disposition == .providerBudgetGateRequired)
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: false
        ) == .fire)

        // ONE dream per refractory window: the owner's accepted-dream record is
        // the whole dedupe, and the very next reading refuses.
        let claimed = OrganismOperationalConsolidator
            .recordingAcceptedIdentityDream(in: .empty, at: now)
        let after = dreamPressureReading(
            now: now.addingTimeInterval(60),
            evidenceAt: now.addingTimeInterval(-3_600),
            repairState: OrganismDreamRepairState(sleepControl: claimed)
        )
        #expect(dreamLane(after).disposition == .refractory)
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: after,
            turnInFlight: false
        ) == .refractory)
    }

    @Test func pressureBelowThresholdNeverFires() {
        let now = Date(timeIntervalSince1970: 1_100_000)
        // Same quiet and refractory posture, only the residuals are ordinary.
        let reading = OrganismResidualRepair.opportunity(
            ledger: .empty,
            field: .empty,
            repairState: .empty,
            lastSignalAt: now.addingTimeInterval(-3_600),
            at: now,
            supplemental: OrganismSupplementalSleepResiduals(
                transitionSurprise: 0.2,
                contradiction: 0.2,
                calibration: 0.2,
                evidence: controlledEvidence(at: now.addingTimeInterval(-3_600))
            )
        )
        #expect(reading.pressure < OrganismResidualRepair.dreamPressure)
        #expect(dreamLane(reading).disposition == .inactive)
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: false
        ) == .belowThreshold)
    }

    @Test func refractoryWindowSuppressesASecondDreamForTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_200_000)
        let dreamedAt = now.addingTimeInterval(-23 * 60 * 60)
        let state = OrganismDreamRepairState(
            sleepControl: OrganismOperationalConsolidator
                .recordingAcceptedIdentityDream(in: .empty, at: dreamedAt)
        )
        let inside = dreamPressureReading(
            now: now,
            evidenceAt: now.addingTimeInterval(-3_600),
            repairState: state
        )
        #expect(inside.pressure >= OrganismResidualRepair.dreamPressure)
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: inside,
            turnInFlight: false
        ) == .refractory)

        // …and releases exactly when the 24-hour window closes (fresh residue,
        // so the release is the refractory clearing rather than pressure decay).
        let released = dreamedAt.addingTimeInterval(OrganismResidualRepair.dreamRefractoryInterval + 1)
        let outside = dreamPressureReading(
            now: released,
            evidenceAt: released.addingTimeInterval(-3_600),
            repairState: state
        )
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: outside,
            turnInFlight: false
        ) == .fire)
    }

    @Test func aTurnInFlightDefersAnOtherwiseEligibleDream() {
        let now = Date(timeIntervalSince1970: 1_300_000)
        let reading = dreamPressureReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))

        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: true
        ) == .turnInFlight)
        // Deferral is not consumption: the same reading fires once the turn
        // settles, so nothing about the eligible window was spent.
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: false
        ) == .fire)
    }

    @Test func resourceInhibitionDefersRatherThanFiring() {
        let now = Date(timeIntervalSince1970: 1_350_000)
        let reading = dreamPressureReading(
            now: now,
            evidenceAt: now.addingTimeInterval(-3_600),
            resourcePressure: .critical
        )
        #expect(OrganismIdentityDreamTrigger.decide(
            opportunity: reading,
            turnInFlight: false
        ) == .resourceInhibited)
    }

    /// The lane used to be "eligibility for its existing owner", so it was
    /// forbidden from arming a wake. It now HAS a resident consumer, so its
    /// quiet boundary is a real deadline — otherwise a mind that fell quiet
    /// with pressure high would wait for an unrelated event to notice.
    @Test func theDreamLaneArmsItsOwnQuietBoundaryButNeverASpinningZeroDelay() {
        let now = Date(timeIntervalSince1970: 1_400_000)
        let waiting = dreamPressureReading(now: now, evidenceAt: now.addingTimeInterval(-60))
        #expect(waiting.pressure >= OrganismResidualRepair.dreamPressure)
        #expect(dreamLane(waiting).disposition == .waitingForQuiet)
        #expect(waiting.nextRepairAt == nil)
        #expect(waiting.nextWakeAt
            == now.addingTimeInterval(OrganismResidualRepair.dreamQuietInterval - 60))

        // Already eligible → `dreamNext` is now, and an already-due lane must
        // never arm a zero-delay timer against itself; the consumer acts on the
        // reading it is holding.
        let due = dreamPressureReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))
        #expect(dreamLane(due).disposition == .providerBudgetGateRequired)
        #expect(due.nextWakeAt == nil)
    }

    @Test func kernelClaimIsAtomicSoTwoWakesCannotBothDream() async {
        let now = Date(timeIntervalSince1970: 1_500_000)
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { now }),
            field: dreamPressureField(at: now.addingTimeInterval(-3_600)),
            predictionLedger: violatedLedger(at: now.addingTimeInterval(-3_600))
        )
        let opportunity = await kernel.residualRepairOpportunity()
        #expect(opportunity.pressure >= OrganismResidualRepair.dreamPressure)

        let first = await kernel.claimIdentityDreamIfDue(turnInFlight: false)
        let second = await kernel.claimIdentityDreamIfDue(turnInFlight: false)
        #expect(first == .fire)
        #expect(second == .refractory)
    }

    @Test func kernelDoesNotSpendTheWindowOnADeferredTurn() async {
        let now = Date(timeIntervalSince1970: 1_600_000)
        let kernel = OrganismKernel(
            configuration: .enabled,
            dependencies: OrganismDependencies(now: { now }),
            field: dreamPressureField(at: now.addingTimeInterval(-3_600)),
            predictionLedger: violatedLedger(at: now.addingTimeInterval(-3_600))
        )
        #expect(await kernel.claimIdentityDreamIfDue(turnInFlight: true) == .turnInFlight)
        #expect(await kernel.claimIdentityDreamIfDue(turnInFlight: false) == .fire)
    }
}

private func dreamLane(
    _ reading: OrganismResidualRepairOpportunity
) -> OrganismSleepLaneOpportunity {
    reading.lanes.first { $0.lane == .identityDreamProposal }!
}

/// Pressure over the 0.60 dream gate with an EMPTY field, so the quiet-local
/// repair lane stays inactive and the deadline assertions above see only the
/// dream lane's own boundary.
private func dreamPressureReading(
    now: Date,
    evidenceAt: Date,
    repairState: OrganismDreamRepairState = .empty,
    resourcePressure: OrganismResourcePressure = .nominal
) -> OrganismResidualRepairOpportunity {
    OrganismResidualRepair.opportunity(
        ledger: violatedLedger(at: evidenceAt),
        field: .empty,
        repairState: repairState,
        lastSignalAt: evidenceAt,
        at: now,
        resourcePressure: resourcePressure,
        supplemental: OrganismSupplementalSleepResiduals(
            transitionSurprise: 1,
            contradiction: 1,
            calibration: 1,
            evidence: controlledEvidence(at: evidenceAt)
        )
    )
}

private func controlledEvidence(at date: Date) -> [OrganismSleepEvidenceReference] {
    OrganismSleepResidualKind.allCases.map { kind in
        OrganismSleepEvidenceReference(
            id: "pressure-dream-\(kind.rawValue)",
            kind: kind,
            evidenceClass: .frozenControlled,
            observedAt: date
        )
    }
}

private func violatedLedger(at date: Date) -> OrganismPredictionLedger {
    var predictions: [String: OrganismPrediction] = [:]
    for index in 0..<3 {
        let prediction = OrganismPrediction(
            id: "pressure-violated-\(index)",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: date.addingTimeInterval(-60),
            dueAt: date,
            status: .violated,
            confidence: 1,
            uncertainty: 1,
            lastUpdatedAt: date
        )
        predictions[prediction.id] = prediction
    }
    return OrganismPredictionLedger(
        predictions: predictions,
        violatedCount: predictions.count,
        strategyCaution: 1,
        bodyConfidence: OrganismBodyConfidence(
            providerPath: 0,
            toolPath: 0,
            phonePath: 0,
            approvalPath: 0,
            workflowPath: 0
        ),
        lastUpdatedAt: date,
        lastViolationAt: date
    )
}

/// The kernel derives pressure from real tissue only (no supplemental
/// artifact), so the claim tests charge the field the way a hard day does.
private func dreamPressureField(at date: Date) -> OrganismField {
    let correction = OrganismNode(
        id: "signal:correctionReceived",
        kind: .signal,
        label: "correctionReceived",
        activation: 1,
        charge: 1,
        lastActivatedAt: date
    )
    let provider = OrganismNode(
        id: "organ:provider",
        kind: .organ,
        label: "provider",
        activation: 1,
        charge: 1,
        lastActivatedAt: date
    )
    let edge = OrganismEdge(
        sourceID: correction.id,
        targetID: provider.id,
        weight: 0.8,
        uncertainty: 1,
        eligibility: 1,
        coActivations: 8,
        lastUpdatedAt: date
    )
    return OrganismField(
        nodes: [correction.id: correction, provider.id: provider],
        edges: [edge.id: edge],
        lastUpdatedAt: date,
        mutationGeneration: 9
    )
}
