import BodyRuntime
import MindCore
import SenseCore
import Foundation
import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SwiftUI
import DeskCore

// Blueprint: | `CardControls.swift` | Mac inline interaction resolver ports; permission requests and typed credential owners |

// MARK: - The resolver's Mac ports

@MainActor
struct AppInlineInteractionPlatformPort: InlineInteractionPlatformPort {
    let engine: @Sendable () throws -> NativeAgentEngine

    nonisolated init(engine: @escaping @Sendable () throws -> NativeAgentEngine) { self.engine = engine }

    func startLocalTurn(_ prompt: String, sessionID: String, hideUserBubble: Bool, turn: Turn) async throws -> Bool {
        let owner = try engine()
        guard let appModel = ApplicationLifetime.shared.appModel, appModel.engine === owner else {
            throw NSError(domain: "InteractionCard", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The request could not continue: no turn starter is available."])
        }
        let envelope = turn.envelope
        var origin = ChatMessageOrigin(surface: envelope?.surface ?? "chat", agent: envelope?.agent)
        origin.peerSources = turn.peerSteering?.checkpointSources ?? []
        origin.elevatedPeerSources = turn.peerSteering?.elevatedSources ?? []
        // The admitted turn retains the continuation's origin through delivery.
        let started = await appModel.startChatTurn(
            prompt, attachments: [], sessionId: sessionID, hideUserBubble: hideUserBubble,
            requireActiveSession: false, origin: origin, parent: turn
        )
        if !hideUserBubble { appModel.publishConversationAnchor(for: started.acceptance) }
        switch started.acceptance {
        case .accepted: return true
        // The refusal's own reason is the card's: a deleted conversation says so, never "just now".
        case .rejected(let message):
            throw NSError(domain: "InteractionCard", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func interactionControls() -> (any InlineInteractionControlPort)? {
        guard let owner = try? engine(), let model = ApplicationLifetime.shared.appModel, model.engine === owner else { return nil }
        return AppInlineInteractionControlPort(appModel: model)
    }

    func mailReadiness(check: Bool) async -> (status: String, word: String, next: String?) {
        do { return try await engine().macIntegration.mailReadiness(check: check) }
        catch { return ("unavailable", error.localizedDescription, nil) }
    }

    func chromeConnectionStatus() async throws -> (enabled: Bool, connected: Bool) {
        let owner = try engine()
        let status = await owner.chrome.setupConnectionStatus(context: .init(dataRoot: owner.dataRoot))
        return (status.enabled, status.state == .connected)
    }

    var chromeSteps: String { InlineCards.chromeSteps }

    func phoneStanding() async -> NAPhoneStanding? {
        try? await engine().deviceSync?.bridge.checkedPhoneStanding()
    }

    func connectorRecords() async throws -> [InlineInteractionConnectorStatus] {
        try await engine().connectors.refresh().get().map {
            (id: $0.id, authState: $0.authState, healthStatus: $0.healthStatus)
        }
    }

    func providers() async throws -> [InlineInteractionProviderStatus] {
        try await engine().providers.list().providers.map {
            (providerID: $0.provider_id, displayName: $0.display_name,
             authState: $0.auth_status.state, eligible: $0.auth_status.eligible, defaultModel: $0.default_model,
             firstModel: $0.offeredModels.first?.id)
        }
    }

    func cardBlockReason(_ ids: [String], mode: InlineInteraction.AccessMode?) async -> String? {
        await SystemPermissionPreflight.cardBlockReason(ids, mode: mode)
    }
}

@MainActor
struct AppInlineInteractionControlPort: InlineInteractionControlPort {
    let appModel: AppModel
    var renderer: UUID? = nil
    // Control decisions read the committed owner; the drawing feed may still hold the previous frame.
    var screenCaptureEnabled: Bool { appModel.engine.trust.policy?.multimodalPolicy?.screen_capture == true }
    var chromeControlEnabled: Bool { appModel.engine.trust.policy?.chromeControlPolicy?.enabled == true }
    var fullMacGrantIsActive: Bool {
        appModel.engine.trust.policy.map(TrustAccessModeCapabilityCatalog.fullMacGrantIsActive) == true
    }
    func enableChromeControl() async { await appModel.saveChromeControlEnabled(true) }
    func setUpChromeControl(turn: Turn) async -> String? {
        do {
            _ = try await ChromeExtensionFolder.setUp(turn: turn, context: .init(dataRoot: appModel.engine.dataRoot))
            return nil
        }
        catch { return ChromeExtensionFolder.setupMessage(error) }
    }

    func saveConnectorCredentials(connector: String, values: [String: String], dataRoot: URL) async -> (error: String?, note: String?) {
        let connector = ConnectorSetup.canonicalID(connector)
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
            sendTelegramTestReply: { _ = try await TelegramFacade(dataRoot: dataRoot).sendTelegramTestReply(
                chatId: $0,
                manager: appModel.backgroundLoopsManager) },
            refresh: { await appModel.refreshForSidebarItem(.connectors) }
        )
        return (outcome.error, outcome.note)
    }

    func openProviderEntry(provider: String, dataRoot: URL) async throws {
        guard appModel.engine.dataRoot.standardizedFileURL == dataRoot.standardizedFileURL else {
            throw PartCallError(code: "mac_required", message: "Open this account's protected entry on its Mac.")
        }
        _ = try await appModel.engine.signInProviderFace(provider, renderer: renderer)
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
            // The person coming back to the app is the agent's window coming to the front: that process is the face, and this one never
            // becomes the active app, so its own activation would never arrive.
            nonisolated(unsafe) let active = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard PersonOnlyWindows.isOwnProcess(app?.processIdentifier) else { return }
                continuation.yield(())
            }
            nonisolated(unsafe) let changed = NotificationCenter.default.observeSynchronously(
                for: MacIntegrationPermissionStore.DidChange.self, queue: .main
            ) { continuation.yield(()) }
            nonisolated(unsafe) let quit = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.systempreferences" else { return }
                continuation.yield(())
            }
            continuation.onTermination = { _ in
                unsafe center.removeObserver(active)
                unsafe NotificationCenter.default.removeObserver(changed)
                unsafe center.removeObserver(quit)
            }
            continuation.yield(())
        }
    }

    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?, passed: Set<String>) async throws -> [String] {
        try await SystemPermissionPreflight.requestMacOSAccess(ids, mode: mode, passed: passed)
    }

    func writeInteractionSnapshots() async {
        do { try await engine().deviceSync?.engine.writeSnapshots() }
        catch { ModuleLog.app("[interaction-notification] snapshot unavailable: %@", error.localizedDescription) }
    }

    func openInteractionCards() async throws -> [(id: String, sessionID: String)] {
        let reads = try await ForPerson.at(engine().dataRoot).inbox()
        var cards: [(id: String, sessionID: String)] = []
        for row in reads {
            guard row.id.hasPrefix("interaction:"), ["unread", "read"].contains(row.status) else { continue }
            do {
                let pointer = try InlineInteractionDelivery.Pointer(item: row)
                cards.append((id: pointer.interactionID, sessionID: pointer.sessionID))
            } catch { ModuleLog.app("[interaction-notification] card %@ unavailable: %@", row.id, error.localizedDescription) }
        }
        return cards
    }

    func refreshInteractionInbox() async {
        do {
            _ = try await engine().inbox.list()
        } catch {
            ModuleLog.app("[interaction-notification] inbox refresh failed: %@", error.localizedDescription)
        }
    }

}
