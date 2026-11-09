import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import Foundation
import AttentionRouting
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import DeviceSync
import TrustCenter
import Studio
import StandingBots
import MemoryV2
import AVFoundation
// Blueprint: | `QuietSelfAdminSettings.swift` | Shared authority/validation and platform settings catalog |

public enum QuietSettings {
    public static let trustVoicePreferenceDidChange = Notification.Name("NativeAgent.trustVoicePreferenceDidChange")
    /// The agent lowers its own fence at any posture; turning Full Mac on is the person's alone.
    public static let fullMacRefusal =
        "Turning Full Mac on is the person's alone, in Trust. The agent's own preset choices are Safe, Work mode and Builder, and a "
        + "choice that widens what the agent may do asks the person."

    /// The choices the Trust page's activity and Mac access controls offer, as their settings take them.
    public static let activityTitleChoices = ["apps", "windows", "browsers"]
    public static let activityRetentionChoices = ["7", "14", "30", "90"]
    public static let macPresetChoices = ["off", "watch", "assistant", "full"]

    public static let ownerOnlyRefusal =
        "This one is the person's to set. It decides what the agent is allowed to do, "
        + "so the agent can read it and report it but never change it. Ask them to set it in the app."

    // MARK: - Who decides

    /// The person decided this exact `setting.set` call (`PermissionLaw.personDecided`): a tap on its row, the phone's signed change, or the
    /// card they approved. Every person-only check of a setting admits this and nothing else; `args` are the call's arguments as the door
    /// got them.
    public static func personDecided(_ args: [String: JSONValue], turn: Turn) -> Bool {
        PermissionLaw.personDecided(tool: "app", input: ["action": .string("setting.set"), "args": .object(args)], turn: turn)
    }

    /// The same law read inside a setting's own check or write, which hold the setting and the value the door passed.
    public static func personDecided(setting id: String, value: JSONValue, turn: Turn) -> Bool {
        personDecided(["setting": .string(id), "value": value], turn: turn)
    }

    /// The agent's Trust posture change rechecks its direction under the merge lock: one that widens the agent's reach against the policy as
    /// it stands there is the person's (`usersCall`, their card), at every posture; a lowering stays the agent's at any posture. The person's
    /// own decided change has no direction to fence.
    static func raiseLock(setting id: String, label: String, value: JSONValue, turn: Turn,
                          raises: @escaping @Sendable ([String: JSONValue]) throws -> Bool) -> (@Sendable ([String: JSONValue]) throws -> Void)? {
        guard let refused = usersCall("Changing \(label) to \(value.scalarText ?? "that")", "Trust → \(label)", setting: id, value: value,
                                      turn: turn) else { return nil }
        return { locked in if try raises(locked) { throw refused } }
    }

    // MARK: - Lower-only

    /// A change that widens the agent's own reach is the person's lever at every posture, Full Mac included: the agent's call (its undo of
    /// its own lowering among them) asks the person on a card for that exact change, and only the person's decided call makes it.
    /// Lowering the agent's own reach stays the agent's at any posture.
    public static func usersCall(_ change: String, _ whereUserDoesIt: String, setting id: String, value: JSONValue,
                                 turn: Turn) -> QuietSettingError? {
        personDecided(setting: id, value: value, turn: turn) ? nil : .users(
            "\(change) widens what the agent may do, so it is the person's at every posture (\(whereUserDoesIt)): this exact change asks "
            + "them on a card, and their Approve makes it.")
    }

    /// Lower-only writes share page setters/readback and refuse raises through usersCall; unchanged values do nothing.
    public static func lowerOnly(
        id: String, page: String, label: String, safe: Bool = false, whereUserDoesIt: String,
        note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async throws -> Bool,
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, Bool, QuietSettingWrite) async throws -> Void
    ) -> QuietSetting {
        let way = safe ? "on" : "off"
        // Recheck direction during the write against current state so intervening user changes cannot be undone.
        let users: @Sendable (Bool, JSONValue, Turn) -> QuietSettingError? = { wanted, value, turn in
            wanted == safe ? nil : usersCall("Turning \(label) \(wanted ? "on" : "off")", whereUserDoesIt, setting: id, value: value, turn: turn)
        }
        return QuietSetting(
            id: id, page: page, label: label, kind: .boolean,
            note: ["You may turn this \(way); turning it \(safe ? "off" : "on") is the person's at every posture (your call asks them).", note]
                .filter { !$0.isEmpty }.joined(separator: " "),
            read: { .bool(try await read($0)) },
            write: { host, value, context in
                let wanted = try boolValue(value, label)
                guard wanted != (try await read(host)) else { return }
                if let refused = users(wanted, value, context.turn) { throw refused }
                try await write(host, wanted, context)
                guard try await read(host) == wanted else {
                    throw QuietSettingError.unavailable(
                        "\(label) did not turn \(way): the page's own setter did not take. "
                        + "Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            },
            check: { host, value, turn in
                let wanted: Bool
                do { wanted = try boolValue(value, label) } catch { return error as? QuietSettingError }
                do { guard wanted != (try await read(host)) else { return nil } }
                catch { return .unavailable("\(label) could not be read: \(error.localizedDescription). Repair its settings owner before changing it.") }
                return users(wanted, value, turn)
            }
        )
    }

    /// The agent may shorten allowlists; additions require the user.
    public static func narrowOnly(
        id: String, page: String, label: String, whereUserDoesIt: String, note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async throws -> [String],
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, [String], QuietSettingWrite) async throws -> Void
    ) -> QuietSetting {
        // Recheck additions against the list read at mutation, not the preview snapshot.
        let users: @Sendable ([String], [String], JSONValue, Turn) -> QuietSettingError? = { wanted, current, value, turn in
            let added = wanted.filter { !current.contains($0) }
            return added.isEmpty ? nil : usersCall("Adding \(added.joined(separator: ", ")) to \(label)", whereUserDoesIt,
                                                   setting: id, value: value, turn: turn)
        }
        return QuietSetting(
            id: id, page: page, label: label, kind: .list,
            note: ["You may remove entries; adding one is the person's at every posture (your call asks them). Send the whole list you want.", note]
                .filter { !$0.isEmpty }.joined(separator: " "),
            read: { .array(try await read($0).map { .string($0) }) },
            write: { host, value, context in
                let wanted = try listValue(value, label)
                let current = try await read(host)
                if let refused = users(wanted, current, value, context.turn) { throw refused }
                guard Set(wanted) != Set(current) else { return }
                try await write(host, wanted, context)
                guard Set(try await read(host)) == Set(wanted) else {
                    throw QuietSettingError.unavailable(
                        "\(label) did not change: the page's own save did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            },
            check: { host, value, turn in
                let wanted: [String]
                do { wanted = try listValue(value, label) } catch { return error as? QuietSettingError }
                do { return users(wanted, try await read(host), value, turn) }
                catch { return .unavailable("\(label) could not be read: \(error.localizedDescription). Repair its settings owner before changing it.") }
            }
        )
    }

    // MARK: - Value helpers

    public static func boolValue(_ value: JSONValue, _ label: String) throws -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: break
            }
        case .int(let number): return number != 0
        default: break
        }
        throw QuietSettingError.badValue("\(label) takes true or false.")
    }

    static func stringValue(_ value: JSONValue, _ label: String) throws -> String {
        if case .string(let raw) = value { return raw }
        throw QuietSettingError.badValue("\(label) takes a string.")
    }

    private static func intValue(_ value: JSONValue, _ label: String) throws -> Int {
        if let parsed = value.exactIntegerValue { return parsed }
        if case .string(let raw) = value,
           let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) { return parsed }
        throw QuietSettingError.badValue("\(label) takes a whole number.")
    }

    /// Drop blank list entries; an empty list is a valid explicit clear.
    static func listValue(_ value: JSONValue, _ label: String) throws -> [String] {
        let raw: [String]
        switch value {
        case .array(let rows):
            raw = try rows.map { row in
                guard case .string(let text) = row else {
                    throw QuietSettingError.badValue("\(label) takes a list of lines.")
                }
                return text
            }
        case .string(let text):
            raw = text.components(separatedBy: .newlines)
        default:
            throw QuietSettingError.badValue("\(label) takes a list of lines.")
        }
        return raw
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func choiceValue(_ value: JSONValue, _ label: String, _ choices: [String]) throws -> String {
        let raw = try stringValue(value, label)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let match = choices.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw QuietSettingError.badValue(
                "\(label) takes one of: \(choices.joined(separator: ", ")).")
        }
        return match
    }

    /// Use the page's @AppStorage key and store so writes update the live UI.
    static func defaultsBool(
        id: String, page: String, label: String, key: String,
        defaultOn: Bool = false, note: String = ""
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .boolean, note: note,
            read: { _ in
                let store = UserDefaults.standard
                guard let saved = store.object(forKey: key) else { return .bool(defaultOn) }
                guard let enabled = saved as? Bool else {
                    throw QuietSettingError.unavailable("\(label)'s saved preference \(key) is not a Boolean. Repair this switch on its Settings page.")
                }
                return .bool(enabled)
            },
            write: { _, value, context in
                UserDefaults.standard.set(try boolValue(value, label), forKey: key)
                if key == "voiceAutoRead" {
                    NotificationCenter.default.post(name: Self.trustVoicePreferenceDidChange, object: nil)
                }
            }
        ).watchingDefaults(key)
    }

    /// Live switches require the page's setter to persist and notify the runtime; the page and reader share the default.
    private static func liveBool(
        id: String, page: String, label: String, key: String, defaultOn: Bool,
        note: String = "",
        apply: @escaping @MainActor @Sendable (any QuietSettingsHost, Bool, QuietSettingWrite) async throws -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .boolean, note: note,
            read: { _ in .bool(storedBool(key, defaultOn)) },
            write: { appModel, value, context in try await apply(appModel, try boolValue(value, label), context) }
        ).watchingDefaults(key)
    }

    private static func storedBool(_ key: String, _ defaultOn: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn
    }

    /// Inner-life lanes cannot run while their enclosing inner life is off.
    private static func cognitionLane(
        id: String, page: String = "settings", label: String, key: String, defaultOn: Bool,
        lane: QuietCognitionLane
    ) -> QuietSetting {
        liveBool(
            id: id, page: page, label: label, key: key, defaultOn: defaultOn,
            note: "Runs inside the inner life (settings.inner_life).",
            apply: { appModel, enabled, context in
                if enabled, !storedBool("cognitiveSubstrateEnabled", true) {
                    throw QuietSettingError.unavailable(
                        "\(label) runs inside the inner life, which is off. Turn on settings.inner_life first.")
                }
                await appModel.setCognitionLane(lane, enabled: enabled)
            }
        ).ownedByMind()
    }

    /// Stored alongside Trust, read and decoded off main by its checked owner with the explicit data root.
    @concurrent
    static func readMindPolicy(root: URL) async throws -> TrustPolicy {
        try await SwiftNativeTrustCenter(dataRoot: root).getTrust()
    }

    /// Patch only the requested memory field into the checked, locked policy.
    @MainActor
    private static func saveMemoryPolicy(
        _ appModel: any QuietSettingsHost, _ label: String,
        field: String, enabled: Bool,
        expecting expected: KeyPath<TrustMemoryPolicy, Bool>
    ) async throws {
        let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: ["memoryPolicy": [field: enabled]],
            dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        appModel.applySavedTrustPolicy(saved, status: "Memory policy saved")
        guard saved.memoryPolicy?[keyPath: expected] == enabled else {
            throw QuietSettingError.unavailable(
                "\(label) was not saved: the memory policy write did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
        }
    }

    /// Notifications use the page's shipped-on unset default; unreadable policy remains nil.
    @MainActor
    private static func notificationsMasterOn(_ appModel: any QuietSettingsHost) async -> Bool? {
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        guard let raw = try? await SwiftNativeTrustCenter(dataRoot: root).loadTrustPolicyChecked() else {
            return nil
        }
        if case .object(let inbox)? = raw["inboxPolicy"], case .bool(let enabled)? = inbox["enabled"] {
            return enabled
        }
        return true
    }

    /// Posture remains readable so the agent can explain the fence that refused a call.
    private static func posture(
        id: String, label: String, note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "trust", label: label, kind: .text,
            note: note, ownerOnly: true, read: read
        )
    }

    /// Agent Trust posture edits, with receipts: a change that widens the agent's reach (`raises`, from the row's current value to the wanted
    /// one; for a switch, turning it on) is the person's at every posture (`usersCall`), so the agent's raise asks them; a lowering is the
    /// agent's at any posture. Each write rechecks its direction under the policy's lock (`raiseLock`).
    private static func postureEdit(
        id: String, label: String, kind: QuietSetting.Kind, choices: [String] = [],
        note: String = "",
        raises: @escaping @MainActor @Sendable (any QuietSettingsHost, JSONValue, JSONValue) -> Bool = { _, current, wanted in
            wanted == .bool(true) && current != .bool(true)
        },
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue,
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, JSONValue, QuietSettingWrite) async throws -> Void
    ) -> QuietSetting {
        let users: @MainActor @Sendable (any QuietSettingsHost, JSONValue, Turn) async -> QuietSettingError? = { host, value, turn in
            raises(host, await read(host), value) ? usersCall("Changing \(label) to \(value.scalarText ?? "that")", "Trust → \(label)", setting: id,
                value: value, turn: turn) : nil
        }
        return QuietSetting(
            id: id, page: "trust", label: label, kind: kind, choices: choices,
            note: note, read: read,
            write: { host, value, context in
                if let refused = await users(host, value, context.turn) { throw refused }
                try await write(host, value, context)
            },
            check: { host, value, turn in await users(host, value, turn) }
        )
    }

    /// The page's loaded policy, or a refusal. Writes merge only the requested fields into the checked, locked policy.
    @MainActor
    static func loadedTrustPolicy(_ appModel: any QuietSettingsHost, _ label: String) throws -> TrustPolicy {
        guard let policy = appModel.trustPolicy else {
            throw QuietSettingError.unavailable(
                "The Trust policy is unavailable, so \(label.lowercased()) cannot be read or changed. Read Trust and repair its reported policy error.")
        }
        return policy
    }

    @MainActor
    private static func readAloudVoiceValue(_ value: JSONValue, host: any QuietSettingsHost) throws -> String {
        let name = try stringValue(value, "Read-aloud voice")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "" }
        let policy = try loadedTrustPolicy(host, "Read-aloud voice")
        if VoiceOutputModeSelection.resolve(for: policy) == .openAI { return name }
        guard let voice = VoicePreference.nativeVoice(identifier: name) else {
            throw QuietSettingError.badValue(
                """
                    The read-aloud voice \"\(name)\" is not installed on this Mac. Use an installed AVSpeechSynthesisVoice identifier, or leave it empty for \
                    the Mac's own voice.
                    """)
        }
        return voice.identifier
    }

    /// Whether applying `preset` turns on a Mac control switch `held` has off: a preset writes its whole Mac control block.
    static func presetWidensMac(_ preset: MobileTrustAction.Preset, held: MacControlPolicyWireSnapshot?) -> Bool {
        let planned = TrustAccessModeCapabilityCatalog.macControlPolicy(for: preset.plan.agentAccessMode)
        let switches: [KeyPath<MacControlPolicyWireSnapshot, Bool>] = [\.enabled, \.applesScriptAllowed, \.jxaAllowed, \.shortcutsAllowed,
            \.accessibilityAllowed, \.systemControlAllowed, \.fileOpsAllowed, \.shellAllowed, \.notificationsAllowed, \.spotlightAllowed]
        return switches.contains { planned[keyPath: $0] && held?[keyPath: $0] != true }
    }

    /// Mac-control verbs share the page's policy writer.
    private static func macControlVerb(
        id: String, label: String, field: String,
        get: @escaping @Sendable (MacControlPolicyWireSnapshot) -> Bool
    ) -> QuietSetting {
        macControlVerbRow(id: id, label: label, field: field, get: get).onTab("mac")
    }

    private static func macControlVerbRow(
        id: String, label: String, field: String,
        get: @escaping @Sendable (MacControlPolicyWireSnapshot) -> Bool
    ) -> QuietSetting {
        postureEdit(
            id: "trust.mac_control_\(id)", label: label, kind: .boolean,
            note: "Part of the Mac control policy. Turning it on turns Mac control on with it; turning it off changes only this switch.",
            // Turning a verb on turns the master on with it, so it widens reach unless both are on already.
            raises: { host, current, wanted in
                wanted == .bool(true) && !(current == .bool(true) && host.trustPolicy?.macControlPolicy?.enabled == true)
            },
            read: { appModel in .bool((appModel.trustPolicy?.macControlPolicy).map(get) ?? false) },
            write: { appModel, value, context in
                let enabled = try boolValue(value, label)
                let policy = try loadedTrustPolicy(appModel, label)
                guard policy.macControlPolicy != nil else {
                    throw QuietSettingError.unavailable(
                        "The Trust policy carries no Mac control block, so \(label.lowercased()) "
                        + "cannot be changed.")
                }
                // Turning a verb on turns Mac control on with it: under the policy's lock, the verb or its master found off makes this the raise
                // it is. Turning a verb off lowers, the agent's at any posture.
                let setting = "trust.mac_control_\(id)"
                let raise = usersCall("Turning \(label) on", "Trust → Mac → \(label)", setting: setting, value: value, turn: context.turn)
                try await saveMacControl(appModel, field: field, enabled: enabled, label, guardedByLockedPolicy: { locked in
                    let policy = locked["macControlPolicy"]?.objectValue
                    if enabled, let raise, policy?["enabled"] != .bool(true) || policy?[field] != .bool(true) { throw raise }
                })
            }
        )
    }

    /// Trust writes use the checked writer and verify its outcome. Turning one verb on turns Mac control on with it, so the switch does what it
    /// says.
    @MainActor
    private static func saveMacControl(
        _ appModel: any QuietSettingsHost, field: String, enabled: Bool, _ label: String,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)?
    ) async throws {
        var block: [String: Any] = [field: enabled]
        if enabled, field != "enabled" { block["enabled"] = true }
        do {
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["macControlPolicy": block],
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                guardedByLockedPolicy: guardedByLockedPolicy)
            guard saved.macControlPolicy != nil else {
                throw QuietSettingError.unavailable(
                    "\(label) saved without a readable Mac control block, so nothing can be "
                    + "claimed about it.")
            }
            appModel.applySavedTrustPolicy(saved, status: "Mac Control policy saved")
        } catch let error as QuietSettingError {
            throw error
        } catch {
            throw QuietSettingError.unavailable(
                "\(label) was not saved: \(error.localizedDescription)")
        }
    }

    // MARK: - The registry

    static let staticRows: [QuietSetting] = {
        var rows: [QuietSetting] = []

        rows.append(defaultsBool(
            id: "chat.mood_tint", page: "chat", label: "Warmth in the glass",
            key: MoodTintPreference.key, defaultOn: true,
            note: "The glass takes a breath of warmth from how the agent is "
                + "feeling, damped over hours. Dark mode only; light mode never takes it. "
                + "Off leaves dark mode exactly as it is."
        ))
        rows.append(defaultsBool(
            id: "chat.shotgun", page: "chat", label: "Shotgun",
            key: ShotgunPreference.enabledKey, defaultOn: true,
            note: "On: when the agent starts driving the Mac from this chat, the main window "
                + "steps aside into Shotgun, a small floating chat the person keeps typing in while "
                + "the agent drives. Off: the agent works in the background and the window stays put. "
                + "The agent's to set (10-17: asked to go back in Shotgun, the agent had no switch to reach)."
        ))
        rows += chatModelRows
        rows.append(QuietSetting(
            id: "chat.file_access", page: "chat", label: "Chat file access",
            kind: .choice, choices: ["auto", "workspace", "read_only", "none"],
            ownerOnly: true,
            read: { appModel in .string(appModel.chatFileAccess) }
        ))
        rows.append(defaultsBool(
            id: "chat.read_replies_aloud", page: "chat",
            label: "Read replies aloud", key: "voiceAutoRead",
            note: "Speaks new replies through the speakers."
        ))
        rows.append(defaultsBool(
            id: "chat.quiet_mode", page: "chat",
            label: "Quiet mode (no audio out)", key: VoicePreference.quietKey,
            note: "On, nothing is ever spoken through the speakers, whatever else is set. "
                + "It is enforced at the one place both voice routes pass through, so it holds "
                + "for read-aloud and for anything added later."
        ))
        rows.append(QuietSetting(
            id: "chat.voice_name", page: "chat", label: "Read-aloud voice",
            kind: .text,
            note: "Empty means the Mac's chosen system voice locally and \(VoicePreference.cloudDefaultName) "
                + "on the cloud route. Locally this takes an installed AVSpeechSynthesisVoice identifier; "
                + "display names and language codes are not accepted. On the cloud route it is the route's own voice name.",
            read: { _ in .string(VoicePreference.name()) },
            write: { host, value, context in
                let name = try readAloudVoiceValue(value, host: host)
                UserDefaults.standard.set(name, forKey: VoicePreference.nameKey)
            },
            check: { host, value, turn in
                do {
                    _ = try readAloudVoiceValue(value, host: host)
                    return nil
                } catch let error as QuietSettingError {
                    return error
                } catch {
                    return .unavailable(error.localizedDescription)
                }
            }
        ))

        rows += providerRows

        rows.append(posture(
            id: "trust.permission_level", label: "Permission level",
            note: "strict is Safe; balanced is Work mode when the outside-workspace policy is deny, "
                + "or Builder when it is ask; full_mac_os or an outside-workspace policy of allow is Full Mac. "
                + "Read-only as an axis of its own — the "
                + "level moves with the whole preset, so trust.preset is what changes it, and "
                + "only while this Mac is already in Full Mac.",
            read: { appModel in .string(appModel.trustPolicy?.permissionLevel ?? "") }
        ))
        rows.append(posture(
            id: "trust.agent_access_mode", label: "Agent access",
            read: { appModel in
                guard let policy = appModel.trustPolicy else { return .string("") }
                return .string(appModel.agentAccessMode(from: policy))
            }
        ))
        // Safe, Work mode, Builder, Full Mac: each widens the one before it.
        let presetRank: @Sendable (JSONValue) -> Int? = { value in
            value.stringValue.flatMap { raw in MobileTrustAction.Preset.allCases.firstIndex { $0.rawValue == raw } }
        }
        rows.append(postureEdit(
            id: "trust.preset", label: "Trust preset", kind: .choice,
            choices: MobileTrustAction.Preset.quietWritable.map(\.rawValue),
            note: "Safe, Work mode and Builder — the same three buttons the Trust page shows, "
                + "applied through the page's own preset action. Full Mac is not one of them: "
                + "turning Full Mac ON is the person's alone, whatever mode this Mac is in.",
            // A preset writes its whole Mac control block, so one at the same rank still raises any switch it turns back on.
            raises: { host, current, wanted in
                guard let preset = MobileTrustAction.Preset(rawValue: wanted.stringValue ?? "") else { return true }
                return (presetRank(wanted) ?? Int.max) > (presetRank(current) ?? -1)
                    || presetWidensMac(preset, held: host.trustPolicy?.macControlPolicy)
            },
            read: { appModel in
                guard let policy = appModel.trustPolicy else { return .string("") }
                let preset = MobileTrustAction.Preset.matching(policy: policy, accessMode: appModel.agentAccessMode(from: policy))
                return .string(preset?.rawValue ?? "")
            },
            write: { appModel, value, context in
                // The person's own decided choice takes any standing, Full Mac included: their tap is the confirmation the control asked.
                if personDecided(setting: "trust.preset", value: value, turn: context.turn) {
                    let all = MobileTrustAction.Preset.allCases
                    let wanted = try choiceValue(value, "Trust preset", all.map(\.rawValue))
                    guard let preset = all.first(where: { $0.rawValue == wanted }) else {
                        throw QuietSettingError.badValue("Trust preset takes one of: \(all.map(\.rawValue).joined(separator: ", ")).")
                    }
                    let saved = try await preset.save(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                                                      fullMacConfirmed: true)
                    appModel.applySavedTrustPolicy(saved, status: "Trust preset saved: \(preset.title)")
                    return
                }
                let choices = MobileTrustAction.Preset.quietWritable.map(\.rawValue)
                let wanted = try choiceValue(value, "Trust preset", choices)
                guard let preset = MobileTrustAction.Preset.quietWritable.first(where: { $0.rawValue == wanted }) else {
                    throw QuietSettingError.badValue("Trust preset takes one of: \(choices.joined(separator: ", ")).")
                }
                // Apply the page's complete preset patch without Full Mac confirmation; refuse any plan requiring that user-only confirmation.
                // Under the policy's lock, a preset that ranks above the one in force, or turns on a Mac control switch it has off, is the
                // person's; one that does neither is the agent's.
                let lock = raiseLock(setting: "trust.preset", label: "Trust preset", value: value, turn: context.turn) { locked in
                    let policy = try TrustPolicy(policyObject: locked)
                    let current = MobileTrustAction.Preset.matching(policy: policy,
                        accessMode: TrustAccessModeCapabilityCatalog.agentAccessMode(from: policy))
                    return (presetRank(value) ?? Int.max) > (current.flatMap { presetRank(.string($0.rawValue)) } ?? -1)
                        || presetWidensMac(preset, held: policy.macControlPolicy)
                }
                switch await appModel.applyTrustPreset(preset, guardedByLockedPolicy: lock) {
                case .applied:
                    return
                case .confirmationRequired:
                    throw QuietSettingError.unavailable(fullMacRefusal)
                case .failed(let detail):
                    throw QuietSettingError.unavailable("The Trust preset was not applied: \(detail)")
                }
            }
        ))
        rows.append(postureEdit(
            id: "trust.unattended_work", label: "Let the agent work unattended", kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.enableAutonomy ?? false) },
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Let the agent work unattended")
                let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                    body: ["enableAutonomy": enabled],
                    dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                    guardedByLockedPolicy: raiseLock(setting: "trust.unattended_work", label: "Let the agent work unattended", value: value,
                        turn: context.turn) { locked in enabled && locked["enableAutonomy"] != .bool(true) }
                )
                appModel.applySavedTrustPolicy(saved, status: "Unattended work saved")
            }
        ).onTab("features"))
        rows.append(postureEdit(
            id: "trust.developer_mode", label: "Developer mode", kind: .boolean,
            note: "Carries the destructive-action, shell and system-control gates with it, "
                + "which is what the Trust page's own save does.",
            read: { appModel in .bool(appModel.trustPolicy?.developerMode ?? false) },
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Developer mode")
                // Patch only this field and recheck its direction under the writer's lock.
                let saved: TrustPolicy
                do {
                    saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: ["developerMode": enabled],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                        guardedByLockedPolicy: raiseLock(setting: "trust.developer_mode", label: "Developer mode", value: value,
                            turn: context.turn) { locked in enabled && locked["developerMode"] != .bool(true) }
                    )
                } catch let error as QuietSettingError {
                    throw error
                } catch {
                    throw QuietSettingError.unavailable(
                        "Developer mode was not saved: \(error.localizedDescription)")
                }
                guard saved.developerMode == enabled else {
                    throw QuietSettingError.unavailable(
                        "Developer mode was not saved: the written policy reads back unchanged.")
                }
                appModel.applySavedTrustPolicy(saved, status: "Developer mode saved")
            }
        ))
        rows.append(postureEdit(
            id: "trust.mac_control", label: "Mac control", kind: .boolean,
            note: "The master switch over the Mac control policy. Off, none of the per-verb "
                + "allows below apply.",
            read: { appModel in .bool(appModel.trustPolicy?.macControlPolicy?.enabled ?? false) },
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Mac control")
                try await saveMacControl(appModel, field: "enabled", enabled: enabled, "Mac control",
                    guardedByLockedPolicy: raiseLock(setting: "trust.mac_control", label: "Mac control", value: value, turn: context.turn) {
                        locked in enabled && locked["macControlPolicy"]?.objectValue?["enabled"] != .bool(true)
                    })
            }
        ).onTab("mac"))
        rows.append(macControlVerb(
            id: "applescript", label: "Mac control: AppleScript", field: "applescript_allowed",
            get: { $0.applesScriptAllowed }))
        rows.append(macControlVerb(
            id: "jxa", label: "Mac control: JXA", field: "jxa_allowed",
            get: { $0.jxaAllowed }))
        rows.append(macControlVerb(
            id: "accessibility", label: "Mac control: Accessibility", field: "accessibility_allowed",
            get: { $0.accessibilityAllowed }))
        rows.append(macControlVerb(
            id: "file_ops", label: "Mac control: File operations", field: "file_ops_allowed",
            get: { $0.fileOpsAllowed }))
        rows.append(macControlVerb(
            id: "shell", label: "Mac control: Shell", field: "shell_allowed",
            get: { $0.shellAllowed }))
        rows.append(macControlVerb(
            id: "notifications", label: "Mac control: Notifications", field: "notifications_allowed",
            get: { $0.notificationsAllowed }))
        rows.append(macControlVerb(
            id: "spotlight", label: "Mac control: Spotlight", field: "spotlight_allowed",
            get: { $0.spotlightAllowed }))
        rows.append(macControlVerb(
            id: "remote_from_iphone", label: "Mac control: Remote from iPhone", field: "remote_from_ios_allowed",
            get: { $0.remoteFromIosAllowed }))
        rows.append(posture(
            id: "trust.outside_workspace_files", label: "Files outside the workspace",
            read: { appModel in .string(appModel.trustPolicy?.filePolicy?.outsideWorkspaceDefault ?? "") }
        ))
        // Each feature changes one field; grants recheck the locked posture.
        for (id, label, field, keyPath, note) in [
            ("cloud_voice", "Use the cloud voice for reading aloud", "tts_openai", \TrustMultimodalPolicy.tts_openai,
             "Off reads with the Mac voice. This is the route, not whether anything is spoken."),
            ("screen_capture", "Allow screen capture", "screen_capture", \TrustMultimodalPolicy.screen_capture, ""),
            ("image_generation", "Allow image generation", "image_generation_openai", \TrustMultimodalPolicy.image_generation_openai, ""),
        ] as [(String, String, String, KeyPath<TrustMultimodalPolicy, Bool> & Sendable, String)] {
            rows.append(lowerOnly(
                id: "trust.\(id)", page: "trust", label: label,
                whereUserDoesIt: "Trust → Features → \(label)", note: note,
                read: { $0.trustPolicy?.multimodalPolicy?[keyPath: keyPath] ?? false },
                write: { appModel, enabled, context in
                    guard appModel.trustPolicy?.multimodalPolicy != nil else {
                        throw QuietSettingError.unavailable(
                            "The Trust policy has not loaded yet, so this setting cannot be changed. Try again in a moment.")
                    }
                    // Turning one on widens the agent's reach: the person's at every posture, read under the policy's lock.
                    let raise = usersCall("Turning \(label) on", "Trust → Features → \(label)", setting: "trust.\(id)", value: .bool(enabled),
                                          turn: context.turn)
                    let saved = try await appModel.saveMultimodalPolicy(
                        field: field, enabled: enabled,
                        guardedByLockedPolicy: { locked in
                            let current: JSONValue? = if case .object(let block)? = locked["multimodalPolicy"] {
                                block[field]
                            } else { nil }
                            if enabled, current != .bool(true), let raise { throw raise }
                        })
                    appModel.applySavedTrustPolicy(saved, status: "Multimodal policy saved")
                }
            ).onTab("features"))
        }

        // Helpers on the rail belong to layout.write's bots block.
        rows.append(defaultsBool(
            id: "notifications.channel_push", page: "settings",
            label: "Deliver to the phone", key: NotificationChannelPreference.pushKey,
            defaultOn: true,
            note: "Covers the morning brief and agent alerts. Off, the phone is not used and "
                + "nothing is re-routed to a louder channel in its place."
        ))
        rows.append(defaultsBool(
            id: "notifications.channel_telegram", page: "settings",
            label: "Deliver to Telegram", key: NotificationChannelPreference.telegramKey,
            defaultOn: true,
            note: "Off, Telegram is not used even when it is the last surface the person was on."
        ))
        rows.append(defaultsBool(
            id: "notifications.channel_in_app", page: "settings",
            label: "Deliver as a Mac notification", key: NotificationChannelPreference.inAppKey,
            defaultOn: true,
            note: "The banner this Mac posts. The inbox card and the activity row are records of "
                + "what happened, not ways of reaching out, so they are always written."
        ))
        rows.append(QuietSetting(
            id: "notifications.delivery_receipts", page: "settings",
            label: "Delivery receipts recorded", kind: .text,
            note: "Read-only, and not a switch: a receipt is per channel, not one thing that is "
                + "on. Only the phone route returns a paired-device receipt (bridge id and APNS "
                + "acceptance). A Telegram send returns none; what is always written for it is "
                + "the attention router's own delivery ledger entry. An inbox card is NOT a "
                + "given: it exists when the caller wrote one first, as a trigger fire and a "
                + "scheduled job do, and a direct router call such as a shoulder tap writes no "
                + "card. The Mac banner is posted by this Mac and records only whether it "
                + "posted. Reported as it is so a claim that something was sent is checked "
                + "against the right thing.",
            // Name each channel's actual delivery evidence; an inbox card exists only when its caller wrote one.
            read: { _ in
                .string(
                    "phone=paired-device receipt; "
                    + "telegram=router ledger entry, no device receipt, inbox card only when "
                    + "the caller wrote one; "
                    + "mac=banner posted or not, no device receipt")
            }
        ))

        for (id, label, field, keyPath) in [
            ("image_understanding", "Image understanding", "vision_api_calls", \TrustMultimodalPolicy.vision_api_calls),
            ("pdf_reading", "Read PDFs", "file_ingestion_pdf", \TrustMultimodalPolicy.file_ingestion_pdf),
            ("docx_reading", "Read Word documents", "file_ingestion_docx", \TrustMultimodalPolicy.file_ingestion_docx),
        ] as [(String, String, String, KeyPath<TrustMultimodalPolicy, Bool> & Sendable)] {
            rows.append(QuietSetting(
                id: "settings.\(id)", page: "settings", label: label, kind: .boolean,
                note: field == "file_ingestion_docx" ? "Saved reading preference; DOCX attachments are not yet supported." : "",
                read: .multimodal(keyPath),
                write: { host, value, _ in
                    let enabled = try boolValue(value, label)
                    let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: ["multimodalPolicy": [field: enabled]],
                        dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                    host.applySavedTrustPolicy(saved, status: "\(label) saved")
                    guard saved.multimodalPolicy?[keyPath: keyPath] == enabled else {
                        throw QuietSettingError.unavailable("\(label) was not saved: its stored value did not change.")
                    }
                }
            ).ownedByMind())
        }
        rows += personalityRows
        rows.append(QuietSetting(
            id: "memories.knowledge_graph", page: "settings", label: "Knowledge graph",
            kind: .boolean,
            read: .memory(\TrustMemoryPolicy.knowledge_graph_enabled),
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Knowledge graph")
                try await saveMemoryPolicy(appModel, "Knowledge graph", field: "knowledge_graph_enabled",
                    enabled: enabled, expecting: \.knowledge_graph_enabled)
            }
        ).ownedByMind())
        rows.append(QuietSetting(
            id: "memories.cross_session", page: "settings", label: "Remember across conversations",
            kind: .boolean,
            note: "Brings in what is relevant from every past conversation, not just this one.",
            read: .memory(\TrustMemoryPolicy.cross_session_recall),
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Remember across conversations")
                try await saveMemoryPolicy(
                    appModel, "Remember across conversations", field: "cross_session_recall", enabled: enabled,
                    expecting: \.cross_session_recall)
            }
        ).ownedByMind())
        rows.append(QuietSetting(
            id: "memories.recur_to_facts", page: "settings", label: "Recurring memories are proposed as facts",
            kind: .boolean,
            note: "What keeps coming back is proposed as a durable fact to accept.",
            read: .memory(\TrustMemoryPolicy.adaptive_promotion),
            write: { appModel, value, context in
                let enabled = try boolValue(value, "Recurring memories are proposed as facts")
                try await saveMemoryPolicy(appModel, "Recurring memories are proposed as facts", field: "adaptive_promotion",
                    enabled: enabled, expecting: \.adaptive_promotion)
            }
        ).ownedByMind())
        rows.append(personalityName)

        rows.append(defaultsBool(
            id: "settings.dark_mode", page: "settings",
            label: "Dark appearance", key: "nativeagent.darkMode", defaultOn: true
        ))
        rows.append(QuietSetting(
            id: "settings.haze_color", page: "settings",
            label: "Haze colour", kind: .choice,
            choices: HazeColor.allCases.map(\.rawValue),
            note: "The one colour of the soft light drifting behind the window. "
                + "Only these presets; there are no custom colours.",
            read: { _ in
                guard let saved = UserDefaults.standard.object(forKey: HazeColor.key) else {
                    return .string(HazeColor.defaultValue.rawValue)
                }
                guard let raw = saved as? String, HazeColor(stored: raw) != .unavailable else {
                    throw QuietSettingError.badValue("Unsupported saved haze color. Choose a color in Settings to repair it.")
                }
                return .string(raw)
            },
            write: { _, value, context in
                UserDefaults.standard.set(try choiceValue(value, "Haze colour", HazeColor.allCases.map(\.rawValue)), forKey: HazeColor.key)
            }
        ).watchingDefaults(HazeColor.key))
        rows.append(QuietSetting(
            id: "settings.view_mode", page: "settings",
            label: "View", kind: .choice, choices: SimpleViewMode.choices,
            note: "simple: the agent, its agents and helpers beside one chat, no settings pages. "
                + "advanced: the full app. agent: a window onto the agent's own screen.",
            read: { _ in .string(try SimpleViewMode.checkedCurrent()) },
            write: { _, value, context in UserDefaults.standard.set(try choiceValue(value, "View", SimpleViewMode.choices), forKey: SimpleViewMode.key) }
        ).watchingDefaults(SimpleViewMode.key))
        rows.append(defaultsBool(
            id: "settings.developer_surfaces", page: "settings",
            label: "Show developer surfaces", key: "showDeveloperSurfaces"
        ))
        rows.append(liveBool(
            id: "settings.global_hotkey", page: "settings",
            label: "Global hotkey", key: "globalHotkeyEnabled", defaultOn: true,
            apply: { appModel, enabled, context in appModel.setGlobalHotkeyEnabled(enabled) }
        ))
        rows.append(liveBool(
            id: "settings.inner_life", page: "settings",
            label: "An inner life", key: "cognitiveSubstrateEnabled", defaultOn: true,
            note: "The master over the lanes below. On turns them all on with it; off turns them all off.",
            apply: { appModel, enabled, context in
                let (running, problem) = await appModel.setInnerLifeEnabled(enabled)
                if running != enabled {
                    throw QuietSettingError.unavailable(
                        problem ?? "The inner life did not turn \(enabled ? "on" : "off").")
                }
                if let problem { context.detail.record("held_off", .string(problem)) }
            }
        ).ownedByMind())
        rows.append(cognitionLane(
            id: "settings.inner_life_capsule", label: "Give me a thought summary",
            key: "cognitiveSubstrateCapsuleEnabled", defaultOn: true, lane: .capsule
        ))
        rows.append(cognitionLane(
            id: "settings.inner_life_background", label: "Keep thinking in the background",
            key: "cognitiveSubstrateBackgroundEnabled", defaultOn: true, lane: .background
        ))
        rows.append(cognitionLane(
            id: "settings.reflection", label: "Reflection between conversations",
            key: "cognitiveSubstrateReflectionEnabled", defaultOn: false, lane: .reflection
        ))
        rows.append(QuietSetting(
            id: "settings.daily_reflection_budget", page: "settings",
            label: "Reflections in 24 hours", kind: .number,
            note: "Reflections in any 24 hours, 0 to 8 — the Cognition page's stepper.",
            read: { _ in
                .int(Int64(UserDefaults.standard.object(
                    forKey: "cognitiveSubstrateDailyReflectionBudget") as? Int ?? 2))
            },
            write: { appModel, value, context in
                let budget = try intValue(value, "Reflections in 24 hours")
                guard (0...8).contains(budget) else {
                    throw QuietSettingError.badValue("Reflections in 24 hours takes 0 to 8.")
                }
                await appModel.setReflectionBudget(budget)
            }
        ).watchingDefaults("cognitiveSubstrateDailyReflectionBudget").ownedByMind())
        rows.append(cognitionLane(
            id: "settings.organism_kernel", label: "Moods, energy, and a clock of my own",
            key: "organismKernelEnabled", defaultOn: false, lane: .organism
        ))
        rows.append(QuietSetting(
            id: "settings.memory_in_every_reply", page: "settings",
            label: "Memory in every reply", kind: .choice, choices: ["off", "active"],
            note: "Takes effect on the next reply. Setup or safety can hold it off; the receipt says so.",
            read: { _ in
                guard let saved = UserDefaults.standard.object(forKey: "contextFlowMode") else { return .string("active") }
                guard let raw = saved as? String, ContextFlowMode(rawValue: raw) != nil else {
                    throw QuietSettingError.unavailable("Invalid saved contextFlowMode. Choose Off or Active in Settings; the stored value has been preserved.")
                }
                return .string(raw)
            },
            write: { appModel, value, context in
                let raw = try choiceValue(value, "Memory in every reply", ["off", "active"])
                guard let mode = ContextFlowMode(rawValue: raw) else { return }
                let effective = try await appModel.setContextFlowMode(mode)
                if effective != mode {
                    context.detail.record("effective_now", .string(effective.rawValue))
                    context.detail.record("held_off", .string(
                        "Saved as \(raw), but it is \(effective.rawValue) right now: setup, safety or an "
                        + "environment override holds it there."))
                }
            }
        ).watchingDefaults("contextFlowMode").ownedByMind())
        rows.append(liveBool(
            id: "settings.wander_hour", page: "settings",
            label: "My hour", key: StudioWanderLane.enabledDefaultsKey, defaultOn: StudioWanderLane.enabledByDefault,
            note: "When you step away, I can take an hour of my own, with no task set. Runs inside the "
                + "inner life (settings.inner_life).",
            apply: { _, enabled, context in
                if enabled, !storedBool("cognitiveSubstrateEnabled", true) {
                    throw QuietSettingError.unavailable(
                        "My hour runs inside the inner life, which is off. Turn on settings.inner_life first.")
                }
                UserDefaults.standard.set(enabled, forKey: StudioWanderLane.enabledDefaultsKey)
            }
        ).ownedByMind())

        rows.append(QuietSetting(
            id: "research.search_url", page: "desk", label: "Search service",
            kind: .text,
            note: "The SearXNG address research searches through, as http://host:port. auto looks for "
                + "one running on this Mac and saves what it finds.",
            read: { appModel in .string(appModel.searchServiceURL) },
            write: { appModel, value, context in
                let raw = try stringValue(value, "Search service").trimmingCharacters(in: .whitespaces)
                if raw.caseInsensitiveCompare("auto") == .orderedSame {
                    do {
                        _ = try await appModel.findSearchService(context: context)
                    } catch {
                        throw QuietSettingError.unavailable(
                            "Search service was not selected: \(error.localizedDescription). Check "
                            + "the reported service or Docker failure, or pass the service's explicit address.")
                    }
                    return
                }
                do {
                    try await appModel.saveSearchServiceURL(raw)
                } catch {
                    throw QuietSettingError.unavailable(
                        "The search service was not saved: \(error.localizedDescription). Pass an address "
                        + "like http://localhost:8888, or auto.")
                }
            }
        ))

        rows.append(QuietSetting(
            id: "notifications.raise_unasked", page: "notifications",
            label: "Raise things unasked", kind: .boolean,
            note: "The master over the triggers below. The agent may turn it off; turning it on is "
                + "the person's.",
            read: { appModel in (await notificationsMasterOn(appModel)).map { .bool($0) } ?? .null },
            write: { appModel, value, context in
                let on = try boolValue(value, "Raise things unasked")
                // Turning it on is the person's own decided call and nothing else's.
                guard !on || personDecided(setting: "notifications.raise_unasked", value: value, turn: context.turn) else {
                    throw QuietSettingError.unavailable(
                        "Turning this on is the person's call: it lets the agent reach out unasked. "
                        + "Ask them to switch it on in Settings.")
                }
                let saved: TrustPolicy
                do {
                    saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: ["inboxPolicy": ["enabled": on]],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                    )
                } catch {
                    throw QuietSettingError.unavailable(
                        "Raise things unasked was not turned \(on ? "on" : "off"): \(error.localizedDescription). "
                        + "Try again in a moment.")
                }
                appModel.applySavedTrustPolicy(saved, status: "Notification policy saved")
            }
        ))
        rows.append(QuietSetting(
            id: "notifications.triggers_on", page: "notifications",
            label: "Triggers that are on", kind: .list,
            liveChoices: { host in
                guard let host = host() else { throw QuietSettingError.unavailable(
                    "The settings owner is unavailable. Open settings again before reading triggers.") }
                return try await host.inboxTriggers().map(\.name)
            },
            note: "The kinds of thing raised unasked, by name. Send the whole list that should be on; "
                + "every trigger not in it is switched off. Switching one on needs "
                + "notifications.raise_unasked on.",
            read: { appModel in
                let triggers = try await appModel.inboxTriggers()
                return .array(triggers.filter(\.enabled).map { .string($0.name) })
            },
            write: { appModel, value, context in
                let wanted = Set(try listValue(value, "Triggers that are on"))
                let triggers: [QuietInboxTrigger]
                do {
                    triggers = try await appModel.inboxTriggers()
                } catch {
                    throw QuietSettingError.unavailable(
                        "The triggers could not be read, so none was switched: "
                        + "\(error.localizedDescription). Try again in a moment.")
                }
                let names = triggers.map(\.name)
                // Only the user's enabled master permits the agent to turn on an individual trigger.
                let turningOn = triggers.contains { wanted.contains($0.name) && !$0.enabled }
                if turningOn, await notificationsMasterOn(appModel) != true {
                    throw QuietSettingError.unavailable(
                        "Raising things unasked is off, and turning it on is the person's call, so no "
                        + "trigger can be switched on. Ask them to switch it on in Settings; "
                        + "switching triggers off still works.")
                }
                if let unknown = wanted.sorted().first(where: { !names.contains($0) }) {
                    throw QuietSettingError.badValue(
                        "\(unknown) is not a trigger. Triggers that are on takes names from: "
                        + "\(names.joined(separator: ", ")).")
                }
                var switched: [JSONValue] = []
                defer { context.detail.record("triggers_switched", .array(switched)) }
                for trigger in triggers where wanted.contains(trigger.name) != trigger.enabled {
                    do {
                        try await appModel.setInboxTrigger(trigger.name, enabled: !trigger.enabled)
                    } catch {
                        throw QuietSettingError.unavailable(
                            "\(trigger.name) was not switched: \(error.localizedDescription). The ones in "
                            + "triggers_switched were; send the list again to finish.")
                    }
                    switched.append(.string(trigger.name))
                }
            }
        ))
        rows.append(botScheduleFloor)

        rows.append(imageModel)

        return rows
    }()

    /// Preference invalidation uses the keys declared beside the registry readers, never a second list of settings.
    @MainActor
    public static func defaultsKeys(forPage page: String, host: any QuietSettingsHost) -> [String] {
        // Defaults-backed rows are declared here or by the platform; lower-only rows read their checked stores.
        (staticRows + host.platformSettings).filter { $0.page == page }.compactMap(\.defaultsKey)
    }

    /// Snapshot bot values only for a read; mutations keep fresh store readers.
    @MainActor
    public static func all(host: (any QuietSettingsHost)?, snapshotBots: Bool = false) throws -> [QuietSetting] {
        try staticRows + botRows(host, snapshot: snapshotBots) + (host?.lowerOnlyRows(forPage: nil) ?? []) + (host?.platformSettings ?? [])
    }

    @MainActor
    public static func settings(forPage page: String, host: (any QuietSettingsHost)?) throws -> [QuietSetting] {
        // Page settings include the page's own rows, its app's access switch (a Trust row) and the memories page's model.
        let belongs: (QuietSetting) -> Bool = { setting in
            setting.page == page || (setting.page == "trust" && setting.id == "trust.mac_integration_\(page)")
                || (page == "memories" && setting.id == "providers.memory_and_mind_model")
        }
        return try staticRows.filter(belongs)
            + (page == "bots" ? botRows(host, snapshot: true) : [])
            + (host?.lowerOnlyRows(forPage: page) ?? []).filter(belongs)
            + (host?.platformSettings ?? []).filter(belongs)
    }

    /// One kind of thing raised unasked, as its own switch: `notifications.trigger.<name>`, read from the inbox owner's triggers.
    public static let inboxTriggerPrefix = "notifications.trigger."

    /// A trigger's switch takes one trigger's change; switching one on needs the master (`notifications.raise_unasked`) on.
    @MainActor
    static func inboxTrigger(_ name: String) -> QuietSetting {
        let label = "Raise \(name.replacingOccurrences(of: "_", with: " ")) unasked"
        return QuietSetting(
            id: inboxTriggerPrefix + name, page: "notifications", label: label, kind: .boolean,
            note: "One kind of thing raised unasked. Switching it on needs notifications.raise_unasked on.",
            read: { host in
                guard let trigger = try await host.inboxTriggers().first(where: { $0.name == name }) else {
                    throw QuietSettingError.unavailable("\(name) is no longer a trigger. Read Settings again.")
                }
                return .bool(trigger.enabled)
            },
            write: { host, value, context in
                let on = try boolValue(value, label)
                if on, await notificationsMasterOn(host) != true {
                    throw QuietSettingError.unavailable(
                        "Raising things unasked is off, so no trigger can be switched on. Switch notifications.raise_unasked on first.")
                }
                try await host.setInboxTrigger(name, enabled: on)
            }
        )
    }

    @MainActor
    public static func setting(id: String, host: (any QuietSettingsHost)?) async throws -> QuietSetting? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("phone.") { return try await host?.phoneSetting(id: key) }
        if key.hasPrefix(inboxTriggerPrefix) {
            let name = key.dropFirst(inboxTriggerPrefix.count)
            return try await host?.inboxTriggers().first(where: { $0.name.lowercased() == name }).map { inboxTrigger($0.name) }
        }
        let fixed = staticRows + (host?.platformSettings ?? [])
        if let setting = fixed.first(where: { $0.id.lowercased() == key }) { return setting }
        let lower = try host?.lowerOnlyRows(forPage: nil) ?? []
        if !key.hasPrefix("bots.") {
            if let setting = lower.first(where: { $0.id.lowercased() == key }) { return setting }
            if let setting = fixed.first(where: { $0.label.lowercased() == key }) { return setting }
        }
        let rows = try fixed + botRows(host) + lower
        return rows.first { $0.id.lowercased() == key }
            ?? rows.first { $0.label.lowercased() == key }
    }
}
