import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 47 acceptance (2026-09-01) — the typed belief layer DRIVES posture.
//
// Measured defect: ~31 KB of estimate/uncertainty/freshness/evidence collapsed
// to a category before posture read it, so a tool path that was merely
// CONFIGURED and a delivery receipt from two days ago both licensed an
// optimistic posture. These pin the general rule — a read licenses optimism only
// when it is confident, current, AND actually saying the good thing — and pin
// that the provider path, which already enforced it, is unchanged.

private func optimismSnapshot(
    bodySchema: BodySchema,
    chemicalState: ChemicalState = .neutral,
    predictionSummary: OrganismPredictionSummary = .empty
) -> OrganismSnapshot {
    OrganismSnapshot(
        generatedAt: Date(timeIntervalSince1970: 500_000),
        enabled: true,
        chemicalState: chemicalState,
        bodySchema: bodySchema,
        predictionSummary: predictionSummary,
        dreamRepairSummary: .empty,
        reflexSummary: .empty,
        reflexCandidates: [],
        signalCount: 1,
        lastSignalAt: Date(timeIntervalSince1970: 499_900)
    )
}

private func evidence(
    _ id: String,
    _ evidenceClass: BodyEvidenceClass,
    at date: Date
) -> BodyEvidenceReference {
    BodyEvidenceReference(id: id, evidenceClass: evidenceClass, observedAt: date, receivedAt: date)
}

// MARK: - Tool path: configuration is not capability

@Test func configuredButNeverExercisedToolPathIsUnprovenButNotAlarming() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let reading = ToolCapabilityReading(
        generatedAt: now,
        configured: true,
        liveCapabilityObserved: false,
        evidence: [evidence("mcp-config", .toolConfiguration, at: now)]
    )
    // The compatibility Boolean still says "available" for old readers…
    #expect(reading.compatibilityAvailable == true)
    #expect(reading.category == .configured)
    // …and the numerics say she has never seen a tool run: estimate 0.6 is
    // below the same 0.65 bar that separates a healthy provider path from an
    // uncertain one, with uncertainty at 0.5.
    #expect(reading.estimate < BodyBeliefOptimism.minimumOptimisticEstimate)
    #expect(!BodyBeliefOptimism.licenses(reading.metrics))

    let body = BodySchema(toolCapabilityReading: reading)
    #expect(body.toolPathIsUnprovenOrStale)
    // Review fix 4: unknown withholds confidence, it does not manufacture
    // alarm. A fresh install and a quiet Monday must not read as a fault.
    #expect(!body.toolPathRequiresCaution)
}

@Test func liveToolCapabilityWithinItsWindowStillLicensesOptimism() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let reading = ToolCapabilityReading(
        generatedAt: now,
        configured: true,
        liveCapabilityObserved: true,
        evidence: [
            evidence("mcp-config", .toolConfiguration, at: now.addingTimeInterval(-60)),
            evidence("tool-live", .liveToolCapability, at: now.addingTimeInterval(-600)),
        ]
    )
    #expect(reading.category == .available)
    #expect(BodyBeliefOptimism.licenses(reading.metrics))

    let body = BodySchema(toolCapabilityReading: reading)
    #expect(!body.toolPathRequiresCaution)
    #expect(!body.toolPathIsUnprovenOrStale)
}

@Test func staleLiveToolReceiptNoLongerSpeaksForTheHandsNowButRaisesNoAlarm() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    // A live receipt far outside the reading's own 6h stale horizon: the
    // category still reads `.available`, the freshness does not.
    let reading = ToolCapabilityReading(
        generatedAt: now,
        configured: true,
        liveCapabilityObserved: true,
        evidence: [evidence("tool-live", .liveToolCapability, at: now.addingTimeInterval(-3 * 24 * 60 * 60))]
    )
    #expect(reading.category == .available)
    #expect(reading.freshness < BodyBeliefOptimism.minimumOptimisticFreshness)

    let body = BodySchema(toolCapabilityReading: reading)
    #expect(body.toolPathIsUnprovenOrStale)
    #expect(!body.toolPathRequiresCaution)
}

// MARK: - Notification path: a receipt ages

@Test func freshDeliveryReceiptDoesNotRequireAnotherReceipt() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let belief = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true,
        deviceReceived: true,
        evidence: [evidence("apns-receipt", .deviceProcessReceipt, at: now.addingTimeInterval(-120))]
    )
    #expect(belief.category == .deviceReceived)
    let body = BodySchema(notificationDeliveryBelief: belief)
    #expect(!body.notificationRequiresReceipt)
}

@Test func twoDayOldDeliveryReceiptStopsStandingInForTodaysDelivery() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let belief = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true,
        deviceReceived: true,
        evidence: [evidence("apns-receipt", .deviceProcessReceipt, at: now.addingTimeInterval(-48 * 60 * 60))]
    )
    #expect(belief.category == .deviceReceived)
    #expect(belief.freshness < BodyBeliefOptimism.minimumOptimisticFreshness)

    let body = BodySchema(notificationDeliveryBelief: belief)
    #expect(body.notificationRequiresReceipt)
}

@Test func anUnconfiguredTransportIsExactTruthAndNeverGoesStale() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let belief = NotificationDeliveryBelief(generatedAt: now, transportConfigured: false)
    #expect(belief.category == .unconfigured)
    // Freshness is 0 (no evidence exists), and that must NOT be read as
    // staleness: there is no delivery whose receipt could be missing.
    let body = BodySchema(notificationDeliveryBelief: belief)
    #expect(!body.notificationRequiresReceipt)
}

// MARK: - Memory path: healthy with nothing behind it is not healthy

@Test func memoryHealthyWithNoEvidenceCannotLicenseOptimism() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let reading = MemoryIntegrityReading(
        generatedAt: now,
        storeAvailable: true,
        maintenanceSucceeded: true,
        evidence: []
    )
    #expect(reading.category == .healthy)
    #expect(reading.freshness == 0)

    let body = BodySchema(memoryIntegrityReading: reading)
    #expect(body.memoryRequiresCurrentContext)
}

@Test func memoryHealthyWithLiveStoreEvidenceStaysOptimistic() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let reading = MemoryIntegrityReading(
        generatedAt: now,
        storeAvailable: true,
        maintenanceSucceeded: true,
        evidence: [evidence("memory-store", .localStorePresence, at: now.addingTimeInterval(-30))]
    )
    #expect(reading.category == .healthy)
    let body = BodySchema(memoryIntegrityReading: reading)
    #expect(!body.memoryRequiresCurrentContext)
}

// MARK: - The provider path is the rule this generalizes, and is unchanged

@Test func healthyProviderProjectionStillLicensesOptimismByConstruction() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let projection = ProviderPathBeliefProjector.project(
        evidence: (0..<6).map {
            ProviderPathEvidence(
                evidenceID: "call-\($0)",
                observedAt: now.addingTimeInterval(-Double($0) * 60),
                outcome: .succeeded
            )
        },
        now: now
    )
    #expect(projection.state == .healthy)
    // The generalized rule is exactly the projector's own three cutoffs, so a
    // `.healthy` projection satisfies it by construction — the provider path's
    // behaviour is unchanged to the bit.
    #expect(BodyBeliefOptimism.licenses(projection))

    let body = BodySchema(providersAvailable: true, providerPathBelief: projection)
    #expect(!body.providerPathRequiresCaution)
}

@Test func uncertainProviderProjectionKeepsRequiringCaution() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let projection = ProviderPathBeliefProjector.project(
        evidence: [
            ProviderPathEvidence(evidenceID: "a", observedAt: now.addingTimeInterval(-60), outcome: .succeeded),
            ProviderPathEvidence(evidenceID: "b", observedAt: now.addingTimeInterval(-90), outcome: .failed),
        ],
        now: now
    )
    #expect(projection.state == .uncertain)
    #expect(projection.bodySchemaProvidersHealthy == nil)

    let body = BodySchema(providersAvailable: true, providerPathBelief: projection)
    #expect(body.providerPathRequiresCaution)
}

// MARK: - Posture actually changes

/// The whole point of review fix 4: an unproven tool read changes posture where
/// it should — it withholds the OPTIMISTIC strategy — and nowhere else. Global
/// posture stays steady, so a fresh install or a quiet weekend is not a fault.
@Test func anUnprovenToolReadWithholdsPreferKnownPathWithoutRaisingAlarm() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let confidentInTools = OrganismPredictionSummary(
        bodyConfidence: OrganismBodyConfidence(toolPath: 0.8)
    )
    let unproven = BodySchema(
        toolCapabilityReading: ToolCapabilityReading(
            generatedAt: now,
            configured: true,
            liveCapabilityObserved: false,
            evidence: [evidence("mcp-config", .toolConfiguration, at: now)]
        )
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: optimismSnapshot(
        bodySchema: unproven, predictionSummary: confidentInTools
    )))
    #expect(posture.toolStrategy == .normal)
    #expect(posture.posture == "steady")
    #expect(posture.claimDiscipline == .normal)
    #expect(!posture.directives.contains { $0.contains("brittleness") })

    // Same confidence, a PROVEN read: the optimistic strategy is available.
    let proven = BodySchema(
        toolCapabilityReading: ToolCapabilityReading(
            generatedAt: now,
            configured: true,
            liveCapabilityObserved: true,
            evidence: [evidence("tool-live", .liveToolCapability, at: now.addingTimeInterval(-300))]
        )
    )
    let provenPosture = try #require(OrganismBehaviorPosture.from(snapshot: optimismSnapshot(
        bodySchema: proven, predictionSummary: confidentInTools
    )))
    #expect(provenPosture.toolStrategy == .preferKnownPath)
}

@Test func realBrittlenessStillRaisesRealCaution() throws {
    let body = BodySchema(providersHealthy: false)
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: optimismSnapshot(bodySchema: body)))

    #expect(posture.posture == "careful")
    #expect(posture.claimDiscipline == .verifyBeforeCompletion)
    #expect(posture.directives.contains { $0.contains("brittleness") })
}

@Test func aFullyProvenBodyStaysSteady() throws {
    let now = Date(timeIntervalSince1970: 500_000)
    let body = BodySchema(
        memoryIntegrityReading: MemoryIntegrityReading(
            generatedAt: now,
            storeAvailable: true,
            maintenanceSucceeded: true,
            evidence: [evidence("memory-store", .localStorePresence, at: now)]
        ),
        toolCapabilityReading: ToolCapabilityReading(
            generatedAt: now,
            configured: true,
            liveCapabilityObserved: true,
            evidence: [evidence("tool-live", .liveToolCapability, at: now.addingTimeInterval(-300))]
        ),
        approvalPathReading: ApprovalPathReading(
            generatedAt: now,
            writable: true,
            evidence: [evidence("approval-store", .approvalStore, at: now)]
        )
    )
    let posture = try #require(OrganismBehaviorPosture.from(snapshot: optimismSnapshot(bodySchema: body)))

    #expect(!body.toolPathIsUnprovenOrStale)
    #expect(posture.posture == "steady")
    #expect(posture.claimDiscipline == .normal)
}
