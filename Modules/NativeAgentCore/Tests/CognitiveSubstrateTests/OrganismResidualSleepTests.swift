import Foundation
import Testing
@testable import CognitiveSubstrate

@Suite("Residual-driven organism sleep")
struct OrganismResidualSleepTests {
    @Test func preregisteredPressureUsesExactProductAndDreamGateIsReachable() {
        let all = OrganismSleepPressureComponents(
            predictionResidual: 1,
            transitionSurprise: 1,
            contradictionResidual: 1,
            fieldChargeResidual: 1,
            calibrationResidual: 1
        )
        let pressure = OrganismResidualRepair.combinedPressure(all)
        let expected = 1 - (0.70 * 0.75 * 0.80 * 0.85 * 0.90)

        #expect(abs(pressure - expected) < 0.000_000_001)
        #expect(pressure < 0.70)
        #expect(OrganismResidualRepair.dreamPressure < pressure)
    }

    @Test func neutralBodyOwnsNoIdleWakeButPendingExpiryHasOneExactDeadline() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let neutral = OrganismResidualRepair.opportunity(
            ledger: .empty,
            field: .empty,
            repairState: .empty,
            lastSignalAt: nil,
            at: now
        )
        #expect(neutral.pressure == 0)
        #expect(neutral.nextRepairAt == nil)
        #expect(neutral.nextWakeAt == nil)
        #expect(neutral.lanes.allSatisfy { $0.disposition == .inactive })

        let due = now.addingTimeInterval(83)
        let prediction = OrganismPrediction(
            id: "pending-provider",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now,
            dueAt: due,
            status: .pending,
            confidence: 0.8,
            uncertainty: 0.2,
            lastUpdatedAt: now
        )
        let waiting = OrganismResidualRepair.opportunity(
            ledger: OrganismPredictionLedger(predictions: [prediction.id: prediction]),
            field: .empty,
            repairState: .empty,
            lastSignalAt: now,
            at: now
        )
        #expect(waiting.pressure == 0)
        #expect(waiting.nextRepairAt == nil)
        #expect(waiting.nextWakeAt == due)
    }

    @Test func diagnosticSleepLanesNeverCreateResidentWakeups() {
        let now = Date(timeIntervalSince1970: 150_000)
        let evidenceAt = now.addingTimeInterval(-3_600)
        let reading = highPressureReading(now: now, evidenceAt: evidenceAt)

        #expect(lane(.operationalConsolidation, in: reading).disposition == .ready)
        #expect(lane(.identityDreamProposal, in: reading).disposition == .providerBudgetGateRequired)
        #expect(reading.nextWakeAt == nil)
    }

    @Test func lanesUseDistinctQuietWindowsAndNeverCallAProvider() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let evidenceAt = now.addingTimeInterval(-3_600)
        let reading = highPressureReading(now: now, evidenceAt: evidenceAt)

        #expect(reading.pressure >= OrganismResidualRepair.dreamPressure)
        #expect(lane(.quietLocalRepair, in: reading).disposition == .ready)
        #expect(lane(.operationalConsolidation, in: reading).disposition == .ready)
        #expect(lane(.identityDreamProposal, in: reading).disposition == .providerBudgetGateRequired)
        #expect(lane(.generatedFrozenRecalibration, in: reading).disposition == .privacyGateRequired)
        #expect(reading.lanes.allSatisfy { !$0.controlAuthority })

        let result = try #require(OrganismOperationalConsolidator.consolidate(
            reading,
            controlState: .empty,
            at: now
        ))
        #expect(result.receipt.providerCalled == false)
        #expect(result.receipt.personalModelUpdated == false)
        #expect(result.receipt.promptAuthority == false)
        #expect(result.receipt.actionAuthority == false)
    }

    @Test func operationalRefractorySurvivesRestartAndSameGenerationCannotReplay() throws {
        let now = Date(timeIntervalSince1970: 300_000)
        let initial = highPressureReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))
        let consolidated = try #require(OrganismOperationalConsolidator.consolidate(
            initial,
            controlState: .empty,
            at: now
        ))
        let repairState = OrganismDreamRepairState(sleepControl: consolidated.controlState)
        let encoded = try JSONEncoder().encode(repairState)
        let restored = try JSONDecoder().decode(OrganismDreamRepairState.self, from: encoded)
        #expect(restored.sleepControl == consolidated.controlState)

        let replay = highPressureReading(
            now: now.addingTimeInterval(7 * 60 * 60),
            evidenceAt: now.addingTimeInterval(-3_600),
            repairState: restored
        )
        #expect(replay.evidenceGeneration == initial.evidenceGeneration)
        #expect(lane(.operationalConsolidation, in: replay).disposition == .refractory)
        #expect(OrganismOperationalConsolidator.consolidate(
            replay,
            controlState: restored.sleepControl,
            at: replay.generatedAt
        ) == nil)
    }

    @Test func resourcePressureInhibitsLocalRepairButArmsBoundedRecheckSoItSelfRecovers() {
        let now = Date(timeIntervalSince1970: 400_000)
        let pressure = highPressureReading(
            now: now,
            evidenceAt: now.addingTimeInterval(-3_600),
            resourcePressure: .critical
        )
        #expect(pressure.pressure >= OrganismResidualRepair.dreamPressure)
        #expect(pressure.resourceInhibited)
        // Inhibition still suppresses the immediate repair (no exact repair
        // deadline, no ready lane)...
        #expect(pressure.nextRepairAt == nil)
        #expect(pressure.lanes.allSatisfy {
            $0.disposition == .resourceInhibited || $0.disposition == .inactive
        })
        // ...but F4-M1: an otherwise-eligible opportunity now carries a bounded
        // fallback wake so the deadline runner arms a timer and the loop
        // re-samples pressure once the Mac cools, instead of staying disarmed
        // until a somatic/system-wake event happens to fire.
        #expect(pressure.nextWakeAt
            == now.addingTimeInterval(OrganismResidualRepair.resourceRecheckInterval))

        let nominal = highPressureReading(
            now: now,
            evidenceAt: now.addingTimeInterval(-3_600),
            resourcePressure: .nominal
        )
        #expect(nominal.pressure == pressure.pressure)
        #expect(nominal.resourceInhibited == false)
        #expect(lane(.quietLocalRepair, in: nominal).disposition == .ready)
        // Not inhibited + quiet already passed → ready NOW via `ready`, so the
        // wake computation is unchanged (no manufactured future wake).
        #expect(nominal.nextWakeAt == nil)
    }

    @Test func resourceInhibitionAddsNoFallbackWhenNothingIsOtherwiseEligible() {
        // A neutral (below-threshold, no evidence) opportunity under inhibition
        // must NOT manufacture a re-check — there is nothing to recover to.
        let now = Date(timeIntervalSince1970: 410_000)
        let idle = OrganismResidualRepair.opportunity(
            ledger: .empty,
            field: .empty,
            repairState: .empty,
            lastSignalAt: nil,
            at: now,
            resourcePressure: .critical
        )
        #expect(idle.resourceInhibited)
        #expect(idle.nextRepairAt == nil)
        #expect(idle.nextWakeAt == nil)
    }

    @Test func resourceInhibitionFallbackNeverArmsLaterThanARealPendingExpiry() {
        // A pending prediction expiry sooner than the 5-min fallback must win —
        // the fallback is an upper bound, never a delay of a real exact wake.
        let now = Date(timeIntervalSince1970: 420_000)
        let soon = now.addingTimeInterval(60)
        let prediction = OrganismPrediction(
            id: "pending-soon",
            kind: .providerCompletion,
            sourceOrgan: "provider",
            createdAt: now,
            dueAt: soon,
            status: .pending,
            confidence: 0.8,
            uncertainty: 0.2,
            lastUpdatedAt: now
        )
        let inhibited = OrganismResidualRepair.opportunity(
            ledger: OrganismPredictionLedger(predictions: [prediction.id: prediction]),
            field: .empty,
            repairState: .empty,
            lastSignalAt: now,
            at: now,
            resourcePressure: .critical
        )
        #expect(inhibited.resourceInhibited)
        // 60s pending expiry < 300s fallback → min wins.
        #expect(inhibited.nextWakeAt == soon)
    }

    @Test func ablationRemovesOnlyItsWeightedContribution() {
        let components = OrganismSleepPressureComponents(
            predictionResidual: 1,
            transitionSurprise: 0.8,
            contradictionResidual: 0.6,
            fieldChargeResidual: 0.7,
            calibrationResidual: 0.5
        )
        let baseline = OrganismResidualRepair.combinedPressure(components)
        let noPrediction = OrganismResidualRepair.combinedPressure(
            components,
            weights: OrganismSleepPressureWeights(prediction: 0)
        )
        let noField = OrganismResidualRepair.combinedPressure(
            components,
            weights: OrganismSleepPressureWeights(fieldCharge: 0)
        )
        #expect(noPrediction < baseline)
        #expect(noField < baseline)
        #expect(noPrediction != noField)
    }

    @Test func generatedFrozenRecalibrationImprovesArtifactButHasNoProductionInfluence() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let reading = controlledRecalibrationReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))
        let samples = (0..<20).map { index in
            OrganismSleepCalibrationSample(
                evidenceID: "frozen-\(index)",
                evidenceClass: index.isMultiple(of: 2) ? .generated : .frozenControlled,
                predictedProbability: 0.30,
                observedSuccess: index < 14
            )
        }
        let result = try OrganismGeneratedSleepRecalibrator.recalibrate(
            reading: reading,
            samples: samples,
            authorization: .generatedAndFrozen,
            at: now
        )
        let artifact = result.artifact
        #expect(artifact.generatedOrFrozenOnly)
        #expect(artifact.personalModelUpdated == false)
        #expect(artifact.productionInfluence == false)
        #expect(artifact.brierAfter < artifact.brierBefore)
        #expect(result.controlState.lastGeneratedEvidenceGeneration == reading.evidenceGeneration)
        #expect(result.controlState.lastGeneratedRecalibrationAt == now)
    }

    @Test func generatedRecalibrationRejectsPersonalRuntimeEvidence() throws {
        let now = Date(timeIntervalSince1970: 600_000)
        let reading = controlledRecalibrationReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))
        let samples = (0..<8).map { index in
            OrganismSleepCalibrationSample(
                evidenceID: "runtime-\(index)",
                evidenceClass: .exactRuntime,
                predictedProbability: 0.5,
                observedSuccess: true
            )
        }
        #expect(throws: OrganismGeneratedSleepRecalibrationError.personalEvidenceDenied) {
            _ = try OrganismGeneratedSleepRecalibrator.recalibrate(
                reading: reading,
                samples: samples,
                authorization: .generatedAndFrozen,
                at: now
            )
        }
    }

    @Test func localRepairReducesFieldResidualAndAcknowledgesExactGeneration() throws {
        let now = Date(timeIntervalSince1970: 700_000)
        let reading = highPressureReading(now: now, evidenceAt: now.addingTimeInterval(-3_600))
        let field = highPressureField(at: now.addingTimeInterval(-3_600))
        var repaired = OrganismDreamRepair.applyingResidualPressure(
            reading,
            at: now,
            to: field,
            state: .empty,
            limits: OrganismDreamRepairLimits(maximumOperations: 16),
            makeUUID: { UUID(uuidString: "75000000-0000-0000-0000-000000000001")! }
        )
        #expect(repaired.field.summary().totalCharge < field.summary().totalCharge)
        #expect(repaired.state.lastReceipt?.sourceFieldGeneration == 0)

        var passDate = now.addingTimeInterval(OrganismResidualRepair.quietInterval + 1)
        for _ in 0..<12 where repaired.state.lastReceipt?.sourceFieldGeneration != field.mutationGeneration {
            let next = OrganismResidualRepair.opportunity(
                ledger: highPressureLedger(at: now.addingTimeInterval(-3_600)),
                field: repaired.field,
                repairState: repaired.state,
                lastSignalAt: now.addingTimeInterval(-3_600),
                at: passDate
            )
            repaired = OrganismDreamRepair.applyingResidualPressure(
                next,
                at: passDate,
                to: repaired.field,
                state: repaired.state,
                limits: OrganismDreamRepairLimits(maximumOperations: 16)
            )
            passDate = passDate.addingTimeInterval(OrganismResidualRepair.quietInterval + 1)
        }
        #expect(repaired.state.lastReceipt?.sourceFieldGeneration == field.mutationGeneration)
        let after = OrganismResidualRepair.opportunity(
            ledger: highPressureLedger(at: now.addingTimeInterval(-3_600)),
            field: repaired.field,
            repairState: repaired.state,
            lastSignalAt: now.addingTimeInterval(-3_600),
            at: passDate
        )
        #expect(after.chargedNodeIDs.isEmpty)
        #expect(after.noisyEdgeIDs.isEmpty)
        #expect(lane(.quietLocalRepair, in: after).disposition == .inactive)
    }
}

private func lane(
    _ lane: OrganismSleepLane,
    in reading: OrganismResidualRepairOpportunity
) -> OrganismSleepLaneOpportunity {
    reading.lanes.first { $0.lane == lane }!
}

private func highPressureReading(
    now: Date,
    evidenceAt: Date,
    repairState: OrganismDreamRepairState = .empty,
    resourcePressure: OrganismResourcePressure = .nominal
) -> OrganismResidualRepairOpportunity {
    highPressureOpportunity(
        ledger: highPressureLedger(at: evidenceAt),
        field: highPressureField(at: evidenceAt),
        repairState: repairState,
        lastSignalAt: evidenceAt,
        now: now,
        resourcePressure: resourcePressure
    )
}

private func controlledRecalibrationReading(
    now: Date,
    evidenceAt: Date
) -> OrganismResidualRepairOpportunity {
    let evidence = [
        OrganismSleepEvidenceReference(
            id: "frozen-surprise",
            kind: .transitionSurprise,
            evidenceClass: .frozenControlled,
            observedAt: evidenceAt
        ),
        OrganismSleepEvidenceReference(
            id: "generated-contradiction",
            kind: .contradiction,
            evidenceClass: .generated,
            observedAt: evidenceAt
        ),
        OrganismSleepEvidenceReference(
            id: "frozen-calibration",
            kind: .calibration,
            evidenceClass: .frozenControlled,
            observedAt: evidenceAt
        ),
    ]
    return OrganismResidualRepair.opportunity(
        ledger: .empty,
        field: .empty,
        repairState: .empty,
        lastSignalAt: evidenceAt,
        at: now,
        supplemental: OrganismSupplementalSleepResiduals(
            transitionSurprise: 1,
            contradiction: 1,
            calibration: 1,
            evidence: evidence
        )
    )
}

private func highPressureOpportunity(
    ledger: OrganismPredictionLedger,
    field: OrganismField,
    repairState: OrganismDreamRepairState,
    lastSignalAt: Date,
    now: Date,
    resourcePressure: OrganismResourcePressure = .nominal
) -> OrganismResidualRepairOpportunity {
    let controlledEvidence = OrganismSleepResidualKind.allCases.map { kind in
        OrganismSleepEvidenceReference(
            id: "controlled-\(kind.rawValue)",
            kind: kind,
            evidenceClass: .frozenControlled,
            observedAt: lastSignalAt
        )
    }
    return OrganismResidualRepair.opportunity(
        ledger: ledger,
        field: field,
        repairState: repairState,
        lastSignalAt: lastSignalAt,
        at: now,
        resourcePressure: resourcePressure,
        supplemental: OrganismSupplementalSleepResiduals(
            transitionSurprise: 1,
            contradiction: 1,
            calibration: 1,
            evidence: controlledEvidence
        )
    )
}

private func highPressureLedger(at date: Date) -> OrganismPredictionLedger {
    var predictions: [String: OrganismPrediction] = [:]
    for index in 0..<3 {
        let prediction = OrganismPrediction(
            id: "violated-\(index)",
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

private func highPressureField(at date: Date) -> OrganismField {
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
