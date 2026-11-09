import AgentConversations
import AuthoredCapabilities
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
// Blueprint: | `QuietSelfAdminSettings+LowerOnly.swift` | Lower-only rows enforce subsets under the authority lock; Slack rows share an asynchronous checked policy per read and refresh it for mutations |

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
    /// Which window titles activity capture records: one of `QuietSettings.activityTitleChoices`.
    var activityTitleCapture: String { get async throws }
    func setActivityTitleCapture(_ choice: String) async throws
    var activityRetentionDays: Int { get async throws }
    func setActivityRetentionDays(_ days: Int) async throws
    /// The apps excluded from activity capture that may be recorded again (the always-excluded ones are not among them).
    var activityExclusions: [String] { get }
    func removeActivityExclusion(_ bundleID: String) async throws
    func configureQuietTelegram(chats: [String], users: [String], mention: Bool, enabled: Bool) async throws
    func refreshQuietTelegram() async
    func slackIsEnabled() async throws -> Bool
    func slackIngressPolicy(dataRoot: URL) async throws -> (allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool)
    func saveSlackIngress(channels: Set<String>, users: Set<String>, mention: Bool, dataRoot: URL) async -> (ok: Bool, error: String?)
    func refreshQuietConnectors() async
}

/// One settings read shares its checked policy across Slack's three rows. Each mutation starts a fresh read; no snapshot outlives this row batch.
@MainActor private final class QuietSlackPolicyRead {
    typealias Policy = (allowedChannelIds: Set<String>, allowedUserIds: Set<String>, requireMention: Bool)
    private let load: @MainActor @Sendable () async throws -> Policy
    private var pending: Task<Policy, Error>?
    init(load: @escaping @MainActor @Sendable () async throws -> Policy) { self.load = load }
    func value() async throws -> Policy {
        if let pending { return try await pending.value }
        let task = Task { try await self.load() }
        pending = task
        return try await task.value
    }
    func invalidate() { pending = nil }
}

/// Lower-only settings share the page setter and Core direction rules.
extension QuietLowerOnlySettingsHost {
    public func lowerOnlyRows(forPage page: String?) throws -> [QuietSetting] {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let peers = page == nil || page == "trust" ? try AgentPeerStore(dataRoot: root).list() : []
        return try lowerOnlyRows(forPage: page, connectedPeers: peers)
    }

    public func lowerOnlyRows(forPage page: String?, connectedPeers: [AgentPeerContact]) throws -> [QuietSetting] {
        let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        var rows: [QuietSetting] = []

        rows.append(QuietSettings.lowerOnly(
            id: "trust.chrome_control", page: "trust", label: "Chrome control in narrower modes",
            whereUserDoesIt: "Trust → Mac → Chrome control",
            note: "This is the saved switch for narrower modes. Full Mac allows Chrome while that standing is on; the extension must still be connected.",
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
        // How much activity capture records and keeps, and the Mac's access preset, are the person's to set: the agent reads them.
        rows.append(QuietSetting(
            id: "trust.activity_titles", page: "trust", label: "Window titles recorded", kind: .choice,
            choices: QuietSettings.activityTitleChoices,
            note: "apps: app names only; windows: window titles; browsers: window and browser titles. Titles may reveal private information.",
            ownerOnly: true,
            read: { _ in .string(try await self.activityTitleCapture) },
            write: { _, value, context in
                try await self.setActivityTitleCapture(QuietSettings.choiceValue(value, "Window titles recorded", QuietSettings.activityTitleChoices))
            }
        ).onTab("features"))
        rows.append(QuietSetting(
            id: "trust.activity_retention", page: "trust", label: "Keep activity history for (days)", kind: .choice,
            choices: QuietSettings.activityRetentionChoices,
            note: "Older history is deleted at cleanup.", ownerOnly: true,
            read: { _ in .string(String(try await self.activityRetentionDays)) },
            write: { _, value, context in
                let choice = try QuietSettings.choiceValue(value, "Keep activity history for", QuietSettings.activityRetentionChoices)
                guard let days = Int(choice) else { throw QuietSettingError.badValue("Keep activity history for takes a number of days.") }
                try await self.setActivityRetentionDays(days)
            }
        ).onTab("features"))
        for bundleID in activityExclusions {
            rows.append(QuietSetting(
                id: "trust.activity_excluded_\(bundleID)", page: "trust", label: "\(bundleID) excluded from activity capture", kind: .boolean,
                note: "Off records this app again. Excluding an app is Trust's Exclude an app, chosen on the Mac.", ownerOnly: true,
                read: { _ in .bool(self.activityExclusions.contains(bundleID)) },
                write: { _, value, context in
                    guard !(try QuietSettings.boolValue(value, "\(bundleID) excluded")) else {
                        throw QuietSettingError.badValue("An app is excluded through Trust's Exclude an app on the Mac; this switch only lets it back in.")
                    }
                    try await self.removeActivityExclusion(bundleID)
                }
            ).onTab("features"))
        }
        rows.append(QuietSetting(
            id: "trust.mac_preset", page: "trust", label: "Mac access preset", kind: .choice,
            choices: QuietSettings.macPresetChoices,
            note: "off, watch, assistant, or full, which is Full Mac.", ownerOnly: true,
            read: { _ in
                guard let policy = self.trustPolicy else { throw QuietSettingError.unavailable("""
                    Trust policy is unavailable. Read Trust and repair its saved policy before reading the Mac access preset.
                    """) }
                if TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy) { return .string(MacIntegrationPreset.full.rawValue) }
                return TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
                    .map { .string(TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: $0).rawValue) } ?? .null
            },
            write: { _, value, context in
                let preset = try QuietSettings.choiceValue(value, "Mac access preset", QuietSettings.macPresetChoices)
                let saved = try await TrustPolicyActions(dataRoot: root).saveMacIntegrationPreset(preset)
                self.applySavedTrustPolicy(saved, status: "Mac access saved")
            }
        ).onTab("mac"))
        if page == nil || page == "trust" {
            let peers = AgentPeerStore(dataRoot: root)
            for peer in connectedPeers {
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
        // One writer for an app's access (nil leaves an axis as saved). The person's decided change records the door it came from; any other
        // change, at any posture, may only take access away, which the store enforces under its lock.
        let setIntegration: @MainActor @Sendable (String, String, String, JSONValue, Bool?, Bool?, QuietSettingWrite) async throws -> Void = {
            integration, name, setting, value, read, write, context in
            let decided = QuietSettings.personDecided(setting: setting, value: value, turn: context.turn)
            let onlyRemovingAxes = !decided
            let act = decided ? context.turn.personAct : nil
            let door = act?.door
            do {
                // The signed phone's tap records the paired device its router verified; another door records itself.
                if door == "phone", let device = act?.device {
                    try await store.setWithReceipt(
                        integrationId: integration, read: read, write: write, actionID: UUID().uuidString.lowercased(), surface: "ios_icloud",
                        provenance: .signedIOS(clientID: device), onlyRemovingAxes: onlyRemovingAxes)
                } else if let door, door != "mac" {
                    try await store.setWithReceipt(
                        integrationId: integration, read: read, write: write, actionID: UUID().uuidString.lowercased(),
                        surface: door + "_face", provenance: .local(decidedBy: door + "_face"), onlyRemovingAxes: onlyRemovingAxes)
                } else {
                    try await store.set(integrationId: integration, read: read, write: write, onlyRemovingAxes: onlyRemovingAxes)
                }
            } catch MacIntegrationPermissionStoreError.wouldGainAxes(let gained) {
                if let refused = QuietSettings.usersCall("Giving \(name) \(gained.joined(separator: " and ")) access", "Trust → Mac → \(name)",
                                                         setting: setting, value: value, turn: context.turn) {
                    throw refused
                }
                throw MacIntegrationPermissionStoreError.wouldGainAxes(gained)
            }
        }
        for integration in MacIntegrationID.all {
            let name = MacIntegrationID.displayName(for: integration)
            let axes = (MacIntegrationID.supportsRead(integration) ? ["read"] : [])
                + (MacIntegrationID.supportsWrite(integration) ? ["write"] : [])
            let choices = ["off"] + axes + (axes.count == 2 ? ["read_write"] : [])
            let current: @MainActor @Sendable () async throws -> Set<String> = {
                let snapshot = try await store.snapshotChecked()
                var on = Set<String>()
                if axes.contains("read"), snapshot.allows(integration, mode: .read) { on.insert("read") }
                if axes.contains("write"), snapshot.allows(integration, mode: .write) { on.insert("write") }
                return on
            }
            let wants: @Sendable (JSONValue) -> Set<String>? = { value in
                guard case .string(let raw) = value,
                      let wanted = choices.first(where: { $0 == raw.trimmingCharacters(in: .whitespaces).lowercased() })
                else { return nil }
                return wanted == "read_write" ? ["read", "write"] : wanted == "off" ? [] : [wanted]
            }
            let id = "trust.mac_integration_\(integration)"
            // Preview refuses access gains; the writer enforces the subset against current access under its file lock.
            let users: @Sendable (Set<String>, Set<String>, JSONValue, Turn) -> QuietSettingError? = { want, now, value, turn in
                let gained = want.subtracting(now)
                return gained.isEmpty ? nil : QuietSettings.usersCall(
                    "Giving \(name) \(gained.sorted().joined(separator: " and ")) access", "Trust → Mac → \(name)",
                    setting: id, value: value, turn: turn)
            }
            rows.append(QuietSetting(
                id: id, page: "trust",
                label: "\(name) access", kind: .choice, choices: choices,
                note: "You may take access away; giving any back is the person's at every posture (your call asks them). "
                    + "Full Mac respects these switches, including their shipped defaults.",
                read: { _ in
                    let on = try await current()
                    return .string(on.isEmpty ? "off" : axes.filter { on.contains($0) }.joined(separator: "_"))
                },
                write: { _, value, context in
                    guard let want = wants(value) else { return }
                    // Write explicit off even when already off so the choice remains authoritative under Full Mac.
                    try await setIntegration(integration, name, id, value, want.contains("read"), want.contains("write"), context)
                },
                check: { _, value, turn in
                    guard let want = wants(value) else {
                        return .badValue("\(name) access takes one of: \(choices.joined(separator: ", ")).")
                    }
                    do { return users(want, try await current(), value, turn) }
                    catch { return .unavailable(error.localizedDescription) }
                }
            ))
            // Each axis is its own switch too, so one change names one axis and the other stays as saved.
            for mode in axes {
                let axisID = "\(id)_\(mode)"
                let label = "\(name) \(mode == "read" ? "Read" : "Write")"
                rows.append(QuietSetting(
                    id: axisID, page: "trust", label: label, kind: .boolean,
                    note: "One axis of \(name) access. You may turn it off; turning it on is the person's at every posture. Off fences Full Mac too.",
                    read: { _ in .bool(try await current().contains(mode)) },
                    write: { _, value, context in
                        let on = try QuietSettings.boolValue(value, label)
                        try await setIntegration(integration, name, axisID, value, mode == "read" ? on : nil, mode == "write" ? on : nil,
                                                 context)
                    },
                    check: { _, value, turn in
                        let on: Bool
                        do { on = try QuietSettings.boolValue(value, label) } catch { return error as? QuietSettingError }
                        guard on else { return nil }
                        do {
                            guard !(try await current().contains(mode)) else { return nil }
                            return QuietSettings.usersCall("Turning \(label) on", "Trust → Mac → \(name)", setting: axisID, value: value, turn: turn)
                        } catch { return .unavailable(error.localizedDescription) }
                    }
                ))
            }
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
        let slack = QuietSlackPolicyRead { try await self.slackIngressPolicy(dataRoot: root) }
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
            slack.invalidate()
            guard result.ok else {
                throw QuietSettingError.unavailable((result.error ?? "Slack's save failed.") + " Nothing was changed.")
            }
            await self.restartQuietSlack()
            await self.refreshQuietConnectors()
        }
        rows.append(QuietSettings.lowerOnly(
            id: "slack.require_mention", page: "connectors", label: "Slack: require an @mention in channels",
            safe: true, whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try await slack.value().requireMention },
            write: { _, on, context in
                slack.invalidate()
                let policy = try await slack.value()
                try await saveSlack(policy.allowedChannelIds, policy.allowedUserIds, on, context)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_channel_ids", page: "connectors", label: "Slack allowed channel IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try await slack.value().allowedChannelIds.sorted() },
            write: { _, ids, context in
                slack.invalidate()
                let policy = try await slack.value()
                try await saveSlack(Set(ids), policy.allowedUserIds, policy.requireMention, context)
            }
        ))
        rows.append(QuietSettings.narrowOnly(
            id: "slack.allowed_user_ids", page: "connectors", label: "Slack allowed user IDs",
            whereUserDoesIt: "Connectors → Slack → Who can message your agent",
            read: { _ in try await slack.value().allowedUserIds.sorted() },
            write: { _, ids, context in
                slack.invalidate()
                let policy = try await slack.value()
                try await saveSlack(policy.allowedChannelIds, Set(ids), policy.requireMention, context)
            }
        ))
        return rows
    }
}
