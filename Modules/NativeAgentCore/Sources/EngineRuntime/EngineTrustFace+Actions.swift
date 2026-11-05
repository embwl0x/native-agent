import ActivityWatch
import AgentConversations
import AppToolRuntime
import AuthoredCapabilities
import Foundation
import MacControl
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
// Blueprint: | `EngineTrustFace+Actions.swift` | Trust row answers through existing person setters or the agent's Turn's setting.set checks |

extension NativeAgentEngine {
    @MainActor func trustAct(row: String, action: String, value: String?, by actor: PartFaces.Actor) async throws -> String? {
        if row == "trust.refresh", action == "refresh" { await trust.refreshPrivacyMap(); return nil }
        if action == "set" {
            guard let control = pages.snapshots["trust"]?.face?.sections.flatMap(\.rows).first(where: { $0.id == row })?.control,
                  let value, control.on != nil ? ["on", "off"].contains(value) : control.options?.contains(where: { $0.id == value }) == true else {
                throw PartCallError(code: "no_control", message: "That Trust row has no such editable choice. Read Trust again.")
            }
        }
        let executor = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false)
        switch actor {
        case .agent(let turn):
            guard let surface = turn.runtime?.surface, !surface.isEmpty else {
                throw PartCallError(code: "turn_unavailable", message: "This Trust action has no originating turn surface; nothing changed.")
            }
            var input: [String: JSONValue]
            if action == "set", let value {
                let setting: String
                let wanted: JSONValue
                if row.hasPrefix("integration.") {
                    let (id, mode) = try trustIntegrationRow(row)
                    let snapshot = try await MacIntegrationPermissionStore(dataRoot: dataRoot).snapshotChecked()
                    let enabled = try trustFaceBool(value)
                    let read = mode == .read ? enabled : snapshot.allows(id, mode: .read)
                    let write = mode == .write ? enabled : snapshot.allows(id, mode: .write)
                    setting = "trust.mac_integration_" + id
                    wanted = .string(read && write ? "read_write" : read ? "read" : write ? "write" : "off")
                } else {
                    guard row == "trust.preset" || trustFaceBooleanRows.contains(row) || row.hasPrefix("trust.agent_elevation_") else {
                        throw PartCallError(code: "owner_only", message: QuietSettings.ownerOnlyRefusal)
                    }
                    setting = row
                    wanted = row == "trust.preset" ? .string(value) : .bool(try trustFaceBool(value))
                }
                input = ["action": .string("setting.set"), "args": .object(["setting": .string(setting), "value": wanted])]
            } else if row == "activity.wipe", action == "wipe" {
                input = ["action": .string("history.clear")]
            } else if row == "backup.create", action == "create" {
                input = ["action": .string("backup.now")]
            } else if row.hasPrefix("backup."), action == "restore" {
                input = ["action": .string("backup.restore"), "args": .object(["id": .string(String(row.dropFirst("backup.".count)))])]
            } else {
                throw PartCallError(code: "owner_only", message: QuietSettings.ownerOnlyRefusal)
            }
            let result = try await executor.execute(tool: "app", input: input, surface: surface, turn: turn)
            guard result.objectValue?["status"] == .string("ok") || result.objectValue?["ok"] == .bool(true) else {
                throw PartCallError(code: "trust_refused", message: try result.serialize(pretty: false))
            }
            return try result.serialize(pretty: false)
        case .person(let door, _):
            guard door == "mac" || door == "phone" else {
                throw PartCallError(code: "unknown_door", message: "This Trust change has no recognized person door.")
            }
            if action == "set" {
                guard let value else { throw PartCallError(code: "missing_value", message: "Choose a new value; nothing changed.") }
                try await setTrustFace(row: row, value: value, door: door)
                return "Trust choice saved."
            }
            if row == "policy.repair", action == "authorize_safe" {
                trust.publishPolicy(try await SwiftNativeTrustCenter(dataRoot: dataRoot).reauthorizeSafePolicy())
                return "The damaged policy was preserved beside trust/policy.json. Safe is now authorized."
            }
            if row == "watches.mail", action == "check_mail" {
                await macIntegration.checkMail()
                return "Mail check finished; its current result is on Trust."
            }
            guard let host = executor.quietHost() as? any TrustFaceHost else {
                throw PartCallError(code: "unavailable", message: "The Mac's Trust controls are unavailable; nothing was requested.")
            }
            if row.hasPrefix("backup."), action == "restore" {
                let id = String(row.dropFirst("backup.".count))
                guard let backup = try await trust.listBackups().first(where: { $0.id == id }) else {
                    throw PartCallError(code: "backup_unavailable", message: "That backup is no longer in the checked list; nothing changed.")
                }
                return try await host.restoreTrustFaceBackup(backup)
            }
            if row == "backup.create", action == "create" { return try await host.trustFaceMacAction("backup") }
            if row == "activity.wipe", action == "wipe" {
                switch await activityWatch.wipeAll() {
                case .deleted(let rows): return "Deleted \(rows) recorded activity spans. Recording settings are kept."
                case .failed(let message): throw PartCallError(code: "delete_failed", message: message)
                }
            }
            let native = ["chrome.setup": ["setup_chrome"], "system.controls": ["macos_permissions"],
                "mac.workbench": ["workbench"], "activity.exclude": ["exclude_app"],
                "mac.setup": ["setup_mac", "check_calendar_reminders"], "mac.notification": ["send_notification"]]
            guard native[row]?.contains(action) == true else {
                throw PartCallError(code: "no_action", message: "That Trust row has no such action.")
            }
            guard door == "mac" else {
                throw PartCallError(code: "mac_required", message: "Use this control in NativeAgent on the Mac; no macOS permission was requested.")
            }
            return try await host.trustFaceMacAction(action)
        }
    }

    @MainActor private func setTrustFace(row: String, value: String, door: String) async throws {
        let owner = TrustPolicyActions(dataRoot: dataRoot)
        if row.hasPrefix("integration.") {
            let (id, mode) = try trustIntegrationRow(row)
            try await macIntegration.set(id, mode: mode, allowed: trustFaceBool(value),
                surface: door == "phone" ? "phone_face" : "mac_ui",
                provenance: .local(decidedBy: door == "phone" ? "phone_face" : "mac_operator"))
            return
        }
        if row.hasPrefix("trust.agent_elevation_") {
            let id = String(row.dropFirst("trust.agent_elevation_".count))
            guard try AgentPeerStore(dataRoot: dataRoot).setElevation(peerID: id, allowed: trustFaceBool(value)) != nil else {
                throw PartCallError(code: "peer_unavailable", message: "That agent is no longer connected; nothing changed.")
            }
            return
        }
        if row.hasPrefix("activity.") || row == "trust.activity_capture" || row == "trust.activity_model_access" {
            try await setTrustActivityFace(row: row, value: value)
            return
        }
        let saved: TrustPolicy
        switch row {
        case "mac.preset":
            guard let preset = MacIntegrationPreset(rawValue: value) else {
                throw PartCallError(code: "bad_value", message: "Choose a Mac access preset shown on Trust.")
            }
            saved = try await owner.saveMacIntegrationPreset(preset.rawValue)
        case "trust.preset":
            guard let preset = MobileTrustAction.Preset(rawValue: value) else {
                throw PartCallError(code: "bad_value", message: "Choose a standing shown on the Trust page.")
            }
            // FaceView sends a choice only after the control's confirmation; typed person authority comes from the host, never the value.
            saved = try await preset.save(dataRoot: dataRoot, fullMacConfirmed: true)
        case "trust.chrome_control": saved = try await owner.saveChromeControlEnabled(trustFaceBool(value))
        case "trust.pause_everything": saved = try await owner.saveKillSwitchEnabled(trustFaceBool(value))
        case "trust.unattended_work": saved = try await owner.saveEnableAutonomy(trustFaceBool(value))
        case "trust.screen_capture", "trust.image_generation":
            let field = row == "trust.screen_capture" ? "screen_capture" : "image_generation_openai"
            saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["multimodalPolicy": [field: try trustFaceBool(value)]], dataRoot: dataRoot)
        case "chat.read_replies_aloud":
            UserDefaults.standard.set(try trustFaceBool(value), forKey: "voiceAutoRead")
            NotificationCenter.default.post(name: QuietSettings.trustVoicePreferenceDidChange, object: nil)
            return
        default:
            let current = try await trust.load()
            guard var mac = current.macControlPolicy, let field = trustFaceMacFields[row] else {
                throw PartCallError(code: "no_control", message: "This row has no editable Trust control.")
            }
            let baseline = mac
            let on = try trustFaceBool(value)
            switch field {
            case "enabled": mac.enabled = on
            case "notifications": mac.notificationsAllowed = on
            case "spotlight": mac.spotlightAllowed = on
            case "file_ops": mac.fileOpsAllowed = on
            case "accessibility": mac.accessibilityAllowed = on
            case "applescript": mac.applesScriptAllowed = on
            case "jxa": mac.jxaAllowed = on
            case "shell": mac.shellAllowed = on
            case "remote_from_iphone": mac.remoteFromIosAllowed = on
            default: throw PartCallError(code: "no_control", message: "This Mac control field is unavailable.")
            }
            if field != "enabled", on { mac.enabled = true }
            saved = try await owner.saveMacControlPolicy(mac, comparedTo: baseline)
        }
        trust.publishPolicy(saved)
        if row == "trust.chrome_control" { await chrome.reconcilePolicy(context: .init(dataRoot: dataRoot)) }
    }

    @MainActor private func setTrustActivityFace(row: String, value: String) async throws {
        let controller = activityWatch
        let policy = try await controller.checkedPolicy()
        let saved: Bool
        switch row {
        case "trust.activity_capture":
            let enabled = try trustFaceBool(value)
            saved = await controller.apply { $0.captureEnabled = enabled }
        case "trust.activity_model_access":
            let enabled = try trustFaceBool(value)
            saved = await controller.apply { $0.allowModelAccess = enabled }
        case "activity.titles":
            let choice: ActivityPolicy.TitleCapture
            switch value {
            case "apps": choice = .appNamesOnly
            case "windows": choice = .windowTitles
            case "browsers": choice = .windowAndBrowserTitles
            default: throw PartCallError(code: "bad_value", message: "Choose app names, window titles, or window and browser titles.")
            }
            saved = await controller.apply { $0 = choice.applied(to: $0) }
        case "activity.retention":
            guard let days = Int(value), [7, 14, 30, 90].contains(days) else {
                throw PartCallError(code: "bad_value", message: "Choose 7, 14, 30 or 90 days.")
            }
            await controller.setRetentionDays(days)
            guard try await controller.checkedPolicy().retentionDays == days else {
                throw PartCallError(code: "save_failed", message: controller.lastError ?? "The retention choice was not saved.")
            }
            return
        default:
            let id = String(row.dropFirst("activity.excluded.".count))
            guard row.hasPrefix("activity.excluded."), policy.excludedBundleIDs.contains(id),
                  !ActivityPolicy.alwaysExcludedBundleIDs.contains(id), try !trustFaceBool(value) else {
                throw PartCallError(code: "no_control", message: "That exclusion cannot be changed here.")
            }
            await controller.removeExclusion(bundleID: id)
            let checked = try await controller.checkedPolicy()
            guard !checked.excludedBundleIDs.contains(id) else {
                throw PartCallError(code: "save_failed", message: controller.lastError ?? "The exclusion was not removed.")
            }
            return
        }
        guard saved else { throw PartCallError(code: "save_failed", message: controller.lastError ?? "Activity settings were not saved.") }
    }
}

private let trustFaceMacFields = ["trust.mac_control": "enabled", "trust.mac_control_notifications": "notifications",
    "trust.mac_control_spotlight": "spotlight", "trust.mac_control_file_ops": "file_ops", "trust.mac_control_accessibility": "accessibility",
    "trust.mac_control_applescript": "applescript", "trust.mac_control_jxa": "jxa", "trust.mac_control_shell": "shell",
    "trust.mac_control_remote_from_iphone": "remote_from_iphone"]
private let trustFaceBooleanRows: Set<String> = Set(trustFaceMacFields.keys).union([
    "trust.chrome_control", "trust.pause_everything", "trust.unattended_work", "trust.screen_capture", "trust.image_generation",
    "trust.activity_capture", "trust.activity_model_access", "chat.read_replies_aloud"
])

private func trustFaceBool(_ value: String) throws -> Bool {
    switch value {
    case "on": true
    case "off": false
    default: throw PartCallError(code: "bad_value", message: "A Trust switch takes on or off.")
    }
}

private func trustIntegrationRow(_ row: String) throws -> (String, MacIntegrationPermissionMode) {
    let pieces = row.split(separator: ".").map(String.init)
    guard pieces.count == 3, pieces[0] == "integration", MacIntegrationID.all.contains(pieces[1]),
          let mode = MacIntegrationPermissionMode(rawValue: pieces[2]),
          mode == .read ? MacIntegrationID.supportsRead(pieces[1]) : MacIntegrationID.supportsWrite(pieces[1]) else {
        throw PartCallError(code: "bad_row", message: "This row has no supported integration permission.")
    }
    return (pieces[1], mode)
}
