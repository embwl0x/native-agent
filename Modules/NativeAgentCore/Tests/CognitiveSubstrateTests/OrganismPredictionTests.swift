import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private func predictionSignal(
    _ kind: SomaticSignalKind,
    sourceOrgan: String = "tool.shell",
    id: UUID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
    at date: Date = Date(timeIntervalSince1970: 3_000),
    intensity: Double = 1,
    metadata: [String: JSONValue] = [:]
) -> SomaticSignal {
    SomaticSignal(
        id: id,
        kind: kind,
        sourceOrgan: sourceOrgan,
        occurredAt: date,
        intensity: intensity,
        metadata: metadata
    )
}

@Test func providerPredictionErrorRaisesVigilanceAndLowersPathConfidence() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(predictionSignal(.providerFailed, sourceOrgan: "provider", at: Date(timeIntervalSince1970: 3_000)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary.violatedCount == 1)
    #expect(snapshot.predictionSummary.bodyConfidence.providerPath < OrganismBodyConfidence.neutral.providerPath)
    #expect(snapshot.chemicalState.vigilance > 0.2)
    #expect(snapshot.bodySchema.providersHealthy == false)
}

@Test func genericPhoneStalenessDoesNotPretendARealDeliveryWasAttempted() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(predictionSignal(.iPhoneStale, sourceOrgan: "phone", at: Date(timeIntervalSince1970: 3_000)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary.violatedCount == 0)
    #expect(snapshot.predictionSummary.pendingCount == 0)
    #expect(snapshot.predictionSummary.peripheralUncertainty == 0)
    #expect(snapshot.predictionSummary.bodyConfidence.phonePath == OrganismBodyConfidence.neutral.phonePath)
    #expect(snapshot.chemicalState.vigilance > 0)
    #expect(snapshot.chemicalState.vigilance < 0.08)
    #expect(snapshot.chemicalState.urgency == 0)
}

@Test func providerLifecycleCreatesAndSettlesOneExactPendingPrediction() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)
    let correlation = "provider-call-1"
    let metadata: [String: JSONValue] = ["predictionCorrelationId": .string(correlation)]

    await kernel.ingest(predictionSignal(
        .providerStarted, sourceOrgan: "provider.openai", at: date, metadata: metadata
    ))
    let pending = await kernel.snapshot()
    await kernel.ingest(predictionSignal(
        .providerSucceeded,
        sourceOrgan: "provider.openai",
        at: date.addingTimeInterval(2),
        metadata: metadata
    ))
    let settled = await kernel.snapshot()

    #expect(pending.predictionSummary.pendingCount == 1)
    #expect(pending.predictionSummary.satisfiedCount == 0)
    #expect(settled.predictionSummary.pendingCount == 0)
    #expect(settled.predictionSummary.satisfiedCount == 1)
    #expect(settled.predictionSummary.bodyConfidence.providerPath > OrganismBodyConfidence.neutral.providerPath)
}

@Test func unrelatedProviderOutcomeCannotSettleAnotherCall() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)

    await kernel.ingest(predictionSignal(
        .providerStarted,
        sourceOrgan: "provider.openai",
        at: date,
        metadata: ["predictionCorrelationId": .string("call-a")]
    ))
    await kernel.ingest(predictionSignal(
        .providerSucceeded,
        sourceOrgan: "provider.openai",
        at: date.addingTimeInterval(2),
        metadata: ["predictionCorrelationId": .string("call-b")]
    ))
    let snapshot = await kernel.snapshot()
    let state = try #require(await kernel.exportPersistentState())

    #expect(snapshot.predictionSummary.pendingCount == 1)
    #expect(snapshot.predictionSummary.satisfiedCount == 1)
    #expect(state.predictionLedger.predictions.values.contains { prediction in
        prediction.status == .pending && prediction.id.contains("call-a")
    })
}

@Test func providerCancellationRemovesPendingExpectationWithoutPunishment() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)
    let metadata: [String: JSONValue] = ["predictionCorrelationId": .string("cancelled-call")]

    await kernel.ingest(predictionSignal(
        .providerStarted, sourceOrgan: "provider.openai", at: date, metadata: metadata
    ))
    await kernel.ingest(predictionSignal(
        .providerCancelled,
        sourceOrgan: "provider.openai",
        at: date.addingTimeInterval(1),
        metadata: metadata
    ))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary.pendingCount == 0)
    #expect(snapshot.predictionSummary.violatedCount == 0)
    #expect(snapshot.predictionSummary.expiredCount == 0)
}

@Test func delayedCorrelatedEvidenceCannotRegressPredictionEpochOrDueHorizon() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let newer = Date(timeIntervalSince1970: 3_000)
    let older = newer.addingTimeInterval(-120)
    let metadata: [String: JSONValue] = [
        "predictionCorrelationId": .string("delayed-provider-call")
    ]

    await kernel.ingest(predictionSignal(
        .providerStarted,
        sourceOrgan: "provider.openai",
        at: newer,
        metadata: metadata
    ))
    let baseline = try #require(await kernel.exportPersistentState())
    let baselinePrediction = try #require(baseline.predictionLedger.predictions.values.first {
        $0.id.contains("delayed-provider-call")
    })

    // Exercise all correlated mutators with source evidence older than the
    // canonical prediction: reopen, terminal failure, and cancellation.
    await kernel.ingest(predictionSignal(
        .providerStarted,
        sourceOrgan: "provider.openai",
        at: older,
        metadata: metadata
    ))
    await kernel.ingest(predictionSignal(
        .providerFailed,
        sourceOrgan: "provider.openai",
        at: older.addingTimeInterval(1),
        metadata: metadata
    ))
    await kernel.ingest(predictionSignal(
        .providerCancelled,
        sourceOrgan: "provider.openai",
        at: older.addingTimeInterval(2),
        metadata: metadata
    ))

    let after = try #require(await kernel.exportPersistentState())
    let afterPrediction = try #require(after.predictionLedger.predictions[baselinePrediction.id])
    #expect(afterPrediction.status == .pending)
    #expect(afterPrediction.createdAt == baselinePrediction.createdAt)
    #expect(afterPrediction.dueAt == baselinePrediction.dueAt)
    #expect(afterPrediction.lastUpdatedAt == newer)
    #expect(afterPrediction.evidenceCount == baselinePrediction.evidenceCount)
}

@Test func signedPhoneReceiptSettlesOnlyItsExactDeliveryPrediction() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)
    let eventID = String(repeating: "a", count: 64)
    let metadata: [String: JSONValue] = ["predictionCorrelationId": .string(eventID)]

    await kernel.ingest(predictionSignal(
        .phoneDeliveryStarted, sourceOrgan: "phone.\(eventID)", at: date, metadata: metadata
    ))
    let pending = await kernel.snapshot()
    await kernel.ingest(predictionSignal(
        .phoneDeliveryReceived,
        sourceOrgan: "phone.\(eventID)",
        at: date.addingTimeInterval(4),
        metadata: metadata
    ))
    let received = await kernel.snapshot()
    let latestDelivery = await kernel.latestPrediction(ofKind: .phoneDelivery)

    #expect(pending.predictionSummary.pendingCount == 1)
    #expect(received.predictionSummary.pendingCount == 0)
    #expect(received.predictionSummary.satisfiedCount == 1)
    #expect(received.bodySchema.iPhoneReachable)
    #expect(received.bodySchema.notificationPathHealthy)
    #expect(latestDelivery?.status == .satisfied)
    #expect(latestDelivery?.lastUpdatedAt == date.addingTimeInterval(4))
}

@Test func toolSuccessSatisfiesPendingPredictionAndRaisesConfidence() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)

    await kernel.ingest(predictionSignal(.toolStarted, at: date))
    let pending = await kernel.snapshot()
    await kernel.ingest(predictionSignal(.toolSucceeded, at: date.addingTimeInterval(10)))
    let satisfied = await kernel.snapshot()

    #expect(pending.predictionSummary.pendingCount == 1)
    #expect(pending.predictionSummary.averagePendingUncertainty > 0)
    #expect(satisfied.predictionSummary.pendingCount == 0)
    #expect(satisfied.predictionSummary.satisfiedCount == 1)
    #expect(satisfied.predictionSummary.bodyConfidence.toolPath > OrganismBodyConfidence.neutral.toolPath)
    #expect(satisfied.chemicalState.confidence > ChemicalState.neutral.confidence)
}

@Test func canonicalToolActionsSettleByExactIdentityAndCancellationIsNeutral() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)
    let source = "tool.workshop"
    let actionA: [String: JSONValue] = ["predictionCorrelationId": .string("action-a")]
    let actionB: [String: JSONValue] = ["predictionCorrelationId": .string("action-b")]

    await kernel.ingest(predictionSignal(.toolStarted, sourceOrgan: source, at: date, metadata: actionA))
    await kernel.ingest(predictionSignal(
        .toolStarted,
        sourceOrgan: source,
        id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
        at: date.addingTimeInterval(1),
        metadata: actionB
    ))
    #expect(await kernel.snapshot().predictionSummary.pendingCount == 2)

    await kernel.ingest(predictionSignal(
        .toolSucceeded,
        sourceOrgan: source,
        id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
        at: date.addingTimeInterval(2),
        metadata: actionA
    ))
    let afterA = await kernel.snapshot()
    #expect(afterA.predictionSummary.pendingCount == 1)
    #expect(afterA.predictionSummary.satisfiedCount == 1)

    let chemistryBeforeCancel = afterA.chemicalState
    await kernel.ingest(predictionSignal(
        .toolCancelled,
        sourceOrgan: source,
        id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
        at: date.addingTimeInterval(3),
        metadata: actionB
    ))
    let settled = await kernel.snapshot()
    #expect(settled.predictionSummary.pendingCount == 0)
    #expect(settled.predictionSummary.violatedCount == 0)
    #expect(settled.chemicalState == chemistryBeforeCancel)
    #expect(settled.bodySchema.toolHandsAvailable)
}

@Test func repeatedToolFailureRaisesStrategyCaution() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)

    await kernel.ingest(predictionSignal(.toolStarted, at: date))
    await kernel.ingest(predictionSignal(.toolFailed, at: date.addingTimeInterval(3)))
    let first = await kernel.snapshot()
    await kernel.ingest(predictionSignal(.toolStarted, at: date.addingTimeInterval(30)))
    await kernel.ingest(predictionSignal(.toolFailed, at: date.addingTimeInterval(33)))
    let second = await kernel.snapshot()

    #expect(first.predictionSummary.violatedCount == 1)
    #expect(second.predictionSummary.violatedCount == 2)
    #expect(second.predictionSummary.strategyCaution > first.predictionSummary.strategyCaution)
    #expect(second.predictionSummary.bodyConfidence.toolPath < OrganismBodyConfidence.neutral.toolPath)
}

@Test func overdueToolPredictionExpiresIntoCaution() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 3_000)

    await kernel.ingest(predictionSignal(.toolStarted, at: date))
    await kernel.ingest(predictionSignal(.userSpoke, sourceOrgan: "chat", at: date.addingTimeInterval(100)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary.expiredCount == 1)
    #expect(snapshot.predictionSummary.pendingCount == 0)
    #expect(snapshot.predictionSummary.strategyCaution > 0)
    #expect(snapshot.predictionSummary.bodyConfidence.toolPath < OrganismBodyConfidence.neutral.toolPath)
}

@Test func disabledKernelKeepsPredictionSummaryEmpty() async throws {
    let kernel = OrganismKernel(configuration: .disabled)

    await kernel.ingest(predictionSignal(.toolStarted, at: Date(timeIntervalSince1970: 3_000)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary == .empty)
}

@Test func clearTransientStateClearsPredictionLedger() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(predictionSignal(.toolStarted, at: Date(timeIntervalSince1970: 3_000)))
    await kernel.clearTransientState()
    let snapshot = await kernel.snapshot()

    #expect(snapshot.predictionSummary == .empty)
}
