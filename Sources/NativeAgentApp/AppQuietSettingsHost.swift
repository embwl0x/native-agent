import AppToolRuntime
import Cognition
import Context
import Foundation
import PersistenceCore
import NativeAgentShared
import ProviderRouting
import Research
import TrustCenter
import TriggerScheduler
// Blueprint: | `AppQuietSettingsHost.swift` | `AppQuietSettingsHost` class; `saveChatBrainDefaultsFailure`, `saveMacControlPolicy` |

/// Adapts the settings catalog to the same observed model actions as the UI.
@MainActor
class AppQuietSettingsHost: QuietLowerOnlySettingsHost {
    let appModel: AppModel

    init(_ appModel: AppModel) { self.appModel = appModel }

    var dataRootOverride: URL? { appModel.dataRootOverride }
    var trustPolicy: TrustPolicy? { appModel.engine.trust.policy }
    var personality: PersonalityProfile? { appModel.engine.persona.profile }
    var dreamError: String? { appModel.dreamError }
    var makeShelfFault: String? { appModel.engine.make.fault }
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
    var chatProvider: String { appModel.chatProvider }
    var searchServiceURL: String { appModel.searxngBaseURL }

    func saveChatBrainDefaultsFailure() async -> String? {
        let result = await appModel.saveChatBrainDefaults()
        switch result {
        case .saved, .unchanged: return nil
        case .failed: return result.agentMessage
        }
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        comparedTo baseline: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws -> TrustPolicy {
        try await appModel.saveMacControlPolicy(policy, comparedTo: baseline, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String) {
        appModel.applySavedTrustPolicy(policy, status: status)
    }

    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String?, model: String?,
        reasoningEffort: String?, serviceTier: String?, clearOverride: Bool
    ) async throws -> ProviderGroupWriteResult {
        try await appModel.saveProviderGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
    }

    func listQuietProviderAccounts() async throws -> [QuietProviderAccount] {
        try await appModel.engine.providers.list().map {
            QuietProviderAccount(providerID: $0.provider_id, authState: $0.auth_status.state,
                                 eligible: $0.auth_status.eligible, models: $0.models)
        }
    }

    func agentAccessMode(from policy: TrustPolicy) -> String {
        TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
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

    func saveMultimodalPolicy(
        field: String, enabled: Bool,
        guardedByLockedPolicy: @escaping @Sendable ([String: JSONValue]) throws -> Void
    ) async throws -> TrustPolicy {
        do {
            return try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["multimodalPolicy": [field: enabled]],
                dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                guardedByLockedPolicy: guardedByLockedPolicy)
        } catch {
            appModel.engine.trust.publishPolicy(nil)
            appModel.recordTrustActionFailure("Multimodal policy save failed: \(error.localizedDescription)")
            throw error
        }
    }

    func dreamEnabled() async -> Bool { await appModel.engine.cognitionView.dreamEnabled() }
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setDreamCycleEnabled(enabled) }
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool { await appModel.setRemCycleEnabled(enabled) }
    func savePersonalityChecked(_ profile: PersonalityProfile) async throws {
        try await appModel.savePersonalityChecked(profile)
    }
    func patchMemoryPolicy(knowledgeGraphEnabled: Bool?, adaptivePromotion: Bool?, hygieneEnabled: Bool?) async -> Bool {
        await appModel.patchMemoryPolicy(
            knowledgeGraphEnabled: knowledgeGraphEnabled,
            adaptivePromotion: adaptivePromotion,
            hygieneEnabled: hygieneEnabled)
    }
    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool) async {
        await appModel.saveMemoryPolicy(
            consolidationEnabled: consolidationEnabled,
            crossSessionRecall: crossSessionRecall)
    }

    func setInnerLifeEnabled(_ enabled: Bool) async -> (enabled: Bool, problem: String?) {
        let (state, problem) = await appModel.setInnerLifeEnabled(enabled)
        return (state.enabled, problem)
    }

    /// The same runtime setters the Settings and Cognition pages call.
    func setCognitionLane(_ lane: QuietCognitionLane, enabled: Bool) async {
        await lane.setEnabled(enabled, runtime: NativeAgentEngine.liveCognition)
    }
    func setReflectionBudget(_ budget: Int) async {
        await NativeAgentEngine.liveCognition.setReflectionBudget(budget)
    }
    func setContextFlowMode(_ mode: ContextFlowMode) async -> ContextFlowMode {
        await NativeAgentEngine.live.contextFlow.setMode(mode).effectiveMode
    }
    /// The key and the manager call together, as the Settings switch pairs
    /// them (SetupRestRows.shortcutRow).
    func setGlobalHotkeyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "globalHotkeyEnabled")
        GlobalHotkeyManager.shared.setEnabled(enabled)
    }

    func savePersonalityName(_ name: String) async -> String? {
        switch await appModel.savePersonalityName(name) {
        case .saved: return nil
        case .refused(let detail), .failed(let detail): return detail
        }
    }

    func saveSearchServiceURL(_ url: String) async throws {
        _ = try await SwiftNativeResearchClient(dataRoot: appModel.engine.dataRoot)
            .saveSearXNGBaseURL(url)
        try await appModel.engine.configuration.readSearXNG(dataRoot: appModel.engine.dataRoot)
    }
    func findSearchService() async throws -> String {
        switch await appModel.autodetectSearXNG() {
        // Find, then Save — the page's two buttons in the order a person
        // presses them.
        case .found(let url):
            try await saveSearchServiceURL(url)
            return appModel.searxngBaseURL
        case .notFound(let detail), .failed(let detail): throw QuietSettingError.unavailable(detail)
        }
    }

    // The Notifications page's own reads and writes (InboxSettingsView).
    func inboxTriggers() async throws -> [QuietInboxTrigger] {
        try await appModel.engine.inbox.triggers().map {
            QuietInboxTrigger(
                name: $0.name, enabled: $0.enabled)
        }
    }
    func setInboxTrigger(_ name: String, enabled: Bool) async throws {
        try await appModel.engine.inbox.setTrigger(name, enabled: enabled)
    }
}
