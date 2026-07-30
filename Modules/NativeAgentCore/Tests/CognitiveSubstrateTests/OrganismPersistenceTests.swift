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
