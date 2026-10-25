import AgentConversations
import ChatToolRuntime
import Cognition
import Foundation
import MacIntegration
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TelegramBot
import TrustCenter
// Blueprint: | `QuietSelfAdminSettings+LowerOnly.swift` | lower-only settings rows and cognition/provider controls; Mac permission reductions enforce their subset under the authority file lock |

extension QuietProviderAccount {
    public init(providerID: String, authState: String, eligible: Bool, models: [ProviderModelInfo]) {
        self.init(id: providerID, authState: authState, eligible: eligible, models: models.map {
            QuietProviderModel(
                id: $0.id,
                defaultEffort: $0.default_reasoning_effort ?? "high",
                efforts: $0.supported_reasoning_efforts ?? ["low", "medium", "high", "xhigh"],
                supportsFast: $0.supports_fast == true)
        })
    }
}

extension QuietCognitionLane {
    public func setEnabled(_ enabled: Bool, runtime: NativeCognitionRuntime) async {
        switch self {
        case .capsule: await runtime.setCapsuleEnabled(enabled)
        case .background: await runtime.setBackgroundEnabled(enabled)
        case .reflection: await runtime.setReflectionEnabled(enabled)
        case .organism: await runtime.setOrganismKernelEnabled(enabled)
        case .viewsExperiment: await runtime.setViewsExperimentEnabled(enabled)
        }
    }
}

@MainActor public protocol QuietLowerOnlySettingsHost: QuietSettingsHost {
    var statusForAgent: String { get }
    var activityCaptureEnabled: Bool { get }
    var activityModelAccessEnabled: Bool { get }
    var restartQuietTelegram: @Sendable () async -> Void { get }
    var restartQuietSlack: @Sendable () async -> Void { get }
    func saveChromeControlEnabled(_ enabled: Bool) async
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool
    func setActivityCaptureEnabled(_ enabled: Bool) async
    func setActivityModelAccessEnabled(_ enabled: Bool) async
    func configureQuietTelegram(chats: [String], users: [String], mention: Bool, enabled: Bool) async throws
    func refreshQuietTelegram() async
    func slackIsEnabled() async -> Bool
    func slackIngressPolicy(dataRoot: URL) throws -> (allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool)
    func afterCurrentSlackHandling(_ operation: @escaping @Sendable () async -> Void) async -> Bool
    func saveSlackIngress(channels: Set<String>, users: Set<String>, mention: Bool, dataRoot: URL) async -> (ok: Bool, error: String?)
    func refreshQuietConnectors() async
}

/// Agent, 2026-10-01, under User's ruling that she is boss below his floor:
/// the switches she may turn down. Each row calls the setter its page calls;
/// the direction rule is Core's (`QuietSettings.lowerOnly` / `narrowOnly`).
extension QuietLowerOnlySettingsHost {
    public var lowerOnlyRows: [QuietSetting] {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var rows: [QuietSetting] = []

        // ── Trust ──────────────────────────────────────────────────────────
        rows.append(QuietSettings.lowerOnly(
            id: "trust.chrome_control", page: "trust", label: "Chrome control",
            whereUserDoesIt: "Trust → Mac → Chrome control",
            note: "Full Mac allows Chrome whatever this says; there, lowering trust.preset is what stops it.",
            read: { _ in self.trustPolicy?.chromeControlPolicy?.enabled ?? false },
            write: { _, enabled in await self.saveChromeControlEnabled(enabled) }
        ).onTab("mac"))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.pause_everything", page: "trust", label: "Pause everything", safe: true,
            whereUserDoesIt: "Trust → Access → Security → Pause everything",
            note: "On, every action stops until the owner lifts it.",
            read: { _ in (try? await SwiftNativeSecurityCenter().status(limit: 1))?.killSwitchEnabled ?? false },
            write: { _, enabled in
                guard await self.saveKillSwitchEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        "Pause everything was not saved: \(self.statusForAgent). Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            }
        ))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.activity_capture", page: "trust", label: "Activity capture",
            whereUserDoesIt: "Trust → Features → Activity capture",
            note: "Off stops recording which app and window are in front. What was recorded stays.",
            read: { _ in self.activityCaptureEnabled },
            write: { _, enabled in await self.setActivityCaptureEnabled(enabled) }
        ).onTab("features"))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.activity_model_access", page: "trust", label: "Let the agent read activity",
            whereUserDoesIt: "Trust → Features → Activity capture",
            note: "Full Mac allows trusted activity queries even when the saved switch is off. Lower trust.preset to stop that override.",
            read: { _ in
                let fullMac = (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName
                return self.activityModelAccessEnabled || fullMac
            },
            write: { _, enabled in
                if !enabled,
                   (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName {
                    throw QuietSettingError.unavailable(
                        "Full Mac still allows trusted activity queries. Lower trust.preset before turning this access off.")
                }
                await self.setActivityModelAccessEnabled(enabled)
            }
        ).onTab("features"))
        let peers = AgentPeerStore(dataRoot: root)
        for peer in (try? peers.list()) ?? [] {
            rows.append(QuietSettings.lowerOnly(
                id: "trust.agent_elevation_\(peer.id)", page: "trust",
                label: "\(peer.name) may use your permissions",
                whereUserDoesIt: "Trust → Access → Connected agents → \(peer.name)",
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
            // Access gained is User's. This previews the refusal; the writer
            // enforces the subset against current access under its file lock.
            let users: @Sendable (Set<String>, Set<String>) -> QuietSettingError? = { want, now in
                let gained = want.subtracting(now)
                return gained.isEmpty ? nil : QuietSettings.usersCall(
                    "Giving \(name) \(gained.sorted().joined(separator: " and ")) access", "Trust → Mac → \(name)")
            }
            rows.append(QuietSetting(
                id: "trust.mac_integration_\(integration)", page: "mac_integration",
                label: "\(name) access", kind: .choice, choices: choices,
                note: "You may take access away; giving any back is the owner's below Full Mac. Under Full Mac an app left "
                    + "untouched is allowed anyway; setting it here records an off that Full Mac respects.",
                read: { _ in
                    let on = await current()
                    return .string(on.isEmpty ? "off" : on.count == 2 ? "read_write" : on.first!)
                },
                write: { _, value in
                    // `check` has refused a bad value.
                    guard let want = wants(value) else { return }
                    let onlyRemovingAxes = !(QuietSettings.fullMac || QuietSettings.byOwner || QuietSettings.restoringPreviousValue)
                    // Written even when it reads the same: an explicit off is
                    // what holds under Full Mac.
                    do {
                        if let phone = PhoneSettingChange.current {
                            try await store.setWithReceipt(
                                integrationId: integration, read: want.contains("read"), write: want.contains("write"),
                                actionID: phone.actionID, surface: "ios_icloud", provenance: .signedIOS(clientID: phone.clientID),
                                onlyRemovingAxes: onlyRemovingAxes)
                        } else {
                            try await store.set(integrationId: integration, read: want.contains("read"), write: want.contains("write"),
                                                onlyRemovingAxes: onlyRemovingAxes)
                        }
                    } catch MacIntegrationPermissionStoreError.wouldGainAxes(let gained) {
                        if let refused = QuietSettings.usersCall(
                            "Giving \(name) \(gained.joined(separator: " and ")) access", "Trust → Mac → \(name)") {
                            throw refused
                        }
                        throw MacIntegrationPermissionStoreError.wouldGainAxes(gained)
                    }
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
            try await self.configureQuietTelegram(chats: chats, users: users, mention: mention, enabled: enabled)
            let restart = self.restartQuietTelegram
            Task.detached {
                await TelegramTurnCoordinator.shared.waitUntilAllIdle()
                await restart()
            }
            await self.refreshQuietTelegram()
            QuietWriteDetail.record("takes_effect", .string(
                "Saved now; Telegram picks it up once every running Telegram turn, this one included, has finished."))
            if !enabled {
                QuietWriteDetail.record("locks_out", .string(
                    "Telegram is off: nobody, the owner included, reaches the bot until they turn it back on at the Mac. Tell them."))
            } else if chats.isEmpty && users.isEmpty {
                QuietWriteDetail.record("locks_out", .string(
                    "Both allowlists are empty: nobody, the owner included, reaches the bot until they add an ID back at the Mac. Tell them."))
            } else if !removed.isEmpty {
                QuietWriteDetail.record("locks_out", .string(
                    "\(removed.joined(separator: ", ")) no longer reach the bot. If one was the owner's, they are locked out of "
                    + "Telegram until they add it back at the Mac. Tell them."))
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
        // A write reads the saved policy and refuses when it is unreadable; a
        // read of an unreadable policy shows the fail-closed state (nobody, @mention on).
        let slack = { try self.slackIngressPolicy(dataRoot: root) }
        let saveSlack: @MainActor @Sendable (Set<String>, Set<String>, Bool) async throws -> Void = { channels, users, mention in
            // The wizard's save also marks Slack on, so it may only run while
            // Slack is on already.
            guard await self.slackIsEnabled() else {
                throw QuietSettingError.unavailable(
                    "Slack is off, so it reaches nobody and there is nothing to narrow. Turning it on is the owner's.")
            }
            guard !channels.isEmpty || !users.isEmpty else {
                throw QuietSettingError.unavailable(
                    "Slack needs at least one allowed channel or user. To cut Slack off entirely, use connector.off with id slack.")
            }
            let result = await self.saveSlackIngress(channels: channels, users: users, mention: mention, dataRoot: root)
            guard result.ok else {
                throw QuietSettingError.unavailable((result.error ?? "Slack's save failed.") + " Nothing was changed.")
            }
            let deferred = await self.afterCurrentSlackHandling(self.restartQuietSlack)
            await self.refreshQuietConnectors()
            if deferred {
                QuietWriteDetail.record("takes_effect", .string(
                    "Saved now; Slack picks it up after this Slack turn finishes."))
            }
        }
        rows.append(QuietSettings.lowerOnly(
            id: "slack.require_mention", page: "connectors", label: "Slack: require an @mention in channels",
            safe: true, whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in (try? slack())?.requireMention ?? true },
            write: { _, on in
                let policy = try slack()
                try await saveSlack(policy.allowedChannelIds, policy.allowedUserIds, on)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_channel_ids", page: "connectors", label: "Slack allowed channel IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in (try? slack())?.allowedChannelIds.sorted() ?? [] },
            write: { _, ids in
                let policy = try slack()
                try await saveSlack(Set(ids), policy.allowedUserIds, policy.requireMention)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_user_ids", page: "connectors", label: "Slack allowed user IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in (try? slack())?.allowedUserIds.sorted() ?? [] },
            write: { _, ids in
                let policy = try slack()
                try await saveSlack(policy.allowedChannelIds, Set(ids), policy.requireMention)
            }
        ))
        return rows
    }
}
