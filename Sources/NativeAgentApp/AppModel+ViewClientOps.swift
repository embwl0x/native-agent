import Foundation
import PersistenceCore
import NativeAgentShared
import NativeAgentCore

// R22: thin AppModel passthroughs for view-level NativeClient calls.
//
// Views used to construct their own NativeClient inline,
// which scattered that wiring across ~17 view files and drifted from
// the single policy model. These wrappers route the identical request through
// AppModel's canonical `client`, so construction lives in exactly one place and a future
// caching/batching layer has a single seam to hook.
//
// PURE PLUMBING: each method forwards verbatim to the same NativeClient call
// the view used to make — identical request semantics, identical errors. No
// new behavior or caching; NativeClient is unconditionally Swift-native.
extension AppModel {

    // MARK: Approvals
    func getApprovals() async throws -> [ApprovalRequest] {
        try await client.getApprovals()
    }

    /// Overload of the existing `resolveApproval(_:decision:)` for callers that
    /// hold only the approval id (inline cards, sidebar rows).
    func resolveApproval(id: String, decision: String) async throws -> ApprovalRequest {
        try await client.resolveApproval(id: id, decision: decision)
    }

    // MARK: Config / raw
    func getConfig() async throws -> AppConfig {
        try await client.getConfig()
    }

    // `sending`: the [String: Any] body crosses out of the MainActor region
    // into the client's nonisolated call — callers pass freshly-built dicts,
    // which is exactly what region-based isolation can prove.
    func postRaw(_ path: String, body: sending [String: Any], timeout: TimeInterval = 60) async throws -> [String: Any] {
        try await client.postRaw(path, body: body, timeout: timeout)
    }

    // MARK: Inbox
    func getInboxItems(unreadOnly: Bool = false) async throws -> [InboxItemRecord] {
        try await client.getInboxItems(unreadOnly: unreadOnly)
    }

    // MARK: Models
    func getModelCatalog(refresh: Bool) async throws -> ModelCatalogResponse {
        try await client.getModelCatalog(refresh: refresh)
    }

    // MARK: Chat context / tools
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await client.getSessionContext(sessionId: sessionId, model: model)
    }

    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> CompactionResult {
        try await client.compactSession(
            sessionId: sessionId,
            model: model,
            providerID: providerID,
            force: force
        )
    }

    func postContextFeedback(
        messageId: String,
        sessionId: String,
        rating: String,
        persona: String
    ) async throws {
        try await client.postContextFeedback(
            messageId: messageId,
            sessionId: sessionId,
            rating: rating,
            persona: persona
        )
    }

    func dispatchToolData(tool: String, inputData: Data, sessionId: String?) async throws -> DispatchResult {
        try await client.dispatchToolData(tool: tool, inputData: inputData, sessionId: sessionId)
    }

    // MARK: Connectors
    func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        try await client.getConnectorRegistrationStatus(provider: provider)
    }

    func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        try await client.registerConnectorApp(provider: provider)
    }

    // MARK: Onboarding
    func startOnboarding() async throws -> OnboardingStartResponse {
        try await client.startOnboarding()
    }

    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResponse {
        try await client.completeOnboarding(agentName: agentName, personaType: personaType, userName: userName)
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResponse {
        try await client.resumePendingOnboarding()
    }

    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResponse {
        try await client.resetOnboarding(confirm: confirm)
    }

    // MARK: Mac assistant / Mac control
    func getMacAssistantStatus() async throws -> MacAssistantStatusResponse {
        try await client.getMacAssistantStatus()
    }

    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await client.saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    /// Overload of the existing `runConnectorAction(_:)` for the id/dryRun/input
    /// call shape used by the Mac-data probe.
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:]) async throws -> ConnectorActionReceipt {
        try await client.runConnectorAction(id: id, dryRun: dryRun, input: input)
    }

    func getTrustPolicy() async throws -> TrustPolicy {
        try await client.getTrustPolicy()
    }

    func saveMacControlPolicy(_ policy: TrustMacControlPolicy) async throws -> TrustPolicy {
        try await client.saveMacControlPolicy(policy)
    }

    func macControlNotify(title: String, message: String) async throws -> Bool {
        try await client.macControlNotify(title: title, message: message)
    }

    func macControlRun(path: String, bodyData: Data, timeout: TimeInterval = 90) async throws -> MacControlRunResult {
        try await client.macControlRun(path: path, bodyData: bodyData, timeout: timeout)
    }

    // MARK: Providers
    func listProviders() async throws -> [ProviderInfo] {
        try await client.listProviders()
    }

    func setActiveProvider(surface: String, providerId: String) async throws -> EmptyResponse {
        let response = try await client.setActiveProvider(surface: surface, providerId: providerId)
        if surface == "chat" {
            chatProvider = providerId
        } else if surface == "cognition_reflection" {
            await NativeCognitionRuntime.shared.refreshConfiguration()
        }
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    func setSurfaceModel(surface: String, model: String, inferProvider: Bool = false) async throws -> ModelCatalogResponse {
        let response = try await client.setSurfaceModel(
            surface: surface,
            model: model,
            inferProvider: inferProvider
        )
        modelCatalog = response
        await refreshSurfacePickerCache()
        if surface == "cognition_reflection" {
            await NativeCognitionRuntime.shared.refreshConfiguration()
        }
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    func configureModel(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String?,
        inferProvider: Bool = false
    ) async throws -> ModelCatalogResponse {
        let response = try await client.configureModel(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            inferProvider: inferProvider
        )
        modelCatalog = response
        applySurfacePickerSelection(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        if surface == "cognition_reflection" {
            await NativeCognitionRuntime.shared.refreshConfiguration()
        }
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    func configureSurfaceSelection(
        surface: String,
        providerID: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String?
    ) async throws -> ModelCatalogResponse {
        let response = try await client.configureSurfaceSelection(
            surface: surface,
            providerID: providerID,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        modelCatalog = response
        applySurfacePickerSelection(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        if surface == "chat" {
            chatProvider = providerID
        } else if surface == "cognition_reflection" {
            await NativeCognitionRuntime.shared.refreshConfiguration()
        }
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    private func applySurfacePickerSelection(
        surface: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String?
    ) {
        switch surface {
        case "chat":
            chatModel = model
            chatReasoningEffort = reasoningEffort
            chatFastMode = serviceTier == "priority"
        case "telegram":
            telegramModel = model
            telegramReasoningEffort = reasoningEffort
        default:
            break
        }
    }

    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String? = nil) async throws -> EmptyResponse {
        let response = try await client.configureProvider(
            id,
            apiKey: apiKey,
            authMode: authMode,
            defaultModel: defaultModel
        )
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    func testProvider(_ id: String) async throws -> ProviderTestResult {
        try await client.testProvider(id)
    }

    func clearProvider(_ id: String) async throws -> EmptyResponse {
        let response = try await client.clearProvider(id)
        Task { _ = await iCloudBridge.shared.publishProviderCatalogStatus() }
        return response
    }

    // MARK: Integrations / inbox
    func configureSearXNG(baseURL: String) async throws {
        try await client.configureSearXNG(baseURL: baseURL)
    }

    func inboxAction(_ id: String, action: String) async throws {
        try await client.inboxAction(id, action: action)
    }
}
