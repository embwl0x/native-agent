import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

private func dreamRepairSignal(
    _ kind: SomaticSignalKind,
    at date: Date = Date(timeIntervalSince1970: 4_000),
    metadata: [String: JSONValue] = [:]
) -> SomaticSignal {
    SomaticSignal(
        id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        kind: kind,
        sourceOrgan: "dream",
        occurredAt: date,
        intensity: 1,
        metadata: metadata
    )
}

private func chargedDreamField(at date: Date = Date(timeIntervalSince1970: 4_000)) -> OrganismField {
    var field = OrganismField.empty
    field.nodes["signal:providerFailed"] = OrganismNode(
        id: "signal:providerFailed",
        kind: .signal,
        label: "providerFailed",
        activation: 0.92,
        charge: 0.64,
        lastActivatedAt: date
    )
    field.nodes["organ:provider"] = OrganismNode(
        id: "organ:provider",
        kind: .organ,
        label: "provider",
        activation: 0.75,
        charge: 0.44,
        lastActivatedAt: date
    )
    field.edges["organ:provider|signal:providerFailed"] = OrganismEdge(
        sourceID: "organ:provider",
        targetID: "signal:providerFailed",
        weight: 0.42,
        uncertainty: 0.34,
        eligibility: 0.6,
        coActivations: 4,
        lastUpdatedAt: date
    )
    field.lastUpdatedAt = date
    return field
}

@Test func dreamRepairLowersChargeButPreservesActivationMeaning() async throws {
    let before = chargedDreamField()
    let beforeSummary = before.summary()

    let repaired = OrganismDreamRepair.applying(
        signal: dreamRepairSignal(.dreamCompleted),
        to: before,
        state: .empty,
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000001")! }
    )
    let afterSummary = repaired.field.summary()

    #expect(afterSummary.totalCharge < beforeSummary.totalCharge)
    #expect(afterSummary.highestActivation > 0.05)
    #expect(repaired.state.summary().receiptCount == 1)
    #expect(repaired.state.summary().softenedNodes > 0)
}

@Test func dreamRepairStrengthensWarmAndWeakensNoisyEdges() async throws {
    let before = chargedDreamField()

    let repaired = OrganismDreamRepair.applying(
        signal: dreamRepairSignal(.remIntegrated),
        to: before,
        state: .empty,
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000002")! }
    )
    let summary = repaired.state.summary()

    #expect(summary.receiptCount == 1)
    #expect(summary.weakenedEdges > 0)
    let edge = try #require(repaired.field.edge(sourceID: "organ:provider", targetID: "signal:providerFailed"))
    #expect(edge.uncertainty < 0.34)
}

@Test func dreamRepairFlagsTensionWithoutFabricatingStandingViewProposal() async throws {
    let felt = "Recurring pattern tension: provider confidence contradicts tool evidence; propose standing view for review."
    let repaired = OrganismDreamRepair.applying(
        signal: dreamRepairSignal(.dreamCompleted, metadata: ["feltDaySummary": .string(felt)]),
        to: chargedDreamField(),
        state: .empty,
        limits: OrganismDreamRepairLimits(maximumOperations: 16, maximumFeltSummaryCharacters: 80),
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000003")! }
    )
    let summary = repaired.state.summary()

    #expect(summary.flaggedContradictions == 1)
    #expect(summary.proposedStandingViews == 0)
    #expect(summary.standingViewProposals.isEmpty)
    #expect(repaired.state.lastReceipt?.operations.contains { $0.kind == .proposeStandingView } == false)
    #expect(summary.feltDaySummaryCharacters == 80)
}

@Test func dreamRepairKeepsEvidenceWithoutClaimingItIsAView() async throws {
    let felt = "Recurring pattern tension: provider confidence contradicts tool evidence; propose standing view for review."
    let repaired = OrganismDreamRepair.applying(
        signal: dreamRepairSignal(.remIntegrated, metadata: ["feltDaySummary": .string(felt)]),
        to: chargedDreamField(),
        state: .empty,
        limits: OrganismDreamRepairLimits(maximumOperations: 16, maximumFeltSummaryCharacters: 240),
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000007")! }
    )
    let summary = repaired.state.summary()

    #expect(summary.latestEvidence.contains { $0.id == "evidence:felt-summary" })
    #expect(summary.latestEvidence.contains { $0.id == "evidence:contradiction" })
    #expect(summary.proposedStandingViews == 0)
    #expect(summary.standingViewProposals.isEmpty)
}

@Test func legacyDreamProposalIsSuppressedImmediatelyAfterRestore() async throws {
    let legacy = OrganismStandingViewProposal(
        id: "standing-view:felt-summary",
        title: "Review recurring felt pattern",
        rationale: "Recurring pattern in dream repair needs review.",
        evidenceIDs: ["evidence:felt-summary"]
    )
    let state = OrganismDreamRepairState(
        receiptCount: 1,
        lastReceipt: OrganismDreamRepairReceipt(
            id: UUID(uuidString: "51000000-0000-0000-0000-000000000009")!,
            generatedAt: Date(timeIntervalSince1970: 4_000),
            reason: "dreamCompleted",
            feltDaySummaryCharacters: 42,
            operations: [OrganismRepairOperation(
                id: "propose-standing-view:felt-summary",
                kind: .proposeStandingView,
                targetID: "review-only",
                delta: 0
            )],
            standingViewProposals: [legacy],
            proposedStandingViewCount: 1
        )
    )

    let summary = state.summary()
    #expect(summary.proposedStandingViews == 0)
    #expect(summary.standingViewProposals.isEmpty)
}

@Test func dreamRepairEvidenceRedactsSecretLookingText() async throws {
    let secretLike = "Recurring pattern with bearer token: sk-fixture should be hidden."
    let repaired = OrganismDreamRepair.applying(
        signal: dreamRepairSignal(.dreamCompleted, metadata: ["feltDaySummary": .string(secretLike)]),
        to: chargedDreamField(),
        state: .empty,
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000008")! }
    )
    let visible = repaired.state.summary().latestEvidence.map(\.summary).joined(separator: "\n").lowercased()

    #expect(!visible.contains("sk-fixture"))
    #expect(visible.contains("[redacted]") || visible.contains("private evidence hidden"))
}

@Test func dreamRepairOperationsAreBoundedAndReplayable() async throws {
    let signal = dreamRepairSignal(.dreamCompleted)
    let first = OrganismDreamRepair.applying(
        signal: signal,
        to: chargedDreamField(),
        state: .empty,
        limits: OrganismDreamRepairLimits(maximumOperations: 2),
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000004")! }
    )
    let second = OrganismDreamRepair.applying(
        signal: signal,
        to: chargedDreamField(),
        state: .empty,
        limits: OrganismDreamRepairLimits(maximumOperations: 2),
        makeUUID: { UUID(uuidString: "51000000-0000-0000-0000-000000000004")! }
    )

    #expect(first.state.lastReceipt?.operations.count == 2)
    #expect(first.field == second.field)
    #expect(first.state.lastReceipt == second.state.lastReceipt)
}

@Test func kernelDreamSignalUpdatesRepairSummary() async throws {
    let kernel = OrganismKernel(configuration: .enabled)
    let date = Date(timeIntervalSince1970: 4_000)

    await kernel.ingest(dreamRepairSignal(.providerFailed, at: date))
    await kernel.ingest(dreamRepairSignal(.dreamCompleted, at: date.addingTimeInterval(10)))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.dreamRepairSummary.receiptCount == 1)
    #expect(snapshot.dreamRepairSummary.lastOperationCount > 0)
    #expect(snapshot.fieldSummary.totalCharge > 0)
}

@Test func disabledKernelKeepsDreamRepairSummaryEmpty() async throws {
    let kernel = OrganismKernel(configuration: .disabled)

    await kernel.ingest(dreamRepairSignal(.dreamCompleted))
    let snapshot = await kernel.snapshot()

    #expect(snapshot.dreamRepairSummary == .empty)
}

@Test func clearTransientStateClearsDreamRepairState() async throws {
    let kernel = OrganismKernel(configuration: .enabled)

    await kernel.ingest(dreamRepairSignal(.providerFailed))
    await kernel.ingest(dreamRepairSignal(.dreamCompleted))
    await kernel.clearTransientState()
    let snapshot = await kernel.snapshot()

    #expect(snapshot.dreamRepairSummary == .empty)
}
