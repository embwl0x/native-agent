import AppToolRuntime
import Foundation
import PersistenceCore
import NativeAgentShared
import TrustCenter

/// Adapts the settings catalog to the same observed model actions as the UI.
@MainActor
class AppQuietSettingsHost: QuietSettingsHost {
    let appModel: AppModel

    init(_ appModel: AppModel) { self.appModel = appModel }

    var dataRootOverride: URL? { appModel.dataRootOverride }
    var trustPolicy: TrustPolicy? { appModel.engine.trust.policy }
    var personality: PersonalityProfile? { appModel.personality }
    var dreamError: String? { appModel.dreamError }
    var chatModel: String {
        get { appModel.chatModel }
        set { appModel.chatModel = newValue }
    }
    var chatReasoningEffort: String {
        get { appModel.chatReasoningEffort }
        set { appModel.chatReasoningEffort = newValue }
    }
    var chatFastMode: Bool {
        get { appModel.chatFastMode }
        set { appModel.chatFastMode = newValue }
    }
    var chatFileAccess: String { appModel.chatFileAccess }

    func saveChatBrainDefaultsFailure() async -> String? {
        switch await appModel.saveChatBrainDefaults() {
        case .saved, .unchanged: return nil
        case .failed(let message, _): return message
        }
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws -> TrustPolicy {
        try await appModel.saveMacControlPolicy(policy, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String) {
        appModel.applySavedTrustPolicy(policy, status: status)
    }

    func configureSurfaceSelection(
        surface: String, providerID: String, model: String,
        reasoningEffort: String, serviceTier: String?
    ) async throws {
        _ = try await appModel.configureSurfaceSelection(
            surface: surface, providerID: providerID, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier)
    }

    func clearSurfaceOverride(surface: String) async throws {
        try await appModel.clearSurfaceOverride(surface: surface)
    }

    func listQuietProviderAccounts() async throws -> [QuietProviderAccount] {
        try await appModel.engine.providers.list().map {
            QuietProviderAccount(id: $0.provider_id, authState: $0.auth_status.state)
        }
    }

    func agentAccessMode(from policy: TrustPolicy) -> String {
        AppModel.agentAccessMode(from: policy)
    }

    func applyTrustPreset(
        _ preset: TrustPolicyPreset,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async -> QuietTrustPresetOutcome {
        switch await TrustPolicyPresetAction.apply(
            preset, appModel: appModel, guardedByLockedPolicy: guardedByLockedPolicy
        ) {
        case .confirmationRequired: return .confirmationRequired
        case .applied: return .applied
        case .failed(let detail): return .failed(detail)
        }
    }

    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async -> Bool {
        await appModel.saveMultimodalPolicy(policy)
    }

    func dreamEnabled() async -> Bool { await appModel.engine.cognitionView.dreamEnabled() }
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setDreamCycleEnabled(enabled) }
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setRemCycleEnabled(enabled) }
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        try await appModel.savePersonalityChecked(profile)
    }
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool) async -> Bool {
        await appModel.patchMemoryPolicy(knowledgeGraphEnabled: knowledgeGraphEnabled)
    }
}
