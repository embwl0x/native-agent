import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #12: TrustCenter
//
// Swift-native implementation owns the trust policy store.
//
// TrustCenter is the Swift-owned permission and policy store. It governs
// surface-specific autonomy (Full Mac, Telegram, Slack, iOS remote, shell,
// files, Workshop executions, mac control, connectors), drives the autonomy/policy
// gate surfaces, and signs autonomous-tool manifests through
// SwiftNativeManifestSigner using data/tools/.manifest_signing_key.

// MARK: - Protocol

/// TrustCenter surface. SwiftNative reads and writes the on-disk trust policy
/// directly.
public protocol TrustCenterProtocol: Sendable {
    func getTrust() async throws -> TrustPolicy
    func updateTrust(_ update: JSONValue) async throws -> TrustPolicy
    func simulateTrust(_ scenario: JSONValue) async throws -> TrustSimulationResult
    func getAutonomyPolicy() async throws -> AutonomyPolicy
}

// MARK: - SwiftNative impl

public actor SwiftNativeTrustCenter: TrustCenterProtocol {
    let dataRoot: URL
    let persistence: any PersistenceCoreProtocol
    let clock: @Sendable () -> Date

    /// Valid autonomy levels for Swift policy evaluation. Exposed so
    /// consumers do not duplicate the accepted values.
    public static let unifiedPolicyAutonomyLevels: Set<String> = [
        "auto", "draft_auto", "send_approval",
        "confirm", "destructive_strong", "blocked",
    ]

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
        self.clock = clock
    }

    public func getTrust() async throws -> TrustPolicy {
        return try Self.decodePolicy(.object(try await loadTrustPolicyChecked()))
    }

    public func updateTrust(_ update: JSONValue) async throws -> TrustPolicy {
        guard case .object(let patch) = update else {
            throw TrustCenterError.invalidRequest
        }
        let path = trustPolicyPath
        let defaults = defaultTrustPolicy()
        try await persistence.withFileLock(path) {
            let current = try Self.loadRawPolicyChecked(at: path)
            try Self.validateKnownAuthorityPolicyTypes(current, against: defaults)
            let merged = Self.deepMerge(current, patch)
            try Self.validateAuthorityPolicyShape(merged)
            try Self.validateKnownAuthorityPolicyTypes(merged, against: defaults)
            try await persistence.writeJSON(.object(merged), to: path)
        }
        return try await getTrust()
    }

    public func simulateTrust(_ scenario: JSONValue) async throws -> TrustSimulationResult {
        guard case .object(let obj) = scenario else {
            throw TrustCenterError.invalidRequest
        }
        let action = Self.firstString(obj, keys: ["action", "tool", "tool_name", "name"]) ?? ""
        let policy = try await loadTrustPolicyChecked()
        let toolOverrides: [String: JSONValue] = {
            if case .object(let o)? = policy["toolAutonomy"] { return o }
            return [:]
        }()
        let defaultLevel: JSONValue = toolOverrides["default"] ?? .string("send_approval")
        let autonomyBundle: [String: JSONValue] = [
            "autonomyOverrides": .object(toolOverrides),
            "autonomyDefault": defaultLevel,
        ]
        let level = autonomyForTool(action, policy: autonomyBundle)
        let allowed = level != "blocked"
        let requiresApproval = ["send_approval", "confirm", "destructive_strong"].contains(level)
        let risk: String = {
            switch level {
            case "blocked": return "blocked"
            case "destructive_strong": return "critical"
            case "confirm", "send_approval": return "medium"
            default: return "low"
            }
        }()
        return TrustSimulationResult(rawResponse: .object([
            "allowed": .bool(allowed),
            "requiresApproval": .bool(requiresApproval),
            "requires_approval": .bool(requiresApproval),
            "risk": .string(risk),
            "action": .string(action),
            "reasons": .array([.string("tool autonomy: \(level)")]),
            "policy": .object(policy),
        ]))
    }

    public func getAutonomyPolicy() async throws -> AutonomyPolicy {
        let policy = try await loadTrustPolicyChecked()
        let permission = Self.string(policy["permissionLevel"]) ?? "balanced"
        let filePolicy: [String: JSONValue] = {
            if case .object(let obj)? = policy["filePolicy"] { return obj }
            return [:]
        }()
        let outsideDefault = Self.string(filePolicy["outsideWorkspaceDefault"]) ?? "deny"
        let fullMacActive = permission == "full_mac_os"
            || (permission == "wide_open_receipts" && outsideDefault == "allow")
        let enableAutonomy: Bool = {
            if case .bool(let b)? = policy["enableAutonomy"] { return b }
            return false
        }()
        let gates: [JSONValue] = [
            .object([
                "id": .string("permissionLevel"),
                "title": .string("Access mode"),
                "enabled": .bool(true),
                "value": .string(permission),
                "status": .string(fullMacActive ? "ok" : "limited"),
                "detail": .string(fullMacActive ? "Full Mac access active" : "Limited access policy"),
                "source": .string("trust/policy.json"),
            ]),
            .object([
                "id": .string("enableAutonomy"),
                "title": .string("Autonomy"),
                "enabled": .bool(enableAutonomy),
                "value": .bool(enableAutonomy),
                "status": .string(enableAutonomy ? "ok" : "off"),
                "detail": .string(enableAutonomy ? "Autonomy enabled" : "Autonomy disabled"),
                "source": .string("trust/policy.json"),
            ]),
        ]
        let raw: JSONValue = .object([
            "status": .string("ready"),
            "permissionLevel": .string(permission),
            "fullMacMode": .string(fullMacActive ? "active" : "off"),
            "gates": .array(gates),
            "policy": .object(policy),
        ])
        return AutonomyPolicy(
            status: "ready",
            permissionLevel: permission,
            fullMacMode: fullMacActive ? "active" : "off",
            gates: gates,
            rawResponse: raw
        )
    }

    private var trustPolicyPath: URL {
        dataRoot
            .appendingPathComponent("trust", isDirectory: true)
            .appendingPathComponent("policy.json")
    }

    private nonisolated static func decodePolicy(_ value: JSONValue) throws -> TrustPolicy {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(TrustPolicy.self, from: data)
    }

    private nonisolated static func deepMerge(
        _ base: [String: JSONValue],
        _ patch: [String: JSONValue]
    ) -> [String: JSONValue] {
        var out = base
        for (key, value) in patch {
            if case .object(let patchObj) = value,
               case .object(let baseObj)? = out[key] {
                out[key] = .object(deepMerge(baseObj, patchObj))
            } else {
                out[key] = value
            }
        }
        return out
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    private nonisolated static func firstString(
        _ obj: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let s)? = obj[key],
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

}

// MARK: - Factory

/// SwiftNative owns the trust store. Manifest HMAC signing has its own
/// Swift-native actor (`SwiftNativeManifestSigner`) below.
public func makeTrustCenter() -> any TrustCenterProtocol {
    return SwiftNativeTrustCenter()
}
