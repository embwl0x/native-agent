import MacIntegration
import MacControl
import GitHubConnector
import TrustCenter
import Connectors
import SlackBot
import Foundation
import SwiftUI
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import NotificationInbox
import ApprovalTransactions
import AttentionRouting
import AppToolRuntime
import ChatOrchestration
import ProviderRouting

/// The Mac door into shared card transactions; navigation remains native.
enum InteractionCardDelivery {
    @MainActor
    static func answer(payload: [String: String], actionID: String, clientID: String, dataRoot: URL) async throws -> [String: String] {
        try await InlineInteractionDelivery.answer(payload: payload, actionID: actionID,
            clientID: clientID, dataRoot: dataRoot, controls: {
                NativeAgentAppCoordinator.shared.appModel.map(AppInlineInteractionControlPort.init)
            })
    }

    @MainActor
    static func act(id: String, action: String, dataRoot: URL, quiet: Bool = false) async throws {
        try await InlineInteractionDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet) { pointer in
            guard let appModel = NativeAgentAppCoordinator.shared.appModel else {
                throw NSError(domain: "InteractionCard", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Open NativeAgent on your Mac to finish this request."
                ])
            }
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == pointer.sessionID }),
                  await InlineInteractionResolver.interaction(id: pointer.interactionID,
                    sessionID: pointer.sessionID, dataRoot: dataRoot) != nil else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            await appModel.selectChatSession(session)
            guard appModel.activeChatSessionId == pointer.sessionID else {
                throw NSError(domain: "InteractionCard", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "This request is unavailable. Refresh Activity and try again."
                ])
            }
            _ = NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        }
    }
}

/// Binds Core verification to the same live owners and macOS probes as the UI.
@MainActor
struct AppInlineInteractionPlatformPort: InlineInteractionPlatformPort {
    func probeAppleEventApp(_ name: String) async -> String {
        await SystemAppleScriptAdapter.automationStatus(app: name, ask: false)
    }

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool) {
        let status = await NativeAgentEngine.live.chrome.setupConnectionStatus()
        return (status.enabled, status.state == .connected)
    }

    var chromeSteps: String { InlineCardProjection.chromeSteps }

    func pairedPhoneCount() async -> Int {
        await NativeAgentEngine.liveDeviceSync.pairedPhones.pairedCount()
    }

    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus] {
        try await ConnectorStatusProjection.readConnectorRecords(root: root, platform: AppConnectorStatusPlatform()).map {
            (id: $0.id, authState: $0.authState, healthStatus: $0.healthStatus)
        }
    }

    func providers() async throws -> [InlineInteractionProviderStatus] {
        try await NativeAgentEngine.live.providers.list().map {
            (providerID: $0.provider_id, displayName: $0.display_name,
             authState: $0.auth_status.state, defaultModel: $0.default_model,
             firstModel: $0.models.first?.id)
        }
    }

    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) -> String? {
        SystemPermissionPreflight.cardBlockReason(ids, mode: mode)
    }
}

@MainActor
struct AppInlineInteractionControlPort: InlineInteractionControlPort {
    let appModel: AppModel
    var screenCaptureEnabled: Bool { appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true }
    var chromeControlEnabled: Bool { appModel.engine.trust.policy?.chromeControlPolicy?.enabled == true }
    var fullMacGrantIsActive: Bool { appModel.engine.trust.policy.map(TrustAccessModeCapabilityCatalog.fullMacGrantIsActive) ?? false }
    func enableChromeControl() async { await appModel.saveChromeControlEnabled(true) }
    func setUpChromeControl() async -> String? {
        let setup = await ChromeExtensionFolder.setUp()
        return setup.folder == nil || !setup.extensionsPageOpened ? setup.message : nil
    }

    func saveConnectorCredentials(connector: String, values: [String: String], dataRoot: URL) async -> (error: String?, note: String?) {
        let connector = InlineInteractionRegistry.canonicalConnectorID(connector)
        let outcome = await NativeOAuthFlow.saveInlineConnector(
            connector: connector,
            service: { InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot) },
            values: values, dataRoot: dataRoot, credentialStore: GitHubCredentialStore.shared,
            slackRequireMention: { SlackSocketModeConfig.loadIngressPolicy(dataRoot: dataRoot).requireMention },
            restartSlack: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "slack_socket_mode") },
            validateTelegramToken: { TelegramFacade.tokenValidationMessage(for: $0) },
            configureTelegram: { token, chats, users, requireMention in
                try await TelegramFacade(dataRoot: dataRoot).configureTelegram(
                    token: token, allowedChatIds: chats, allowedUserIds: users, requireMention: requireMention,
                    model: "", reasoningEffort: "", enabled: true,
                    restartPollLoop: { _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll") }
                )
            },
            refreshTelegram: { _ = await appModel.refreshTelegram() },
            sendTelegramTestReply: { _ = try await TelegramFacade(dataRoot: dataRoot).sendTelegramTestReply(chatId: $0, manager: appModel.backgroundLoopsManager) },
            refresh: { await appModel.refreshForSidebarItem(.connectors) }
        )
        return (outcome.error, outcome.note)
    }

    func saveProviderCredential(provider: String, value: String) async -> (error: String?, note: String?) {
        if provider == "anthropic_oauth_direct" {
            if let raw = NativeOAuthFlow.saveAnthropicSetupToken(value) {
                return (NativeOAuthFlow.inlineSetupFailureReason(raw, service: "Claude", secret: "setup token", typed: [value]), nil)
            }
            await appModel.loadProvidersForChat()
            await appModel.adoptProviderForBlankSurfaces(provider)
            return (nil, nil)
        }
        let outcome = await NativeOAuthFlow.saveInlineProviderKey(
            value, providerName: InlineInteractionRegistry.providerDisplayName(provider),
            testProvider: { try await appModel.testProvider(provider, apiKeyOverride: value) },
            configureProvider: {
                try await appModel.configureProvider(provider, apiKey: value, authMode: "api_key", defaultModel: nil)
            }
        )
        return (outcome.error, outcome.note)
    }

    func signInProvider(_ signIn: InlineInteractionRegistry.ProviderSignIn, dataRoot: URL) async -> String? {
        let result = await NativeOAuthFlow.startOAuthFlow(platform: NativeOAuthPlatform.self,
            providerId: signIn.oauthProviderID, dataRoot: appModel.dataRootOverride ?? dataRoot)
        if result.ok {
            await appModel.loadProvidersForChat()
            await appModel.adoptProviderForBlankSurfaces(signIn.oauthProviderID)
            return nil
        }
        return NativeOAuthFlow.inlineSetupFailureReason(result.error ?? "", service: signIn.displayShort,
            secret: "sign-in", otherwise: "\(signIn.displayShort) sign-in didn't finish (details in the app log).")
    }

    func grantMacControlCategories(_ categories: [String], dataRoot: URL, logTag: String) async {
        await AppToolExecutor.applyMacControlCategoryGrant(categories, appModel: AppQuietSettingsHost(appModel),
            dataRoot: dataRoot, logTag: logTag)
    }

    func grantCapabilityFlag(policyKey: String, dataRoot: URL, logTag: String) async {
        await AppToolExecutor.applyCapabilityFlagGrant(policyKey: policyKey, appModel: AppQuietSettingsHost(appModel),
            dataRoot: dataRoot, logTag: logTag, requireFullMac: false)
    }

    func saveProviderGroupSelection(group: ProviderSurfaceGroup, providerID: String?, model: String) async throws {
        _ = try await appModel.saveProviderGroupSelection(group: group, providerID: providerID, model: model)
    }
}

extension AppInlineInteractionPlatformPort {
    var applicationIsActive: Bool { NSApp.isActive }

    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool {
        await SystemPermissionPreflight.askMacOSForCard(ids, mode: mode)
    }

    func writeInteractionSnapshots() async { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }

    func refreshInteractionInbox() async {
        do {
            let latest = try await NativeAgentEngine.live.inbox.list()
            if NativeAgentEngine.live.inbox.items != latest { NativeAgentEngine.live.inbox.items = latest }
        } catch {
            ModuleLog.app("[interaction-notification] inbox refresh failed: %@", error.localizedDescription)
        }
    }

    func postInteractionBanner(title: String, body: String, sessionID: String) async {
        let posted = await NativeAgentNotifications.postAndReport(title: title, body: body,
            userInfo: [NativeAgentNotificationActions.sessionKey: sessionID])
        if !posted.posted {
            ModuleLog.app("[interaction-notification] banner failed: %@", posted.error ?? posted.delivery)
        }
    }

    func residentWakeHeld(sessionID: String, dataRoot: URL) -> Bool {
        AttentionRouter.holdsResidentWake(session: sessionID, dataRoot: dataRoot)
    }

    func routeInteractionAttention(id: String, title: String, body: String) async throws {
        try await AttentionRouter.shared.route(eventId: id, importance: .ownerWaiting, title: title, body: body,
            userInfo: ["screen": "inbox", "source": InlineInteractionDelivery.source, "itemId": id], pinnedTo: .phone)
    }

    var telegramApprovalFiler: TelegramApprovalFiler? { TelegramApprovalFilerRef.shared.current() }
}

/// Reuse the chat card and its existing controls without copying its state to
/// User's conversation or changing the session that a tap resumes.
struct InteractionInboxCard: View {
    /// The card's inbox note id, or the original card itself (a chat mirror).
    let noteID: String
    var pinned: InlineInteractionDelivery.Pointer? = nil
    /// Above the chat only what still needs an answer shows; a receipt
    /// belongs in its conversation, never pinned over this one.
    var hidesAnswered = false
    private var observesOrigin = true
    init(item: InboxItemRecord) { noteID = item.id; hidesAnswered = true }
    init(mirrorOf pointer: InlineInteractionDelivery.Pointer, hidesAnswered: Bool = false,
         binding: InlineInteractionChatBinding? = nil) {
        noteID = "interaction:\(pointer.interactionID)"
        pinned = pointer
        self.hidesAnswered = hidesAnswered
        observesOrigin = binding == nil
        if let binding { _binding = State(initialValue: binding) }
    }
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    @State private var binding = InlineInteractionChatBinding()
    @State private var pointer: InlineInteractionDelivery.Pointer?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading) {
            if let pointer, let card = binding.cardsByRow.values.flatMap({ $0 })
                .first(where: { $0.id == pointer.interactionID }),
               !hidesAnswered || card.needsAttention {
                InlineCardView(model: card) { action in
                    binding.handle(card: card, action: action, appModel: appModel)
                }
                .padding(.bottom, hidesAnswered ? 8 : 0)
            } else if !loaded {
                ProgressView()
            }
            // Loaded with no card: answered or gone, so nothing is left to show.
        }
        .sheet(item: Binding(get: { binding.connectorSheet }, set: { request in
            if request == nil { Task { await binding.connectorSheetClosed() } }
        })) { request in
            ConnectorWizardView(provider: request.provider, startsSignIn: true) {
                Task { await binding.connectorSheetClosed() }
            }
            .environment(appModel)
        }
        .sheet(isPresented: Binding(get: { binding.panelPage != nil }, set: { shown in
            if !shown { Task { await binding.panelClosed() } }
        })) {
            if let page = binding.panelPage {
                SimpleSetupPanel(showsClose: true, close: {
                    Task { await binding.panelClosed() }
                }) {
                    InlineCardSetupPresentation.page(page)
                }
                .frame(minWidth: 700, minHeight: 540)
                .environment(appModel)
            }
        }
        .task(id: noteID) {
            do {
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let origin: InlineInteractionDelivery.Pointer
                if let pinned { origin = pinned } else {
                    origin = try await InlineInteractionDelivery.pointer(id: noteID, dataRoot: root)
                }
                pointer = origin
                if observesOrigin { await binding.refresh(sessionID: origin.sessionID) }
            } catch {}
            loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: InlineInteractionWire.changedNotification)) { event in
            guard observesOrigin, let pointer, event.object as? String == pointer.sessionID else { return }
            Task { await binding.refresh(sessionID: pointer.sessionID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await binding.verifyOnReturn() } }
        }
        .onChange(of: chatPageIsVisible) { _, visible in
            if visible { Task { await binding.verifyOnReturn() } }
        }
    }
}
