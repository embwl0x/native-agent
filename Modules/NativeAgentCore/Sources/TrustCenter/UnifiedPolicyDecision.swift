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

public extension SecurityToolEnvelope {
    func unifiedPolicyDecision(
        fullMacActive: Bool,
        developerMode: Bool,
        expiresAt: String? = nil
    ) -> UnifiedPolicyDecision {
        let remote = UnifiedPolicyDecision.isRemoteSurface(surface) || origin.isRemote == true
        return UnifiedPolicyDecision(
            actionKind: UnifiedPolicyDecision.actionKind(for: capabilities),
            actor: UnifiedPolicyDecision.actor(from: origin),
            surface: surface,
            requestedAction: tool,
            requestedCapability: UnifiedPolicyDecision.primaryCapability(from: capabilities),
            dataScope: UnifiedPolicyDecision.dataScope(from: capabilities),
            sideEffectLevel: risk,
            outcome: UnifiedPolicyDecision.outcome(from: decision),
            reason: UnifiedPolicyDecision.primaryReason(
                envelope: self,
                fullMacActive: fullMacActive,
                developerMode: developerMode,
                remoteSurface: remote
            ),
            policySource: UnifiedPolicyDecision.policySource(
                envelope: self,
                fullMacActive: fullMacActive,
                developerMode: developerMode,
                remoteSurface: remote
            ),
            expiresAt: expiresAt,
            fullMacActive: fullMacActive,
            developerMode: developerMode,
            remoteSurface: remote,
            surfaceTrusted: originTrusted
        )
    }
}

extension UnifiedPolicyDecision {
    static func actor(from origin: SecurityOriginContext) -> String {
        if let source = nonEmpty(origin.source) { return source }
        if let userId = nonEmpty(origin.userId) { return "user:\(userId)" }
        if let deviceId = nonEmpty(origin.deviceId) { return "device:\(deviceId)" }
        if let chatId = nonEmpty(origin.chatId) { return "chat:\(chatId)" }
        if let sessionId = nonEmpty(origin.sessionId) { return "session:\(sessionId)" }
        return "surface:\(origin.surface)"
    }

    static func isRemoteSurface(_ surface: String) -> Bool {
        ConversationSurfaceProfile(surface).isRemote
    }

    static func actionKind(for capabilities: [String]) -> String {
        let set = Set(capabilities)
        if set.contains("external_send") { return "connector_send" }
        if set.contains("process_spawn") || set.contains("shell") { return "process" }
        if set.contains("system_control") { return "system_control" }
        if set.contains("filesystem_delete") { return "file_delete" }
        if set.contains("filesystem_write") { return "file_write" }
        if set.contains("memory_write") { return "memory_write" }
        if set.contains("network_write") { return "network_write" }
        if set.contains("network_read") { return "network_read" }
        if set.contains("safe_read") || set.contains("catalog_read") { return "read" }
        return "tool"
    }

    static func primaryCapability(from capabilities: [String]) -> String {
        let priority = [
            "destructive",
            "evolution_apply_trigger",
            "evolution_write",
            "shell",
            "process_spawn",
            "system_control",
            "outside_app_data_write",
            "filesystem_delete",
            "filesystem_write",
            "external_send",
            "network_write",
            "approval_stage",
            "memory_write",
            "network_read",
            "safe_read",
            "catalog_read",
            "notification",
            "tool_call",
        ]
        let set = Set(capabilities)
        return priority.first(where: { set.contains($0) }) ?? capabilities.sorted().first ?? "tool_call"
    }

    static func dataScope(from capabilities: [String]) -> String {
        let set = Set(capabilities)
        if set.contains("outside_app_data_write") { return "outside_app_data" }
        if set.contains("filesystem_delete") || set.contains("filesystem_write") { return "filesystem" }
        if set.contains("external_send") { return "external_service" }
        if set.contains("network_write") { return "network_write" }
        if set.contains("network_read") { return "network_read" }
        if set.contains("memory_write") { return "memory" }
        if set.contains("safe_read") || set.contains("catalog_read") { return "read_only" }
        return "app"
    }

    static func outcome(from decision: SecurityToolDecision) -> UnifiedPolicyOutcome {
        switch decision {
        case .allow: return .allow
        case .ask: return .confirm
        case .block: return .deny
        }
    }

    static func primaryReason(
        envelope: SecurityToolEnvelope,
        fullMacActive: Bool,
        developerMode: Bool,
        remoteSurface: Bool
    ) -> String {
        if envelope.decision == .allow {
            if envelope.risk == "critical", fullMacActive, !developerMode, !remoteSurface {
                return "Full Mac access allows this critical local action"
            }
            if envelope.risk == "critical", developerMode {
                return "Developer Mode allows this critical action"
            }
            if (envelope.risk == "high" || envelope.risk == "critical"),
               remoteSurface,
               envelope.originTrusted {
                return "trusted remote origin allows this high-risk action"
            }
        }
        let priority = [
            "kill switch",
            "secret firewall",
            "prompt-injection",
            "remote high-risk command is unsigned",
            "remote high-risk origin",
            "request signature not verified",
            "allowlist",
            "no trust root",
            "developer mode",
            "full mac",
            "external send requires approval",
            "tool autonomy",
            "unsigned high-risk",
            "tool signature",
        ]
        for needle in priority {
            if let reason = envelope.reasons.first(where: {
                $0.lowercased().contains(needle)
            }) {
                return reason
            }
        }
        if let reason = envelope.reasons.first(where: { reason in
            !reason.lowercased().hasPrefix("autonomy:")
        }) {
            return reason
        }
        return envelope.reasons.first ?? "Security Center evaluated the action"
    }

    static func policySource(
        envelope: SecurityToolEnvelope,
        fullMacActive: Bool,
        developerMode: Bool,
        remoteSurface: Bool
    ) -> String {
        let reasons = envelope.reasons.map { $0.lowercased() }
        if reasons.contains(where: { $0.contains("kill switch") }) { return "hard_deny" }
        if reasons.contains(where: { $0.contains("secret firewall") }) { return "secret_firewall" }
        if reasons.contains(where: { $0.contains("prompt-injection") }) { return "prompt_injection" }
        if reasons.contains(where: { $0.contains("remote high-risk command is unsigned") }) {
            return "remote_signature"
        }
        if reasons.contains(where: {
            $0.contains("remote high-risk origin")
                || $0.contains("allowlist")
                || $0.contains("request signature not verified")
                || $0.contains("no trust root")
        }) {
            return "origin_trust"
        }
        if reasons.contains(where: { $0.contains("developer mode") }) { return "developer_mode" }
        if reasons.contains(where: { $0.contains("full mac") }) { return "full_mac" }
        if reasons.contains(where: { $0.contains("external send requires approval") }) {
            return "connector_policy"
        }
        if reasons.contains(where: { $0.contains("tool autonomy") }) { return "tool_autonomy" }
        if reasons.contains(where: { $0.contains("unsigned high-risk") || $0.contains("tool signature") }) {
            return "tool_signing"
        }
        if envelope.decision == .allow {
            if envelope.risk == "critical", fullMacActive, !developerMode, !remoteSurface {
                return "full_mac"
            }
            if envelope.risk == "critical", developerMode {
                return "developer_mode"
            }
            if (envelope.risk == "high" || envelope.risk == "critical"),
               remoteSurface,
               envelope.originTrusted {
                return "origin_trust"
            }
        }
        return "security_center"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
