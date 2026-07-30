import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

private func makeBodyReaderRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeCognitionRuntimeBodyReader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func organismBodyReaderUsesProviderCredentialWithoutLeakingSecret() throws {
    let root = try makeBodyReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let providerDir = root.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providerDir, withIntermediateDirectories: true)
    try #"{"provider_fixture":"credential_value"}"#.write(
        to: providerDir.appendingPathComponent("openai_oauth_direct.json"),
        atomically: true,
        encoding: .utf8
    )

    let read = NativeCognitionRuntime.makeOrganismBodyRead(
        dataRoot: root,
        now: Date(timeIntervalSince1970: 10_000)
    )
    let exported = String(describing: read).lowercased()

    #expect(read.providersAvailable == true)
    #expect(read.providersHealthy == nil)
    #expect(!exported.contains("credential_value"))
    #expect(!exported.contains("provider_fixture"))
}

@Test func organismBodyReaderProviderAvailabilityIsHermeticToInjectedRoot() throws {
    let configuredRoot = try makeBodyReaderRoot()
    let emptyRoot = try makeBodyReaderRoot()
    defer {
        try? FileManager.default.removeItem(at: configuredRoot)
        try? FileManager.default.removeItem(at: emptyRoot)
    }

    let providerDir = configuredRoot.appendingPathComponent("providers", isDirectory: true)
    try FileManager.default.createDirectory(at: providerDir, withIntermediateDirectories: true)
    try #"{"provider_fixture":"credential_value"}"#.write(
        to: providerDir.appendingPathComponent("openai_oauth_direct.json"),
        atomically: true,
        encoding: .utf8
    )

    let configured = NativeCognitionRuntime.makeOrganismBodyRead(
        dataRoot: configuredRoot,
        now: Date(timeIntervalSince1970: 10_000)
    )
    let empty = NativeCognitionRuntime.makeOrganismBodyRead(
        dataRoot: emptyRoot,
        now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(configured.providersAvailable == true)
    #expect(empty.providersAvailable == false)
    #expect(configured.providersHealthy == nil)
    #expect(empty.providersHealthy == nil)
}

@Test func organismBodyReaderDoesNotTreatMobileTokenFreshnessAsPeerContact() throws {
    let root = try makeBodyReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 10_000)
    let tokenDir = root.appendingPathComponent("mobile_push", isDirectory: true)
    try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
    try """
    [
      {
        "deviceId": "test-device",
        "token": "fixture-mobile-value",
        "updatedAt": "1970-01-01T02:45:00Z"
      }
    ]
    """.write(to: tokenDir.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)

    let read = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    let body = OrganismBodySchemaSampler.bodySchema(
        from: read,
        previous: BodySchema(iPhoneReachable: true, notificationPathHealthy: true),
        now: now
    )
    let exported = String(describing: read).lowercased()

    #expect(body.iPhoneReachable == false)
    #expect(body.notificationPathHealthy == false)
    #expect(!exported.contains("fixture-mobile-value"))
}

@Test func organismBodyReaderIgnoresRetiredLegacyPairingFile() throws {
    let root = try makeBodyReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mobileRoot = root.appendingPathComponent("mobile", isDirectory: true)
    try FileManager.default.createDirectory(at: mobileRoot, withIntermediateDirectories: true)
    try #"{"pairings":{"retired-token":{"expires_at":"2099-01-01T00:00:00Z"}}}"#
        .write(
            to: mobileRoot.appendingPathComponent("pairing.json"),
            atomically: true,
            encoding: .utf8
        )

    let now = Date(timeIntervalSince1970: 10_000)
    let read = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    let body = OrganismBodySchemaSampler.bodySchema(from: read, now: now)

    #expect(read.peerPresenceBelief?.category == .unobserved)
    #expect(read.notificationDeliveryBelief?.category == .unconfigured)
    #expect(body.iPhoneReachable == false)
}

@Test func organismBodyReaderMapsFreshSignedPeerEvidence() async throws {
    let root = try makeBodyReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 10_000)
    let tokenDir = root.appendingPathComponent("mobile_push", isDirectory: true)
    try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
    try """
    [
      {
        "deviceId": "test-device",
        "token": "fixture-mobile-value",
        "updatedAt": "1970-01-01T02:45:00Z"
      }
    ]
    """.write(to: tokenDir.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    try await SignedPeerEvidenceStore.record(
        eventID: "signed-event-fixture",
        channel: .inboxAction,
        peerCreatedAt: now.addingTimeInterval(-3),
        observedAt: now.addingTimeInterval(-2),
        dataRoot: root
    )

    let read = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    let body = OrganismBodySchemaSampler.bodySchema(from: read, now: now)

    #expect(body.iPhoneReachable == true)
    #expect(body.notificationPathHealthy == true)
    #expect(read.iPhoneLastSeenAt == now.addingTimeInterval(-2))
}

@Test func signedPeerEvidenceKeepsNewestAuthenticatedObservation() async throws {
    let root = try makeBodyReaderRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let newer = Date(timeIntervalSince1970: 20_000)
    try await SignedPeerEvidenceStore.record(
        eventID: "newer",
        channel: .chat,
        peerCreatedAt: newer,
        observedAt: newer,
        dataRoot: root
    )
    try await SignedPeerEvidenceStore.record(
        eventID: "older-finishes-late",
        channel: .inboxAction,
        peerCreatedAt: newer.addingTimeInterval(-10),
        observedAt: newer.addingTimeInterval(-5),
        dataRoot: root
    )

    let evidence = try #require(SignedPeerEvidenceStore.load(dataRoot: root))
    #expect(evidence.eventID == "newer")
    #expect(evidence.channel == .chat)
    #expect(evidence.observedAt == newer)
}

@Test func organismDebugScenarioMapsProviderBrittleWithoutTouchingFiles() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let base = OrganismBodyRead(
        macAwake: true,
        iPhoneReachable: true,
        providersHealthy: true,
        memoryHealthy: true,
        dreamHealthy: true,
        toolHandsAvailable: true,
        approvalChannelsOpen: true,
        notificationPathHealthy: true,
        resourcePressure: .nominal
    )

    let read = NativeCognitionRuntime.simulatedOrganismBodyRead(
        base: base,
        scenario: .providerBrittle,
        now: now
    )
    let body = OrganismBodySchemaSampler.bodySchema(from: read, now: now)
    let projection = OrganismChemistry.projection(
        at: now,
        chemicalState: .neutral,
        bodySchema: body
    )

    #expect(body.providersHealthy == false)
    #expect(body.toolHandsAvailable == false)
    #expect(projection.bodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
}

@Test func organismDebugScenarioMapsStalePhonePath() throws {
    let now = Date(timeIntervalSince1970: 200_000)
    let base = OrganismBodyRead(
        macAwake: true,
        iPhoneReachable: true,
        iPhoneLastSeenAt: now,
        providersHealthy: true,
        memoryHealthy: true,
        dreamHealthy: true,
        toolHandsAvailable: true,
        approvalChannelsOpen: true,
        notificationPathHealthy: true,
        resourcePressure: .nominal
    )

    let read = NativeCognitionRuntime.simulatedOrganismBodyRead(
        base: base,
        scenario: .stalePhone,
        now: now
    )
    let body = OrganismBodySchemaSampler.bodySchema(from: read, now: now)

    #expect(body.iPhoneReachable == false)
    #expect(body.notificationPathHealthy == false)
}

@Test func organismDebugScenariosMapResourceMemoryAndApprovalPressure() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let base = OrganismBodyRead(
        macAwake: true,
        iPhoneReachable: true,
        providersHealthy: true,
        memoryHealthy: true,
        dreamHealthy: true,
        toolHandsAvailable: true,
        approvalChannelsOpen: true,
        notificationPathHealthy: true,
        resourcePressure: .nominal
    )

    let resource = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base,
            scenario: .resourceTight,
            now: now
        ),
        now: now
    )
    let memory = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base,
            scenario: .memoryBrittle,
            now: now
        ),
        now: now
    )
    let approval = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base,
            scenario: .approvalClosed,
            now: now
        ),
        now: now
    )

    #expect(resource.resourcePressure == .critical)
    #expect(memory.memoryHealthy == false)
    #expect(approval.approvalChannelsOpen == false)
}

@Test func organismDebugScenariosPerturbProductionTypedBeliefs() throws {
    let now = Date(timeIntervalSince1970: 30_000)
    let evidence: (String, BodyEvidenceClass) -> BodyEvidenceReference = { id, kind in
        BodyEvidenceReference(
            id: id, evidenceClass: kind, observedAt: now, receivedAt: now
        )
    }
    let base = OrganismBodyRead(
        macAwake: true,
        providersHealthy: true,
        providersAvailable: true,
        providerPathBelief: ProviderPathBeliefProjection(
            generatedAt: now, estimate: 1, freshness: 1, uncertainty: 0,
            evidenceCount: 1, newestEvidenceAt: now, state: .healthy,
            bodySchemaProvidersHealthy: true
        ),
        peerPresenceBelief: PeerPresenceBelief(
            generatedAt: now,
            evidence: [evidence("peer", .signedPeerContact)]
        ),
        notificationDeliveryBelief: NotificationDeliveryBelief(
            generatedAt: now, transportConfigured: true, deviceReceived: true,
            evidence: [evidence("notification", .deviceProcessReceipt)]
        ),
        memoryIntegrityReading: MemoryIntegrityReading(
            generatedAt: now, storeAvailable: true, maintenanceSucceeded: true,
            evidence: [evidence("memory", .maintenanceReceipt)]
        ),
        toolCapabilityReading: ToolCapabilityReading(
            generatedAt: now, configured: true, liveCapabilityObserved: true,
            evidence: [evidence("tool-config", .toolConfiguration),
                       evidence("tool-live", .liveToolCapability)]
        ),
        approvalPathReading: ApprovalPathReading(
            generatedAt: now, writable: true,
            evidence: [evidence("approval", .approvalStore)]
        ),
        resourcePressureReading: ResourcePressureReading(
            generatedAt: now, thermalPressure: .nominal, lowPowerMode: false,
            evidence: [evidence("thermal", .processThermalState)]
        )
    )

    let provider = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base, scenario: .providerBrittle, now: now
        ), now: now
    )
    let phone = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base, scenario: .stalePhone, now: now
        ), now: now
    )
    let resource = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base, scenario: .resourceTight, now: now
        ), now: now
    )
    let memory = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base, scenario: .memoryBrittle, now: now
        ), now: now
    )
    let approval = OrganismBodySchemaSampler.bodySchema(
        from: NativeCognitionRuntime.simulatedOrganismBodyRead(
            base: base, scenario: .approvalClosed, now: now
        ), now: now
    )

    #expect(provider.providerPathBelief?.state == .brittle)
    #expect(provider.toolCapabilityReading?.category == .unavailable)
    #expect(provider.providersHealthy == false)
    #expect(phone.peerPresenceBelief?.category == .stale)
    #expect(phone.notificationDeliveryBelief?.category == .failed)
    #expect(phone.iPhoneReachable == false)
    #expect(resource.resourcePressureReading?.category == .critical)
    #expect(resource.resourcePressure == .critical)
    #expect(memory.memoryIntegrityReading?.category == .degraded)
    #expect(memory.memoryHealthy == false)
    #expect(approval.approvalPathReading?.category == .closed)
    #expect(approval.approvalChannelsOpen == false)
}

@Test func bridgeCapsuleSummaryExtractsOnlyBodyLine() throws {
    let dynamic = """
    - Focus: keep the proof path tight.
    - Voice: direct, careful.
    - Body: provider or tool path feels brittle; be careful before claiming completion.
    """

    let bodyLine = NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: dynamic)

    #expect(bodyLine == "- Body: provider or tool path feels brittle; be careful before claiming completion.")
    #expect(NativeCognitionRuntime.bodyLine(inCapsuleDynamicContext: "- Inner: no body here") == nil)
}
