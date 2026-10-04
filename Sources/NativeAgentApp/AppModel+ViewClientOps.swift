import MacAssistantStatus
import Foundation
import PersistenceCore
import NativeAgentShared
import ChatOrchestration
import NativeAgentCore
import ApprovalInbox
import Cognition
import ProviderRouting
import TrustCenter
import DeviceSync

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
    /// Overload of the existing `resolveApproval(_:decision:)` for callers that
    /// hold only the approval id (inline cards, sidebar rows). Concurrent
    /// callers share one task because a terminal approval may start a real
    /// executor after its durable decision is written.
    func resolveApproval(id: String, decision: String) async throws -> ApprovalRecord {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw NSError(domain: "NativeAgentApproval", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "The approval request has no identifier."
            ])
        }
        let normalizedDecision = decision
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let task = approvalResolutionTasks[trimmedID] {
            // 2026-09-06: joining is only honest for the SAME decision. The
            // opposite one used to be swallowed and answered with the first
            // decision's result, so pressing Deny over a running Approve read
            // back as an approval nobody made.
            if let inFlight = approvalResolutionDecisions[trimmedID],
               inFlight != normalizedDecision {
                throw NSError(domain: "NativeAgentApproval", code: 409, userInfo: [
                    NSLocalizedDescriptionKey:
                        "This request is already being \(inFlight). That decision was not sent."
                ])
            }
            return try await task.value
        }

        let resolverOverride = approvalResolverOverride
        let resolverClient = client
        let task = Task<ApprovalRecord, Error> { @MainActor in
            if let resolverOverride {
                return try await resolverOverride(trimmedID, decision)
            }
            return try await resolverClient.resolveApproval(id: trimmedID, decision: decision)
        }
        approvalResolutionTasks[trimmedID] = task
        approvalResolutionDecisions[trimmedID] = normalizedDecision
        approvalResolutionInFlightIDs.insert(trimmedID)
        defer {
            approvalResolutionTasks.removeValue(forKey: trimmedID)
            approvalResolutionDecisions.removeValue(forKey: trimmedID)
            approvalResolutionInFlightIDs.remove(trimmedID)
        }
        return try await task.value
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

    // MARK: Chat context / tools
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await client.getSessionContext(sessionId: sessionId, model: model)
    }

    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
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

    /// User, 2026-09-06: the resident refresh is sequenced HERE, not inside the
    /// client call, because only the app knows whether a turn is in flight.
    /// Restarting Context Flow and reloading cognition underneath a running
    /// turn changes the ground it is standing on mid-answer, so a repair that
    /// lands during a turn defers its refresh to the turn's close.
    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResponse {
        let response = try await client.repairOnboardingProfile(
            agentName: agentName, personaType: personaType, userName: userName
        )
        if response.ok {
            // The personality reload (so `agentDisplayName` and AgentVoice stop
            // showing the pre-repair name) and the resident refresh are ONE
            // act, applied behind the same turn-idle gate. User, 2026-09-06: the
            // reload used to run ahead of the gate, so a repair during a live
            // turn re-taught the name and swapped the header underneath the
            // answer in flight while the refresh it belongs with waited.
            await refreshResidentMindAfterProfileRepair()
        }
        return response
    }

    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResponse {
        try await client.resetOnboarding(confirm: confirm)
    }

    // MARK: Mac assistant / Mac control
    func getMacAssistantStatus() async throws -> MacAssistantStatusResult {
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

    func fullMacYoloAuthorityAdmitted(tool: String, surface: String) async -> Bool {
        await client.fullMacYoloAuthorityAdmitted(tool: tool, surface: surface)
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await client.saveMacControlPolicy(policy, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func macControlNotify(title: String, message: String) async throws -> Bool {
        try await client.macControlNotify(title: title, message: message)
    }

    func macControlRun(path: String, bodyData: Data, timeout: TimeInterval = 90) async throws -> MacControlRunResult {
        try await client.macControlRun(path: path, bodyData: bodyData, timeout: timeout, localWorkbench: true)
    }

    // MARK: Providers
    func clearSurfaceOverride(surface: String) async throws {
        let routing = SwiftNativeProviderRouting(dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot())
        try await routing.clearSurfaceOverride(surface: surface)
        if let preference = try await routing.checkedRoutingSnapshot().preferences[surface] {
            applySurfacePickerSelection(
                surface: surface, model: preference.model,
                reasoningEffort: preference.reasoningEffort, serviceTier: preference.serviceTier
            )
        }
        if surface == "cognition_reflection" {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    func setActiveProvider(surface: String, providerId: String) async throws -> EmptyResponse {
        let response = try await client.setActiveProvider(surface: surface, providerId: providerId)
        if surface == "chat" {
            chatProvider = providerId
        } else if surface == "cognition_reflection" {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return response
    }

    func setSurfaceModel(surface: String, model: String, inferProvider: Bool = false) async throws -> ModelCatalogResponse {
        let response = try await client.setSurfaceModel(
            surface: surface,
            model: model,
            inferProvider: inferProvider
        )
        engine.providers.catalog = response
        await refreshSurfacePickerCache()
        if surface == "cognition_reflection" {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
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
        engine.providers.catalog = response
        applySurfacePickerSelection(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        if surface == "cognition_reflection" {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return response
    }

    func saveProviderGroupSelection(
        group: ProviderSurfaceGroup, providerID: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, serviceTier: String? = nil, clearOverride: Bool = false
    ) async throws -> ProviderGroupWriteResult {
        let result = try await engine.providers.routing.saveGroupSelection(
            group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
            serviceTier: serviceTier, clearOverride: clearOverride
        )
        applySurfacePickerSnapshot(result.snapshot)
        if group.surfaces.contains("cognition_reflection") {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return result
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
        engine.providers.catalog = response
        applySurfacePickerSelection(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        if surface == "chat" {
            chatProvider = providerID
            let canonical = response.current.chat
            chatBrainCanonicalSelection = ChatBrainSelection(
                model: canonical.model,
                reasoningEffort: canonical.reasoningEffort,
                fastMode: canonical.serviceTier == "priority"
            )
        } else if surface == "cognition_reflection" {
            await NativeAgentEngine.liveCognition.refreshConfiguration()
        }
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
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
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return response
    }

    /// `apiKeyOverride` is the unsaved key typed into the provider sheet; when
    /// present the probe tests THAT credential instead of the one on disk
    /// (User, 2026-09-06).
    func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> ProviderTestResult {
        try await client.testProvider(id, apiKeyOverride: apiKeyOverride)
    }

    func clearProvider(_ id: String) async throws -> EmptyResponse {
        let response = try await client.clearProvider(id)
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
        return response
    }

    /// The provider sheet's Remove the key, which provider.disconnect runs
    /// too: the registry row, then the sign-in. `detail` is the sheet's status
    /// line; `ok` false claims no removal.
    func disconnectProvider(_ id: String) async -> (ok: Bool, detail: String) {
        do {
            _ = try await clearProvider(id)
            // User, 2026-09-06: for an OAuth provider the credential does not
            // live in providers/<id>.json — ChatGPT's is in codex_home/auth.json
            // and the others in their adapters' own token files — so removing
            // the registry row left the account connected while the sheet said
            // it had been disconnected. Go through the same path the OAuth
            // "Sign out" button uses; it no-ops for non-OAuth providers.
            let clearedOAuth = NativeOAuthFlow.clearTokens(
                providerId: id,
                dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
            let oauthID = NativeOAuthFlow.normalizedOAuthProviderId(id)
            if ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(oauthID),
               !clearedOAuth {
                _ = await loadProvidersForChat()
                return (false, "Clear failed: the OAuth credential could not be removed.")
            }
            // The shared ~/.codex/auth.json belongs to the Codex CLI and is
            // never deleted here, so say so rather than claiming a removal
            // that did not happen (same wording the Sign out button uses).
            // User, 2026-09-06: this asked `isSignedIn`, which reads the auth
            // path chat will USE — and the removal just flipped CLI adoption to
            // declined, so the normal case answered false and reported
            // "Credentials removed" with the shared file still on disk. The
            // disclosure now keys off the shared file itself.
            let detail = NativeOAuthFlow.sharedCodexCLISessionRemains(providerId: id)
                ? "Shared Codex auth is still signed in. Sign out from Codex to remove it."
                : "Credentials removed."
            // S.5: propagate cleared credentials to the provider list so the
            // parent ProviderSettingsView and the chat brain bar reflect the
            // new auth_status (needs_key / needs_oauth) immediately.
            _ = await loadProvidersForChat()
            return (true, detail)
        } catch {
            return (false, "Clear failed: \(error.localizedDescription)")
        }
    }

    // MARK: Integrations / inbox
    func configureSearXNG(baseURL: String) async throws {
        try await client.configureSearXNG(baseURL: baseURL)
    }

    func inboxAction(_ id: String, action: String) async throws {
        if let inboxActionOverride {
            return try await inboxActionOverride(id, action)
        }
        try await client.inboxAction(id, action: action)
    }
}
