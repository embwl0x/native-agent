import EngineRuntime
import ActivityWatch
import AgentConversations
import AppToolRuntime
import ChatToolRuntime
import Connectors
import DeviceSync
import Foundation
import MacIntegration
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import SlackBot
import TelegramBot
import TrustCenter

// Blueprint: | `AppQuietLowerOnly.swift` | `AppQuietSettingsHost`, `AppQuietToolHost`: Connector commands; Full Mac ownership |

extension AppQuietSettingsHost {
    var statusForAgent: String { appModel.statusForAgent }
    var activityCaptureEnabled: Bool {
        get async throws { try await appModel.engine.activityWatch.checkedPolicy().captureEnabled }
    }
    var activityModelAccessEnabled: Bool {
        get async throws { try await appModel.engine.activityWatch.checkedPolicy().allowModelAccess }
    }
    var restartQuietTelegram: @Sendable () async -> Void {
        { [loops = appModel.backgroundLoopsManager] in _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll", manager: loops) }
    }
    var restartQuietSlack: @Sendable () async -> Void {
        { _ = await NativeAgentEngine.restartBackgroundLoop(id: "slack_socket_mode") }
    }
    func saveChromeControlEnabled(_ enabled: Bool) async { await appModel.saveChromeControlEnabled(enabled) }
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool { await appModel.saveKillSwitchEnabled(enabled) }
    func setActivityCaptureEnabled(_ enabled: Bool) async { await appModel.engine.activityWatch.setCaptureEnabled(enabled) }
    func setActivityModelAccessEnabled(_ enabled: Bool) async { await appModel.engine.activityWatch.setModelAccessEnabled(enabled) }
    func configureQuietTelegram(chats: [String], users: [String], mention: Bool, enabled: Bool) async throws {
        try await appModel.engine.telegram.configureTelegram(
            token: "", allowedChatIds: chats, allowedUserIds: users, requireMention: mention,
            model: "", reasoningEffort: "", enabled: enabled)
    }
    func refreshQuietTelegram() async { _ = await appModel.refreshTelegram() }
    func slackIsEnabled() async throws -> Bool {
        let connectors = try await appModel.engine.connectors.refresh().get()
        guard let slack = connectors.first(where: { $0.id == "slack" }) else {
            throw QuietSettingError.unavailable("Slack is absent from the checked connector inventory. Read Connectors before changing its ingress policy.")
        }
        return slack.enabled
    }
    func refreshQuietConnectors() async { _ = await appModel.refreshForSidebarItem(.connectors) }
    func slackIngressPolicy(dataRoot: URL) throws -> (allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool) {
        let policy = try SlackSocketModeConfig.loadIngressPolicy(dataRoot: dataRoot)
        return (policy.allowedChannelIds, policy.allowedUserIds, policy.requireMention)
    }
    func afterCurrentSlackHandling(_ operation: @escaping @Sendable () async -> Void) async -> Bool {
        // The mounted settings host holds no Slack handler completion.
        await SlackSocketModeLoop.afterCurrentHandling(operation, deferAfterHandling: nil)
    }
    func saveSlackIngress(channels: Set<String>, users: Set<String>, mention: Bool, dataRoot: URL) async -> (ok: Bool, error: String?) {
        let result = await NativeOAuthFlow.saveSlackToken(
            "", appToken: "", allowedChannelIds: channels, allowedUserIds: users,
            requireMention: mention, dataRoot: dataRoot)
        return (result.ok, result.error)
    }
}

// MARK: - connections

extension AppQuietToolHost {
    func connections(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        func text(_ key: String) -> String {
            input[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func outcome(_ result: AppMutationResult) -> JSONValue {
            .object(["status": .string(result.succeeded ? "ok" : "failed"), "detail": .string(result.agentMessage)])
        }
        func decided(_ tool: String) {
            HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: tool, sessionID: input["__session_id"]?.scalarText,
                                   dataRoot: appModel.engine.dataRoot)
        }
        switch verb {
        case "connector_off", "connector_on":
            // Below Full Mac, enabling belongs to the user; the tool door refuses it.
            let on = verb == "connector_on"
            let wanted = text("id").lowercased()
            let connectors: [ConnectorRecord]
            do { connectors = try await appModel.engine.connectors.refresh().get() }
            catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            guard let connector = connectors.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return AppToolExecutor.failure("unknown_connector",
                    "No connector is called \(wanted.isEmpty ? "that" : wanted). Pass id, one of the ids below.",
                    extra: ["ids": .array(connectors.map { .string($0.id) })])
            }
            guard connector.enabled != on else {
                return .object(["status": .string("ok"), "changed": .bool(false), "id": .string(connector.id),
                                "detail": .string("\(connector.name) is already \(on ? "on" : "off").")])
            }
            switch await appModel.updateConnector(connector, enabled: on) {
            case .verified:
                if on {
                    HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: "connector.on \(connector.id)",
                                           sessionID: input["__session_id"]?.scalarText,
                                           dataRoot: appModel.engine.dataRoot)
                }
                return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(connector.id),
                                "detail": .string(on ? "\(connector.name) is on."
                                    : "\(connector.name) is off. Turning it back on is the owner's below Full Mac.")])
            case .failed(let detail):
                // Preserve the raw cause alongside the plain failure line.
                let line = appModel.statusCause == nil ? detail : appModel.statusForAgent
                return AppToolExecutor.failure("\(verb)_failed",
                    "\(line) \(connector.name) may still be \(on ? "off" : "on"); read app {page:\"connectors\"}, then retry.",
                    extra: ["id": .string(connector.id), "effects": .string("unknown")])
            }
        // Below Full Mac, these four controls belong to the user; each publishes its decided row.
        case "connector_disconnect":
            let wanted = text("id").lowercased()
            let connectors: [ConnectorRecord]
            do { connectors = try await appModel.engine.connectors.refresh().get() }
            catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            guard let connector = connectors.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return AppToolExecutor.failure("unknown_connector",
                    "No connector is called \(wanted.isEmpty ? "that" : wanted). Pass id, one of the ids below.",
                    extra: ["ids": .array(connectors.map { .string($0.id) })])
            }
            do { _ = try await NativeAgentEngine.live.ports.deviceSyncHost.disconnectConnector(id: connector.id) } catch {
                return AppToolExecutor.failure("connector_disconnect_failed",
                    "\(error.localizedDescription) Read app {page:\"connectors\"} for where \(connector.name) stands.",
                    extra: ["id": .string(connector.id), "effects": .string("unknown")])
            }
            _ = await appModel.refreshForSidebarItem(.connectors)
            decided("connector.disconnect \(connector.id)")
            return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(connector.id),
                            "detail": .string("\(connector.name) is disconnected and off. Signing back in is the owner's.")])
        case "telegram_disconnect":
            // Defer Telegram poll restart until all turns finish because shutdown awaits them, including this turn.
            // Read metadata independently so a Keychain fault cannot erase settings or block revocation.
            let result = await appModel.clearTelegramToken(restartPollLoop: false)
            let loops = appModel.backgroundLoopsManager
            Task.detached {
                await TelegramTurns.shared.waitUntilAllIdle()
                _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll", manager: loops)
            }
            if result.succeeded { decided("telegram.disconnect") }
            return outcome(result)
        case "pairing_remove":
            guard let store = appModel.engine.sync.owner?.pairedPhones else {
                return AppToolExecutor.failure("pairing_unavailable", "Pairing is unavailable, so nothing was removed.")
            }
            await store.reload()
            let phones = store.phones.filter { $0.status != .removed }
            guard let phone = phones.first(where: { $0.id == text("id") }) else {
                return AppToolExecutor.failure("unknown_phone",
                    "No paired or waiting phone has that id. Pass id, one of the ids below.",
                    extra: ["ids": .array(phones.map { .string($0.id) })])
            }
            guard await store.setStatus(.removed, id: phone.id) else {
                return AppToolExecutor.failure(
                    "pairing_remove_failed",
                    (store.message ?? "The removal did not save.") + " The phone is as it was.",
                    extra: ["id": .string(phone.id), "effects": .string("unknown")]
                )
            }
            decided("pairing.remove \(phone.id)")
            return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(phone.id),
                            "detail": .string("Removed the phone: it no longer decides approvals. Pairing it again is the owner's.")])
        case "telegram_repair":
            do {
                return try await TelegramUpdateInbox.repair(dataRoot: appModel.engine.dataRoot, inbox: text("inbox"))
            } catch {
                return ChatToolOutcome.failure(error: error, tool: "app")
            }
        case "telegram_test":
            return outcome(await appModel.testTelegram())
        default:
            await appModel.clearTelegramLogs()
            switch appModel.telegramClearLogsOutcome {
            case .completed(let receipt)?:
                return .object(["status": .string("ok"), "detail": .string(appModel.statusForAgent),
                                "removed_rows": .int(Int64(receipt.removedRowCount))])
            case .failed(let detail)?:
                let line = appModel.statusCause == nil ? detail : appModel.statusForAgent
                return AppToolExecutor.failure(
                    "clear_logs_failed",
                    line + " The logs are as they were; retry, or read \(AppToolExecutor.doorDoctor).",
                    extra: ["effects": .string("unknown")]
                )
            case nil:
                return AppToolExecutor.failure("clear_logs_busy", "A clear is already running; read app {page:\"telegram\"} in a moment.")
            }
        }
    }
}
