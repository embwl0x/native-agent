import Foundation
import PersistenceCore
import TrustCenter

extension NativeClient {
    private var trustPolicyActions: TrustPolicyActions {
        TrustPolicyActions(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    static func developerModePatchBody(enabled: Bool) -> [String: Any] {
        TrustPolicyActions.developerModePatchBody(enabled: enabled)
    }

    func saveDeveloperMode(_ enabled: Bool) async throws -> TrustPolicy {
        try await trustPolicyActions.saveDeveloperMode(enabled)
    }

    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async throws -> TrustPolicy {
        try await trustPolicyActions.saveMultimodalPolicy(policy)
    }

    func saveEnableAutonomy(_ enabled: Bool) async throws -> TrustPolicy {
        try await trustPolicyActions.saveEnableAutonomy(enabled)
    }

    func saveChromeControlEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await trustPolicyActions.saveChromeControlEnabled(enabled)
    }

    func saveKillSwitchEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await trustPolicyActions.saveKillSwitchEnabled(enabled)
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await trustPolicyActions.saveMacControlPolicy(policy, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await trustPolicyActions.saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    func saveAgentAccessMode(_ mode: String, currentPolicy: TrustPolicy? = nil, developerMode: Bool? = nil) async throws -> TrustPolicy {
        try await trustPolicyActions.saveAgentAccessMode(mode, currentPolicy: currentPolicy, developerMode: developerMode)
    }

    static func macControlPolicyForAccessMode(_ mode: String, remoteFromIosAllowed: Bool = false, developerMode: Bool = false) -> [String: Any] {
        TrustPolicyActions.macControlPolicyForAccessMode(mode, remoteFromIosAllowed: remoteFromIosAllowed, developerMode: developerMode)
    }

    func saveTrustPolicyFull(
        permissionLevel: String,
        autonomyDefault: String,
        requireBackups: Bool,
        outsideDefault: String,
        developerMode: Bool = false,
        autonomousTraining: Bool? = nil,
        dreamScheduler: Bool? = nil,
        routeThroughPromotion: Bool? = nil,
        promotionEnabled: Bool? = nil,
        autoPromoteTierA: Bool? = nil
    ) async throws -> TrustPolicy {
        try await trustPolicyActions.saveTrustPolicyFull(
            permissionLevel: permissionLevel, autonomyDefault: autonomyDefault,
            requireBackups: requireBackups, outsideDefault: outsideDefault,
            developerMode: developerMode, autonomousTraining: autonomousTraining,
            dreamScheduler: dreamScheduler, routeThroughPromotion: routeThroughPromotion,
            promotionEnabled: promotionEnabled, autoPromoteTierA: autoPromoteTierA)
    }
}
