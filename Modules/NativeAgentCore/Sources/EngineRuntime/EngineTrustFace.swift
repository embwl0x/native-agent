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
// Blueprint: | `EngineTrustFace.swift` | Trust's face over checked policy, grants, peers, receipts, privacy and backups |

/// Platform operations the old Trust buttons already owned; a person answers these, never an agent's payload.
@MainActor public protocol TrustFaceHost {
    func restoreTrustFaceBackup(_ backup: BackupRecord) async throws -> String
    func trustFaceMacAction(_ action: String) async throws -> String
}

extension NativeAgentEngine {
    var trustFacePaths: [URL] {
        ["trust/policy.json", "security/mac_integration_permissions.json", "agents/peers.json", "agents/conversations.json",
         "agents/discovery.json", "chat/sessions.json", "backups/index.json", "telegram/config.json", "paired_phones.json",
         "scheduler/jobs.json", "abilities/mac-watch-catalog.js", "connectors/registry.json"].map { dataRoot.appendingPathComponent($0) }
            + [ActivityWatchPaths.policyURL(dataRoot: dataRoot), AgentLocalHealth.url(dataRoot),
               TransportAllowlist.slackMetadataPath(dataRoot: dataRoot)]
    }

    @MainActor var trustFaceNotifications: [Notification.Name] {
        [SwiftNativeSecurityCenter.consentDidWrite, SystemPermissionPreflight.permissionDidChange,
         ChatGPTDotIPCTransport.didChange, QuietSettings.trustVoicePreferenceDidChange,
         SwiftNativeMacControl.auditDidWrite, ActivityWatchController.didChange, ChromeControlRuntime.connectionDidChange,
         MacIntegrationFacade.systemStatusesDidChange, MacIntegrationFacade.watchesDidChange, NSApplication.didBecomeActiveNotification]
    }

    @MainActor func trustFace() async throws -> (PartFace, UInt64) {
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
                    actions: [.init(id: "authorize_safe", label: "Authorize Safe", role: .destructive)])
            ]))
        }
        sections += await trustSecurityFace()
        sections.append(await trustPeersFace())
        sections.append(await trustIntegrationsFace())
        sections.append(trustSystemFace())
        sections.append(await trustWatchesFace())
        sections += await trustActivityFace()
        try Task.checkCancellation()
        // Inventory walks the data root. Keep its owner's sampled reading until the person asks for a fresh inventory.
        if trust.privacyMap == nil { await trust.refreshPrivacyMap() }
        if let map = trust.privacyMap {
            sections.append(.init(id: "privacy", title: "Privacy map", style: .list, footer: map.dataRoot, rows: [
                .init(id: "privacy.read", title: "Inventory reading", detail: "Refresh reads the inventory again.", at: map.generatedAt)
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
                actions: [.init(id: "create", label: "Back up now")])]
            rows += backups.prefix(8).map { backup in
                .init(id: "backup." + backup.id, title: backup.reason,
                      detail: "Scopes: " + backup.scope.joined(separator: ", ")
                        + ". A safety backup comes first; if it fails, nothing is replaced. Restored work stays stopped; Resume starts it fresh.",
                      at: backup.createdAt, actions: [.init(id: "restore", label: "Restore backup", role: .destructive)])
            }
            sections.append(.init(id: "backups", title: "Backups", style: .list,
                footer: backups.isEmpty ? "No backups yet." : nil, rows: rows))
        } catch {
            sections.append(trustFaceFailure("backups", "Backups", error))
        }
        sections.append(.init(id: "refresh", rows: [.init(id: "trust.refresh", title: "Read Trust again",
            actions: [.init(id: "refresh", label: "Refresh")])]))
        return (.init(title: "Trust", line: "What I may do on my own.", sections: sections), epoch)
    }

    @MainActor private func trustPolicyFace(_ policy: TrustPolicy) async -> [PartFace.Section] {
        let mode = TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy)
        let full = TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(policy)
        let preset = MobileTrustAction.Preset.matching(policy: policy, accessMode: mode)
        var sections: [PartFace.Section] = [.init(id: "access", title: "Access and policy", style: .list, rows: [
            .init(id: "trust.preset", title: "Standing", detail: (preset?.summary ?? "Custom access: " + mode)
                + (full ? ". Full Mac stays on until you change it." : ""),
                control: .choice(MobileTrustAction.Preset.allCases.map { .init(id: $0.rawValue, label: $0.title) },
                    selected: preset?.rawValue, confirm: "Apply the selected standing? If you select Full Mac:\n" + MobileTrustAction.fullMacMessage)),
            // The standing and "What this allows" already say the level, the default before acting and files outside workspaces in words.
            .init(id: "trust.backups", title: "Backup before changes",
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
            full ? .init(id: "trust.chrome_control", title: "Chrome control", detail: "Full Mac allows it; the extension must still be connected.",
                value: "On with Full Mac")
                : chrome.map { trustFaceToggle("trust.chrome_control", "Chrome control", $0.enabled,
                    "I use inactive tabs in my group while you stay signed in. Selecting a tab gives it back to you.") }
                    ?? .init(id: "trust.chrome_control", title: "Chrome control policy is unavailable.", tone: .attention),
            .init(id: "chrome.setup", title: "Chrome extension", detail: "Set up once on this Mac. Allow Mac access if asked, then watch me set it up.",
                value: connection,
                actions: [.init(id: "setup_chrome", label: "Set up Chrome on this Mac")])
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
                    confirm: "Apply the selected Mac access? If you select Full Mac:\n" + MobileTrustAction.fullMacMessage)),
                .init(id: "mac.setup", title: "Set up Mac access",
                    detail: "If Mac access is Off or Watch, selects Assistant, then checks Calendar and Reminders. Otherwise access stays as it is.",
                    actions: [.init(id: "setup_mac", label: "Set up Mac access on this Mac"),
                              .init(id: "check_calendar_reminders", label: "Check Calendar and Reminders on this Mac")]),
                .init(id: "mac.notification", title: "Mac notifications",
                    actions: [.init(id: "send_notification", label: "Send a notification on this Mac")])
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
                        actions: [.init(id: "workbench", label: "Open workbench on this Mac")])
                ]))
        } else {
            sections.append(.init(id: "mac_control", title: "Mac control", rows: [
                .init(id: "mac.unavailable", title: "The saved policy has no Mac control block.", tone: .attention)
            ]))
        }
        return sections
    }

    @MainActor private func trustPeersFace() async -> PartFace.Section {
        do {
            _ = try await contacts.refresh()
            if let error = contacts.loadError { throw PartCallError(code: "contacts_unavailable", message: error) }
            let rows = contacts.doors.compactMap { row -> PartFace.Row? in
                guard let peer = row.contact else { return nil }
                return .init(id: "trust.agent_elevation_" + peer.id, title: row.displayName,
                    detail: row.route + "\n" + row.pillWord + " · " + row.status
                        + (row.elevationFailure.map { "\nYour grant cannot take effect: " + $0.localizedDescription } ?? ""),
                    value: peer.elevationAllowed && row.elevationFailure == nil ? "Authority on" : "Authority off",
                    control: !peer.elevationAllowed && row.elevationFailure != nil ? nil
                        : .toggle(peer.elevationAllowed, confirm: peer.elevationAllowed ? nil : "Let this agent use your existing permissions?"))
            }
            return .init(id: "peers", title: "Connected agents", footer: rows.isEmpty ? "No agents are connected."
                : "Only requests authenticated with each connection's own key use your grant. Delivery is checked separately.", rows: rows)
        } catch { return trustFaceFailure("peers", "Connected agents", error) }
    }

    @MainActor private func trustIntegrationsFace() async -> PartFace.Section {
        do {
            let snapshot = try await macIntegration.refresh(refreshWatches: false).get()
            let rows = MacIntegrationID.all.flatMap { id -> [PartFace.Row] in
                [MacIntegrationPermissionMode.read, .write].compactMap { mode in
                    guard mode == .read ? MacIntegrationID.supportsRead(id) : MacIntegrationID.supportsWrite(id) else { return nil }
                    return trustFaceToggle("integration." + id + "." + mode.rawValue,
                        MacIntegrationID.displayName(for: id) + " · " + mode.rawValue.capitalized, snapshot.allows(id, mode: mode),
                        "Checked before each use. Off fences Full Mac too.")
                }
            }
            return .init(id: "integrations", title: "Apps and features", rows: rows)
        } catch { return trustFaceFailure("integrations", "Apps and features", error) }
    }
}

func trustFaceToggle(_ id: String, _ title: String, _ on: Bool, _ detail: String? = nil, safe: Bool = false) -> PartFace.Row {
    .init(id: id, title: title, detail: detail, control: .toggle(on,
        confirm: on == safe ? "Change what I may do: " + title + "?" : nil))
}

func trustFaceFailure(_ id: String, _ title: String, _ error: Error) -> PartFace.Section {
    .init(id: id, title: title, rows: [.init(id: id + ".unavailable", title: "Could not read " + title.lowercased(),
        detail: error.localizedDescription, tone: .failed)])
}
