import Testing
import Foundation
@testable import TrustCenter
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.unifiedPolicyDecision.toJSONValue
//   • core.trust.unifiedPolicyDecision.turnPlan
//
// `toJSONValue()` is the ONLY serialisation contract for the policy decision
// that lands in the turn record (TurnPlanning.swift persists it as
// payload["policyDecision"]) and it is what a Turn Inspector reader parses.
// Nothing asserted its key set: a rename or an omitted key makes the consumer
// read a default instead of erroring, so a turn that WAS gated renders as
// ungated with no parse failure anywhere.
//
// `turnPlan(...)` flips outcome AND the user-facing reason on
// `requiresApprovalHint` alone. If the hint stops being computed upstream the
// decision silently reads .allow with the reassuring "tool actions re-evaluate
// before dispatch" copy.

/// The persisted schema, dated 2026-08-23. Every key a consumer may read.
private let policyDecisionKeys: Set<String> = [
    "actionKind", "actor", "surface", "requestedAction", "requestedCapability",
    "dataScope", "sideEffectLevel", "outcome", "reason", "policySource",
    "expiresAt", "fullMacActive", "developerMode", "remoteSurface", "surfaceTrusted",
]

private func decisionObject(_ decision: UnifiedPolicyDecision) -> [String: JSONValue] {
    guard case .object(let obj) = decision.toJSONValue() else { return [:] }
    return obj
}

@Test func UnifiedPolicyDecision_toJSONValue_emitsExactlyThePersistedKeySet() {
    let decision = UnifiedPolicyDecision.turnPlan(
        surface: "chat", actor: "session:abc", goalType: "build",
        risk: "high", requiresApprovalHint: true, fileAccess: "workspace",
        fullMacActive: true, developerMode: false,
        remoteSurface: false, surfaceTrusted: true,
        expiresAt: "never"
    )
    let obj = decisionObject(decision)
    #expect(Set(obj.keys) == policyDecisionKeys, """
        the persisted policyDecision schema changed.
          added: \(Set(obj.keys).subtracting(policyDecisionKeys).sorted())
          dropped: \(policyDecisionKeys.subtracting(obj.keys).sorted())
        A dropped key makes a Turn Inspector read a DEFAULT instead of erroring —
        a gated turn renders as ungated. Update every consumer, then this pin.
        """)

    // Types are part of the contract: a bool that becomes a string reads as a
    // truthy default in a lenient consumer.
    #expect(obj["fullMacActive"] == .bool(true))
    #expect(obj["developerMode"] == .bool(false))
    #expect(obj["remoteSurface"] == .bool(false))
    #expect(obj["surfaceTrusted"] == .bool(true))
    #expect(obj["outcome"] == .string(UnifiedPolicyOutcome.confirm.rawValue))
    #expect(obj["expiresAt"] == .string("never"))
    for key in ["actionKind", "actor", "surface", "requestedAction",
                "requestedCapability", "dataScope", "sideEffectLevel",
                "reason", "policySource"] {
        if case .string(let s)? = obj[key] {
            #expect(!s.isEmpty, "\(key) serialised as an empty string")
        } else {
            Issue.record("\(key) is not a string in the persisted decision")
        }
    }
}

/// A nil expiry must serialise as an explicit null, not vanish — a missing key
/// and "no expiry" are different facts to a reader.
@Test func UnifiedPolicyDecision_toJSONValue_nilExpiryIsAnExplicitNull() {
    let decision = UnifiedPolicyDecision.turnPlan(
        surface: "chat", actor: "session:abc", goalType: "",
        risk: "", requiresApprovalHint: false, fileAccess: "",
        fullMacActive: false, developerMode: false,
        remoteSurface: false, surfaceTrusted: false,
        expiresAt: nil
    )
    let obj = decisionObject(decision)
    #expect(Set(obj.keys) == policyDecisionKeys, "the key set is not stable across a nil expiry")
    #expect(obj["expiresAt"] == .null)
    // Empty inputs must still produce non-empty envelope values.
    #expect(obj["requestedAction"] == .string("chat"))
    #expect(obj["dataScope"] == .string("auto"))
    #expect(obj["sideEffectLevel"] == .string("low"))
}

/// The envelope-derived decision — the other producer that lands in the same
/// persisted slot — must emit the SAME key set. Two producers, one schema.
@Test func UnifiedPolicyDecision_bothProducersEmitTheSameSchema() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnifiedPolicySchema-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await seedHermeticTrustPolicy([
        "permissionLevel": .string("balanced"),
        "toolAutonomy": .object(["default": .string("auto")]),
    ], at: root)

    let envelope = await SwiftNativeSecurityCenter(dataRoot: root).evaluateTool(
        tool: "email.send",
        input: ["to": .string("someone@example.com"), "body": .string("hi")],
        origin: SecurityOriginContext(surface: "chat")
    )
    let fromEnvelope = envelope.unifiedPolicyDecision(
        fullMacActive: false, developerMode: false, expiresAt: nil)
    #expect(Set(decisionObject(fromEnvelope).keys) == policyDecisionKeys)

    // And the envelope's own decision must survive the projection: an .ask
    // envelope may not serialise as an allow.
    #expect(fromEnvelope.outcome != .allow || envelope.decision == .allow,
            "an approval-gated envelope projected to outcome=allow")
}

/// The hint is the ONLY thing that flips the turn-plan outcome and its copy.
/// Pin both directions so a hint that stops being computed upstream shows up
/// as a changed decision, not as reassuring text.
@Test func UnifiedPolicyDecision_turnPlan_outcomeAndReasonFollowTheApprovalHint() {
    func plan(_ hint: Bool) -> UnifiedPolicyDecision {
        UnifiedPolicyDecision.turnPlan(
            surface: "chat", actor: "session:abc", goalType: "build",
            risk: "high", requiresApprovalHint: hint, fileAccess: "workspace",
            fullMacActive: false, developerMode: false,
            remoteSurface: false, surfaceTrusted: true,
            expiresAt: nil
        )
    }
    let gated = plan(true)
    let open = plan(false)

    #expect(gated.outcome == .confirm)
    #expect(open.outcome == .allow)
    #expect(gated.reason != open.reason,
            "both hint values produce the same user-facing reason")
    #expect(gated.reason.lowercased().contains("approval"),
            "the gated reason does not say approval: \(gated.reason)")
    #expect(open.reason.lowercased().contains("re-evaluate"),
            "the ungated reason drops its 're-evaluated before dispatch' promise: \(open.reason)")

    // Everything else about the two decisions must be identical — the hint may
    // not silently move the actor, surface, scope or risk.
    #expect(gated.actionKind == open.actionKind)
    #expect(gated.actor == open.actor)
    #expect(gated.surface == open.surface)
    #expect(gated.requestedAction == open.requestedAction)
    #expect(gated.requestedCapability == open.requestedCapability)
    #expect(gated.dataScope == open.dataScope)
    #expect(gated.sideEffectLevel == open.sideEffectLevel)
    #expect(gated.policySource == open.policySource)
}
