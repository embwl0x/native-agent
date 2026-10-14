import Foundation
import PersistenceCore

public enum UnifiedPolicyOutcome: String, Codable, Sendable, Equatable {
    case allow
    case confirm
    case deny
}

public struct UnifiedPolicyDecision: Codable, Sendable, Equatable {
    public var actionKind: String
    public var actor: String
    public var surface: String
    public var requestedAction: String
    public var requestedCapability: String
    public var dataScope: String
    public var sideEffectLevel: String
    public var outcome: UnifiedPolicyOutcome
    public var reason: String
    public var policySource: String
    public var expiresAt: String?
    public var fullMacActive: Bool
    public var developerMode: Bool
    public var remoteSurface: Bool
    public var surfaceTrusted: Bool

    public init(
        actionKind: String,
        actor: String,
        surface: String,
        requestedAction: String,
        requestedCapability: String,
        dataScope: String,
        sideEffectLevel: String,
        outcome: UnifiedPolicyOutcome,
        reason: String,
        policySource: String,
        expiresAt: String? = nil,
        fullMacActive: Bool,
        developerMode: Bool,
        remoteSurface: Bool,
        surfaceTrusted: Bool
    ) {
        self.actionKind = actionKind
        self.actor = actor
        self.surface = surface
        self.requestedAction = requestedAction
        self.requestedCapability = requestedCapability
        self.dataScope = dataScope
        self.sideEffectLevel = sideEffectLevel
        self.outcome = outcome
        self.reason = reason
        self.policySource = policySource
        self.expiresAt = expiresAt
        self.fullMacActive = fullMacActive
        self.developerMode = developerMode
        self.remoteSurface = remoteSurface
        self.surfaceTrusted = surfaceTrusted
    }

    public func toJSONValue() -> JSONValue {
        var payload: [String: JSONValue] = [
            "actionKind": .string(actionKind),
            "actor": .string(actor),
            "surface": .string(surface),
            "requestedAction": .string(requestedAction),
            "requestedCapability": .string(requestedCapability),
            "dataScope": .string(dataScope),
            "sideEffectLevel": .string(sideEffectLevel),
            "outcome": .string(outcome.rawValue),
            "reason": .string(reason),
            "policySource": .string(policySource),
            "fullMacActive": .bool(fullMacActive),
            "developerMode": .bool(developerMode),
            "remoteSurface": .bool(remoteSurface),
            "surfaceTrusted": .bool(surfaceTrusted),
        ]
        payload["expiresAt"] = expiresAt.map { .string($0) } ?? .null
        return .object(payload)
    }
}

public extension UnifiedPolicyDecision {
    static func turnPlan(
        surface: String,
        actor: String,
        goalType: String,
        risk: String,
        requiresApprovalHint: Bool,
        fileAccess: String,
        fullMacActive: Bool,
        developerMode: Bool,
        remoteSurface: Bool,
        surfaceTrusted: Bool,
        expiresAt: String?
    ) -> UnifiedPolicyDecision {
        UnifiedPolicyDecision(
            actionKind: "turn_plan",
            actor: actor,
            surface: surface,
            requestedAction: goalType.isEmpty ? "chat" : goalType,
            requestedCapability: "context_route",
            dataScope: fileAccess.isEmpty ? "auto" : fileAccess,
            sideEffectLevel: risk.isEmpty ? "low" : risk,
            outcome: requiresApprovalHint ? .confirm : .allow,
            reason: requiresApprovalHint
                ? "turn route predicts an approval-gated action"
                : "turn route is context planning only; tool actions re-evaluate before dispatch",
            policySource: "turn_plan",
            expiresAt: expiresAt,
            fullMacActive: fullMacActive,
            developerMode: developerMode,
            remoteSurface: remoteSurface,
            surfaceTrusted: surfaceTrusted
        )
    }
}
