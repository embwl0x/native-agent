import Foundation
import Testing
@testable import CognitiveSubstrate

@Test func peerPresenceUsesLocalReceiptTimeInsteadOfSourceClock() throws {
    let now = Date(timeIntervalSince1970: 50_000)
    let evidence = BodyEvidenceReference(
        id: "signed-peer-event",
        evidenceClass: .signedPeerContact,
        observedAt: now.addingTimeInterval(30 * 24 * 60 * 60),
        receivedAt: now.addingTimeInterval(-10)
    )
    let belief = PeerPresenceBelief(
        generatedAt: now,
        evidence: [evidence],
        staleAfter: 60
    )

    #expect(belief.category == .present)
    #expect(belief.compatibilityReachable)
    #expect(belief.freshness > 0.5)
    #expect(belief.observedAt == evidence.observedAt)
    #expect(belief.receivedAt == evidence.receivedAt)
    #expect(belief.nextMeaningfulExpiry == evidence.receivedAt.addingTimeInterval(60))
}

@Test func bodyEvidenceRejectsFutureLocalReceiptsAndDeduplicatesIDs() throws {
    let now = Date(timeIntervalSince1970: 60_000)
    let duplicate = BodyEvidenceReference(
        id: "same-event",
        evidenceClass: .signedPeerContact,
        observedAt: now,
        receivedAt: now
    )
    let future = BodyEvidenceReference(
        id: "future-event",
        evidenceClass: .signedPeerContact,
        observedAt: now,
        receivedAt: now.addingTimeInterval(600)
    )
    let belief = PeerPresenceBelief(
        generatedAt: now,
        evidence: [duplicate, duplicate, future]
    )

    #expect(belief.evidence.count == 1)
    #expect(belief.evidence.first?.id == duplicate.id)
    #expect(!belief.evidence.contains(where: { $0.id == future.id }))
}

@Test func notificationAcceptanceNeverClaimsDisplayOrUserAttention() throws {
    let now = Date(timeIntervalSince1970: 70_000)
    let accepted = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true,
        transportAccepted: true,
        evidence: [BodyEvidenceReference(
            id: "apns-accepted",
            evidenceClass: .apnsAcceptance,
            observedAt: now,
            receivedAt: now
        )]
    )

    #expect(accepted.category == .transportAccepted)
    #expect(accepted.transportAccepted)
    #expect(!accepted.deviceReceived)
    #expect(!accepted.displayed)
    #expect(!accepted.userSeen)
    #expect(accepted.compatibilityPathHealthy == nil)
    #expect(accepted.uncertainty == 1)
}

@Test func hostileNotificationDecodeRederivesCategoryFromExactFacts() throws {
    let now = Date(timeIntervalSince1970: 80_000)
    let original = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true,
        transportAccepted: true,
        evidence: [BodyEvidenceReference(
            id: "accepted-proof",
            evidenceClass: .apnsAcceptance,
            observedAt: now,
            receivedAt: now
        )]
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["category"] = NotificationDeliveryCategory.userSeen.rawValue
    let hostile = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(NotificationDeliveryBelief.self, from: hostile)

    #expect(decoded.category == .transportAccepted)
    #expect(!decoded.userSeen)
    #expect(!decoded.displayed)
}

@Test func hostileNotificationBooleanRequiresMatchingEvidenceClass() throws {
    let now = Date(timeIntervalSince1970: 85_000)
    let configured = NotificationDeliveryBelief(
        generatedAt: now,
        transportConfigured: true
    )
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(configured)) as? [String: Any]
    )
    object["deviceReceived"] = true
    object["displayed"] = true
    object["userSeen"] = true
    let decoded = try JSONDecoder().decode(
        NotificationDeliveryBelief.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.category == .configured)
    #expect(!decoded.deviceReceived)
    #expect(!decoded.displayed)
    #expect(!decoded.userSeen)
}

@Test func configuredToolPathDoesNotMasqueradeAsLiveHealth() throws {
    let now = Date(timeIntervalSince1970: 90_000)
    let reading = ToolCapabilityReading(
        generatedAt: now,
        configured: true,
        liveCapabilityObserved: false,
        evidence: [BodyEvidenceReference(
            id: "mcp-config",
            evidenceClass: .toolConfiguration,
            observedAt: now,
            receivedAt: now
        )]
    )

    #expect(reading.category == .configured)
    #expect(reading.compatibilityAvailable == true)
    #expect(reading.uncertainty == 0.5)
}

@Test func resourcePressureIsExactAndHostileCategoryCannotOverrideInputs() throws {
    let now = Date(timeIntervalSince1970: 100_000)
    let reading = ResourcePressureReading(
        generatedAt: now,
        thermalPressure: .nominal,
        lowPowerMode: true,
        evidence: []
    )
    var object = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as? [String: Any]
    )
    object["category"] = OrganismResourcePressure.critical.rawValue
    if var metrics = object["metrics"] as? [String: Any] {
        metrics["estimate"] = Double.nan
        metrics["uncertainty"] = 99
        metrics["freshness"] = -99
        object["metrics"] = metrics
    }
    // JSON cannot carry NaN, so encode the hostile finite range separately.
    if var metrics = object["metrics"] as? [String: Any] {
        metrics["estimate"] = 99
        object["metrics"] = metrics
    }
    let decoded = try JSONDecoder().decode(
        ResourcePressureReading.self,
        from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded.category == .elevated)
    #expect(abs(decoded.estimate - (1.0 / 3.0)) < 0.000_001)
    #expect(decoded.uncertainty == 0)
    #expect(decoded.freshness == 1)
}

@Test func typedBodyReadsRemainTransientAcrossPersistence() throws {
    let now = Date(timeIntervalSince1970: 110_000)
    let body = BodySchema(
        peerPresenceBelief: PeerPresenceBelief(generatedAt: now, evidence: []),
        notificationDeliveryBelief: NotificationDeliveryBelief(
            generatedAt: now,
            transportConfigured: true
        ),
        memoryIntegrityReading: MemoryIntegrityReading(
            generatedAt: now,
            storeAvailable: true,
            maintenanceSucceeded: true,
            evidence: []
        ),
        dreamIntegrityReading: DreamIntegrityReading(
            generatedAt: now,
            storeAvailable: true,
            completionEvidence: []
        ),
        toolCapabilityReading: ToolCapabilityReading(
            generatedAt: now,
            configured: true,
            liveCapabilityObserved: false,
            evidence: []
        ),
        approvalPathReading: ApprovalPathReading(generatedAt: now, writable: true, evidence: []),
        resourcePressureReading: ResourcePressureReading(
            generatedAt: now,
            thermalPressure: .nominal,
            lowPowerMode: false,
            evidence: []
        )
    )
    let data = try JSONEncoder().encode(body)
    let text = String(decoding: data, as: UTF8.self)
    let restored = try JSONDecoder().decode(BodySchema.self, from: data)

    #expect(!text.contains("peerPresenceBelief"))
    #expect(!text.contains("notificationDeliveryBelief"))
    #expect(!text.contains("memoryIntegrityReading"))
    #expect(restored.peerPresenceBelief == nil)
    #expect(restored.notificationDeliveryBelief == nil)
    #expect(restored.memoryIntegrityReading == nil)
    #expect(restored.dreamIntegrityReading == nil)
    #expect(restored.toolCapabilityReading == nil)
    #expect(restored.approvalPathReading == nil)
    #expect(restored.resourcePressureReading == nil)

    let observationalOnly = BodySchema(
        memoryIntegrityReading: MemoryIntegrityReading(
            generatedAt: now,
            storeAvailable: true,
            maintenanceSucceeded: true,
            evidence: []
        )
    )
    #expect(OrganismProjection(generatedAt: now, bodySchema: observationalOnly).isNeutral)
}

@Test func typedBodyDomainAblationChangesOnlyItsCompatibilityProjection() throws {
    let now = Date(timeIntervalSince1970: 120_000)
    let baseline = BodySchema(
        iPhoneReachable: true,
        memoryHealthy: true,
        dreamHealthy: true,
        toolHandsAvailable: true,
        approvalChannelsOpen: true,
        notificationPathHealthy: true,
        resourcePressure: .nominal
    )
    let degradedMemory = MemoryIntegrityReading(
        generatedAt: now,
        storeAvailable: true,
        maintenanceSucceeded: false,
        evidence: []
    )
    let result = OrganismBodySchemaSampler.bodySchema(
        from: OrganismBodyRead(memoryIntegrityReading: degradedMemory),
        previous: baseline,
        now: now
    )

    #expect(result.memoryHealthy == false)
    #expect(result.memoryIntegrityReading == degradedMemory)
    #expect(result.iPhoneReachable == baseline.iPhoneReachable)
    #expect(result.dreamHealthy == baseline.dreamHealthy)
    #expect(result.toolHandsAvailable == baseline.toolHandsAvailable)
    #expect(result.approvalChannelsOpen == baseline.approvalChannelsOpen)
    #expect(result.notificationPathHealthy == baseline.notificationPathHealthy)
    #expect(result.resourcePressure == baseline.resourcePressure)
}
