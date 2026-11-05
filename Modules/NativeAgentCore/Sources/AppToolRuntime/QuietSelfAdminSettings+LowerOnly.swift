import AgentConversations
import ChatToolRuntime
import Cognition
import Foundation
import MacIntegration
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import TelegramBot
import TrustCenter
// Blueprint: | `QuietSelfAdminSettings+LowerOnly.swift` | Lower-only rows enforce subsets under the authority lock |

extension QuietProviderAccount {
    public init(providerID: String, authState: String, eligible: Bool, models: [ProviderModelInfo]) {
        self.init(id: providerID, authState: authState, eligible: eligible, models: models.map {
            QuietProviderModel(
                id: $0.id,
                defaultEffort: $0.default_reasoning_effort ?? "",
                efforts: $0.supported_reasoning_efforts ?? [],
                supportsFast: $0.supports_fast == true,
                reasoningCapabilitiesKnown: $0.supported_reasoning_efforts != nil)
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
        }
    }
}

@MainActor public protocol QuietLowerOnlySettingsHost: QuietSettingsHost {
    var statusForAgent: String { get }
    var activityCaptureEnabled: Bool { get async throws }
    var activityModelAccessEnabled: Bool { get async throws }
    var restartQuietTelegram: @Sendable () async -> Void { get }
    var restartQuietSlack: @Sendable () async -> Void { get }
    func saveChromeControlEnabled(_ enabled: Bool) async
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool
    func setActivityCaptureEnabled(_ enabled: Bool) async
    func setActivityModelAccessEnabled(_ enabled: Bool) async
    func configureQuietTelegram(chats: [String], users: [String], mention: Bool, enabled: Bool) async throws
    func refreshQuietTelegram() async
    func slackIsEnabled() async throws -> Bool
    func slackIngressPolicy(dataRoot: URL) throws -> (allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool)
    func afterCurrentSlackHandling(_ operation: @escaping @Sendable () async -> Void) async -> Bool
    func saveSlackIngress(channels: Set<String>, users: Set<String>, mention: Bool, dataRoot: URL) async -> (ok: Bool, error: String?)
    func refreshQuietConnectors() async
}

/// Lower-only settings share the page setter and Core direction rules.
extension QuietLowerOnlySettingsHost {
    public func lowerOnlyRows(forPage page: String?) throws -> [QuietSetting] {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var rows: [QuietSetting] = []

        rows.append(QuietSettings.lowerOnly(
            id: "trust.chrome_control", page: "trust", label: "Chrome control",
            whereUserDoesIt: "Trust → Mac → Chrome control",
            note: "Full Mac allows Chrome whatever this says; there, lowering trust.preset is what stops it.",
            read: { _ in
                guard let policy = self.trustPolicy else { throw QuietSettingError.unavailable("""
                    Trust policy is unavailable. Read Trust and repair its saved policy before changing Chrome control.
                    """) }
                return policy.chromeControlPolicy?.enabled ?? false
            },
            write: { _, enabled, context in await self.saveChromeControlEnabled(enabled) }
        ).onTab("mac"))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.pause_everything", page: "trust", label: "Pause everything", safe: true,
            whereUserDoesIt: "Trust → Access → Security → Pause everything",
            note: "On, every action stops until the owner lifts it.",
            read: { _ in try await SwiftNativeSecurityCenter(dataRoot: root).status(limit: 1).killSwitchEnabled },
            write: { _, enabled, context in
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
            read: { _ in try await self.activityCaptureEnabled },
            write: { _, enabled, context in await self.setActivityCaptureEnabled(enabled) }
        ).onTab("features"))
        rows.append(QuietSettings.lowerOnly(
            id: "trust.activity_model_access", page: "trust", label: "Let the agent read activity",
            whereUserDoesIt: "Trust → Features → Activity capture",
            note: "Full Mac allows trusted activity queries even when the saved switch is off. Lower trust.preset to stop that override.",
            read: { _ in
                let fullMac = (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName
                let modelAccess = try await self.activityModelAccessEnabled
                return modelAccess || fullMac
            },
            write: { _, enabled, context in
                if !enabled,
                   (await AppToolExecutor.freshQuietPosture(dataRoot: root))?.name == AppToolExecutor.fullMacModeName {
                    throw QuietSettingError.unavailable(
                        "Full Mac still allows trusted activity queries. Lower trust.preset before turning this access off.")
                }
                await self.setActivityModelAccessEnabled(enabled)
            }
        ).onTab("features"))
        if page == nil || page == "trust" {
            let peers = AgentPeerStore(dataRoot: root)
            for peer in try peers.list() {
                rows.append(QuietSettings.lowerOnly(
                    id: "trust.agent_elevation_\(peer.id)", page: "trust",
                    label: "\(peer.name) may use your permissions",
                    whereUserDoesIt: "Trust → Access → Connected agents → \(peer.name)",
                    read: { _ in
                        guard let current = try peers.list().first(where: { $0.id == peer.id }) else {
                            throw QuietSettingError.unavailable("\(peer.name) is no longer in the checked contact list. Read connected agents again.")
                        }
                        return current.elevationAllowed ?? false
                    },
                    write: { _, allowed, context in
                        guard try peers.setElevation(peerID: peer.id, allowed: allowed) != nil else {
                            throw QuietSettingError.unavailable(
                                "\(peer.name) is no longer a connected agent. Read app {page:\"connectors\"} for the current list.")
                        }
                    }
                ))
            }
        }

        let store = MacIntegrationPermissionStore(dataRoot: root)
        for integration in MacIntegrationID.all {
            let name = MacIntegrationID.displayName(for: integration)
            let axes = (MacIntegrationID.supportsRead(integration) ? ["read"] : [])
                + (MacIntegrationID.supportsWrite(integration) ? ["write"] : [])
            let choices = ["off"] + axes + (axes.count == 2 ? ["read_write"] : [])
            let current: @MainActor @Sendable () async throws -> Set<String> = {
                let snapshot = try await store.snapshotChecked()
                var on = Set<String>()
                if snapshot.allows(integration, mode: .read) { on.insert("read") }
                if snapshot.allows(integration, mode: .write) { on.insert("write") }
                return on
            }
            let wants: @Sendable (JSONValue) -> Set<String>? = { value in
                guard case .string(let raw) = value,
                      let wanted = choices.first(where: { $0 == raw.trimmingCharacters(in: .whitespaces).lowercased() })
                else { return nil }
                return wanted == "read_write" ? ["read", "write"] : wanted == "off" ? [] : [wanted]
            }
            // Preview refuses access gains; the writer enforces the subset against current access under its file lock.
            let users: @Sendable (Set<String>, Set<String>, Turn) -> QuietSettingError? = { want, now, turn in
                let gained = want.subtracting(now)
                return gained.isEmpty ? nil : QuietSettings.usersCall(
                    "Giving \(name) \(gained.sorted().joined(separator: " and ")) access", "Trust → Mac → \(name)", turn: turn)
            }
            rows.append(QuietSetting(
                id: "trust.mac_integration_\(integration)", page: "mac_integration",
                label: "\(name) access", kind: .choice, choices: choices,
                note: "You may take access away; giving any back is the owner's below Full Mac. Under Full Mac an app left "
                    + "untouched is allowed anyway; setting it here records an off that Full Mac respects.",
                read: { _ in
                    let on = try await current()
                    return .string(on.isEmpty ? "off" : on.count == 2 ? "read_write" : on.first!)
                },
                write: { _, value, context in
                    guard let want = wants(value) else { return }
                    let onlyRemovingAxes = !(context.turn.settingFullMac || context.turn.settingByOwner || context.turn.restoresPreviousSetting)
                    // Write explicit off even when already off so the choice remains authoritative under Full Mac.
                    do {
                        if let phone = context.turn.phoneSettingChange {
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
                            "Giving \(name) \(gained.joined(separator: " and ")) access", "Trust → Mac → \(name)", turn: context.turn) {
                            throw refused
                        }
                        throw MacIntegrationPermissionStoreError.wouldGainAxes(gained)
                    }
                },
                check: { _, value, turn in
                    guard let want = wants(value) else {
                        return .badValue("\(name) access takes one of: \(choices.joined(separator: ", ")).")
                    }
                    do { return users(want, try await current(), turn) }
                    catch { return .unavailable(error.localizedDescription) }
                }
            ))
        }

        let telegram: @Sendable () throws -> TelegramBot.TelegramConfig = {
            guard let saved = try TelegramBot.TelegramConfig.loadSavedConfiguration(dataRoot: root, resolveCredential: false) else {
                throw QuietSettingError.unavailable("""
                    Telegram has no saved settings. Open Connectors → Telegram and save its configuration before reading or changing these controls.
                    """)
            }
            return saved
        }
        let saveTelegram: @MainActor @Sendable (
            QuietSettingWrite,
            _ change: (inout Bool, inout Bool, inout [String], inout [String]) -> Void
        ) async throws -> Void = { context, change in
            let saved = try telegram()
            var enabled = saved.enabled, mention = saved.requireMention
            var chats = saved.allowedChatIds.sorted().map(String.init)
            var users = saved.allowedUserIds.sorted().map(String.init)
            change(&enabled, &mention, &chats, &users)
            let removed = Set(saved.allowedChatIds.map(String.init)).union(saved.allowedUserIds.map(String.init))
                .subtracting(chats).subtracting(users).sorted()
            // Empty token/model/think preserve saved values. Defer poll-loop restart until all Telegram turns finish to avoid self-cancellation.
            try await self.configureQuietTelegram(chats: chats, users: users, mention: mention, enabled: enabled)
            let restart = self.restartQuietTelegram
            Task.detached {
                await TelegramTurns.shared.waitUntilAllIdle()
                await restart()
            }
            await self.refreshQuietTelegram()
            context.detail.record("takes_effect", .string(
                "Saved now; Telegram picks it up once every running Telegram turn, this one included, has finished."))
            if !enabled {
                context.detail.record("locks_out", .string(
                    "Telegram is off: nobody, the owner included, reaches the bot until they turn it back on at the Mac. Tell them."))
            } else if chats.isEmpty && users.isEmpty {
                context.detail.record("locks_out", .string(
                    "Both allowlists are empty: nobody, the owner included, reaches the bot until they add an ID back at the Mac. Tell them."))
            } else if !removed.isEmpty {
                context.detail.record("locks_out", .string(
                    "\(removed.joined(separator: ", ")) no longer reach the bot. If one was the owner's, they are locked out of "
                    + "Telegram until they add it back at the Mac. Tell them."))
            }
        }
        rows.append(QuietSettings.lowerOnly(
            id: "telegram.enabled", page: "telegram", label: "Telegram is on",
            whereUserDoesIt: "Connectors → Telegram → Telegram is on, then Save",
            note: "Off stops the bot answering; the token stays saved.",
            read: { _ in try telegram().enabled },
            write: { _, on, context in try await saveTelegram(context) { enabled, _, _, _ in enabled = on } }
        ))
        rows.append(QuietSettings.lowerOnly(
            id: "telegram.require_mention", page: "telegram", label: "Only answer when mentioned in a group",
            safe: true, whereUserDoesIt: "Connectors → Telegram, then Save",
            read: { _ in try telegram().requireMention },
            write: { _, on, context in try await saveTelegram(context) { _, mention, _, _ in mention = on } }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "telegram.allowed_chat_ids", page: "telegram", label: "Allowed chat IDs",
            whereUserDoesIt: "Connectors → Telegram → Allowed chat IDs, then Save",
            note: "With both lists empty nobody reaches the bot.",
            read: { _ in try telegram().allowedChatIds.sorted().map(String.init) },
            write: { _, ids, context in try await saveTelegram(context) { _, _, chats, _ in chats = ids } }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "telegram.allowed_user_ids", page: "telegram", label: "Allowed user IDs",
            whereUserDoesIt: "Connectors → Telegram → Allowed user IDs, then Save",
            note: "With both lists empty nobody reaches the bot.",
            read: { _ in try telegram().allowedUserIds.sorted().map(String.init) },
            write: { _, ids, context in try await saveTelegram(context) { _, _, _, users in users = ids } }
        ))

        // Checked policy owns both reads and writes; unavailable policy cannot appear as an empty allowlist.
        let slack = { try self.slackIngressPolicy(dataRoot: root) }
        let saveSlack: @MainActor @Sendable (Set<String>, Set<String>, Bool, QuietSettingWrite) async throws -> Void = { channels, users, mention, context in
            // The wizard's save also marks Slack on, so it may only run while Slack is on already.
            guard try await self.slackIsEnabled() else {
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
                context.detail.record("takes_effect", .string(
                    "Saved now; Slack picks it up after this Slack turn finishes."))
            }
        }
        rows.append(QuietSettings.lowerOnly(
            id: "slack.require_mention", page: "connectors", label: "Slack: require an @mention in channels",
            safe: true, whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try slack().requireMention },
            write: { _, on, context in
                let policy = try slack()
                try await saveSlack(policy.allowedChannelIds, policy.allowedUserIds, on, context)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_channel_ids", page: "connectors", label: "Slack allowed channel IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try slack().allowedChannelIds.sorted() },
            write: { _, ids, context in
                let policy = try slack()
                try await saveSlack(Set(ids), policy.allowedUserIds, policy.requireMention, context)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_user_ids", page: "connectors", label: "Slack allowed user IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try slack().allowedUserIds.sorted() },
            write: { _, ids, context in
                let policy = try slack()
                try await saveSlack(policy.allowedChannelIds, Set(ids), policy.requireMention, context)
            }
        ))
        return rows
    }
}
