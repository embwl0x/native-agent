import Foundation
import NativeAgentShared

// MARK: - iOS-local models (not shared — different shape from Mac side)


struct TrustFilePolicy: Codable, Hashable, Sendable {
    var requireBackupBeforeWrite: Bool?
    var outsideWorkspaceDefault: String?
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
    var filePolicy: TrustFilePolicy?
    var trainingPolicy: TrustTrainingPolicy?
    var updatedAt: String?
    var macControlPolicy: MacControlPolicyWireSnapshot?

    enum CodingKeys: String, CodingKey {
        case resolvedPreset, effectivePermissionLevel
        case permissionLevel, autonomyDefault, requireBackups, outsideDefault, developerMode
        case filePolicy, trainingPolicy, updatedAt, macControlPolicy
    }

}

/// Present malformed values must fail decoding; an extension preserves the synthesized memberwise initializer.
extension TrustPolicy {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolvedPreset = try c.decodeIfPresent(String.self, forKey: .resolvedPreset)
        effectivePermissionLevel = try c.decodeIfPresent(String.self, forKey: .effectivePermissionLevel)
        permissionLevel = try c.decodeIfPresent(String.self, forKey: .permissionLevel)
        autonomyDefault = try c.decodeIfPresent(String.self, forKey: .autonomyDefault)
        requireBackups = try c.decodeIfPresent(Bool.self, forKey: .requireBackups)
        outsideDefault = try c.decodeIfPresent(String.self, forKey: .outsideDefault)
        developerMode = try c.decodeIfPresent(Bool.self, forKey: .developerMode)
        filePolicy = try c.decodeIfPresent(TrustFilePolicy.self, forKey: .filePolicy)
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



typealias ProviderAuthStatus = NativeAgentShared.ProviderAuthStatus

typealias ProviderModelInfo = NativeAgentShared.ProviderModelInfo


typealias ProviderTestResult = NativeAgentShared.ProviderTestResult
