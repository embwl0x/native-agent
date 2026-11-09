import EngineRuntime
import ApprovalTransactions
import AppToolRuntime
import AttentionRouting
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import Connectors
import DeviceSync
import Experiences
import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SlackBot
import SwiftUI
import TrustCenter

// Blueprint: | `CardControls.swift` | Mac inline interaction resolver ports; permission requests and typed credential owners |

// MARK: - The resolver's Mac ports

@MainActor
struct AppInlineInteractionPlatformPort: InlineInteractionPlatformPort {
    func interactionControls() -> (any InlineInteractionControlPort)? {
        ApplicationLifetime.shared.appModel.map { AppInlineInteractionControlPort(appModel: $0) }
    }

    func mailReadiness(root: URL, check: Bool) async -> (status: String, word: String, next: String?) {
        await NativeAgentEngine.forRoot(root).macIntegration.mailReadiness(check: check)
    }

    func chromeConnectionStatus() async -> (enabled: Bool, connected: Bool) {
        let status = await NativeAgentEngine.live.chrome.setupConnectionStatus(context: .init(dataRoot: PersistenceCore.defaultDataRoot()))
        return (status.enabled, status.state == .connected)
    }

    var chromeSteps: String { InlineCards.chromeSteps }

    func phoneStanding() async -> NAPhoneStanding? {
        await NativeAgentEngine.liveDeviceSync.bridge.checkedPhoneStanding()
    }

    func connectorRecords(root: URL) async throws -> [InlineInteractionConnectorStatus] {
        try await NativeAgentEngine.forRoot(root).connectors.refresh().get().map {
            (id: $0.id, authState: $0.authState, healthStatus: $0.healthStatus)
        }
    }

    func providers(root: URL) async throws -> [InlineInteractionProviderStatus] {
        try await NativeAgentEngine.forRoot(root).providers.list().providers.map {
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

    func askMacOSForCard(_ ids: [String], mode: InlineInteraction.AccessMode?) async throws -> [String] {
        try await SystemPermissionPreflight.askMacOSForCard(ids, mode: mode)
    }

    func writeInteractionSnapshots() async { await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots() }

    func openInteractionCards() async throws -> [(id: String, sessionID: String)] {
        let reads = try await ForPerson.at(PersistenceCore.defaultDataRoot()).inbox()
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
            _ = try await NativeAgentEngine.live.inbox.list()
        } catch {
            ModuleLog.app("[interaction-notification] inbox refresh failed: %@", error.localizedDescription)
        }
    }

}
