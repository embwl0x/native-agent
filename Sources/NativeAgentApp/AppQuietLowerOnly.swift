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

/// Agent, 2026-10-01, under User's ruling that she is boss below his floor:
/// the switches she may turn down. Each row calls the setter its page calls;
/// the direction rule is Core's (`QuietSettings.lowerOnly` / `narrowOnly`).
extension AppQuietSettingsHost {
    var lowerOnlyRows: [QuietSetting] {
        let appModel = appModel
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var rows: [QuietSetting] = []

        // ── Trust ──────────────────────────────────────────────────────────
        rows.append(QuietSettings.lowerOnly(
            id: "trust.chrome_control", page: "trust", label: "Chrome control",
            whereUserDoesIt: "Trust → Chrome control",
            note: "Full Mac allows Chrome whatever this says; there, lowering trust.preset is what stops it.",
            read: { _ in appModel.engine.trust.policy?.chromeControlPolicy?.enabled ?? false },
            write: { _, enabled in await appModel.saveChromeControlEnabled(enabled) }
        ))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.pause_everything", page: "trust", label: "Pause everything", safe: true,
            whereUserDoesIt: "Trust → Security → Pause everything",
            note: "On, every action stops until User lifts it.",
            read: { _ in (try? await SwiftNativeSecurityCenter().status(limit: 1))?.killSwitchEnabled ?? false },
            write: { _, enabled in
                guard await appModel.saveKillSwitchEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        "Pause everything was not saved: \(appModel.statusText). Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            }
        ))
        let activity = ActivityWatchController.shared
        rows.append(QuietSettings.lowerOnly(
            id: "trust.activity_capture", page: "trust", label: "Activity capture",
            whereUserDoesIt: "Trust → Activity capture",
            note: "Off stops recording which app and window are in front. What was recorded stays.",
            read: { _ in activity.policy.captureEnabled },
            write: { _, enabled in activity.setCaptureEnabled(enabled) }
        ))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.activity_model_access", page: "trust", label: "Let the agent read activity",
            whereUserDoesIt: "Trust → Activity capture",
            note: "Full Mac allows trusted activity queries even when the saved switch is off. Lower trust.preset to stop that override.",
            read: { _ in
                let fullMac = (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName
                return activity.policy.allowModelAccess || fullMac
            },
            write: { _, enabled in
                if !enabled,
                   (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName {
                    throw QuietSettingError.unavailable(
                        "Full Mac still allows trusted activity queries. Lower trust.preset before turning this access off.")
                }
                activity.setModelAccessEnabled(enabled)
            }
        ))
        let peers = AgentPeerStore(dataRoot: root)
        for peer in (try? peers.list()) ?? [] {
            rows.append(QuietSettings.lowerOnly(
                id: "trust.agent_elevation_\(peer.id)", page: "trust",
                label: "\(peer.name) may use your permissions",
                whereUserDoesIt: "Trust → Connected agents → \(peer.name)",
                read: { _ in (try? peers.list())?.first { $0.id == peer.id }?.elevationAllowed ?? false },
                write: { _, allowed in
                    guard try peers.setElevation(peerID: peer.id, allowed: allowed) != nil else {
                        throw QuietSettingError.unavailable(
                            "\(peer.name) is no longer a connected agent. Read app {page:\"connectors\"} for the current list.")
                    }
                }
            ))
        }

        // ── Mac Integration: off, read, write or both, per app ─────────────
        let store = MacIntegrationPermissionStore.shared
        for integration in MacIntegrationID.all {
            let name = MacIntegrationID.displayName(for: integration)
            let axes = (MacIntegrationID.supportsRead(integration) ? ["read"] : [])
                + (MacIntegrationID.supportsWrite(integration) ? ["write"] : [])
            let choices = ["off"] + axes + (axes.count == 2 ? ["read_write"] : [])
            let current: @MainActor @Sendable () async -> Set<String> = {
                var on = Set<String>()
                if await store.allows(integration, mode: .read) { on.insert("read") }
                if await store.allows(integration, mode: .write) { on.insert("write") }
                return on
            }
            // The axes a value asks for, or nil when it is not one of choices.
            let wants: @Sendable (JSONValue) -> Set<String>? = { value in
                guard case .string(let raw) = value,
                      let wanted = choices.first(where: { $0 == raw.trimmingCharacters(in: .whitespaces).lowercased() })
                else { return nil }
                return wanted == "read_write" ? ["read", "write"] : wanted == "off" ? [] : [wanted]
            }
            // Access gained is User's. Asked by `check` for the preview and
            // again by `write` against the access it reads itself.
            let users: @Sendable (Set<String>, Set<String>) -> QuietSettingError? = { want, now in
                let gained = want.subtracting(now)
                return gained.isEmpty ? nil : QuietSettings.usersCall(
                    "Giving \(name) \(gained.sorted().joined(separator: " and ")) access", "Trust → Mac integration → \(name)")
            }
            rows.append(QuietSetting(
                id: "trust.mac_integration_\(integration)", page: "mac_integration",
                label: "\(name) access", kind: .choice, choices: choices,
                note: "You may take access away; giving any back is User's below Full Mac. Under Full Mac an app left "
                    + "untouched is allowed anyway; setting it here records an off that Full Mac respects.",
                read: { _ in
                    let on = await current()
                    return .string(on.isEmpty ? "off" : on.count == 2 ? "read_write" : on.first!)
                },
                write: { _, value in
                    // `check` has refused a bad value.
                    guard let want = wants(value) else { return }
                    if let refused = users(want, await current()) { throw refused }
                    // Written even when it reads the same: an explicit off is
                    // what holds under Full Mac.
                    try await store.set(integrationId: integration, read: want.contains("read"), write: want.contains("write"))
                    NativeAgentEngine.liveDeviceSync.macIntegrationPermissions.push(
                        id: integration, read: want.contains("read"), write: want.contains("write"))
                },
                check: { _, value in
                    guard let want = wants(value) else {
                        return .badValue("\(name) access takes one of: \(choices.joined(separator: ", ")).")
                    }
                    return users(want, await current())
                }
            ))
        }

        // ── Telegram: saved through the page's own save, one field changed ─
        let telegram: @Sendable () -> TelegramBot.TelegramConfig? = {
            TelegramBot.TelegramConfig.loadFromDisk(dataRoot: root)
        }
        let saveTelegram: @MainActor @Sendable (
            _ change: (inout Bool, inout Bool, inout [String], inout [String]) -> Void
        ) async throws -> Void = { change in
            guard let saved = telegram() else {
                throw QuietSettingError.unavailable(
                    "Telegram has no readable saved settings, so nothing was changed. Read app {page:\"telegram\"}.")
            }
            var enabled = saved.enabled, mention = saved.requireMention
            var chats = saved.allowedChatIds.sorted().map(String.init)
            var users = saved.allowedUserIds.sorted().map(String.init)
            change(&enabled, &mention, &chats, &users)
            let removed = Set(saved.allowedChatIds.map(String.init)).union(saved.allowedUserIds.map(String.init))
                .subtracting(chats).subtracting(users).sorted()
            // Empty token, model and think keep what is saved. The poll loop
            // is NOT restarted here: its shutdown cancels and awaits every
            // running Telegram turn, this one included when she was asked
            // over Telegram. It restarts once every Telegram turn is done.
            try await appModel.client.configureTelegram(
                token: "", allowedChatIds: chats, allowedUserIds: users,
                requireMention: mention, model: "", reasoningEffort: "", enabled: enabled,
                restartPollLoop: false)
            let loops = appModel.client.backgroundLoopsManager
            Task.detached {
                await TelegramTurnCoordinator.shared.waitUntilAllIdle()
                _ = await loops.restartLoop(id: "telegram_poll")
            }
            _ = await appModel.refreshTelegram()
            QuietWriteDetail.record("takes_effect", .string(
                "Saved now; Telegram picks it up once every running Telegram turn, this one included, has finished."))
            if !enabled {
                QuietWriteDetail.record("locks_out", .string(
                    "Telegram is off: nobody, User included, reaches the bot until he turns it back on at the Mac. Tell him."))
            } else if chats.isEmpty && users.isEmpty {
                QuietWriteDetail.record("locks_out", .string(
                    "Both allowlists are empty: nobody, User included, reaches the bot until he adds an ID back at the Mac. Tell him."))
            } else if !removed.isEmpty {
                QuietWriteDetail.record("locks_out", .string(
                    "\(removed.joined(separator: ", ")) no longer reach the bot. If one was User's, he is locked out of "
                    + "Telegram until he adds it back at the Mac. Tell him."))
            }
        }
        rows.append(QuietSettings.lowerOnly(
            id: "telegram.enabled", page: "telegram", label: "Telegram is on",
            whereUserDoesIt: "Connectors → Telegram → Telegram is on, then Save",
            note: "Off stops the bot answering; the token stays saved.",
            read: { _ in telegram()?.enabled ?? false },
            write: { _, on in try await saveTelegram { enabled, _, _, _ in enabled = on } }
        ))
        rows.append(QuietSettings.lowerOnly(
            id: "telegram.require_mention", page: "telegram", label: "Only answer when mentioned in a group",
            safe: true, whereUserDoesIt: "Connectors → Telegram, then Save",
            read: { _ in telegram()?.requireMention ?? false },
            write: { _, on in try await saveTelegram { _, mention, _, _ in mention = on } }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "telegram.allowed_chat_ids", page: "telegram", label: "Allowed chat IDs",
            whereUserDoesIt: "Connectors → Telegram → Allowed chat IDs, then Save",
            note: "With both lists empty nobody reaches the bot.",
            read: { _ in telegram()?.allowedChatIds.sorted().map(String.init) ?? [] },
            write: { _, ids in try await saveTelegram { _, _, chats, _ in chats = ids } }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "telegram.allowed_user_ids", page: "telegram", label: "Allowed user IDs",
            whereUserDoesIt: "Connectors → Telegram → Allowed user IDs, then Save",
            note: "With both lists empty nobody reaches the bot.",
            read: { _ in telegram()?.allowedUserIds.sorted().map(String.init) ?? [] },
            write: { _, ids in try await saveTelegram { _, _, _, users in users = ids } }
        ))

        // ── Slack: the connector wizard's save, with the saved tokens ─────
        let slack: @Sendable () -> SlackIngressPolicy = { SlackSocketModeConfig.loadIngressPolicy(dataRoot: root) }
        let saveSlack: @MainActor @Sendable (Set<String>, Set<String>, Bool) async throws -> Void = { channels, users, mention in
            // The wizard's save also marks Slack on, so it may only run while
            // Slack is on already.
            guard (try? await appModel.client.getConnectors())?.first(where: { $0.id == "slack" })?.enabled == true else {
                throw QuietSettingError.unavailable(
                    "Slack is off, so it reaches nobody and there is nothing to narrow. Turning it on is User's.")
            }
            guard !channels.isEmpty || !users.isEmpty else {
                throw QuietSettingError.unavailable(
                    "Slack needs at least one allowed channel or user. To cut Slack off entirely, use connector.off with id slack.")
            }
            let result = await NativeOAuthFlow.saveSlackToken(
                "", appToken: "", allowedChannelIds: channels, allowedUserIds: users,
                requireMention: mention, dataRoot: root)
            guard result.ok else {
                throw QuietSettingError.unavailable((result.error ?? "Slack's save failed.") + " Nothing was changed.")
            }
            let deferred = await SlackSocketModeLoop.afterCurrentHandling {
                _ = await BackgroundLoopsManager.shared.restartLoop(id: "slack_socket_mode")
            }
            _ = await appModel.refreshForSidebarItem(.connectors)
            if deferred {
                QuietWriteDetail.record("takes_effect", .string(
                    "Saved now; Slack picks it up after this Slack turn finishes."))
            }
        }
        rows.append(QuietSettings.lowerOnly(
            id: "slack.require_mention", page: "connectors", label: "Slack: require an @mention in channels",
            safe: true, whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in slack().requireMention },
            write: { _, on in
                let policy = slack()
                try await saveSlack(policy.allowedChannelIds, policy.allowedUserIds, on)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_channel_ids", page: "connectors", label: "Slack allowed channel IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in slack().allowedChannelIds.sorted() },
            write: { _, ids in
                let policy = slack()
                try await saveSlack(Set(ids), policy.allowedUserIds, policy.requireMention)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_user_ids", page: "connectors", label: "Slack allowed user IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in slack().allowedUserIds.sorted() },
            write: { _, ids in
                let policy = slack()
                try await saveSlack(policy.allowedChannelIds, Set(ids), policy.requireMention)
            }
        ))
        return rows
    }
}

// MARK: - connections

extension AppQuietToolHost {
    /// The Connectors, Telegram and MCP pages' own buttons. Those report
    /// through the status line, so the status line is the result.
    func connections(verb: String, input: [String: JSONValue]) async -> JSONValue {
        func text(_ key: String) -> String {
            AppToolExecutor.inputString(input[key])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func outcome(_ line: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            let failed = line.localizedCaseInsensitiveContains("failed") || line.localizedCaseInsensitiveContains("disabled")
            var body = extra
            body["status"] = .string(failed ? "failed" : "ok")
            body["detail"] = .string(line)
            return .object(body)
        }
        func decided(_ tool: String) {
            HarnessDecidedRow.post(requester: "Full Mac", tool: tool, sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        }
        switch verb {
        case "connector_off", "connector_on":
            // On is User's below Full Mac; the door refuses it there.
            let on = verb == "connector_on"
            let wanted = text("id").lowercased()
            let connectors = (try? await appModel.client.getConnectors()) ?? appModel.connectors
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
                    HarnessDecidedRow.post(requester: "Full Mac", tool: "connector.on \(connector.id)",
                                           sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                           dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                }
                return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(connector.id),
                                "detail": .string(on ? "\(connector.name) is on."
                                    : "\(connector.name) is off. Turning it back on is User's below Full Mac.")])
            case .failed(let detail):
                return AppToolExecutor.failure("\(verb)_failed",
                    "\(detail) \(connector.name) may still be \(on ? "off" : "on"); read app {page:\"connectors\"}, then retry.",
                    extra: ["id": .string(connector.id)])
            }
        // User's four below Full Mac; the door refuses them there. Each posts
        // the decided row he sees it by.
        case "connector_disconnect":
            // The phone's Connectors → Disconnect: the credential is revoked.
            let wanted = text("id").lowercased()
            let connectors = (try? await appModel.client.getConnectors()) ?? appModel.connectors
            guard let connector = connectors.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return AppToolExecutor.failure("unknown_connector",
                    "No connector is called \(wanted.isEmpty ? "that" : wanted). Pass id, one of the ids below.",
                    extra: ["ids": .array(connectors.map { .string($0.id) })])
            }
            do { _ = try await AppDeviceSyncHost().disconnectConnector(id: connector.id) } catch {
                return AppToolExecutor.failure("connector_disconnect_failed",
                    "\(error.localizedDescription) Read app {page:\"connectors\"} for where \(connector.name) stands.",
                    extra: ["id": .string(connector.id)])
            }
            _ = await appModel.refreshForSidebarItem(.connectors)
            decided("connector.disconnect \(connector.id)")
            return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(connector.id),
                            "detail": .string("\(connector.name) is disconnected and off. Signing back in is User's.")])
        case "telegram_disconnect":
            // Telegram's Disconnect. The poll loop restarts only once every
            // Telegram turn is done: its shutdown awaits them, this one too.
            guard await appModel.refreshTelegram() else {
                return AppToolExecutor.failure("telegram_disconnect_failed", "Telegram didn't read; nothing was removed.")
            }
            await appModel.clearTelegramToken(restartPollLoop: false)
            let loops = appModel.client.backgroundLoopsManager
            Task.detached {
                await TelegramTurnCoordinator.shared.waitUntilAllIdle()
                _ = await loops.restartLoop(id: "telegram_poll")
            }
            let result = outcome(appModel.statusText)
            if case .object(let body) = result, body["status"] == .string("ok") { decided("telegram.disconnect") }
            return result
        case "pairing_remove":
            // Connectors → iPhone → Remove.
            guard let store = appModel.engine.sync.owner?.pairedPhones else {
                return AppToolExecutor.failure("pairing_unavailable", "Pairing is unavailable, so nothing was removed.")
            }
            store.reload()
            let phones = store.phones.filter { $0.status != .removed }
            guard let phone = phones.first(where: { $0.id == text("id") }) else {
                return AppToolExecutor.failure("unknown_phone",
                    "No paired or waiting phone has that id. Pass id, one of the ids below.",
                    extra: ["ids": .array(phones.map { .string($0.id) })])
            }
            appModel.engine.sync.setStatus(.removed, id: phone.id)
            guard store.message == nil, store.phones.first(where: { $0.id == phone.id })?.status == .removed else {
                return AppToolExecutor.failure("pairing_remove_failed",
                    (store.message ?? "The removal did not save.") + " The phone is as it was.", extra: ["id": .string(phone.id)])
            }
            decided("pairing.remove \(phone.id)")
            return .object(["status": .string("ok"), "changed": .bool(true), "id": .string(phone.id),
                            "detail": .string("Removed the phone: it no longer decides approvals. Pairing it again is User's.")])
        case "mcp_revoke_consent":
            // Connectors → MCP → Revoke, on a granted consent.
            appModel.mcpConsent = (try? await appModel.client.getMCPConsent()) ?? appModel.mcpConsent
            let granted = appModel.mcpConsent.filter { $0.status == "granted" }
            guard let consent = granted.first(where: { $0.id == text("id") }) else {
                return AppToolExecutor.failure("unknown_consent",
                    "No granted MCP consent has that id. Pass id, one of the consents below.",
                    extra: ["consents": .array(granted.map {
                        .object(["id": .string($0.id), "server_id": .string($0.serverId ?? ""), "tool": .string($0.toolName ?? "")])
                    })])
            }
            await appModel.revokeMCPConsent(consent)
            let result = outcome(appModel.statusText, ["id": .string(consent.id)])
            if case .object(let body) = result, body["status"] == .string("ok") { decided("mcp.revoke_consent \(consent.id)") }
            return result
        case "telegram_test":
            await appModel.testTelegram()
            return outcome(appModel.statusText)
        case "telegram_clear_logs":
            await appModel.clearTelegramLogs()
            switch appModel.telegramClearLogsOutcome {
            case .completed(let receipt)?:
                return .object(["status": .string("ok"), "detail": .string(appModel.statusText),
                                "removed_rows": .int(Int64(receipt.removedRowCount))])
            case .failed(let detail)?:
                return AppToolExecutor.failure("clear_logs_failed", detail + " The logs are as they were; retry, or read \(AppToolExecutor.doorDoctor).")
            case nil:
                return AppToolExecutor.failure("clear_logs_busy", "A clear is already running; read app {page:\"telegram\"} in a moment.")
            }
        default: // mcp_warm, mcp_restart, mcp_refresh
            if appModel.mcpServers.isEmpty { _ = await appModel.refreshForSidebarItem(.mcp) }
            let wanted = text("server_id").lowercased()
            guard let server = appModel.mcpServers.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return AppToolExecutor.failure("unknown_server",
                    "No MCP server is called \(wanted.isEmpty ? "that" : wanted). Pass server_id, one of the ids below.",
                    extra: ["ids": .array(appModel.mcpServers.map { .string($0.id) })])
            }
            switch verb {
            case "mcp_warm": await appModel.warmMCPServer(server)
            case "mcp_restart": await appModel.restartMCPServer(server)
            default: await appModel.refreshMCPCache(server)
            }
            return outcome(appModel.statusText, ["server_id": .string(server.id)])
        }
    }
}
