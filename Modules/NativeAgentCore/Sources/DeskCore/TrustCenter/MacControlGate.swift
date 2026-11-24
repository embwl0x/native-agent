import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `MacControlGate.swift` | `MacControlGate`; Origin-aware Full Mac and resolved-path policy. |

// MARK: - Policy input shapes

public struct MacControlPolicy: Sendable, Equatable {
    /// Call-scoped origin admission, projected only by the checked Full Mac owner. Never serialized as a saved policy field.
    public var fullMacAdmitted = false
    public var enabled: Bool
    public var remoteFromIOSAllowed: Bool
    /// Per-category allow flags (e.g. `shell_allowed`); missing keys deny.
    public var categoryAllowed: [String: Bool]
    /// Without retained file policy this gate is inactive; effect owners still enforce their boundaries.
    public var trustPolicy: [String: JSONValue]?
    public var workspaceRoots: [String]

    public init(
        enabled: Bool = false,
        remoteFromIOSAllowed: Bool = false,
        categoryAllowed: [String: Bool] = [:],
        trustPolicy: [String: JSONValue]? = nil,
        workspaceRoots: [String] = []
    ) {
        self.enabled = enabled
        self.remoteFromIOSAllowed = remoteFromIOSAllowed
        self.categoryAllowed = categoryAllowed
        self.trustPolicy = trustPolicy
        self.workspaceRoots = workspaceRoots
    }

    public static let `default`: MacControlPolicy = {
        let mac = SwiftNativeTrustCenter.defaultMacControlPolicy
        return MacControlPolicy(enabled: mac["enabled"] == .bool(true),
            remoteFromIOSAllowed: mac["remote_from_ios_allowed"] == .bool(true),
            categoryAllowed: mac.filter { $0.key.hasSuffix("_allowed") && $0.key != "remote_from_ios_allowed" }
                .mapValues { $0 == .bool(true) })
    }()
}

// MARK: - Category → policy key map

public func categoryPolicyKey(_ category: String) -> String {
    category == "system" ? "system_control_allowed" : "\(category)_allowed"
}

// MARK: - Gate decision

public struct MacControlGateDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String
    public let remedy: JSONValue?
    public init(allowed: Bool, reason: String, remedy: JSONValue? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.remedy = remedy
    }
    public static let allow = MacControlGateDecision(allowed: true, reason: "")
}

public enum MacControlGate {

    public static func continuationCaptureRefusal(dataRoot: URL) async -> String? {
        do {
            let snapshot = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadAuthorizationSnapshotChecked()
            let authority = SwiftNativeSecurityCenter.fullMacYoloAuthority(surface: "chat", originTrusted: true, snapshot: snapshot)
            let policy = policyForAdmittedFullMac(
                MacControlPolicy.fromTrustPolicyObject(snapshot.policy, dataRoot: dataRoot), admitted: authority.state == .admitted)
            guard PermissionLaw.posture(snapshot.policy) == .fullMac,
                  gate(policy, category: "accessibility", trigger: "user").allowed else {
                return "accessibility_read_not_authorized"
            }
            return nil
        } catch {
            return "trust_policy_unavailable"
        }
    }

    /// Only origin-checked admission may project Full Mac into this call; never persist it over lower-mode settings.
    public static func policyForAdmittedFullMac(
        _ policy: MacControlPolicy, admitted: Bool
    ) -> MacControlPolicy {
        guard admitted, let trust = policy.trustPolicy, PermissionLaw.posture(trust) == .fullMac else { return policy }
        var effective = policy
        effective.fullMacAdmitted = true
        effective.enabled = true
        effective.remoteFromIOSAllowed = true
        for key in MacControlPolicy.default.categoryAllowed.keys {
            effective.categoryAllowed[key] = true
        }
        return effective
    }

    // MARK: master / remote / per-category

    /// Master, remote and category gates retain their order and name the saved field and the person's matching control.
    public static func gate(
        _ policy: MacControlPolicy,
        category: String,
        trigger: String = "user"
    ) -> MacControlGateDecision {
        if !policy.enabled {
            return refusal("enabled", control: "Mac control > Mac control", category: category)
        }
        if trigger == "ios" && !policy.remoteFromIOSAllowed {
            return refusal("remote_from_ios_allowed", control: "iPhone remote control > Allow iPhone remote control", category: category)
        }
        let key = categoryPolicyKey(category)
        if !(policy.categoryAllowed[key] ?? false) {
            let label = ["shell": "Shell commands > Shell commands", "file_ops": "Kinds of control > File operations",
                "accessibility": "Kinds of control > Accessibility", "applescript": "Kinds of control > AppleScript",
                "jxa": "Kinds of control > JavaScript for Automation (JXA)", "notifications": "Kinds of control > Notifications",
                "spotlight": "Kinds of control > Spotlight search"][category]
            return refusal(key, control: label, category: category)
        }
        return .allow
    }

    private static func refusal(_ key: String, control: String?, category: String) -> MacControlGateDecision {
        let owner = "trust/policy.json macControlPolicy.\(key)"
        if let control {
            let tap = "Trust > Mac > Advanced Mac control > \(control); then Mac control > Save"
            return MacControlGateDecision(allowed: false,
                reason: "mac_control_policy_disabled: \(owner)=false blocks this action. Only the owner can enable it at \(tap).",
                remedy: Repair.why(owner: owner, tap: tap, instruction: "Only the owner can enable this Mac control switch."))
        }
        return MacControlGateDecision(allowed: false,
            reason: "mac_control_category_denied: \(owner)=false blocks category '\(category)'. This category has no matching switch.",
            remedy: .object(["kind": .string("correct_arguments"), "owner": .string(owner),
                "instruction": .string("Inspect supported Mac actions with next_call and choose one with an available control."),
                "next_call": .object(["tool": .string("app"), "input": .object(["find": .string("mac")])])]))
    }

    // MARK: file policy

    /// Use execution's resolved paths for containment; nil trust leaves this gate inactive.
    public static func fileReason(
        _ policy: MacControlPolicy,
        forPaths paths: [String]
    ) -> String? {
        guard let trust = policy.trustPolicy else { return nil }
        let workspaceRoots = policy.workspaceRoots.map { URL(fileURLWithPath: resolvedPath($0)) }
        for raw in paths {
            if raw.isEmpty { continue }
            let resolved = resolvedPath(raw)
            if SwiftNativeSecurityCenter.pathIsInsideRoots(resolved, roots: workspaceRoots) {
                continue
            }
            if PermissionLaw.posture(trust) == .fullMac { continue }
            let outside = trust["filePolicy"]?.objectValue?["outsideWorkspaceDefault"]?.stringValue ?? "deny"
            if outside == "ask" {
                return "file_policy_requires_approval: \(resolved) is outside configured workspaces"
            }
            return "file_policy_denied: \(resolved) is outside configured workspaces"
        }
        return nil
    }

    // MARK: - helpers

    /// Policy and execution share file spelling and macOS firmlink identity.
    public static func resolvedPath(_ raw: String) -> String {
        NativeAgentWorkspaceRoot.canonicalFileURL(NativeAgentWorkspaceRoot.fileCandidate(
            raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))).path
    }

}

public extension MacControlPolicy {
    static func fromTrustPolicyObject(_ root: [String: JSONValue], dataRoot: URL = defaultDataRoot()) -> MacControlPolicy {
        let defaults = MacControlPolicy.default
        let mac = root["macControlPolicy"]?.objectValue ?? [:]
        let filePolicy = root["filePolicy"]?.objectValue ?? [:]

        var categoryAllowed = defaults.categoryAllowed
        for key in categoryAllowed.keys {
            categoryAllowed[key] = mac[key]?.boolValue ?? categoryAllowed[key] ?? false
        }

        let workspaceRoots = SwiftNativeSecurityCenter.normalizedUniqueRoots([dataRoot]
            + SwiftNativeSecurityCenter.trustedWorkspaceRoots(filePolicy: filePolicy, dataRoot: dataRoot))
            .map(\.path)

        return MacControlPolicy(
            enabled: mac["enabled"]?.boolValue ?? defaults.enabled,
            remoteFromIOSAllowed: mac["remote_from_ios_allowed"]?.boolValue ?? defaults.remoteFromIOSAllowed,
            categoryAllowed: categoryAllowed,
            trustPolicy: root,
            workspaceRoots: workspaceRoots
        )
    }
}
