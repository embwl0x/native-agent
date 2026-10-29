// iOS-specific snapshot models; shared wire types live in NativeAgentShared.
import Foundation
import NativeAgentShared

// MARK: - iOS-local models (not shared — different shape from Mac side)

// Command-summary count and policy models live in NativeAgentShared.

struct TrustToolPolicy: Codable, Hashable, Sendable {
    var autoRunRiskClasses: [String]?
}

struct TrustFilePolicy: Codable, Hashable, Sendable {
    var allowedWorkspaceIds: [String]?
    var allowedPaths: [String]?
    var requireBackupBeforeWrite: Bool?
    var outsideWorkspaceDefault: String?
}

struct TrustConnectorPolicy: Codable, Hashable, Sendable {
    var enabledConnectors: [String]?
}

struct TrustProviderPolicy: Codable, Hashable, Sendable {
    var activePerSurface: [String: String]?

    enum CodingKeys: String, CodingKey {
        case activePerSurface = "active_per_surface"
    }
}

struct TrustTrainingPolicy: Decodable, Hashable, Sendable {
    var dreamScheduler: Bool?

    enum CodingKeys: String, CodingKey {
        case dreamScheduler
        case dream_scheduler
    }

    init(dreamScheduler: Bool? = nil) {
        self.dreamScheduler = dreamScheduler
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dreamScheduler = try c.decodeIfPresent(Bool.self, forKey: .dreamScheduler)
            ?? c.decodeIfPresent(Bool.self, forKey: .dream_scheduler)
    }
}

struct TrustPolicy: Decodable, Hashable, Sendable {
    var resolvedPreset: String?
    var effectivePermissionLevel: String?
    var permissionLevel: String?
    var autonomyDefault: String?
    var requireBackups: Bool?
    var outsideDefault: String?
    var developerMode: Bool?
    var workshopPolicy: TrustWorkshopPolicy?
    var toolPolicy: TrustToolPolicy?
    var filePolicy: TrustFilePolicy?
    var connectorPolicy: TrustConnectorPolicy?
    var providerPolicy: TrustProviderPolicy?
    var trainingPolicy: TrustTrainingPolicy?
    var updatedAt: String?
    var macControlPolicy: MacControlPolicyWireSnapshot?

    enum CodingKeys: String, CodingKey {
        case resolvedPreset, effectivePermissionLevel
        case permissionLevel, autonomyDefault, requireBackups, outsideDefault, developerMode
        case workshopPolicy = "missionPolicy" // compatibility wire ID
        case toolPolicy, filePolicy, connectorPolicy, providerPolicy, trainingPolicy, updatedAt, macControlPolicy
    }

}

/// Reads both workshop-policy spellings.
/// A malformed present value fails decoding. Extension placement preserves
/// the synthesized memberwise initializer.
extension TrustPolicy {
    private enum FutureCodingKeys: String, CodingKey {
        case workshopPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolvedPreset = try c.decodeIfPresent(String.self, forKey: .resolvedPreset)
        effectivePermissionLevel = try c.decodeIfPresent(String.self, forKey: .effectivePermissionLevel)
        permissionLevel = try c.decodeIfPresent(String.self, forKey: .permissionLevel)
        autonomyDefault = try c.decodeIfPresent(String.self, forKey: .autonomyDefault)
        requireBackups = try c.decodeIfPresent(Bool.self, forKey: .requireBackups)
        outsideDefault = try c.decodeIfPresent(String.self, forKey: .outsideDefault)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode)
        // Future spelling first, on-wire spelling as the fallback. A PRESENT
        // but malformed future block throws, exactly like the legacy key —
        // the future spelling must never be the more forgiving one.
        let future = try decoder.container(keyedBy: FutureCodingKeys.self)
        workshopPolicy = try future.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
            ?? c.decodeIfPresent(TrustWorkshopPolicy.self, forKey: .workshopPolicy)
        toolPolicy = try c.decodeIfPresent(TrustToolPolicy.self, forKey: .toolPolicy)
        filePolicy = try c.decodeIfPresent(TrustFilePolicy.self, forKey: .filePolicy)
        connectorPolicy = try c.decodeIfPresent(TrustConnectorPolicy.self, forKey: .connectorPolicy)
        providerPolicy = try c.decodeIfPresent(TrustProviderPolicy.self, forKey: .providerPolicy)
        trainingPolicy = try c.decodeIfPresent(TrustTrainingPolicy.self, forKey: .trainingPolicy)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        macControlPolicy = try c.decodeIfPresent(MacControlPolicyWireSnapshot.self, forKey: .macControlPolicy)
    }

    var effectiveRequireBackups: Bool? {
        requireBackups ?? filePolicy?.requireBackupBeforeWrite
    }

    var effectiveOutsideDefault: String? {
        outsideDefault ?? filePolicy?.outsideWorkspaceDefault
    }
}

// ApprovalRequest moved to NativeAgentShared.


typealias ProviderAuthStatus = NativeAgentShared.ProviderAuthStatus

typealias ProviderModelInfo = NativeAgentShared.ProviderModelInfo


typealias ProviderTestResult = NativeAgentShared.ProviderTestResult
