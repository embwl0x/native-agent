import MacAssistantStatus
import Foundation
import ApprovalTransactions
import PersistenceCore
import Connectors
import NativeAgentShared
import ChatOrchestration
import NativeAgentCore
import ApprovalInbox
import Cognition
import ProviderRouting
import TrustCenter
import DeviceSync
import DoctorChecks
import Dispatcher
import MacControl
import Onboarding
import PersonaEngine

// R22: thin AppModel passthroughs for view-level engine calls.
//
// Views used to construct their own runtime client inline, which scattered
// that wiring across ~17 view files and drifted from the single policy model.
// These methods route the request through AppModel's data root to its owner,
// so construction lives in exactly one place.
//
// PURE PLUMBING: each method forwards verbatim — identical request semantics,
// identical errors. No new behavior or caching.
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
        let coordinator = ApprovalTransactionCoordinator.app(dataRootOverride: dataRootOverride)
        let task = Task<ApprovalRecord, Error> { @MainActor in
            if let resolverOverride {
                return try await resolverOverride(trimmedID, decision)
            }
            return try await coordinator.resolveApproval(id: trimmedID, decision: decision)
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

    // MARK: Config
    /// Each feature's own settings file, read off the main actor: research,
    /// Doctor's schedule, Telegram, Codex sign-in and model routing.
    nonisolated static func readConfig(dataRoot: URL) async throws -> AppConfig {
        var config = AppConfig()
        let researchPath = dataRoot
            .appendingPathComponent("research", isDirectory: true)
            .appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: researchPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = parsed["searxng_base_url"] as? String {
            config.searxngBaseURL = raw
        } else {
            config.searxngBaseURL = ""
        }
        config.autoDoctor = DoctorStatusProjection.readAutoDoctorConfig(dataRoot: dataRoot)
        config.telegram = await TelegramFacade(dataRoot: dataRoot).configuration()
        config.codexAuth = try? await ProvidersFacade(dataRoot: dataRoot).codexAuthStatus()
        config.modelRouting = try await ProvidersFacade.readModelRoutingConfig(dataRoot: dataRoot)
        return config
    }

    // MARK: Chat context / tools
    func getSessionContext(sessionId: String, model: String? = nil) async throws -> SessionContextStatus {
        try await RuntimeReadProjection.getSessionContext(
            sessionId: sessionId, model: model, dataRoot: engine.dataRoot, configuredThresholdTokens: nil)
    }

    /// ChatOrchestration's canonical transcript compactor, so automatic and
    /// manual requests share validation, verified backup, durable
    /// replacement, traces, and optional distillation.
    func compactSession(
        sessionId: String,
        model: String? = nil,
        providerID: String? = nil,
        force: Bool = false
    ) async throws -> ChatSessionCompactionOutcome {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = trimmedModel.flatMap { $0.isEmpty ? nil : $0 }
        // User, 2026-09-13: no hardcoded model on a call path. Compaction is a
        // Memory and mind activity ("Conversation summaries"), so when the caller
        // names no model the `compaction` surface answers — which is the group's
        // choice, or Chat's when the group has no override of its own.
        let routedModel = await engine.providers.routing.modelStringForSurface("compaction")
        let outcome = try await macChatClient.compactSession(
            sessionId: sessionId,
            model: resolvedModel ?? routedModel ?? "",
            surface: "compaction",
            runId: nil,
            providerID: providerID,
            force: force
        )
        if outcome.compacted {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: outcome.sessionId)
        }
        return outcome
    }

    /// A slash command's tool run. The caller serializes its input on the
    /// main actor so only Sendable data crosses into the dispatcher.
    func dispatchToolData(tool: String, inputData: Data, sessionId: String?) async throws -> DispatchResult {
        guard case .object(let input)? = try? JSONValue.parse(inputData) else {
            throw NSError(domain: "NativeAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not deserialize inputData"])
        }
        return try await dispatchSlashCommand(tool: tool, input: input, sessionId: sessionId, dataRoot: engine.dataRoot)
    }

    // MARK: Connectors
    func getConnectorRegistrationStatus(provider: String) async throws -> ConnectorRegistrationStatus {
        try await ConnectorWizardActions.getConnectorRegistrationStatus(provider: provider)
    }

    func registerConnectorApp(provider: String) async throws -> ConnectorRegisterAppResponse {
        try await ConnectorWizardActions.registerConnectorApp(provider: provider)
    }

    // MARK: Onboarding
    /// The onboarding writer uses the same store root as the personality
    /// reader: an injected body falling back to the process default would let
    /// the starter panel create a persona somewhere other than the panel then
    /// reloads.
    private var onboarding: any OnboardingClient {
        guard let dataRootOverride else { return makeOnboardingClient() }
        return SwiftNativeOnboardingClient(
            personaRoot: PersonaRootResolver.resolveIsolated(dataRoot: dataRootOverride),
            dataRoot: dataRootOverride
        )
    }

    func startOnboarding() async throws -> OnboardingStartResult {
        try await onboarding.startOnboarding()
    }

    func completeOnboarding(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        let result = try await onboarding.completeOnboarding(payload: OnboardingCompletePayload(
            agentName: agentName, personaType: personaType, userName: userName
        ))
        if result.ok { await refreshResidentMindAfterOnboardingTransition() }
        return result
    }

    func resumePendingOnboarding() async throws -> OnboardingCompleteResult {
        let result = try await onboarding.resumePendingOnboarding()
        if result.ok { await refreshResidentMindAfterOnboardingTransition() }
        return result
    }

    /// User, 2026-09-06: the resident refresh is sequenced HERE, not inside the
    /// client call, because only the app knows whether a turn is in flight.
    /// Restarting Context Flow and reloading cognition underneath a running
    /// turn changes the ground it is standing on mid-answer, so a repair that
    /// lands during a turn defers its refresh to the turn's close.
    func repairOnboardingProfile(agentName: String, personaType: String, userName: String) async throws -> OnboardingCompleteResult {
        // Writes only memory/profile.json and leaves every persona document
        // untouched; it does not refresh the resident mind itself.
        let response = try await onboarding.repairProfile(payload: OnboardingCompletePayload(
            agentName: agentName, personaType: personaType, userName: userName
        ))
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

    func resetOnboarding(confirm: Bool = true) async throws -> OnboardingResetResult {
        let result = try await onboarding.resetOnboarding(confirm: confirm)
        if result.ok { await refreshResidentMindAfterOnboardingTransition() }
        return result
    }

    /// A finished, resumed or reset onboarding changes who she is: Context
    /// Flow reloads and cognition refreshes together.
    func refreshResidentMindAfterOnboardingTransition() async {
        async let contextFlow: Void = NativeAgentEngine.live.contextFlow.reloadConfiguration()
        async let cognition = NativeAgentEngine.liveCognition.refreshAfterOnboardingTransition()
        _ = await (contextFlow, cognition)
    }

    // MARK: Mac assistant / Mac control
    func getMacAssistantStatus() async throws -> MacAssistantStatusResult {
        // UI consumes the full access/template lists — request non-lightweight.
        try await AppConnectorActionPlatform(dataRoot: engine.dataRoot).macAssistantStatusClient()
            .macAssistantStatus(lightweight: false)
    }

    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    /// Overload of the existing `runConnectorAction(_:)` for the id/dryRun/input
    /// call shape used by the Mac-data probe.
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:]) async throws -> ConnectorActionReceipt {
        try await ConnectorActions(platform: AppConnectorActionPlatform(dataRoot: engine.dataRoot))
            .runConnectorAction(id: id, dryRun: dryRun, input: input)
    }

    func fullMacYoloAuthorityAdmitted(tool: String, surface: String) async -> Bool {
        await ConnectorActions.fullMacYoloAdmitted(tool: tool, surface: surface, dataRoot: engine.dataRoot)
    }

    func saveMacControlPolicy(
        _ policy: TrustMacControlPolicy,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot)
            .saveMacControlPolicy(policy, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func macControlNotify(title: String, message: String) async throws -> Bool {
        let impl = makeMacControl(
            policyProvider: TrustCenterMacControlPolicyProvider(dataRoot: engine.dataRoot),
            auditAppendPath: MacControlActionRoutes.auditPath(dataRoot: engine.dataRoot),
            notificationCenterAdapter: NativeAgentMacControlNotificationAdapter()
        )
        return try await impl.dispatch(action: "notify", body: [
            "title": .string(title),
            "message": .string(message),
        ]).ok
    }

    func macControlRun(path: String, bodyData: Data) async throws -> MacControlRunResult {
        try await TrustCenterMacControlPolicyProvider.run(
            path: path, bodyData: bodyData, dataRoot: engine.dataRoot, localWorkbench: true
        )
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
        let response = try await engine.providers.saveSurfaceSelection(
            surface: surface,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            providerID: providerID
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

    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String? = nil) async throws {
        try await engine.providers.configureProvider(
            id: id,
            apiKey: apiKey,
            authMode: authMode,
            defaultModel: defaultModel
        )
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    /// `apiKeyOverride` is the unsaved key typed into the provider sheet; when
    /// present the probe tests THAT credential instead of the one on disk
    /// (User, 2026-09-06).
    func testProvider(_ id: String, apiKeyOverride: String? = nil) async throws -> ProviderTestResult {
        try await engine.providers.testProvider(id, apiKeyOverride: apiKeyOverride)
    }

    func clearProvider(_ id: String) async throws {
        try await engine.providers.clearProvider(id)
        Task { _ = await NativeAgentEngine.liveDeviceSync.bridge.publishProviderCatalogStatus() }
    }

    /// The provider sheet's Remove the key, which provider.disconnect runs
    /// too: the registry row, then the sign-in. `detail` is the sheet's status
    /// line; `ok` false claims no removal.
    func disconnectProvider(_ id: String) async -> (ok: Bool, detail: String, cause: String?) {
        do {
            try await clearProvider(id)
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
                return (false, "Clear failed: the OAuth credential could not be removed.", nil)
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
            return (true, detail, nil)
        } catch {
            return (false, UserFacingError.message(error, action: "remove the sign-in"), error.localizedDescription)
        }
    }

    // MARK: Integrations / inbox
    func inboxAction(_ id: String, action: String) async throws {
        if let inboxActionOverride {
            return try await inboxActionOverride(id, action)
        }
        try await InboxCardActions.perform(id, action: action, dataRootOverride: dataRootOverride)
    }
}
