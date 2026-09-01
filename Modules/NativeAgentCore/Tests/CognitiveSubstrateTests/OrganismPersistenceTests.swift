import Foundation
import Testing
@testable import CognitiveSubstrate

@Test func persistedOrganismStateRestoresWithDecay() async throws {
    let savedAt = Date(timeIntervalSince1970: 10_000)
    let restoredAt = savedAt.addingTimeInterval(12 * 3_600)
    let node = OrganismNode(
        id: "signal:providerFailed",
        kind: .signal,
        label: "providerFailed",
        activation: 0.9,
        charge: 0.8,
        lastActivatedAt: savedAt
    )
    let edge = OrganismEdge(
        sourceID: "signal:providerFailed",
        targetID: "body:provider:brittle",
        weight: 0.7,
        uncertainty: 0.2,
        eligibility: 0.8,
        coActivations: 4,
        lastUpdatedAt: savedAt
    )
    let state = OrganismPersistentState(
        savedAt: savedAt,
        chemicalState: ChemicalState(vigilance: 0.8, fatigue: 0.6, coherence: 0.2, confidence: 0.1),
        bodySchema: BodySchema(providersHealthy: false, resourcePressure: .critical),
        field: OrganismField(nodes: [node.id: node], edges: [edge.id: edge], lastUpdatedAt: savedAt),
        signalCount: 42,
        lastSignalAt: savedAt
    )

    let kernel = OrganismKernel(
        configuration: .enabled,
        dependencies: OrganismDependencies(now: { restoredAt }, makeUUID: { UUID() })
    )
    await kernel.restorePersistentState(state)
    let snapshot = await kernel.snapshot()

    #expect(snapshot.signalCount == 42)
    #expect(snapshot.chemicalState.vigilance < 0.8)
    #expect(snapshot.chemicalState.fatigue < 0.6)
    #expect(snapshot.chemicalState.coherence > 0.2)
    #expect(snapshot.chemicalState.confidence > 0.1)
    #expect(snapshot.bodySchema.resourcePressure == .nominal)
    #expect(snapshot.fieldSummary.nodeCount == 1)
    #expect(snapshot.fieldSummary.totalCharge < 0.8)
}

@Test func futureDatedSavedAtDecaysToZeroSoForwardSettledStateIsNotReDecayed() throws {
    // F3-M5 guard: settleContinuity() anchors a settled state at now+6h. A
    // snapshot exported with that future savedAt must NOT be re-decayed when
    // restored inside the window. decayed(at:) clamps elapsed to >= 0, so a
    // savedAt in the future yields the state unchanged (mirror of the
    // in-memory settleElapsedTime negative-elapsed guard).
    let savedAt = Date(timeIntervalSince1970: 200_000)
    let restoredAt = savedAt.addingTimeInterval(-3 * 3_600) // 3h BEFORE savedAt
    let node = OrganismNode(
        id: "signal:providerFailed",
        kind: .signal,
        label: "providerFailed",
        activation: 0.9,
        charge: 0.8,
        lastActivatedAt: savedAt
    )
    let state = OrganismPersistentState(
        savedAt: savedAt,
        chemicalState: ChemicalState(vigilance: 0.8, fatigue: 0.6),
        bodySchema: BodySchema(providersHealthy: false, resourcePressure: .critical),
        field: OrganismField(nodes: [node.id: node], edges: [:], lastUpdatedAt: savedAt),
        signalCount: 7,
        lastSignalAt: savedAt
    )

    let decayed = state.decayed(at: restoredAt)
    // Zero elapsed → decayed returns self unchanged (no double-decay).
    #expect(decayed == state)
    #expect(decayed.chemicalState == state.chemicalState)
    #expect(decayed.field == state.field)
}

@Test func disabledKernelDoesNotExportOrganismContinuity() async throws {
    let kernel = OrganismKernel(configuration: .disabled)

    await kernel.ingest(SomaticSignal(
        id: UUID(uuidString: "53000000-0000-0000-0000-000000000001")!,
        kind: .providerFailed,
        sourceOrgan: "provider",
        occurredAt: Date(timeIntervalSince1970: 1_000),
        intensity: 1
    ))

    let state = await kernel.exportPersistentState()
    #expect(state == nil)
}

@Test func legacyReflexStateWithoutReviewReceiptsStillDecodes() throws {
    let data = Data(#"{"observations":{},"candidates":{},"lastUpdatedAt":"1970-01-01T00:00:00Z"}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let state = try decoder.decode(OrganismReflexState.self, from: data)

    #expect(state.reviewReceipts.isEmpty)
    #expect(state.candidates.isEmpty)
}

@Test func reflexReviewReceiptSurvivesOrganismPersistenceRoundTrip() throws {
    let reviewedAt = Date(timeIntervalSince1970: 20_000)
    let candidate = OrganismReflexCandidate(
        id: "tool:tool-grep",
        pattern: "Prefer the bounded grep path.",
        trustClass: .lowRisk,
        evidenceCount: 9,
        successCount: 9,
        confidence: 0.92,
        firstSeenAt: reviewedAt.addingTimeInterval(-100),
        lastUpdatedAt: reviewedAt.addingTimeInterval(-1)
    )
    let reflexState = OrganismReflexState(
        observations: [candidate.id: candidate],
        candidates: [candidate.id: candidate]
    ).reviewedCandidate(
        id: candidate.id,
        decision: .approve,
        reviewedAt: reviewedAt,
        note: "User approved",
        reviewedBy: "agent",
        source: "reflex_review:codex",
        receiptID: "receipt-round-trip"
    )
    let state = OrganismPersistentState(savedAt: reviewedAt, reflexState: reflexState)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(OrganismPersistentState.self, from: data)
    let receipt = try #require(decoded.reflexState.reviewReceipts.first)

    #expect(receipt.id == "receipt-round-trip")
    #expect(receipt.candidateID == candidate.id)
    #expect(receipt.decision == .approve)
    #expect(receipt.reviewedBy == "agent")
    #expect(receipt.source == "reflex_review:codex")
    #expect(receipt.autoActivationAllowed)
    #expect(decoded.reflexState.candidates[candidate.id]?.autoActivationAllowed == true)
}

@Test func restartExpiryRecordsTheSameOutcomeEvidenceAsTheLiveSweep() throws {
    // The restart/idle decay flipped overdue pendings to .expired without the
    // outcome bookkeeping the live sweep does, so every expiry that landed
    // across an app restart vanished from the cumulative evidence the
    // capability self-read now prefers. Both paths must agree.
    let savedAt = Date(timeIntervalSince1970: 500_000)
    let now = savedAt.addingTimeInterval(2 * 3_600)
    let overdue = OrganismPrediction(
        id: OrganismPredictiveBody.predictionID(
            kind: .toolCompletion, sourceOrgan: "tool", correlationID: "run-1"
        ),
        kind: .toolCompletion,
        sourceOrgan: "tool",
        createdAt: savedAt,
        dueAt: savedAt.addingTimeInterval(90),
        lastUpdatedAt: savedAt
    )
    let ledger = OrganismPredictionLedger(
        predictions: [overdue.id: overdue],
        outcomeCountsByKind: [:]
    )

    let restored = OrganismPersistentState(savedAt: savedAt, predictionLedger: ledger)
        .decayed(at: now)
        .predictionLedger

    let swept = OrganismPredictiveBody.applying(
        signal: SomaticSignal(id: UUID(), kind: .userSpoke, sourceOrgan: "chat", occurredAt: now),
        to: ledger,
        chemicalState: .neutral,
        bodySchema: .neutral
    ).ledger

    #expect(restored.predictions[overdue.id]?.status == .expired)
    #expect(swept.predictions[overdue.id]?.status == .expired)
    #expect(restored.expiredCount == swept.expiredCount)
    #expect(restored.expiredCount == 1)
    #expect(restored.outcomeCountsByKind == swept.outcomeCountsByKind)
    #expect(restored.outcomeCountsByKind?[OrganismPredictionKind.toolCompletion.rawValue]?.expired == 1)
}

@Test func restartExpiryIsCountedOnceAcrossRepeatedSweeps() throws {
    // The decay runs on every settle tick; only the tick that flips the row
    // may count it.
    let savedAt = Date(timeIntervalSince1970: 600_000)
    let overdue = OrganismPrediction(
        id: "pending:toolCompletion:tool:run-2",
        kind: .toolCompletion,
        sourceOrgan: "tool",
        createdAt: savedAt,
        dueAt: savedAt.addingTimeInterval(90),
        lastUpdatedAt: savedAt
    )
    var state = OrganismPersistentState(
        savedAt: savedAt,
        predictionLedger: OrganismPredictionLedger(predictions: [overdue.id: overdue])
    )
    for step in 1...5 {
        state = state.decayed(at: savedAt.addingTimeInterval(Double(step) * 600))
    }

    #expect(state.predictionLedger.expiredCount == 1)
    #expect(state.predictionLedger
        .outcomeCountsByKind?[OrganismPredictionKind.toolCompletion.rawValue]?.expired == 1)
}

@Test func outcomeWeightsAreAnAdditiveWireChange() throws {
    // Old state files carry no `weights` key: they must decode, and the
    // lifetime tally must seed the forgetting rather than be discarded.
    let legacy = Data("""
    {"satisfied":80,"violated":20,"expired":3}
    """.utf8)
    let decoded = try JSONDecoder().decode(OrganismPredictionOutcomeCounts.self, from: legacy)

    #expect(decoded.weights == nil)
    // No evidence date to age it against: seeded at full strength.
    #expect(decoded.effectiveWeights(at: Date(timeIntervalSince1970: 0))
        == OrganismPredictionOutcomeWeights(satisfied: 80, violated: 20, expired: 3))

    // And a new file stays readable by a decoder that never heard of weights.
    let current = OrganismPredictionOutcomeCounts(
        satisfied: 5, violated: 1, expired: 2,
        weights: OrganismPredictionOutcomeWeights(satisfied: 2.5, violated: 0.5, expired: 1)
    )
    let encoded = try JSONEncoder().encode(current)
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var withoutWeights = object
    withoutWeights.removeValue(forKey: "weights")
    let oldReaderView = try JSONDecoder().decode(
        OrganismPredictionOutcomeCounts.self,
        from: try JSONSerialization.data(withJSONObject: withoutWeights)
    )

    #expect(object["satisfied"] as? Int == 5)
    #expect(oldReaderView.satisfied == 5)
    #expect(oldReaderView.expired == 2)
}

@Test func legacyOutcomeTallyIsSeededAtItsOwnAgeNotAtFullStrength() throws {
    // Forgetting only runs forward from the upgrade, so seeding the lifetime
    // tally undiscounted would let an old install's months-stale evidence read
    // as if all of it had just landed — the belief would report high certainty
    // and near-zero freshness from the same record.
    let now = Date(timeIntervalSince1970: 3_000_000)
    func legacyLedger(evidenceAgeDays: Double) -> OrganismPredictionLedger {
        OrganismPredictionLedger(
            bodyConfidence: OrganismBodyConfidence(toolPath: 0.5),
            outcomeCountsByKind: [
                OrganismPredictionKind.toolCompletion.rawValue:
                    OrganismPredictionOutcomeCounts(
                        satisfied: 640,
                        violated: 0,
                        expired: 0,
                        lastEvidenceAt: now.addingTimeInterval(-evidenceAgeDays * 24 * 3_600)
                    ),
            ]
        )
    }
    func toolBelief(_ ledger: OrganismPredictionLedger) throws -> OrganismCapabilityBelief {
        try #require(OrganismCapabilitySelfModel.beliefs(ledger: ledger, at: now)
            .first { $0.kind == .toolCompletion })
    }

    // Seven half-lives stale: 640 -> 5.
    let stale = try toolBelief(legacyLedger(evidenceAgeDays: 49))
    #expect(stale.resolvedEvidenceCount == 5)
    #expect(stale.freshness < 0.01)
    // Uncertainty must agree with that freshness rather than contradict it.
    #expect(stale.uncertainty > 0.35)

    // An hour old: still essentially everything it earned (an hour against a
    // seven-day half-life is a fraction of a percent).
    let recent = try toolBelief(legacyLedger(evidenceAgeDays: 1.0 / 24))
    #expect(recent.resolvedEvidenceCount > 630)
    #expect(recent.freshness > 0.99)
    #expect(recent.uncertainty < 0.05)

    // And the first decay tick must not charge the same elapsed time twice:
    // the seed is already aged to `now` when it is materialized.
    let materialized = OrganismPersistentState(
        savedAt: now.addingTimeInterval(-24 * 3_600),
        predictionLedger: legacyLedger(evidenceAgeDays: 49)
    ).decayed(at: now).predictionLedger
    let seeded = try #require(materialized
        .outcomeCountsByKind?[OrganismPredictionKind.toolCompletion.rawValue]?.weights)

    #expect(abs(seeded.satisfied - 5) < 0.001)
}
