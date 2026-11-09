import AgentConversations
import AgentWorkspace
import ActivityWatch
import AppKit
import AppToolRuntime
import AuthoredCapabilities
import Foundation
import ChromeControl
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import TrustCenter
import TrustPersistence
// Blueprint: | `EngineTrustFace.swift` | Trust's checked policy, Mac grants, peers, receipts, privacy and backup controls |

extension NativeAgentEngine {
    var trustFacePaths: [URL] {
        ["trust/policy.json", "security/mac_integration_permissions.json", "agents/peers.json", "agents/conversations.json",
         "agents/discovery.json", "chat/sessions.json", "backups/index.json", "telegram/config.json", "paired_phones.json",
         "abilities/mac-watch-catalog.js", "connectors/registry.json"].map { dataRoot.appendingPathComponent($0) }
            + [ActivityWatchPaths.policyURL(dataRoot: dataRoot), AgentLocalHealth.url(dataRoot),
               TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)]
    }

    @MainActor var trustFaceNotifications: [Notification.Name] {
        [SwiftNativeSecurityCenter.consentDidWrite, SystemPermissionPreflight.permissionDidChange,
         ChatGPTDotIPCTransport.didChange, QuietSettings.trustVoicePreferenceDidChange,
         SwiftNativeMacControl.auditDidWrite, ActivityWatchController.didChange, ChromeControlRuntime.connectionDidChange,
         MacIntegrationFacade.systemStatusesDidChange, MacIntegrationFacade.watchesDidChange, NSApplication.didBecomeActiveNotification]
    }

    @concurrent func trustFace() async throws -> (PartFace, UInt64) {
        try Task.checkCancellation()
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        var sections: [PartFace.Section] = []
        do {
            let policy = try await trust.load()
            sections += await trustPolicyFace(policy)
        } catch {
            sections.append(trustFaceFailure("policy", "Access and policy", error))
            sections.append(.init(id: "repair", title: "Repair saved authority", rows: [
                .init(id: "policy.repair", title: "Preserve damaged policy and authorize Safe",
                    detail: "Keeps the damaged policy beside trust/policy.json before authorizing Safe. Only you can do this.",
                    actions: [.init(id: "authorize_safe", label: "Authorize Safe", role: .destructive, call: PartFace.Call("trust.authorize_safe"))])
            ]))
        }
        async let securityRead = trustSecurityFace()
        async let peerRead = trustPeersFace()
        async let integrationRead = trustIntegrationsFace()
        async let systemRead = trustSystemFace()
        async let watchRead = trustWatchesFace()
        async let activityRead = trustActivityFace()
        let (security, peers, integrations, system, watches, activity) = await (
            securityRead, peerRead, integrationRead, systemRead, watchRead, activityRead)
        sections += security
        sections += [peers, integrations, system, watches]
        sections += activity
        try Task.checkCancellation()
        // Inventory walks the data root. Keep its owner's sampled reading until the person asks for a fresh inventory.
        if await trust.privacyMap == nil { await trust.refreshPrivacyMap() }
        if let map = await trust.privacyMap {
            sections.append(.init(id: "privacy", title: "Privacy map", style: .list, footer: map.dataRoot, rows: [
                .init(id: "privacy.read", title: "Inventory reading", detail: "Refresh reads the inventory again.")
            ] + map.categories.map {
                .init(id: "privacy." + $0.id, title: $0.title, detail: $0.contains + "\n" + $0.path,
                      value: $0.exportable ? "Exportable" : "Protected", tone: $0.exportable ? .quiet : .attention)
            }))
        } else {
            sections.append(.init(id: "privacy", title: "Privacy map", rows: [
                .init(id: "privacy.unavailable", title: "The privacy map has not published a reading.", tone: .attention)
            ]))
        }
        do {
            let backups = try await trust.refreshBackups()
            var rows: [PartFace.Row] = [.init(id: "backup.create", title: "Back up now",
                detail: "Copies app-owned settings, memory, chats, abilities, connectors and jobs. Your own files are outside this operation.",
                actions: [.init(id: "create", label: "Back up now", call: PartFace.Call("backup.now"))])]
            rows += backups.prefix(8).map { backup in
                .init(id: "backup." + backup.id, title: backup.reason,
                      detail: "Scopes: " + backup.scope.joined(separator: ", ")
                        + ". A safety backup comes first; if it fails, nothing is replaced. Restored work stays stopped; Resume starts it fresh.",
                      at: backup.createdAt, actions: [.init(id: "restore", label: "Restore backup", role: .destructive,
                                                            call: PartFace.Call("backup.restore", ["id": .string(backup.id)]))])
            }
            sections.append(.init(id: "backups", title: "Backups", style: .list,
                footer: backups.isEmpty ? "No app-data restore points listed. The file-write backup policy is separate." : nil, rows: rows))
        } catch {
            sections.append(trustFaceFailure("backups", "Backups", error))
        }
        sections.append(.init(id: "refresh", rows: [.init(id: "trust.refresh", title: "Read Trust again",
            actions: [.init(id: "refresh", label: "Refresh", call: PartFace.Call("trust.refresh_privacy"))])]))
        return (.init(title: "Trust", line: "What I may do on my own.", sections: sections), epoch)
    }

    private func trustPolicyFace(_ policy: TrustPolicy) async -> [PartFace.Section] {
        let mode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
        let full = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        let preset = MobileTrustAction.Preset.matching(policy: policy, accessMode: mode)
        var sections: [PartFace.Section] = [.init(id: "access", title: "Access and policy", style: .list, rows: [
            .init(id: "trust.preset", title: "Standing", detail: (preset?.summary ?? "Custom access: " + mode)
                + (full ? ". Full Mac stays on until you change it." : ""),
                control: .choice(MobileTrustAction.Preset.allCases.map { .init(id: $0.rawValue, label: $0.title) },
                    selected: preset?.rawValue, confirm: "Apply the selected standing? If you select Full Mac:\n" + MobileTrustAction.fullMacMessage,
                    call: settingSetCall("trust.preset"))),
            // The standing and "What this allows" already say the level, the default before acting and files outside workspaces in words.
            .init(id: "trust.backups", title: "Backup before changes",
                detail: "The file-write backup policy. App-data restore points are listed under Backups.",
                value: (policy.filePolicy?.requireBackupBeforeWrite).map { $0 ? "Required" : "Not required" })
        ])]
        sections.append(.init(id: "guardrails", title: "What this allows", rows:
            TrustGuardrailSummary.rows(policy: policy, accessMode: mode).map {
                .init(id: "guardrail." + $0.id, title: $0.title, detail: $0.detail, value: $0.value,
                    tone: $0.tone == .danger ? .attention : .plain)
            }))
        var features: [PartFace.Row] = []
        if let multimodal = policy.multimodalPolicy {
            features += [
                trustFaceToggle("trust.screen_capture", "Allow screen capture", multimodal.screen_capture,
                    "I capture your screen when you click the camera button in Chat."),
                trustFaceToggle("trust.image_generation", "Allow image generation", multimodal.image_generation_openai,
                    "I make images when you ask for one.")
            ]
        } else {
            features.append(.init(id: "multimodal.unavailable", title: "Multimodal permissions are unavailable.", tone: .attention))
        }
        if let saved = UserDefaults.standard.object(forKey: "voiceAutoRead"), !(saved is Bool) {
            features.append(.init(id: "voice.unavailable", title: "The saved read-aloud preference is not a Boolean.", tone: .failed))
        } else {
            features.append(trustFaceToggle("chat.read_replies_aloud", "Read replies aloud automatically",
                UserDefaults.standard.bool(forKey: "voiceAutoRead"), "Uses your saved voice settings; the cloud voice needs its own permission."))
        }
        features.append(full
            ? .init(id: "trust.unattended_work", title: "Let me work unattended",
                detail: "Full Mac keeps unattended work on. Choose a narrower standing to change it.",
                value: "On with Full Mac")
            : trustFaceToggle("trust.unattended_work", "Let me work unattended", policy.enableAutonomy,
                "Scheduled helpers and background improvement. Run once still works either way because you asked."))
        sections.append(.init(id: "features", title: "Features", footer: "Background work picks up changes next time it runs; other changes apply right away.",
            rows: features))
        // Rows that act in the foreground on this Mac run from the Mac's door.
        let macDoor = ["mac"]
        let chrome = policy.chromeControlPolicy
        var connection = "No connection reading"
        for await state in await self.chrome.connectionStates() {
            switch state {
            case .connected: connection = "Connected"
            case .disconnected: connection = "Extension not connected"
            case .extensionNotLoaded: connection = "Extension not set up"
            }
            break
        }
        sections.append(.init(id: "chrome", title: "Chrome control", rows: [
            full ? .init(id: "trust.chrome_control", title: "Chrome control",
                detail: "Full Mac allows it; the extension must still be connected. " + (chrome.map {
                    "The saved switch for narrower modes is " + ($0.enabled ? "On." : "Off.")
                } ?? "The saved switch for narrower modes is unavailable."),
                value: "On with Full Mac")
                : chrome.map { trustFaceToggle("trust.chrome_control", "Chrome control", $0.enabled,
                    "I use inactive tabs in my group while you stay signed in. Selecting a tab gives it back to you.") }
                    ?? .init(id: "trust.chrome_control", title: "Chrome control policy is unavailable.", tone: .attention),
            .init(id: "chrome.setup", title: "Chrome extension", detail: "Set up once on this Mac. Allow Mac access if asked, then watch me set it up.",
                value: connection,
                actions: [.init(id: "setup_chrome", label: "Set up Chrome on this Mac", doors: macDoor, call: PartFace.Call("browser.chrome_setup"))])
        ]))
        if let mac = policy.macControlPolicy {
            let effective = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(policy)
            let macPreset = full ? MacIntegrationPreset.full : effective.map { TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: $0) }
            sections.append(.init(id: "mac_preset", title: "Mac access", rows: [
                .init(id: "mac.preset", title: "Mac control preset", control: .choice(
                    [MacIntegrationPreset.off, .watch, .assistant, .full].map {
                        .init(id: $0.rawValue, label: $0 == .full ? "Full Mac" : $0.rawValue.capitalized)
                    },
                    selected: macPreset?.rawValue,
                    confirm: "Apply the selected Mac access? If you select Full Mac:\n" + MobileTrustAction.fullMacMessage,
                    call: settingSetCall("trust.mac_preset"))),
                // Set up is offered only while access is Off or Watch, where it selects Assistant; each check is the door read the agent makes.
                .init(id: "mac.setup", title: "Set up Mac access",
                    detail: "While Mac access is Off or Watch, Set up selects Assistant. Each check asks macOS on this Mac the first time it is needed.",
                    actions: (macPreset == .off || macPreset == .watch ? [.init(id: "setup_mac", label: "Set up Mac access",
                        call: settingSetCall("trust.mac_preset", .string(MacIntegrationPreset.assistant.rawValue)))] : []) + [
                        .init(id: "check_calendar", label: "Check Calendar on this Mac", doors: macDoor,
                              call: PartFace.Call("calendar.upcoming", ["hours_ahead": .int(24), "limit": .int(5)])),
                        .init(id: "check_reminders", label: "Check Reminders on this Mac", doors: macDoor,
                              call: PartFace.Call("reminders.due_today", ["limit": .int(10)]))]),
                .init(id: "mac.notification", title: "Mac notifications",
                    actions: [.init(id: "send_notification", label: "Send a notification on this Mac", doors: macDoor,
                                    call: PartFace.Call("trust.test_notification"))])
            ]))
            let fields: [(String, String, Bool)] = [
                ("enabled", "Mac control", mac.enabled), ("notifications", "Notifications", mac.notificationsAllowed),
                ("spotlight", "Spotlight search", mac.spotlightAllowed), ("file_ops", "File operations", mac.fileOpsAllowed),
                ("accessibility", "Clicking, typing and reading apps", mac.accessibilityAllowed),
                ("applescript", "AppleScript", mac.applesScriptAllowed), ("jxa", "JavaScript for Automation", mac.jxaAllowed),
                ("shell", "Shell commands", mac.shellAllowed), ("remote_from_iphone", "iPhone remote control", mac.remoteFromIosAllowed)
            ]
            sections.append(.init(id: "mac_control", title: "Mac control", footer: full
                ? "These are saved choices for narrower modes. Full Mac's effective permissions apply until you change standing."
                : "Each switch saves immediately. File rules, macOS grants and Trust still apply.", rows: fields.map { id, title, on in
                    trustFaceToggle(id == "enabled" ? "trust.mac_control" : "trust.mac_control_" + id, title, on)
                } + [
                    .init(id: "mac.shortcuts", title: "macOS Shortcuts", value: "Not built yet"),
                    .init(id: "mac.system", title: "System control", value: "Not built yet"),
                    .init(id: "mac.workbench", title: "Mac control workbench", detail: "Freeform commands use the Mac's native workbench.",
                        actions: [.init(id: "workbench", label: "Open workbench on this Mac", doors: macDoor, call: PartFace.Call("trust.workbench"))])
                ]))
        } else {
            sections.append(.init(id: "mac_control", title: "Mac control", rows: [
                .init(id: "mac.unavailable", title: "The saved policy has no Mac control block.", tone: .attention)
            ]))
        }
        return sections
    }

    private func trustPeersFace() async -> PartFace.Section {
        do {
            _ = try await contacts.refresh()
            let state = await MainActor.run { (error: contacts.loadError, doors: contacts.doors) }
            if let error = state.error { throw PartCallError(code: "contacts_unavailable", message: error) }
            let rows = state.doors.compactMap { row -> PartFace.Row? in
                guard let peer = row.contact else { return nil }
                return .init(id: "trust.agent_elevation_" + peer.id, title: row.displayName,
                    detail: row.route + "\n" + row.pillWord + " · " + row.status
                        + (row.elevationFailure.map { "\nYour grant cannot take effect: " + $0.localizedDescription } ?? ""),
                    value: peer.elevationAllowed && row.elevationFailure == nil ? "Authority on" : "Authority off",
                    control: !peer.elevationAllowed && row.elevationFailure != nil ? nil
                        : .toggle(peer.elevationAllowed, confirm: peer.elevationAllowed ? nil : "Let this agent use your existing permissions?",
                                  call: settingSetCall("trust.agent_elevation_" + peer.id)))
            }
            return .init(id: "peers", title: "Connected agents", footer: rows.isEmpty ? "No agents are connected."
                : "Only requests authenticated with each connection's own key use your grant. Delivery is checked separately.", rows: rows)
        } catch { return trustFaceFailure("peers", "Connected agents", error) }
    }

    private func trustIntegrationsFace() async -> PartFace.Section {
        do {
            let snapshot = try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()
            let rows = MacIntegrationID.all.flatMap { id -> [PartFace.Row] in
                [MacIntegrationPermissionMode.read, .write].compactMap { mode in
                    guard mode == .read ? MacIntegrationID.supportsRead(id) : MacIntegrationID.supportsWrite(id) else { return nil }
                    return trustFaceToggle("integration." + id + "." + mode.rawValue,
                        MacIntegrationID.displayName(for: id) + " · " + mode.rawValue.capitalized, snapshot.allows(id, mode: mode),
                        "Checked before each use. Off fences Full Mac too.", setting: "trust.mac_integration_" + id + "_" + mode.rawValue)
                }
            }
            return .init(id: "integrations", title: "Apps and features", rows: rows)
        } catch { return trustFaceFailure("integrations", "Apps and features", error) }
    }
}

/// A Trust switch: its change is `setting.set` on `setting`, or on the setting the row's own id names.
func trustFaceToggle(_ id: String, _ title: String, _ on: Bool, _ detail: String? = nil, safe: Bool = false, setting: String? = nil) -> PartFace.Row {
    .init(id: id, title: title, detail: detail, control: .toggle(on,
        confirm: on == safe ? "Change what I may do: " + title + "?" : nil, call: settingSetCall(setting ?? id)))
}

func trustFaceFailure(_ id: String, _ title: String, _ error: Error) -> PartFace.Section {
    .init(id: id, title: title, rows: [.init(id: id + ".unavailable", title: "Could not read " + title.lowercased(),
        detail: error.localizedDescription, tone: .failed)])
}
