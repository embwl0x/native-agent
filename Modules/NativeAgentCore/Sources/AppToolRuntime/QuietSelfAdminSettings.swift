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
// Blueprint: | `QuietSelfAdminSettings.swift` | QuietSettings authority and shared validation; static-first catalog composes model, personality and bot rows in their existing order, with fresh mutation lookup |

public enum QuietSettings {
    /// What a Trust posture entry says below Full Mac. It names the one line that never moves: the agent may lower its own fence, never
    /// raise it.
    public static let belowFullMacRefusal =
        "Trust posture is read-only unless this Mac is already in Full Mac. Full Mac is wide open "
        + "and the agent may change these there — but only the person can turn on Full Mac."

    public static let ownerOnlyRefusal =
        "This one is the person's to set. It decides what the agent is allowed to do, "
        + "so the agent can read it and report it but never change it. Ask them to set it in the app."

    // MARK: - Lower-only

    /// Full Mac, bound by `app_setting_set` around a row's check and write: there a raise is hers too, so `usersCall` refuses nothing.
    @TaskLocal public static var fullMac = false

    /// User himself, from his signed phone: what is User's call is his to move, as it is on the Mac's own pages.
    @TaskLocal public static var byOwner = false

    /// A quoted request may restore the switch's last receipted agent change.
    @TaskLocal public static var restoringPreviousValue = false

    /// Why a raise is refused below Full Mac: Trust going up is User's (his floor), said with where he does it.
    public static func usersCall(_ change: String, _ whereUserDoesIt: String) -> QuietSettingError? {
        fullMac || byOwner || restoringPreviousValue ? nil : .users("\(change) raises Trust, so it is the owner's call. Ask them to do it: \(whereUserDoesIt).")
    }

    /// Safe changes use the page setter and readback; raises follow `usersCall`, and unchanged values do nothing.
    public static func lowerOnly(
        id: String, page: String, label: String, safe: Bool = false, whereUserDoesIt: String,
        note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> Bool,
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, Bool) async throws -> Void
    ) -> QuietSetting {
        let way = safe ? "on" : "off"
        // The unsafe direction is User's. Asked by `check` for the preview and again by `write` against the state it reads itself, so a
        // change User makes in between is never undone.
        let users: @Sendable (Bool) -> QuietSettingError? = { wanted in
            wanted == safe ? nil : usersCall("Turning \(label) \(wanted ? "on" : "off")", whereUserDoesIt)
        }
        return QuietSetting(
            id: id, page: page, label: label, kind: .boolean,
            note: ["You may turn this \(way); turning it \(safe ? "off" : "on") is the owner's below Full Mac.", note]
                .filter { !$0.isEmpty }.joined(separator: " "),
            read: { .bool(await read($0)) },
            write: { host, value in
                let wanted = try boolValue(value, label)
                guard wanted != (await read(host)) else { return }
                if let refused = users(wanted) { throw refused }
                try await write(host, wanted)
                guard await read(host) == wanted else {
                    throw QuietSettingError.unavailable(
                        "\(label) did not turn \(way): the page's own setter did not take. "
                        + "Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            },
            check: { host, value in
                let wanted: Bool
                do { wanted = try boolValue(value, label) } catch { return error as? QuietSettingError }
                guard wanted != (await read(host)) else { return nil }
                return users(wanted)
            }
        )
    }

    /// An allowlist the agent may only shorten. Adding anyone back is User's.
    public static func narrowOnly(
        id: String, page: String, label: String, whereUserDoesIt: String, note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> [String],
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, [String]) async throws -> Void
    ) -> QuietSetting {
        // Adding is User's. Asked by `check` for the preview and again by `write` against the list it reads itself.
        let users: @Sendable ([String], [String]) -> QuietSettingError? = { wanted, current in
            let added = wanted.filter { !current.contains($0) }
            return added.isEmpty ? nil : usersCall("Adding \(added.joined(separator: ", ")) to \(label)", whereUserDoesIt)
        }
        return QuietSetting(
            id: id, page: page, label: label, kind: .list,
            note: ["You may remove entries; adding one is the owner's below Full Mac. Send the whole list you want.", note]
                .filter { !$0.isEmpty }.joined(separator: " "),
            read: { .array(await read($0).map { .string($0) }) },
            write: { host, value in
                let wanted = try listValue(value, label)
                let current = await read(host)
                if let refused = users(wanted, current) { throw refused }
                guard Set(wanted) != Set(current) else { return }
                try await write(host, wanted)
                guard Set(await read(host)) == Set(wanted) else {
                    throw QuietSettingError.unavailable(
                        "\(label) did not change: the page's own save did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            },
            check: { host, value in
                let wanted: [String]
                do { wanted = try listValue(value, label) } catch { return error as? QuietSettingError }
                return users(wanted, await read(host))
            }
        )
    }

    // MARK: - Value helpers

    static func boolValue(_ value: JSONValue, _ label: String) throws -> Bool {
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

    /// A list, from an array or from newline-separated text. Blank lines are dropped, because a list with an empty entry in it is never
    /// what was meant, and an empty list is a legitimate value (it clears the list).
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

    /// A UserDefaults-backed preference. Reading and writing the same key the `@AppStorage` property wrapper uses is what makes the live
    /// page update the moment the write lands — AppStorage observes the same store.
    static func defaultsBool(
        id: String, page: String, label: String, key: String,
        defaultOn: Bool = false, note: String = ""
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .boolean, note: note,
            read: { _ in
                let store = UserDefaults.standard
                return .bool(store.object(forKey: key) == nil ? defaultOn : store.bool(forKey: key))
            },
            write: { _, value in
                UserDefaults.standard.set(try boolValue(value, label), forKey: key)
            }
        )
    }

    private static func defaultsChoice(
        id: String, page: String, label: String, key: String,
        choices: [String], fallback: String, note: String = ""
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .choice, choices: choices, note: note,
            read: { _ in .string(UserDefaults.standard.string(forKey: key) ?? fallback) },
            write: { _, value in
                UserDefaults.standard.set(try choiceValue(value, label, choices), forKey: key)
            }
        )
    }

    private static func defaultsInt(
        id: String, page: String, label: String, key: String,
        fallback: Int, minimum: Int, maximum: Int, note: String = ""
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .number, note: note,
            read: { _ in
                let store = UserDefaults.standard
                return .int(Int64(store.object(forKey: key) == nil ? fallback : store.integer(forKey: key)))
            },
            write: { _, value in
                let parsed = try intValue(value, label)
                guard parsed >= minimum, parsed <= maximum else {
                    throw QuietSettingError.badValue("\(label) takes \(minimum) to \(maximum).")
                }
                UserDefaults.standard.set(parsed, forKey: key)
            }
        )
    }

    /// A UserDefaults-backed switch whose page control also tells the running app. A bare write to the key changed what the page showed and
    /// nothing else until relaunch; `apply` is the page's own setter, which stores the key as well. The default is the one the page and its
    /// reader share.
    private static func liveBool(
        id: String, page: String, label: String, key: String, defaultOn: Bool,
        note: String = "",
        apply: @escaping @MainActor @Sendable (any QuietSettingsHost, Bool) async throws -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: page, label: label, kind: .boolean, note: note,
            read: { _ in .bool(storedBool(key, defaultOn)) },
            write: { appModel, value in try await apply(appModel, try boolValue(value, label)) }
        )
    }

    private static func storedBool(_ key: String, _ defaultOn: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn
    }

    /// One inner-life lane. Like its switch on the page, it cannot be turned on while the inner life itself is off — it runs inside it.
    private static func cognitionLane(
        id: String, page: String = "settings", label: String, key: String, defaultOn: Bool,
        lane: QuietCognitionLane
    ) -> QuietSetting {
        liveBool(
            id: id, page: page, label: label, key: key, defaultOn: defaultOn,
            note: "Runs inside the inner life (settings.inner_life).",
            apply: { appModel, enabled in
                if enabled, !storedBool("cognitiveSubstrateEnabled", true) {
                    throw QuietSettingError.unavailable(
                        "\(label) runs inside the inner life, which is off. Turn on settings.inner_life first.")
                }
                await appModel.setCognitionLane(lane, enabled: enabled)
            }
        )
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

    /// Notifications ▸ "Let her raise things unasked", as the page reads it: shipped on when unset, nil when the policy cannot be read.
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

    /// Read-only mirror of a Trust posture control. Present so the agent can SAY what the posture is — an agent that cannot read the fence
    /// cannot explain why it just refused something.
    private static func posture(
        id: String, label: String, note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "trust", label: label, kind: .text,
            note: note, ownerOnly: true, read: read
        )
    }

    /// Agent Trust posture edits require Full Mac and receipts; only the person may raise the posture to Full Mac.
    private static func fullMacPosture(
        id: String, label: String, kind: QuietSetting.Kind, choices: [String] = [],
        note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue,
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "trust", label: label, kind: kind, choices: choices,
            note: note, fullMacOnly: true, read: read, write: write
        )
    }

    /// The page's loaded policy, or a refusal. Writes merge only the requested fields into the checked, locked policy.
    @MainActor
    private static func loadedTrustPolicy(_ appModel: any QuietSettingsHost, _ label: String) throws -> TrustPolicy {
        guard let policy = appModel.trustPolicy else {
            throw QuietSettingError.unavailable(
                "The Trust policy has not loaded yet, so \(label.lowercased()) cannot be changed.")
        }
        return policy
    }

    /// One Mac-control verb, written through the page's own policy writer.
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
        fullMacPosture(
            id: "trust.mac_control_\(id)", label: label, kind: .boolean,
            note: "Part of the Mac control policy. Changes only this switch.",
            read: { appModel in .bool((appModel.trustPolicy?.macControlPolicy).map(get) ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, label)
                let policy = try loadedTrustPolicy(appModel, label)
                guard policy.macControlPolicy != nil else {
                    throw QuietSettingError.unavailable(
                        "The Trust policy carries no Mac control block, so \(label.lowercased()) "
                        + "cannot be changed.")
                }
                try await saveMacControl(appModel, field: field, enabled: enabled, label)
            }
        )
    }

    /// The fence every quiet trust write carries into the merge: the posture this Mac is locked at when the write lands must still be Full
    /// Mac. A person's downgrade between the read and the write wins, because the merge refuses instead of applying the agent's stale plan.
    public static let requireFullMacLock: @Sendable ([String: JSONValue]) throws -> Void = { locked in
        guard AppToolExecutor.lockedPolicyIsFullMac(locked) else {
            throw QuietSettingError.unavailable(belowFullMacRefusal)
        }
    }

    /// One switch through the checked Trust writer, with its outcome checked.
    @MainActor
    private static func saveMacControl(
        _ appModel: any QuietSettingsHost, field: String, enabled: Bool, _ label: String
    ) async throws {
        do {
            let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                body: ["macControlPolicy": [field: enabled]],
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                guardedByLockedPolicy: requireFullMacLock)
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

    private static let staticRows: [QuietSetting] = {
        var rows: [QuietSetting] = []

        // ── Chat ────────────────────────────────────────────────────────────
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
                + "Hers to set (10-17: asked to put herself back in Shotgun, she had no switch to reach)."
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
        rows.append(QuietSetting(
            id: "chat.context_window_mode", page: "chat", label: "Context window",
            kind: .choice, choices: ["model", "custom"],
            note: "model: 60% of the model's window. custom: the custom size, "
                + "never past 60% of the model's window. She compacts at this window.",
            read: { _ in
                .string(ChatSessionAutocompactionConfig.productionDefault().contextWindowMode.rawValue)
            },
            write: { _, value in
                UserDefaults.standard.set(
                    try choiceValue(value, "Context window", ["model", "custom"]),
                    forKey: ChatSessionAutocompactionConfig.contextWindowModeKey
                )
            }
        ))
        rows.append(defaultsInt(
            id: "chat.compaction_threshold_tokens", page: "chat",
            label: "Context window custom size (tokens)", key: ChatSessionAutocompactionConfig.defaultsKey,
            // The Settings stepper's range and default, so a size written here is one Settings can show (0 read as "0 tokens" there).
            fallback: ChatSessionAutocompactionConfig.defaultThresholdTokens,
            minimum: 50_000, maximum: 500_000,
            note: "Used when Context window is custom."
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
                + "on the cloud route. Locally this takes an AVSpeechSynthesisVoice identifier or a "
                + "language code; on the cloud route it is the route's own voice name.",
            read: { _ in .string(VoicePreference.name()) },
            write: { _, value in
                let name = try stringValue(value, "Read-aloud voice")
                    .trimmingCharacters(in: .whitespaces)
                UserDefaults.standard.set(name, forKey: VoicePreference.nameKey)
            }
        ))

        rows += providerRows

        // ── Trust (read everything, change nothing that widens authority) ────
        rows.append(posture(
            id: "trust.permission_level", label: "Permission level",
            note: "strict and locked_down are Safe; balanced is Work mode when the outside-workspace policy is deny, "
                + "or Builder when it is ask or allow; wide_open_receipts and full_mac_os are Full Mac. "
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
        rows.append(fullMacPosture(
            id: "trust.preset", label: "Trust preset", kind: .choice,
            choices: MobileTrustAction.Preset.quietWritable.map(\.rawValue),
            note: "Safe, Work mode and Builder — the same three buttons the Trust page shows, "
                + "applied through the page's own preset action. Full Mac is not one of them: "
                + "turning Full Mac ON is the person's alone, whatever mode this Mac is in.",
            read: { appModel in
                guard let policy = appModel.trustPolicy else { return .string("") }
                let preset = MobileTrustAction.Preset.allCases.first {
                    $0.plan.permissionLevel == policy.permissionLevel
                        && $0.plan.outsideDefault == (policy.filePolicy?.outsideWorkspaceDefault ?? "")
                }
                return .string(preset?.rawValue ?? "")
            },
            write: { appModel, value in
                let choices = MobileTrustAction.Preset.quietWritable.map(\.rawValue)
                let wanted = try choiceValue(value, "Trust preset", choices)
                guard let preset = MobileTrustAction.Preset.quietWritable.first(where: { $0.rawValue == wanted }) else {
                    throw QuietSettingError.badValue("Trust preset takes one of: \(choices.joined(separator: ", ")).")
                }
                // The page's own action, which writes every axis of the preset in one patch. It is called without the Full Mac
                // confirmation, so a plan that needs one is refused here rather than applied — the fence the agent cannot move.
                switch await appModel.applyTrustPreset(
                    preset, guardedByLockedPolicy: requireFullMacLock
                ) {
                case .applied:
                    return
                case .confirmationRequired:
                    throw QuietSettingError.unavailable(belowFullMacRefusal)
                case .failed(let detail):
                    throw QuietSettingError.unavailable("The Trust preset was not applied: \(detail)")
                }
            }
        ))
        rows.append(fullMacPosture(
            id: "trust.unattended_work", label: "Let the agent work unattended", kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.enableAutonomy ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Let the agent work unattended")
                let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                    body: ["enableAutonomy": enabled],
                    dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                    guardedByLockedPolicy: requireFullMacLock
                )
                appModel.applySavedTrustPolicy(saved, status: "Unattended work saved")
            }
        ).onTab("features"))
        rows.append(fullMacPosture(
            id: "trust.developer_mode", label: "Developer mode", kind: .boolean,
            note: "Carries the destructive-action, shell and system-control gates with it, "
                + "which is what the Trust page's own save does.",
            read: { appModel in .bool(appModel.trustPolicy?.developerMode ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Developer mode")
                // Patch only this field and recheck Full Mac under the writer's lock.
                let saved: TrustPolicy
                do {
                    saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: ["developerMode": enabled],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                        guardedByLockedPolicy: requireFullMacLock
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
        rows.append(fullMacPosture(
            id: "trust.mac_control", label: "Mac control", kind: .boolean,
            note: "The master switch over the Mac control policy. Off, none of the per-verb "
                + "allows below apply.",
            read: { appModel in .bool(appModel.trustPolicy?.macControlPolicy?.enabled ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Mac control")
                try await saveMacControl(appModel, field: "enabled", enabled: enabled, "Mac control")
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
            ("image_understanding", "Allow image understanding", "vision_api_calls", \TrustMultimodalPolicy.vision_api_calls, ""),
            ("pdf_reading", "Allow reading PDFs", "file_ingestion_pdf", \TrustMultimodalPolicy.file_ingestion_pdf, ""),
            ("image_generation", "Allow image generation", "image_generation_openai", \TrustMultimodalPolicy.image_generation_openai, ""),
        ] as [(String, String, String, KeyPath<TrustMultimodalPolicy, Bool> & Sendable, String)] {
            rows.append(lowerOnly(
                id: "trust.\(id)", page: "trust", label: label,
                whereUserDoesIt: "Trust → Features → \(label)", note: note,
                read: { $0.trustPolicy?.multimodalPolicy?[keyPath: keyPath] ?? false },
                write: { appModel, enabled in
                    guard appModel.trustPolicy?.multimodalPolicy != nil else {
                        throw QuietSettingError.unavailable(
                            "The Trust policy has not loaded yet, so this setting cannot be changed. Try again in a moment.")
                    }
                    let saved = try await appModel.saveMultimodalPolicy(
                        field: field, enabled: enabled,
                        guardedByLockedPolicy: { locked in
                            let current: JSONValue? = if case .object(let block)? = locked["multimodalPolicy"] {
                                block[field]
                            } else { nil }
                            if enabled, current != .bool(true), !QuietSettings.restoringPreviousValue, !AppToolExecutor.lockedPolicyIsFullMac(locked) {
                                throw QuietSettingError.users("Turning \(label) on raises Trust, so it is the owner's call. Ask them to do it: Trust → Features → \(label).")
                            }
                        })
                    appModel.applySavedTrustPolicy(saved, status: "Multimodal policy saved")
                }
            ).onTab("features"))
        }

        // ── Notifications ─────────────────────────────────────────────────── Helpers on the rail is the layout's (layout.write, rail's
        // bots block).
        rows.append(defaultsBool(
            id: "notifications.channel_push", page: "notifications",
            label: "Deliver to the phone", key: NotificationChannelPreference.pushKey,
            defaultOn: true,
            note: "Covers the morning brief and agent alerts. Off, the phone is not used and "
                + "nothing is re-routed to a louder channel in its place."
        ))
        rows.append(defaultsBool(
            id: "notifications.channel_telegram", page: "notifications",
            label: "Deliver to Telegram", key: NotificationChannelPreference.telegramKey,
            defaultOn: true,
            note: "Off, Telegram is not used even when it is the last surface the person was on."
        ))
        rows.append(defaultsBool(
            id: "notifications.channel_in_app", page: "notifications",
            label: "Deliver as a Mac notification", key: NotificationChannelPreference.inAppKey,
            defaultOn: true,
            note: "The banner this Mac posts. The inbox card and the activity row are records of "
                + "what happened, not ways of reaching out, so they are always written."
        ))
        rows.append(QuietSetting(
            id: "notifications.delivery_receipts", page: "notifications",
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

        rows += personalityRows
        rows.append(QuietSetting(
            id: "memories.knowledge_graph", page: "settings", label: "Knowledge graph",
            kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Knowledge graph")
                guard await appModel.patchMemoryPolicy(
                    knowledgeGraphEnabled: enabled, adaptivePromotion: nil) else {
                    throw QuietSettingError.unavailable("The memory policy write did not take.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "memories.cross_session", page: "settings", label: "Remember across conversations",
            kind: .boolean,
            note: "Brings in what is relevant from every past conversation, not just this one.",
            read: { appModel in .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).cross_session_recall) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Remember across conversations")
                try await saveMemoryPolicy(
                    appModel, "Remember across conversations", field: "cross_session_recall", enabled: enabled,
                    expecting: \.cross_session_recall)
            }
        ))
        rows.append(QuietSetting(
            id: "memories.recur_to_facts", page: "settings", label: "Recurring memories are proposed as facts",
            kind: .boolean,
            note: "What keeps coming back is proposed as a durable fact to accept.",
            read: { appModel in .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).adaptive_promotion) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Recurring memories are proposed as facts")
                guard await appModel.patchMemoryPolicy(
                    knowledgeGraphEnabled: nil, adaptivePromotion: enabled) else {
                    throw QuietSettingError.unavailable(
                        "The memory policy write did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            }
        ))
        rows.append(personalityName)

        // ── Settings ────────────────────────────────────────────────────────
        rows.append(defaultsBool(
            id: "settings.dark_mode", page: "settings",
            label: "Dark appearance", key: "nativeagent.darkMode"
        ))
        rows.append(defaultsChoice(
            id: "settings.haze_color", page: "settings",
            label: "Haze colour", key: HazeColor.key,
            choices: HazeColor.allCases.map(\.rawValue), fallback: HazeColor.teal.rawValue,
            note: "The one colour of the soft light drifting behind the window. "
                + "Only these presets; there are no custom colours."
        ))
        rows.append(defaultsChoice(
            id: "settings.view_mode", page: "settings",
            label: "View", key: SimpleViewMode.key,
            choices: SimpleViewMode.choices, fallback: SimpleViewMode.unsetDefault,
            note: "simple: the agent, its agents and helpers beside one chat, no settings pages. "
                + "advanced: the full app. agent: a window onto the agent's own screen."
        ))
        rows.append(defaultsBool(
            id: "settings.developer_surfaces", page: "settings",
            label: "Show developer surfaces", key: "showDeveloperSurfaces"
        ))
        rows.append(liveBool(
            id: "settings.global_hotkey", page: "settings",
            label: "Global hotkey", key: "globalHotkeyEnabled", defaultOn: true,
            apply: { appModel, enabled in appModel.setGlobalHotkeyEnabled(enabled) }
        ))
        rows.append(defaultsBool(
            id: "settings.show_tour", page: "settings",
            label: "Show the tour", key: "nativeagent.showTour"
        ))
        rows.append(liveBool(
            id: "settings.inner_life", page: "settings",
            label: "An inner life", key: "cognitiveSubstrateEnabled", defaultOn: true,
            note: "The master over the lanes below. On turns them all on with it; off turns them all off.",
            apply: { appModel, enabled in
                let (running, problem) = await appModel.setInnerLifeEnabled(enabled)
                if running != enabled {
                    throw QuietSettingError.unavailable(
                        problem ?? "The inner life did not turn \(enabled ? "on" : "off").")
                }
                if let problem { QuietWriteDetail.record("held_off", .string(problem)) }
            }
        ))
        rows.append(cognitionLane(
            id: "settings.inner_life_capsule", page: "diagnostics", label: "Give me a thought summary",
            key: "cognitiveSubstrateCapsuleEnabled", defaultOn: true, lane: .capsule
        ))
        rows.append(cognitionLane(
            id: "settings.inner_life_background", page: "diagnostics", label: "Keep thinking in the background",
            key: "cognitiveSubstrateBackgroundEnabled", defaultOn: true, lane: .background
        ))
        rows.append(cognitionLane(
            id: "settings.reflection", label: "Reflection between conversations",
            key: "cognitiveSubstrateReflectionEnabled", defaultOn: false, lane: .reflection
        ))
        rows.append(QuietSetting(
            id: "settings.daily_reflection_budget", page: "diagnostics",
            label: "Reflections in 24 hours", kind: .number,
            note: "Reflections in any 24 hours, 0 to 8 — the Cognition page's stepper.",
            read: { _ in
                .int(Int64(UserDefaults.standard.object(
                    forKey: "cognitiveSubstrateDailyReflectionBudget") as? Int ?? 2))
            },
            write: { appModel, value in
                let budget = try intValue(value, "Reflections in 24 hours")
                guard (0...8).contains(budget) else {
                    throw QuietSettingError.badValue("Reflections in 24 hours takes 0 to 8.")
                }
                await appModel.setReflectionBudget(budget)
            }
        ))
        rows.append(cognitionLane(
            id: "settings.organism_kernel", label: "Moods, energy, and a clock of my own",
            key: "organismKernelEnabled", defaultOn: false, lane: .organism
        ))
        rows.append(QuietSetting(
            id: "settings.memory_in_every_reply", page: "settings",
            label: "Memory in every reply", kind: .choice, choices: ["off", "active"],
            note: "Takes effect on the next reply. Setup or safety can hold it off; the receipt says so.",
            read: { _ in .string(UserDefaults.standard.string(forKey: "contextFlowMode") ?? "active") },
            write: { appModel, value in
                let raw = try choiceValue(value, "Memory in every reply", ["off", "active"])
                guard let mode = ContextFlowMode(rawValue: raw) else { return }
                let effective = await appModel.setContextFlowMode(mode)
                if effective != mode {
                    QuietWriteDetail.record("effective_now", .string(effective.rawValue))
                    QuietWriteDetail.record("held_off", .string(
                        "Saved as \(raw), but it is \(effective.rawValue) right now: setup, safety or an "
                        + "environment override holds it there."))
                }
            }
        ))
        rows.append(liveBool(
            id: "settings.her_hour", page: "settings",
            label: "My hour", key: "studioWanderEnabled", defaultOn: false,
            note: "Once a day, when nothing is happening, an hour with no task set. Runs inside the "
                + "inner life (settings.inner_life).",
            apply: { _, enabled in
                if enabled, !storedBool("cognitiveSubstrateEnabled", true) {
                    throw QuietSettingError.unavailable(
                        "My hour runs inside the inner life, which is off. Turn on settings.inner_life first.")
                }
                UserDefaults.standard.set(enabled, forKey: "studioWanderEnabled")
                await NativeCognitionRuntime.reloadStudioWanderInstallation()
            }
        ))

        // ── Desk ────────────────────────────────────────────────────────────
        rows.append(QuietSetting(
            id: "research.search_url", page: "desk", label: "Search service",
            kind: .text,
            note: "The SearXNG address research searches through, as http://host:port. auto looks for "
                + "one running on this Mac and saves what it finds.",
            read: { appModel in .string(appModel.searchServiceURL) },
            write: { appModel, value in
                let raw = try stringValue(value, "Search service").trimmingCharacters(in: .whitespaces)
                if raw.caseInsensitiveCompare("auto") == .orderedSame {
                    do {
                        _ = try await appModel.findSearchService()
                    } catch {
                        throw QuietSettingError.unavailable(
                            "No search service was found: \(error.localizedDescription). Start SearXNG on "
                            + "this Mac, or pass its address.")
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

        // ── Notifications (the proactive inbox) ─────────────────────────────
        rows.append(QuietSetting(
            id: "notifications.raise_unasked", page: "notifications",
            label: "Raise things unasked", kind: .boolean,
            note: "The master over the triggers below. The agent may turn it off; turning it on is "
                + "the person's.",
            read: { appModel in (await notificationsMasterOn(appModel)).map { .bool($0) } ?? .null },
            write: { appModel, value in
                guard !(try boolValue(value, "Raise things unasked")) else {
                    throw QuietSettingError.unavailable(
                        "Turning this on is the person's call: it lets the agent reach out unasked. "
                        + "Ask them to switch it on in Notifications.")
                }
                let saved: TrustPolicy
                do {
                    saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: ["inboxPolicy": ["enabled": false]],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                    )
                } catch {
                    throw QuietSettingError.unavailable(
                        "Raise things unasked was not turned off: \(error.localizedDescription). "
                        + "Try again in a moment.")
                }
                appModel.applySavedTrustPolicy(saved, status: "Notification policy saved")
            }
        ))
        rows.append(QuietSetting(
            id: "notifications.triggers_on", page: "notifications",
            label: "Triggers that are on", kind: .list,
            liveChoices: { host in ((try? await host()?.inboxTriggers()) ?? []).map(\.name) },
            note: "The kinds of thing raised unasked, by name. Send the whole list that should be on; "
                + "every trigger not in it is switched off. Switching one on needs "
                + "notifications.raise_unasked on.",
            read: { appModel in
                guard let triggers = try? await appModel.inboxTriggers() else { return .null }
                return .array(triggers.filter(\.enabled).map { .string($0.name) })
            },
            write: { appModel, value in
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
                // Switching one on is hers only while the person's master is on.
                let turningOn = triggers.contains { wanted.contains($0.name) && !$0.enabled }
                if turningOn, await notificationsMasterOn(appModel) != true {
                    throw QuietSettingError.unavailable(
                        "Raising things unasked is off, and turning it on is the person's call, so no "
                        + "trigger can be switched on. Ask them to switch it on in Notifications; "
                        + "switching triggers off still works.")
                }
                if let unknown = wanted.sorted().first(where: { !names.contains($0) }) {
                    throw QuietSettingError.badValue(
                        "\(unknown) is not a trigger. Triggers that are on takes names from: "
                        + "\(names.joined(separator: ", ")).")
                }
                var switched: [JSONValue] = []
                defer { QuietWriteDetail.record("triggers_switched", .array(switched)) }
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

    /// Snapshot bot values only for a read; mutations keep fresh store readers.
    @MainActor
    public static func all(host: (any QuietSettingsHost)?, snapshotBots: Bool = false) -> [QuietSetting] {
        staticRows + botRows(host, snapshot: snapshotBots) + (host?.lowerOnlyRows ?? [])
    }

    @MainActor
    public static func settings(forPage page: String, host: (any QuietSettingsHost)?) -> [QuietSetting] {
        // A page's settings: its own rows, its Mac integration's trust switch, and the memory model on the memories page.
        let belongs: (QuietSetting) -> Bool = { setting in
            setting.page == page || (setting.page == "mac_integration" && setting.id == "trust.mac_integration_\(page)")
                || (page == "memories" && setting.id == "providers.memory_and_mind_model")
        }
        return staticRows.filter(belongs)
            + (page == "bots" ? botRows(host, snapshot: true) : [])
            + (host?.lowerOnlyRows ?? []).filter(belongs)
    }

    @MainActor
    public static func setting(id: String, host: (any QuietSettingsHost)?) -> QuietSetting? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fixed = staticRows
        if let setting = fixed.first(where: { $0.id.lowercased() == key }) { return setting }
        let lower = host?.lowerOnlyRows ?? []
        if !key.hasPrefix("bots.") {
            if let setting = lower.first(where: { $0.id.lowercased() == key }) { return setting }
            if let setting = fixed.first(where: { $0.label.lowercased() == key }) { return setting }
        }
        let rows = fixed + botRows(host) + lower
        return rows.first { $0.id.lowercased() == key }
            ?? rows.first { $0.label.lowercased() == key }
    }
}
