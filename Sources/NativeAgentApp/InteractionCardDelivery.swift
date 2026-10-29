import MacIntegration
import MacControl
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
import ChatToolRuntime
import ProviderRouting
// Blueprint: | `InteractionCardDelivery.swift` | `InteractionCardDelivery`: `answer`, `act`; shared card transactions with native navigation; `AppInlineInteractionPlatformPort`, `AppInlineInteractionControlPort`, `InteractionInboxCard` |

/// The Mac door into shared card transactions; navigation remains native.
enum InteractionCardDelivery {
    @MainActor
    static func answer(payload: [String: String], actionID: String, clientID: String, dataRoot: URL) async throws -> [String: String] {
        try await InlineInteractionDelivery.answer(payload: payload, actionID: actionID,
            clientID: clientID, dataRoot: dataRoot, controls: {
                ApplicationLifetime.shared.appModel.map(AppInlineInteractionControlPort.init)
            })
    }

    @MainActor
    static func act(id: String, action: String, dataRoot: URL, quiet: Bool = false) async throws {
        try await InlineInteractionDelivery.act(id: id, action: action, dataRoot: dataRoot, quiet: quiet) { pointer in
            guard let appModel = ApplicationLifetime.shared.appModel else {
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
            _ = ApplicationLifetime.shared.request(.sidebar(.chat))
        }
    }
}

/// Binds Core verification to the same live owners and macOS probes as the UI.
@MainActor
struct AppInlineInteractionPlatformPort: InlineInteractionPlatformPort {
    func interactionControls() -> (any InlineInteractionControlPort)? {
        ApplicationLifetime.shared.appModel.map(AppInlineInteractionControlPort.init)
    }

    func probeAppleEventApp(_ name: String) async -> String {
        await AppleScriptExecution.automationStatus(app: name, ask: false)
    }

    func mailListRecent(input: [String: JSONValue]) async throws -> JSONValue {
        try await MacAppleScriptBridge.mailListRecent(input: input)
    }

    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool) {
        let status = await NativeAgentEngine.live.chrome.setupConnectionStatus()
        return (status.enabled, status.state == .connected)
    }

    var chromeSteps: String { InlineCards.chromeSteps }

    func pairedPhoneCount() async -> Int {
        await NativeAgentEngine.liveDeviceSync.pairedPhones.pairedCount()
    }

    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus] {
        try await NativeAgentEngine.forRoot(root).connectors.refresh().get().map {
            (id: $0.id, authState: $0.authState, healthStatus: $0.healthStatus)
        }
    }

    func providers() async throws -> [InlineInteractionProviderStatus] {
        try await NativeAgentEngine.live.providers.list().providers.map {
            (providerID: $0.provider_id, displayName: $0.display_name,
             authState: $0.auth_status.state, eligible: $0.auth_status.eligible, defaultModel: $0.default_model,
             firstModel: $0.models.first?.id)
        }
    }

    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String? {
        await SystemPermissionPreflight.cardBlockReason(ids, mode: mode)
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
        do { _ = try await ChromeExtensionFolder.setUp(); return nil }
        catch { return ChromeExtensionFolder.setupMessage(error) }
    }

    func saveConnectorCredentials(connector: String, values: [String: String], dataRoot: URL) async -> (error: String?, note: String?) {
        let connector = InlineInteractionRegistry.canonicalConnectorID(connector)
        let outcome = await NativeOAuthFlow.saveInlineConnector(
            connector: connector,
            service: { InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot) },
            values: values, dataRoot: dataRoot,
            slackRequireMention: { try SlackSocketModeConfig.loadIngressPolicy(dataRoot: dataRoot).requireMention },
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
            await appModel.adoptProviderForBlankSurfaces(provider)
            return (nil, nil)
        }
        let outcome = await NativeOAuthFlow.saveInlineProviderKey(
            value, providerName: InlineInteractionRegistry.providerDisplayName(provider),
            testProvider: { try await appModel.engine.providers.testProvider(provider, apiKeyOverride: value) },
            configureProvider: {
                try await appModel.engine.configureProvider(provider, apiKey: value, authMode: "api_key", defaultModel: nil)
            }
        )
        return (outcome.error, outcome.note)
    }

    func signInProvider(_ signIn: InlineInteractionRegistry.ProviderSignIn, dataRoot: URL) async -> String? {
        let result = await NativeOAuthFlow.startOAuthFlow(platform: NativeOAuthPlatform.self,
            providerId: signIn.oauthProviderID, dataRoot: dataRoot)
        if result.ok {
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
        _ = try await appModel.engine.saveProviderGroupSelection(group: group, providerID: providerID, model: model)
    }
}

extension AppInlineInteractionPlatformPort {
    func permissionChanges() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let center = NSWorkspace.shared.notificationCenter
            // Tokens are immutable; NotificationCenter can remove them from any thread.
            nonisolated(unsafe) let active = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in continuation.yield(()) }
            nonisolated(unsafe) let changed = NotificationCenter.default.addObserver(
                forName: SystemPermissionPreflight.permissionDidChange, object: nil, queue: .main
            ) { _ in continuation.yield(()) }
            nonisolated(unsafe) let quit = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.systempreferences" else { return }
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(active)
                NotificationCenter.default.removeObserver(changed)
                center.removeObserver(quit)
            }
            continuation.yield(())
        }
    }

    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> Bool {
        await SystemPermissionPreflight.askMacOSForCard(ids, mode: mode)
    }

    func writeInteractionSnapshots() async { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }

    func openInteractionCards() async -> [(id: String, sessionID: String)] {
        let rows = (try? await NativeAgentEngine.live.inbox.list()) ?? []
        return rows.compactMap { row in
            guard row.id.hasPrefix("interaction:"), ["unread", "read"].contains(row.status),
                  let pointer = try? InlineInteractionDelivery.Pointer(item: row) else { return nil }
            return (id: pointer.interactionID, sessionID: pointer.sessionID)
        }
    }

    func refreshInteractionInbox() async {
        do {
            _ = try await NativeAgentEngine.live.inbox.list()
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

    var telegramApprovalFiler: TelegramApprovalFiler? { ApprovalChatCards.runningTelegram }
}

/// Reuse the chat card and its existing controls without copying its state to
/// User's conversation or changing the session that a tap resumes.
struct InteractionInboxCard: View {
    let origin: Result<InlineInteractionDelivery.Pointer, Error>
    init(item: InboxItemRecord, binding: InlineInteractionChatBinding) {
        origin = Result { try .init(item: item) }
        self.binding = binding
    }
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatPageIsVisible) private var chatPageIsVisible
    let binding: InlineInteractionChatBinding
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading) {
            if case .failure(let error) = origin {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Try again") { Task { await retry() } }.disabled(isRetrying)
            } else if case .success(let pointer) = origin {
                if let card = appModel.engine.transcripts.card(id: pointer.interactionID, in: pointer.sessionID),
                   card.needsAttention {
                    InlineCardView(model: card) { action in
                        binding.handle(card: card, action: action, appModel: appModel)
                    }
                    .padding(.bottom, 8)
                } else if case .unavailable(let reason) = appModel.engine.transcripts.transcriptReadStatus(for: pointer.sessionID) {
                    Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Try again") { Task { await retry() } }.disabled(isRetrying)
                } else if case .loading = appModel.engine.transcripts.transcriptReadStatus(for: pointer.sessionID) {
                    ProgressView()
                }
            }
            // Loaded with no card: answered or gone, so nothing is left to show.
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await binding.verifyOnReturn() } }
        }
        .onChange(of: chatPageIsVisible) { _, visible in
            if visible { Task { await binding.verifyOnReturn() } }
        }
    }

    private func retry() async {
        isRetrying = true
        defer { isRetrying = false }
        switch origin {
        case .success(let pointer): await appModel.engine.transcripts.refreshCards(in: pointer.sessionID)
        case .failure: await appModel.engine.inbox.refresh()
        }
    }
}
