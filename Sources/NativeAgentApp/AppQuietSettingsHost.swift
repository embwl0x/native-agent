import AppToolRuntime
import Cognition
import Context
import Foundation
import PersistenceCore
import NativeAgentShared
import ProviderRouting
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
    var chatProvider: String { appModel.chatProvider }
    var searchServiceURL: String { appModel.searxngBaseURL }

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
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        return try await appModel.engine.providers.list().map {
            // The Providers page's own list and fallback levels
            // (`ProviderSettingsView.modelsForProvider`). A ready account
            // whose last test failed for its current key needs a reconnect,
            // so no `*_account` list offers it.
            let failed = $0.auth_status.state == "ready"
                && LLMProviderStatusFeed.failedTest(providerID: $0.provider_id, dataRoot: root) == "key rejected"
            return QuietProviderAccount(id: $0.provider_id, authState: failed ? "needs_reconnect" : $0.auth_status.state, models: $0.models.map {
                QuietProviderModel(
                    id: $0.id,
                    defaultEffort: $0.default_reasoning_effort ?? "high",
                    efforts: $0.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"],
                    supportsFast: $0.supports_fast == true)
            })
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
            appModel.engine.trust.policy = nil
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
    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool, autoPromoteConsolidated: Bool) async {
        await appModel.saveMemoryPolicy(
            consolidationEnabled: consolidationEnabled,
            crossSessionRecall: crossSessionRecall,
            autoPromoteConsolidated: autoPromoteConsolidated)
    }

    func setInnerLifeEnabled(_ enabled: Bool) async -> (enabled: Bool, problem: String?) {
        let (state, problem) = await appModel.setInnerLifeEnabled(enabled)
        return (state.enabled, problem)
    }

    /// The same runtime setters the Settings and Cognition pages call.
    func setCognitionLane(_ lane: QuietCognitionLane, enabled: Bool) async {
        let runtime = NativeAgentEngine.liveCognition
        switch lane {
        case .capsule: await runtime.setCapsuleEnabled(enabled)
        case .background: await runtime.setBackgroundEnabled(enabled)
        case .reflection: await runtime.setReflectionEnabled(enabled)
        case .organism: await runtime.setOrganismKernelEnabled(enabled)
        case .viewsExperiment: await runtime.setViewsExperimentEnabled(enabled)
        }
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

    func memoryMode() async throws -> String {
        EmbeddingsSettingsStatusPresentation(status: try await appModel.fetchEmbeddingsStatus()).memoryMode
    }
    func setMemoryMode(_ mode: String) async throws {
        let result = try await appModel.setEmbeddingsMemoryMode(mode: mode)
        if let error = result.error {
            throw QuietSettingError.unavailable(result.detail.map { "\(error): \($0)" } ?? error)
        }
    }

    func savePersonalityName(_ name: String) async -> String? {
        switch await appModel.savePersonalityName(name) {
        case .saved: return nil
        case .refused(let detail), .failed(let detail): return detail
        }
    }

    func saveSearchServiceURL(_ url: String) async throws {
        _ = try await appModel.saveSearXNGBaseURL(url)
    }
    func findSearchService() async throws -> String {
        switch await appModel.autodetectSearXNG() {
        // Find, then Save — the page's two buttons in the order a person
        // presses them.
        case .found(let url): return try await appModel.saveSearXNGBaseURL(url)
        case .notFound(let detail), .failed(let detail): throw QuietSettingError.unavailable(detail)
        }
    }

    // The Notifications page's own reads and writes (InboxSettingsView).
    func inboxTriggers() async throws -> [QuietInboxTrigger] {
        try await appModel.client.getInboxTriggers().map {
            QuietInboxTrigger(
                name: $0.name, enabled: $0.enabled,
                paths: ($0.config?["paths"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
        }
    }
    func setInboxTrigger(_ name: String, enabled: Bool) async throws {
        try await appModel.client.inboxTriggerEnable(name, enabled: enabled)
    }
    func saveWatchedFolders(_ paths: [String]) async throws {
        try await appModel.client.inboxTriggerConfigure("file_watch", body: ["paths": paths])
    }
}
