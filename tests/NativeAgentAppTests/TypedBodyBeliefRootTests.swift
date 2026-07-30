import Foundation
import Testing
import CognitiveSubstrate
@testable import NativeAgentApp

private func makeTypedBodyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypedBodyBeliefRoot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func bodyBeliefsRebuildFromCanonicalInjectedRootEvidence() async throws {
    let root = try makeTypedBodyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 2_000_000)

    try await SignedPeerEvidenceStore.record(
        eventID: "signed-peer-root-fixture",
        channel: .inboxAction,
        peerCreatedAt: now.addingTimeInterval(7 * 24 * 60 * 60),
        observedAt: now.addingTimeInterval(-30),
        dataRoot: root
    )

    let mobileRoot = root.appendingPathComponent("mobile_push", isDirectory: true)
    try FileManager.default.createDirectory(at: mobileRoot, withIntermediateDirectories: true)
    try #"[{"deviceId":"fixture","token":"private-token","updatedAt":"1970-01-24T03:33:20Z"}]"#
        .write(to: mobileRoot.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    let apnsDate = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20))
    try """
    {"apnsId":"apns-fixture","createdAt":"\(apnsDate)","status":"ok","httpStatus":200,"response":"","tokenSuffix":"private-suffix"}
    """.write(to: mobileRoot.appendingPathComponent("receipts.jsonl"), atomically: true, encoding: .utf8)

    let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
    try Data("sqlite-fixture".utf8).write(to: memoryRoot.appendingPathComponent("memory.sqlite"))
    try #"{"status":"failed"}"#.write(
        to: memoryRoot.appendingPathComponent("hygiene_last_run.json"),
        atomically: true,
        encoding: .utf8
    )

    let dreamRoot = root.appendingPathComponent("dream_diary", isDirectory: true)
    try FileManager.default.createDirectory(at: dreamRoot, withIntermediateDirectories: true)
    let staleDream = ISO8601DateFormatter().string(from: now.addingTimeInterval(-11 * 24 * 60 * 60))
    try "{\"last_dreamed_at\":\"\(staleDream)\"}".write(
        to: dreamRoot.appendingPathComponent(".dream_state.json"),
        atomically: true,
        encoding: .utf8
    )

    let mcpRoot = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpRoot, withIntermediateDirectories: true)
    try #"{"fixture":{"command":"redacted"}}"#.write(
        to: mcpRoot.appendingPathComponent("servers.json"),
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("workflows/approvals", isDirectory: true),
        withIntermediateDirectories: true
    )

    let read = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    let body = OrganismBodySchemaSampler.bodySchema(from: read, now: now)
    let exported = String(describing: read).lowercased()

    #expect(read.peerPresenceBelief?.category == .present)
    #expect(read.peerPresenceBelief?.observedAt == now.addingTimeInterval(7 * 24 * 60 * 60))
    #expect(read.peerPresenceBelief?.receivedAt == now.addingTimeInterval(-30))
    #expect(body.iPhoneReachable)
    #expect(read.notificationDeliveryBelief?.category == .transportAccepted)
    #expect(read.notificationDeliveryBelief?.transportAccepted == true)
    #expect(read.notificationDeliveryBelief?.deviceReceived == false)
    #expect(read.notificationDeliveryBelief?.displayed == false)
    #expect(read.notificationDeliveryBelief?.userSeen == false)
    #expect(body.notificationPathHealthy)
    #expect(read.memoryIntegrityReading?.category == .degraded)
    #expect(body.memoryHealthy == false)
    #expect(read.dreamIntegrityReading?.category == .stale)
    #expect(body.dreamHealthy == false)
    #expect(read.toolCapabilityReading?.category == .configured)
    #expect(body.toolHandsAvailable)
    #expect(read.approvalPathReading?.category == .open)
    #expect(read.resourcePressureReading?.uncertainty == 0)
    #expect(!exported.contains("private-token"))
    #expect(!exported.contains("private-suffix"))
    #expect(!exported.contains(root.path.lowercased()))
}

@Test func liveDeviceProcessReceiptProjectsWithoutPersistedSelfRead() throws {
    let root = try makeTypedBodyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 3_000_000)

    let mobileRoot = root.appendingPathComponent("mobile_push", isDirectory: true)
    try FileManager.default.createDirectory(at: mobileRoot, withIntermediateDirectories: true)
    try #"[{"deviceId":"fixture","token":"private-token","updatedAt":"1970-02-04T17:20:00Z"}]"#
        .write(to: mobileRoot.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)

    let prediction = OrganismPrediction(
        id: "phone-delivery-fixture",
        kind: .phoneDelivery,
        sourceOrgan: "phone.fixture",
        createdAt: now.addingTimeInterval(-40),
        dueAt: now.addingTimeInterval(20),
        status: .satisfied,
        confidence: 0.9,
        uncertainty: 0.1,
        evidenceCount: 2,
        lastUpdatedAt: now.addingTimeInterval(-10)
    )
    // A conflicting persisted snapshot must not override the live owner read.
    let stalePrediction = OrganismPrediction(
        id: "stale-file-prediction",
        kind: .phoneDelivery,
        sourceOrgan: "phone.fixture",
        createdAt: now.addingTimeInterval(-60),
        dueAt: now.addingTimeInterval(-30),
        status: .violated,
        lastUpdatedAt: now.addingTimeInterval(-30)
    )
    let state = OrganismPersistentState(
        savedAt: now.addingTimeInterval(-30),
        predictionLedger: OrganismPredictionLedger(
            predictions: [stalePrediction.id: stalePrediction],
            violatedCount: 1,
            lastUpdatedAt: now.addingTimeInterval(-30)
        )
    )
    let cognitionRoot = root.appendingPathComponent("cognition", isDirectory: true)
    try FileManager.default.createDirectory(at: cognitionRoot, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(state).write(to: cognitionRoot.appendingPathComponent("organism_state.json"))

    let first = NativeCognitionRuntime.makeOrganismBodyRead(
        dataRoot: root,
        now: now,
        phoneDeliveryPrediction: prediction
    )
    let second = NativeCognitionRuntime.makeOrganismBodyRead(
        dataRoot: root,
        now: now.addingTimeInterval(1),
        phoneDeliveryPrediction: prediction
    )

    #expect(first.notificationDeliveryBelief?.category == .deviceReceived)
    #expect(first.notificationDeliveryBelief?.deviceReceived == true)
    #expect(first.notificationDeliveryBelief?.displayed == false)
    #expect(first.notificationDeliveryBelief?.userSeen == false)
    #expect(first.notificationDeliveryBelief?.compatibilityPathHealthy == true)
    #expect(second.notificationDeliveryBelief?.category == .deviceReceived)
}

@Test func typedBodyBeliefsDoNotBleedAcrossInjectedRoots() async throws {
    let observedRoot = try makeTypedBodyRoot()
    let emptyRoot = try makeTypedBodyRoot()
    defer {
        try? FileManager.default.removeItem(at: observedRoot)
        try? FileManager.default.removeItem(at: emptyRoot)
    }
    let now = Date(timeIntervalSince1970: 4_000_000)
    try await SignedPeerEvidenceStore.record(
        eventID: "observed-only",
        channel: .chat,
        peerCreatedAt: now,
        observedAt: now,
        dataRoot: observedRoot
    )

    let observed = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: observedRoot, now: now)
    let empty = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: emptyRoot, now: now)

    #expect(observed.peerPresenceBelief?.category == .present)
    #expect(empty.peerPresenceBelief?.category == .unobserved)
    #expect(observed.iPhoneReachable == true)
    #expect(empty.iPhoneReachable == false)
    #expect(empty.notificationDeliveryBelief?.deviceReceived == false)
}

@Test func emptyToolCatalogIsConfiguredOnlyAndFutureReceiptCannotMakeItLive() throws {
    let root = try makeTypedBodyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 5_000_000)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("tools/active", isDirectory: true),
        withIntermediateDirectories: true
    )

    let configured = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    #expect(configured.toolCapabilityReading?.category == .configured)
    #expect(configured.toolCapabilityReading?.liveCapabilityObserved == false)

    let traceRoot = root.appendingPathComponent("traces", isDirectory: true)
    try FileManager.default.createDirectory(at: traceRoot, withIntermediateDirectories: true)
    let future = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))
    try """
    {"id":"future-tool","kind":"tool.dispatch","status":"ok","createdAt":"\(future)"}
    """.write(
        to: traceRoot.appendingPathComponent("events.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    let futureIgnored = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    #expect(futureIgnored.toolCapabilityReading?.category == .configured)
    #expect(futureIgnored.toolCapabilityReading?.liveCapabilityObserved == false)

    let current = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
    try """
    {"id":"current-tool","kind":"tool.dispatch","status":"ok","createdAt":"\(current)"}
    """.write(
        to: traceRoot.appendingPathComponent("events.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    let live = NativeCognitionRuntime.makeOrganismBodyRead(dataRoot: root, now: now)
    #expect(live.toolCapabilityReading?.category == .available)
    #expect(live.toolCapabilityReading?.liveCapabilityObserved == true)
    #expect(live.toolCapabilityReading?.nextMeaningfulExpiry == now.addingTimeInterval(-2 + 6 * 60 * 60))
}
