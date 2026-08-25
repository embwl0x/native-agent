import Foundation
import Testing
import PersistenceCore
@testable import SystemOps

// Ledger rows: systemops.routePlanResult.wireBridge, systemops.routePlanResult.decoder
//
// Silent-failure class: DROPPED ROW at a CROSS-VOCABULARY SEAM. The Mac app
// does exactly this, in one line, with no fallback:
//
//   NativeClient+ProviderWorkflowGraph.swift:315
//     try JSONDecoder().decode(IntentRoutePlan.self, from: swiftResult.toJSON().serializedData())
//
// Core speaks `RoutePlanResult` (JSONValue bag); the app speaks
// `IntentRoutePlan` (Swift Codable, with `matchedCapabilities: [CapabilityRecord]`
// whose `id` and `kind` are NON-optional). Nothing on either side of that decode
// is type-checked against the other. If a produced capability record ever lacks
// `id` or `kind`, or a top-level key is renamed, the decode throws and the whole
// route plan silently vanishes from the workflow graph.
//
// `AppSideRoutePlanMirror` below is a byte-for-byte transcription of the app's
// IntentRoutePlan/CapabilityRecord shapes (same field names, same optionality).
// It is a TEST-side mirror on purpose: the core package cannot import
// NativeAgentApp, and pinning the mirror is what makes a drift on either side
// fail here instead of in the UI.

private struct AppSideCapabilityRecordMirror: Codable, Hashable {
    var id: String
    var sourceId: String?
    var name: String?
    var kind: String
    var status: String?
    var description: String?
    var triggers: [String]?
    var permissions: [String]?
    var riskClass: String?
    var autoload: Bool?
    var useCount: Int?
    var lastUsedAt: String?
    var updatedAt: String?
}

private struct AppSideRoutePlanMirror: Codable, Hashable {
    var id: String
    var message: String
    var goalType: String
    var recommendedSurface: String?
    var risk: String
    var requiresApproval: Bool
    var matchedCapabilities: [AppSideCapabilityRecordMirror]
    var nextActions: [String]
    var createdAt: String?
}

/// Messages chosen to walk every goalType branch that produces a different
/// surface / risk / readiness combination, so the seam is exercised on the real
/// capability catalog rather than one lucky route.
private let routeProbeMessages: [String] = [
    "where does the nativeagent repo stand right now",
    "research the state of on-device embeddings",
    "build me a workflow that files the weekly report",
    "send an email to the team about the release",
    "schedule a dentist appointment for next tuesday",
    "remember that I prefer the dry register",
    "open safari and click the download button",
    "read the file at Sources/main.swift and summarize it",
    "go to https://example.com and tell me what changed",
    "what do you think about this",
]

private func planner() -> SwiftNativeRouterPlanClient {
    SwiftNativeRouterPlanClient(
        now: { Date(timeIntervalSince1970: 1_787_000_000) },
        idFactory: { "route-fixed-id" }
    )
}

@Test("every real route plan decodes as the app's IntentRoutePlan")
func routePlanCrossesTheAppSeam() async throws {
    let client = planner()
    for message in routeProbeMessages {
        let result = try await client.planRoute(message: message)
        let bytes = try result.toJSON().serializedData(pretty: false)
        let decoded: AppSideRoutePlanMirror
        do {
            decoded = try JSONDecoder().decode(AppSideRoutePlanMirror.self, from: bytes)
        } catch {
            Issue.record("app-side decode failed for \(message.debugDescription): \(error)")
            continue
        }
        #expect(decoded.id == result.id)
        #expect(decoded.message == result.message)
        #expect(decoded.goalType == result.goalType)
        #expect(decoded.recommendedSurface == result.recommendedSurface)
        #expect(decoded.risk == result.risk)
        #expect(decoded.requiresApproval == result.requiresApproval)
        #expect(decoded.nextActions == result.nextActions)
        #expect(decoded.matchedCapabilities.count == result.matchedCapabilities.count)
        // The app's CapabilityRecord makes `id` and `kind` non-optional. A
        // produced record missing either one throws above and takes the whole
        // plan with it, so pin the invariant explicitly too.
        for record in decoded.matchedCapabilities {
            #expect(!record.id.isEmpty)
            #expect(!record.kind.isEmpty)
        }
    }
}

@Test("the route planner actually matches capabilities — the seam is not vacuously empty")
func routePlanCarriesRealCapabilities() async throws {
    let client = planner()
    var total = 0
    for message in routeProbeMessages {
        total += try await client.planRoute(message: message).matchedCapabilities.count
    }
    // If the capability catalog ever silently empties, every decode above still
    // passes (an empty array is valid) while the workflow graph shows nothing.
    #expect(total > 0, "no route in the probe set matched any capability")
}

@Test("toJSON emits exactly the documented key set")
func routePlanEmitsDocumentedKeys() async throws {
    let result = try await planner().planRoute(message: "where does the nativeagent repo stand")
    guard case .object(let wire) = result.toJSON() else {
        Issue.record("toJSON did not produce an object")
        return
    }
    #expect(Set(wire.keys) == Set([
        "id", "message", "goalType", "recommendedSurface", "contextMode", "risk",
        "requiresApproval", "matchedCapabilities", "toolReadinessGroups",
        "nextActions", "createdAt",
    ]))
    // `contextMode` and `toolReadinessGroups` are core-only — the app mirror
    // ignores them, which is fine, but they must still be on the wire for the
    // readiness lane.
    #expect(wire["contextMode"] != nil)
    #expect(wire["toolReadinessGroups"] != nil)
}

@Test("toJSON → init(from:) is a lossless round-trip on live route plans")
func routePlanDecoderRoundTripsLivePlans() async throws {
    let client = planner()
    for message in routeProbeMessages {
        let result = try await client.planRoute(message: message)
        let reparsed = try RoutePlanResult(
            from: try JSONValue.parse(try result.toJSON().serializedData(pretty: true))
        )
        #expect(reparsed == result, "round-trip drifted for \(message.debugDescription)")
    }
}

@Test("the decoder rejects a missing required string instead of substituting an empty one")
func routePlanDecoderRejectsMissingStrings() {
    let complete: [String: JSONValue] = [
        "id": .string("r-1"),
        "message": .string("hello"),
        "goalType": .string("chat"),
        "recommendedSurface": .string("chat"),
        "contextMode": .string("default"),
        "risk": .string("low"),
        "requiresApproval": .bool(false),
        "matchedCapabilities": .array([]),
        "toolReadinessGroups": .array([]),
        "nextActions": .array([]),
        "createdAt": .string("2026-08-23T10:00:00Z"),
    ]
    #expect(throws: Never.self) { _ = try RoutePlanResult(from: .object(complete)) }

    for key in ["id", "message", "goalType", "recommendedSurface", "contextMode", "risk", "createdAt"] {
        var broken = complete
        broken.removeValue(forKey: key)
        #expect(throws: SystemOpsError.self, "missing '\(key)' was silently accepted") {
            _ = try RoutePlanResult(from: .object(broken))
        }
        var wrongType = complete
        wrongType[key] = .int(7)
        #expect(throws: SystemOpsError.self, "wrong-typed '\(key)' was silently accepted") {
            _ = try RoutePlanResult(from: .object(wrongType))
        }
    }

    #expect(throws: SystemOpsError.self) { _ = try RoutePlanResult(from: .array([])) }
    #expect(throws: SystemOpsError.self) { _ = try RoutePlanResult(from: .null) }
}

@Test("the decoder's tolerant fields degrade to empty rather than crashing or half-reading")
func routePlanDecoderTolerantFieldsDegradeCleanly() throws {
    let base: [String: JSONValue] = [
        "id": .string("r-1"),
        "message": .string("hello"),
        "goalType": .string("chat"),
        "recommendedSurface": .string("chat"),
        "contextMode": .string("default"),
        "risk": .string("low"),
        "createdAt": .string("2026-08-23T10:00:00Z"),
    ]
    // Missing entirely.
    let bare = try RoutePlanResult(from: .object(base))
    #expect(bare.requiresApproval == false)
    #expect(bare.matchedCapabilities.isEmpty)
    #expect(bare.nextActions.isEmpty)
    #expect(bare.toolReadinessGroups.isEmpty)

    // Wrong-typed booleans fail CLOSED — an approval gate must never widen on a
    // malformed wire value.
    for poison: JSONValue in [.string("true"), .int(1), .null, .array([])] {
        var body = base
        body["requiresApproval"] = poison
        #expect(try RoutePlanResult(from: .object(body)).requiresApproval == false)
    }

    // Non-string entries in the string arrays are dropped, not crashed on, and
    // the surviving entries keep their order.
    var mixed = base
    mixed["nextActions"] = .array([.string("first"), .int(3), .null, .string("second")])
    mixed["toolReadinessGroups"] = .array([.string("builder"), .object([:]), .string("files")])
    let decoded = try RoutePlanResult(from: .object(mixed))
    #expect(decoded.nextActions == ["first", "second"])
    #expect(decoded.toolReadinessGroups == ["builder", "files"])
}

@Test("matchedCapabilities are carried opaquely — the decoder never reshapes them")
func routePlanDecoderCarriesCapabilitiesOpaquely() throws {
    let capability = JSONValue.object([
        "id": .string("cap-1"),
        "kind": .string("skill"),
        "unknownFutureField": .array([.string("keep me")]),
        "nested": .object(["depth": .int(2)]),
    ])
    let body: [String: JSONValue] = [
        "id": .string("r-1"),
        "message": .string("hello"),
        "goalType": .string("chat"),
        "recommendedSurface": .string("chat"),
        "contextMode": .string("default"),
        "risk": .string("low"),
        "createdAt": .string("2026-08-23T10:00:00Z"),
        "matchedCapabilities": .array([capability]),
    ]
    let decoded = try RoutePlanResult(from: .object(body))
    #expect(decoded.matchedCapabilities == [capability])
    #expect(try RoutePlanResult(from: decoded.toJSON()).matchedCapabilities == [capability])
}
