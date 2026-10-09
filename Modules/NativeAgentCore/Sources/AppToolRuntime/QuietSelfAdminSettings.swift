import ChatOrchestration
import Cognition
import Context
import Foundation
import AttentionRouting
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Studio
import ProviderRouting
import StandingBots
import TrustCenter

public typealias QuietSettingsHostProvider = @MainActor @Sendable () -> (any QuietSettingsHost)?

public enum QuietSettingError: Error, LocalizedError {
    case badValue(String)
    case unavailable(String)
    /// The value would raise Trust: User's call, refused as `users_call`.
    case users(String)

    public var errorDescription: String? {
        switch self {
        case .badValue(let detail): return detail
        case .unavailable(let detail): return detail
        case .users(let detail): return detail
        }
    }
}

/// Extra lines a write leaves for its own receipt.
///
/// A setting that covers several surfaces changes more than its own row, and
/// `app_setting_set` cannot see that from the lead value it reads back. The
/// write records what it actually touched here, and the tool folds it into the
/// receipt — the same trail, no second ledger. Main-actor only, and taken
/// exactly once per call, so two writes cannot read each other's detail.
@MainActor
public final class QuietWriteDetail {
    @TaskLocal public static var current: QuietWriteDetail?
    private var pending: [String: JSONValue] = [:]

    public init() {}

    public static func record(_ key: String, _ value: JSONValue) { current?.pending[key] = value }

    public func take() -> [String: JSONValue] {
        defer { pending = [:] }
        return pending
    }
}

/// One control on one page, named so the model never has to guess.
///
/// A setting is registered ONCE, with the read that answers what the page
/// shows and the write that the page's own control calls. There is no
/// reflection and no key-guessing: `app_settings_list` returns exactly this
/// registry, so a control that is not here is honestly reported as absent
/// rather than silently attempted.
public struct QuietSetting: Sendable {
    public enum Kind: String, Sendable {
        case boolean, text, choice, number
        /// An ordered list of lines. Read back as an array; written as an array,
        /// or as one string of newline-separated lines. Add and remove are the
        /// same operation — send the list you want.
        case list
    }

    public let id: String
    public let page: String
    /// The page's tab the control is on, by the key the page stores; nil is
    /// the page's first tab. ⌘K opens the control there.
    public private(set) var tab: String?
    public let label: String
    public let kind: Kind
    /// Non-empty for `.choice`. Stated in the catalog so a set never has to
    /// discover the allowed values by being refused.
    public let choices: [String]
    /// Choices that only exist at run time — the accounts this Mac has
    /// actually connected. The catalog reports exactly what the write
    /// enforces, out of one closure, so a set can never be refused for a value
    /// `app_settings_list` had just offered.
    public let liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async -> [String])?
    public let note: String
    /// The person's own posture. These READ like any other setting and refuse
    /// to be written, saying why — the agent widening its own authority is the
    /// one thing self-administration must not be able to do.
    public let ownerOnly: Bool
    /// Writable only while this Mac is in Full Mac, which is wide open by
    /// User's own word (2026-09-13): there the agent may lower the fence,
    /// receipted like anything else. Below Full Mac it reads and refuses. The
    /// one move no posture opens is RAISING to Full Mac.
    public let fullMacOnly: Bool
    public let read: @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue
    public let write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void)?
    /// The rule a value must pass before it is written (which way a
    /// lower-only switch may move, what a narrow-only list may gain), read
    /// only. `write` asks it first, and the door's preview asks it alone, so
    /// a preview refuses what the write would.
    public let check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async -> QuietSettingError?)?

    public init(
        id: String,
        page: String,
        label: String,
        kind: Kind,
        choices: [String] = [],
        liveChoices: (@MainActor @Sendable (@escaping QuietSettingsHostProvider) async -> [String])? = nil,
        note: String = "",
        ownerOnly: Bool = false,
        fullMacOnly: Bool = false,
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue,
        write: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async throws -> Void)? = nil,
        check: (@MainActor @Sendable (any QuietSettingsHost, JSONValue) async -> QuietSettingError?)? = nil
    ) {
        self.id = id
        self.page = page
        self.label = label
        self.kind = kind
        self.choices = choices
        self.liveChoices = liveChoices
        self.note = note
        self.ownerOnly = ownerOnly
        self.fullMacOnly = fullMacOnly
        self.read = read
        self.check = check
        if let write {
            self.write = { @MainActor @Sendable host, value in
                if let refused = await check?(host, value) { throw refused }
                try await write(host, value)
            }
        } else {
            self.write = nil
        }
    }

    /// The same control, on `tab` of its page.
    public func onTab(_ tab: String) -> QuietSetting {
        var row = self
        row.tab = tab
        return row
    }

    /// Whether a set would be accepted RIGHT NOW. `fullMac` is the posture read
    /// fresh off the saved policy, so the catalog's `writable` and the answer
    /// `app_setting_set` gives are one answer.
    public func writable(fullMac: Bool) -> Bool {
        guard !ownerOnly, write != nil else { return false }
        return fullMac || !fullMacOnly
    }

    public func catalogRow(fullMac: Bool, host: @escaping QuietSettingsHostProvider) async -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "page": .string(page),
            "label": .string(label),
            "type": .string(kind.rawValue),
            "writable": .bool(writable(fullMac: fullMac)),
        ]
        let offered = await (liveChoices?(host) ?? choices)
        if !offered.isEmpty { row["choices"] = .array(offered.map { .string($0) }) }
        if !note.isEmpty { row["note"] = .string(note) }
        if ownerOnly {
            row["owner_only"] = .bool(true)
            row["refusal"] = .string(QuietSettings.ownerOnlyRefusal)
        }
        if fullMacOnly {
            row["full_mac_only"] = .bool(true)
            if !fullMac { row["refusal"] = .string(QuietSettings.belowFullMacRefusal) }
        }
        return .object(row)
    }
}

public enum QuietSettings {
    /// What a Trust posture entry says below Full Mac. It names the one line
    /// that never moves: the agent may lower its own fence, never raise it.
    public static let belowFullMacRefusal =
        "Trust posture is read-only unless this Mac is already in Full Mac. Full Mac is wide open "
        + "and the agent may change these there — but only the person can turn on Full Mac."

    public static let ownerOnlyRefusal =
        "This one is the person's to set. It decides what the agent is allowed to do, "
        + "so the agent can read it and report it but never change it. Ask them to set it in the app."

    // MARK: - Lower-only

    /// Full Mac, bound by `app_setting_set` around a row's check and write:
    /// there a raise is hers too (User, 10-02), so `usersCall` refuses nothing.
    @TaskLocal public static var fullMac = false

    /// User himself, from his signed phone: what is User's call is his to move,
    /// as it is on the Mac's own pages.
    @TaskLocal public static var byOwner = false

    /// A quoted request may restore the switch's last receipted agent change.
    @TaskLocal public static var restoringPreviousValue = false

    /// Why a raise is refused below Full Mac: Trust going up is User's (his
    /// floor), said with where he does it.
    public static func usersCall(_ change: String, _ whereUserDoesIt: String) -> QuietSettingError? {
        fullMac || byOwner || restoringPreviousValue ? nil : .users("\(change) raises Trust, so it is the owner's call. Ask them to do it: \(whereUserDoesIt).")
    }

    /// A switch the agent may move only the safe way (Agent, 2026-10-01, under
    /// User's ruling that she is boss below his floor). The safe direction runs
    /// the page's own setter and is read back; the other direction refuses as
    /// User's. Asking for what is already set changes nothing.
    public static func lowerOnly(
        id: String, page: String, label: String, safe: Bool = false, whereUserDoesIt: String,
        note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> Bool,
        write: @escaping @MainActor @Sendable (any QuietSettingsHost, Bool) async throws -> Void
    ) -> QuietSetting {
        let way = safe ? "on" : "off"
        // The unsafe direction is User's. Asked by `check` for the preview and
        // again by `write` against the state it reads itself, so a change
        // User makes in between is never undone.
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
        // Adding is User's. Asked by `check` for the preview and again by
        // `write` against the list it reads itself.
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

    private static func boolValue(_ value: JSONValue, _ label: String) throws -> Bool {
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

    private static func stringValue(_ value: JSONValue, _ label: String) throws -> String {
        if case .string(let raw) = value { return raw }
        throw QuietSettingError.badValue("\(label) takes a string.")
    }

    private static func intValue(_ value: JSONValue, _ label: String) throws -> Int {
        switch value {
        case .int(let number):
            if let parsed = Int(exactly: number) { return parsed }
        case .double(let number):
            if let parsed = Int(exactly: number) { return parsed }
        case .string(let raw):
            if let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) { return parsed }
        default: break
        }
        throw QuietSettingError.badValue("\(label) takes a whole number.")
    }

    /// A list, from an array or from newline-separated text. Blank lines are
    /// dropped, because a list with an empty entry in it is never what was
    /// meant, and an empty list is a legitimate value (it clears the list).
    private static func listValue(_ value: JSONValue, _ label: String) throws -> [String] {
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

    private static func choiceValue(_ value: JSONValue, _ label: String, _ choices: [String]) throws -> String {
        let raw = try stringValue(value, label)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let match = choices.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw QuietSettingError.badValue(
                "\(label) takes one of: \(choices.joined(separator: ", ")).")
        }
        return match
    }

    /// The chat brain persists through one coordinator, and that coordinator
    /// can fail and roll the visible value back
    /// (`AppModel.saveChatBrainDefaults`). Assigning the property is only the
    /// optimistic half: without this wait a receipt reported the value it had
    /// just typed in, while the saved value was the old one.
    @MainActor
    private static func settleChatBrain(_ appModel: any QuietSettingsHost, _ label: String) async throws {
        if let message = await appModel.saveChatBrainDefaultsFailure() {
            throw QuietSettingError.unavailable("\(label) was not saved: \(message)")
        }
    }

    /// A UserDefaults-backed preference. Reading and writing the same key the
    /// `@AppStorage` property wrapper uses is what makes the live page update
    /// the moment the write lands — AppStorage observes the same store.
    private static func defaultsBool(
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

    /// A UserDefaults-backed switch whose page control also tells the running
    /// app. A bare write to the key changed what the page showed and nothing
    /// else until relaunch; `apply` is the page's own setter, which stores the
    /// key as well. The default is the one the page and its reader share.
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

    /// One inner-life lane. Like its switch on the page, it cannot be turned on
    /// while the inner life itself is off — it runs inside it.
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
        var patch = [field: enabled]
        if field == "consolidation_enabled", !enabled {
            patch["auto_promote_consolidated"] = false
        }
        let saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: ["memoryPolicy": patch],
            dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            guardedByLockedPolicy: { locked in
                if field == "auto_promote_consolidated", enabled,
                   case .object(let memory)? = locked["memoryPolicy"],
                   memory["consolidation_enabled"] == .bool(false) {
                    throw QuietSettingError.unavailable(
                        "Keeping consolidated memories needs consolidation, which is off. Turn on "
                        + "memories.consolidation first.")
                }
            })
        appModel.applySavedTrustPolicy(saved, status: "Memory policy saved")
        guard saved.memoryPolicy?[keyPath: expected] == enabled else {
            throw QuietSettingError.unavailable(
                "\(label) was not saved: the memory policy write did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
        }
    }

    /// Notifications ▸ "Let her raise things unasked", as the page reads it:
    /// shipped on when unset, nil when the policy cannot be read.
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

    /// Read-only mirror of a Trust posture control. Present so the agent can
    /// SAY what the posture is — an agent that cannot read the fence cannot
    /// explain why it just refused something.
    private static func posture(
        id: String, label: String, note: String = "",
        read: @escaping @MainActor @Sendable (any QuietSettingsHost) async -> JSONValue
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "trust", label: label, kind: .text,
            note: note, ownerOnly: true, read: read
        )
    }

    /// A Trust posture control the agent may change WHILE this Mac is in Full
    /// Mac, and not otherwise (User, 2026-09-13: "full mac is supposed to be
    /// wide open yolo"). Below Full Mac it reads and refuses with
    /// `belowFullMacRefusal`; the receipt is the ordinary one, because a fence
    /// the agent moved has to read back in the same trail as everything else.
    ///
    /// Nothing built here can RAISE the posture to Full Mac: the preset row
    /// does not offer Full Mac as a choice, and `TrustPolicyPresetAction` is
    /// called without the confirmation the person alone gives.
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

    /// The page's loaded policy, or a refusal. Writes merge only the requested
    /// fields into the checked, locked policy.
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
        get: @escaping @Sendable (TrustMacControlPolicy) -> Bool
    ) -> QuietSetting {
        macControlVerbRow(id: id, label: label, field: field, get: get).onTab("mac")
    }

    private static func macControlVerbRow(
        id: String, label: String, field: String,
        get: @escaping @Sendable (TrustMacControlPolicy) -> Bool
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

    /// The fence every quiet trust write carries into the merge: the posture
    /// this Mac is locked at when the write lands must still be Full Mac. A
    /// person's downgrade between the read and the write wins, because the
    /// merge refuses instead of applying the agent's stale plan.
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

    // MARK: - Providers

    /// Both doors use ProviderRouting's one recoverable group transaction.
    @MainActor
    private static func writeGroupSelection(
        _ appModel: any QuietSettingsHost,
        group: ProviderSurfaceGroup,
        providerID: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String
    ) async throws {
        let result = try await writeProviderGroup(appModel, group: group, providerID: providerID,
            model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier, clearOverride: false)
        QuietWriteDetail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
    }

    @MainActor private static func writeProviderGroup(
        _ appModel: any QuietSettingsHost, group: ProviderSurfaceGroup, providerID: String?,
        model: String?, reasoningEffort: String?, serviceTier: String?, clearOverride: Bool
    ) async throws -> ProviderGroupWriteResult {
        do {
            return try await appModel.saveProviderGroupSelection(
                group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
                serviceTier: serviceTier, clearOverride: clearOverride
            )
        } catch let failure as ProviderGroupWriteFailure {
            QuietWriteDetail.record("surfaces_changed", failure.surfacesPendingRecovery.isEmpty ? .array([]) : .null)
            QuietWriteDetail.record("surfaces_rolled_back", .array(failure.surfacesRolledBack.map { .string($0) }))
            QuietWriteDetail.record("surfaces_pending_recovery", .array(failure.surfacesPendingRecovery.map { .string($0) }))
            throw failure
        }
    }

    /// The row's "Use Chat's choice" (`ProviderSettingsView.clearGroupOverride`):
    /// every member but Chat itself drops its own pick and follows Chat again,
    /// all of them or none. Reads true when no member has a choice of its own,
    /// by the page's own test: a saved pin, or an answer that differs from Chat's.
    private static func providerGroupUseChat(_ group: ProviderSurfaceGroup) -> QuietSetting {
        let label = "\(group.title): use Chat's choice"
        @Sendable func hasOwnChoice(_ snapshot: ProviderRoutingSnapshot) -> Bool {
            let chat = snapshot.preferences["chat"]
            let chatProvider = snapshot.activeProviders["chat"]
            return group.surfaces.contains { surface in
                guard surface != "chat" else { return false }
                let mine = snapshot.preferences[surface]
                return snapshot.pinnedModels[surface] != nil
                    || mine?.model != chat?.model
                    || mine?.reasoningEffort != chat?.reasoningEffort
                    || mine?.serviceTier != chat?.serviceTier
                    || (snapshot.activeProviders[surface] ?? chatProvider) != chatProvider
            }
        }
        return QuietSetting(
            id: "providers.\(group.id)_use_chat",
            page: "providers",
            label: label,
            kind: .boolean,
            note: "true: every \(group.title) activity but Chat follows Chat's model; providers.\(group.id)_model gives it its own.",
            read: { _ in
                guard let snapshot = try? await SwiftNativeProviderRouting(
                    dataRoot: PersistenceCore.defaultDataRoot()).checkedRoutingSnapshot() else { return .null }
                return .bool(!hasOwnChoice(snapshot))
            },
            write: { appModel, value in
                let before = try await SwiftNativeProviderRouting(
                    dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                ).checkedRoutingSnapshot()
                guard try boolValue(value, label) else {
                    guard hasOwnChoice(before) else {
                        throw QuietSettingError.badValue(
                            "\(group.title) follows Chat now, and false does not pick anything. To give it a "
                            + "model of its own, set providers.\(group.id)_model.")
                    }
                    return
                }
                let result = try await writeProviderGroup(
                    appModel, group: group, providerID: nil, model: nil,
                    reasoningEffort: nil, serviceTier: nil, clearOverride: true
                )
                QuietWriteDetail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// The two activities that keep a model of their own outside the
    /// Providers page: the Telegram page's Model, and the Settings picker for
    /// my hour (`SetupStudioWanderPicker`). Each is a one-member group, so it
    /// is pinned through the same rows and the same all-or-nothing write as a
    /// whole group. (The Settings reflection picker is not here: it writes
    /// the whole Memory and mind group, which providers.memory_and_mind_* is.)
    private static let surfacePins: [ProviderSurfaceGroup] = [
        ProviderSurfaceGroup(id: "telegram", title: "Telegram", members: [.init("telegram", "Telegram")]),
        ProviderSurfaceGroup(
            id: "her_hour", title: "My hour",
            members: [.init(NativeCognitionRuntime.studioWanderSurface, "My hour")]),
    ]

    /// The three activity groups are the whole of the Providers page's model
    /// choice (`ProviderSurfaceGroups`), and a group's pick is written to every
    /// surface it claims — exactly what `requestSetGroupSelection` does when a
    /// person changes the picker.
    private static func providerGroupModel(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_model",
            page: "providers",
            label: "\(group.title) model",
            kind: .text,
            liveChoices: { host in
                await offeredModels(host(), providerID: await leadProvider(group)).map(\.id)
            },
            note: "Covers \(group.surfaces.joined(separator: ", ")). Another account's models need providers.\(group.id)_account first.",
            read: { _ in
                guard let preference = await currentPreference(surface: group.surfaces.first ?? group.id) else {
                    return .string("")
                }
                return .string(preference.model)
            },
            write: { appModel, value in
                let model = try stringValue(value, "\(group.title) model")
                    .trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    throw QuietSettingError.badValue("\(group.title) model takes a model id.")
                }
                let lead = group.surfaces.first ?? group.id
                let preference = await currentPreference(surface: lead)
                let providerID = await leadProvider(group)
                var effort = preference?.reasoningEffort ?? "high"
                var tier = preference?.serviceTier ?? "default"
                // A fetched catalogue that has not loaded lists nothing, and
                // its silence is not evidence against the id.
                let offered = await offeredModels(appModel, providerID: providerID)
                if !offered.isEmpty {
                    guard let choice = offered.first(where: { $0.id == model }) else {
                        throw QuietSettingError.badValue(
                            "\(model) is not a model \(providerID) offers. \(group.title) model takes one "
                            + "of: \(offered.map(\.id).joined(separator: ", ")). For another account's "
                            + "models, set providers.\(group.id)_account first.")
                    }
                    // The page's own reconcile (`requestSetGroupModel`).
                    if !choice.efforts.contains(effort) {
                        effort = choice.efforts.contains(choice.defaultEffort)
                            ? choice.defaultEffort : (choice.efforts.first ?? "high")
                    }
                    if !choice.supportsFast { tier = "default" }
                }
                try await writeGroupSelection(
                    appModel, group: group, providerID: providerID, model: model,
                    reasoningEffort: effort, serviceTier: tier
                )
            }
        )
    }

    private static func providerGroupEffort(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_thinking",
            page: "providers",
            label: "\(group.title) thinking",
            kind: .choice,
            liveChoices: { await groupEfforts(group, $0()) },
            read: { _ in .string(await currentPreference(surface: group.surfaces.first ?? group.id)?.reasoningEffort ?? "") },
            write: { appModel, value in
                let lead = group.surfaces.first ?? group.id
                guard let preference = await currentPreference(surface: lead), !preference.model.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "\(group.title) has no model chosen yet, so there is no thinking level to set. "
                        + "Set providers.\(group.id)_model first.")
                }
                let effort = try effortValue(
                    value, "\(group.title) thinking", await groupEfforts(group, appModel),
                    model: preference.model, modelSetting: "providers.\(group.id)_model")
                let providerID = await leadProvider(group)
                try await writeGroupSelection(
                    appModel, group: group, providerID: providerID, model: preference.model,
                    reasoningEffort: effort, serviceTier: preference.serviceTier
                )
            }
        )
    }

    /// Fast is not a flag of its own anywhere: it is `serviceTier == "priority"`,
    /// which is exactly what the Providers row's Fast toggle writes. Registering
    /// it as a boolean saves the agent from having to know that, while the value
    /// that lands is identical to the person's own click.
    private static func providerGroupFast(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_fast",
            page: "providers",
            label: "\(group.title) fast",
            kind: .boolean,
            note: "Only a model with a fast tier can be fast; others read false.",
            read: { _ in
                .bool(await currentPreference(surface: group.surfaces.first ?? group.id)?
                    .serviceTier == "priority")
            },
            write: { appModel, value in
                let enabled = try boolValue(value, "\(group.title) fast")
                let lead = group.surfaces.first ?? group.id
                guard let preference = await currentPreference(surface: lead),
                      !preference.model.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "\(group.title) has no model chosen yet, so there is nothing to make fast.")
                }
                let providers = await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                    .activeProvidersForSurfaces()
                let providerID = providers[lead] ?? "codex"
                // The same gate the row applies before it offers the toggle at
                // all (`selectedChoice?.supportsFast == true`). A route whose
                // catalog this build does not ship is not second-guessed.
                if enabled, let descriptor = routeDescriptor(preference.model, providerID: providerID),
                   !descriptor.supportsFast {
                    throw QuietSettingError.badValue(
                        "\(preference.model) does not offer a fast tier on \(providerID), so "
                        + "\(group.title) cannot be set fast. Choose a model that does.")
                }
                // Through the same helper as model and thinking: a loop of its
                // own bypassed the rollback, so a failure on the third surface
                // left the first two fast with a receipt that said nothing.
                try await writeGroupSelection(
                    appModel, group: group, providerID: providerID, model: preference.model,
                    reasoningEffort: preference.reasoningEffort,
                    serviceTier: enabled ? "priority" : "default"
                )
            }
        )
    }

    /// The accounts the Providers page's own account menu offers — every
    /// connected provider, by the same `auth_status.state == "ready"` test the
    /// menu applies; one whose last test failed for its key reads
    /// needs_reconnect. `app_settings_list` reports this list and the write
    /// enforces it, so the two are one list.
    @MainActor
    private static func connectedAccountIDs(_ appModel: (any QuietSettingsHost)?) async -> [String] {
        guard let appModel, let providers = try? await appModel.listQuietProviderAccounts() else { return [] }
        return providers
            .filter { $0.authState == "ready" }
            .map(\.id)
    }

    /// Which connected account a group runs on — the Providers row's account
    /// menu. Changing it must carry a model the NEW account serves, which is
    /// what the row's own `reconciledBrainForProvider` does; otherwise the group
    /// is left pointing at a model its route cannot run, the exact shape that
    /// made dreams unrunnable on a ChatGPT-only install.
    private static func providerGroupAccount(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_account",
            page: "providers",
            label: "\(group.title) account",
            kind: .choice,
            liveChoices: { await connectedAccountIDs($0()) },
            note: "Keeps the model when the new account serves it, else takes the account's first model.",
            read: { _ in
                let providers = await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                    .activeProvidersForSurfaces()
                return .string(providers[group.surfaces.first ?? group.id] ?? "")
            },
            write: { appModel, value in
                // Any non-empty string used to be accepted, which pinned the
                // group to an account that does not exist on this Mac. Only
                // the page's own connected accounts are.
                let connected = await connectedAccountIDs(appModel)
                guard !connected.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "No account is connected, so \(group.title) has nothing to run on. "
                        + "The person connects one in Providers.")
                }
                let account = try choiceValue(value, "\(group.title) account", connected)
                let lead = group.surfaces.first ?? group.id
                let preference = await currentPreference(surface: lead)
                let catalog = FirstPartyModelCatalog.models(forProviderID: account)
                let current = preference?.model ?? ""
                // No shipped catalog for this account (fetched, or one this
                // build has never seen): pin the account only, exactly as the
                // row does when it has no model list to reconcile against.
                guard !catalog.isEmpty else {
                    // This loop was the last one still writing the group a
                    // surface at a time: a failure on the third surface left
                    // the first two on the new account with no rollback. It
                    // goes through the same helper as every other group write,
                    // carrying the model the group is already on so the account
                    // moves and the model does not.
                    guard let preference else {
                        throw QuietSettingError.unavailable(
                            "\(group.title) has no model recorded to carry to \(account), and "
                            + "this build has no model list for that account.")
                    }
                    // Carrying a model the account cannot run left every reply
                    // on it failing. The account's fetched list decides; with
                    // no list there is nothing to check against, so no move.
                    let offered = await offeredModels(appModel, providerID: account).map(\.id)
                    guard !offered.isEmpty else {
                        throw QuietSettingError.unavailable(
                            "\(account)'s model list isn't loaded, so there's no telling whether it runs "
                            + "\(preference.model). Nothing was changed. Run provider.refresh first, "
                            + "then try again.")
                    }
                    guard offered.contains(preference.model) else {
                        throw QuietSettingError.badValue(
                            "\(account) doesn't offer \(preference.model), the model \(group.title) is on, so "
                            + "nothing was changed. \(account) offers: \(offered.joined(separator: ", ")). Set "
                            + "providers.\(group.id)_model to one of those the current account also runs, then "
                            + "move; if there is none, ask the owner to move it in Providers.")
                    }
                    try await writeGroupSelection(
                        appModel, group: group, providerID: account, model: preference.model,
                        reasoningEffort: preference.reasoningEffort,
                        serviceTier: preference.serviceTier
                    )
                    return
                }
                let descriptor = catalog.first { $0.id.lowercased() == current.lowercased() }
                    ?? catalog[0]
                let wanted = preference?.reasoningEffort ?? descriptor.defaultReasoningEffort
                let effort = descriptor.supportedReasoningEfforts.contains(wanted)
                    ? wanted
                    : descriptor.defaultReasoningEffort
                let fast = preference?.serviceTier == "priority" && descriptor.supportsFast
                // Through the same helper as every other group write, so a
                // failure halfway cannot leave half the group on a new account.
                try await writeGroupSelection(
                    appModel, group: group, providerID: account, model: descriptor.id,
                    reasoningEffort: effort, serviceTier: fast ? "priority" : "default"
                )
            }
        )
    }

    /// The account a group's lead surface runs on.
    private static func leadProvider(_ group: ProviderSurfaceGroup) async -> String {
        let providers = await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
            .activeProvidersForSurfaces()
        return providers[group.surfaces.first ?? group.id] ?? "codex"
    }

    /// The models an account offers, each with the thinking levels it takes —
    /// the list the Providers page and the composer pick from. Empty when the
    /// account's list could not be read.
    @MainActor
    private static func offeredModels(
        _ appModel: (any QuietSettingsHost)?, providerID: String
    ) async -> [QuietProviderModel] {
        guard let appModel, let accounts = try? await appModel.listQuietProviderAccounts() else { return [] }
        return accounts.first { $0.id == providerID }?.models ?? []
    }

    /// The Think menu beside a group's model on the Providers page. A saved
    /// model the account does not list keeps only its own level, as the page
    /// shows it.
    @MainActor
    private static func groupEfforts(
        _ group: ProviderSurfaceGroup, _ appModel: (any QuietSettingsHost)?
    ) async -> [String] {
        guard let preference = await currentPreference(surface: group.surfaces.first ?? group.id),
              !preference.model.isEmpty else { return [] }
        let offered = await offeredModels(appModel, providerID: await leadProvider(group))
        return offered.first { $0.id == preference.model }?.efforts ?? [preference.reasoningEffort]
    }

    /// The composer's Think menu: the levels Chat's own model takes, or the
    /// composer's fallback when the model is not in its account's list
    /// (`ChatComposerSettings.efforts`).
    @MainActor
    private static func chatEfforts(_ appModel: (any QuietSettingsHost)?) async -> [String] {
        guard let appModel else { return [] }
        let offered = await offeredModels(appModel, providerID: appModel.chatProvider)
        return offered.first { $0.id == appModel.chatModel }?.efforts ?? ["low", "medium", "high", "xhigh"]
    }

    /// A thinking level the model actually takes. The refusal names the levels
    /// and where a model with others is chosen.
    private static func effortValue(
        _ value: JSONValue, _ label: String, _ choices: [String], model: String, modelSetting: String
    ) throws -> String {
        do {
            return try choiceValue(value, label, choices)
        } catch {
            throw QuietSettingError.badValue(
                "\(label) takes one of: \(choices.joined(separator: ", ")) — the levels \(model) offers. "
                + "For another level, choose a model that has it in \(modelSetting).")
        }
    }

    private static func routeDescriptor(
        _ model: String, providerID: String
    ) -> FirstPartyModelDescriptor? {
        let catalog = FirstPartyModelCatalog.models(forProviderID: providerID)
        guard !catalog.isEmpty else { return nil }
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.first { $0.id.lowercased() == id }
    }

    private static func currentPreference(surface: String) async -> SurfacePreference? {
        let routing = SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
        guard let snapshot = try? await routing.checkedRoutingSnapshot() else { return nil }
        return snapshot.preferences[surface]
    }

    // MARK: - Bots

    /// A bot's cadence, in one line the model can both read and write:
    /// `manual`, `interval:900`, or `cron:<zone>:<expression>`. Zones carry no
    /// colon and the expression is last, so the three-way split is unambiguous.
    public static func cadenceText(_ cadence: BotCadence) -> String {
        switch cadence {
        case .manual: return "manual"
        case .interval(let seconds):
            if let rounded = Int(exactly: seconds.rounded()) { return "interval:\(rounded)" }
            return "interval:\(seconds)"
        case .cron(let expression, let timeZone): return "cron:\(timeZone):\(expression)"
        }
    }

    public static func parseCadence(_ raw: String, _ label: String) throws -> BotCadence {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare("manual") == .orderedSame { return .manual }
        if text.lowercased().hasPrefix("interval:") {
            let tail = String(text.dropFirst("interval:".count)).trimmingCharacters(in: .whitespaces)
            guard let seconds = Double(tail), seconds.isFinite, seconds > 0,
                  Int(exactly: seconds.rounded()) != nil else {
                throw QuietSettingError.badValue("\(label): interval takes positive seconds below \(Int.max), as interval:900.")
            }
            return .interval(seconds: seconds)
        }
        if text.lowercased().hasPrefix("cron:") {
            let tail = String(text.dropFirst("cron:".count))
            let parts = tail.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw QuietSettingError.badValue(
                    "\(label): cron takes cron:<zone>:<expression>, as cron:Europe/London:0 7 * * *.")
            }
            let zone = parts[0].trimmingCharacters(in: .whitespaces)
            let expression = parts[1].trimmingCharacters(in: .whitespaces)
            guard TimeZone(identifier: zone) != nil else {
                throw QuietSettingError.badValue("\(label): \(zone) is not a time zone.")
            }
            return .cron(expression: expression, timeZone: zone)
        }
        throw QuietSettingError.badValue(
            "\(label) takes manual, interval:<seconds>, or cron:<zone>:<expression>.")
    }

    @MainActor
    private static func botStore(_ appModel: any QuietSettingsHost) -> BotDefinitionStore {
        BotDefinitionStore(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    /// One cadence row and one paused row per bot that exists right now.
    ///
    /// Bots are made and deleted while the app runs, so this part of the
    /// registry cannot be a compile-time list. It is still a registry and not
    /// reflection: each row names one bot by id and carries the same two store
    /// calls the Bots page makes (`update`, `pause`). A bot that has been
    /// deleted simply has no rows, which is the honest answer to "can I change
    /// its schedule".
    @MainActor
    private static func botRows(_ appModel: (any QuietSettingsHost)?) -> [QuietSetting] {
        guard let appModel,
              let bots = try? botStore(appModel).list() else { return [] }
        return bots.flatMap { bot -> [QuietSetting] in
            let key = bot.id.uuidString.lowercased()
            let name = bot.name
            return [
                QuietSetting(
                    id: "bots.\(key).cadence",
                    page: "bots",
                    label: "\(name) schedule",
                    kind: .text,
                    note: "manual, interval:<seconds>, or cron:<zone>:<expression>. Scheduled runs "
                        + "may be no closer together than the bot floor "
                        + "(bots.minimum_interval_minutes), which the store enforces.",
                    read: { appModel in
                        guard let current = try? botStore(appModel).get(bot.id) else { return .string("") }
                        return .string(cadenceText(current.cadence))
                    },
                    write: { appModel, value in
                        let text = try stringValue(value, "\(name) schedule")
                        let store = botStore(appModel)
                        // Read fresh: `update` refuses a definition edited from
                        // a stale read, so the row must not carry the snapshot
                        // it was listed with.
                        var edited = try store.get(bot.id)
                        edited.cadence = try parseCadence(text, "\(name) schedule")
                        _ = try store.update(edited)
                    }
                ),
                QuietSetting(
                    id: "bots.\(key).paused",
                    page: "bots",
                    label: "\(name) paused",
                    kind: .boolean,
                    note: "Paused stops scheduled turns. Follow-ups and run-once still work.",
                    read: { appModel in
                        guard let current = try? botStore(appModel).get(bot.id) else { return .bool(false) }
                        return .bool(current.paused)
                    },
                    write: { appModel, value in
                        _ = try botStore(appModel).pause(
                            bot.id, paused: try boolValue(value, "\(name) paused"))
                    }
                ),
            ]
        }
    }

    // MARK: - Personality

    /// One of the profile's free-form lists, written through the same
    /// `savePersonality` the Personality page uses. The whole profile is the
    /// unit of write, so the read has to come from the loaded profile and a
    /// write with none loaded refuses rather than inventing one.
    private static func personalityList(
        id: String,
        label: String,
        note: String,
        get: @escaping @Sendable (PersonalityProfile) -> [String]?,
        set: @escaping @Sendable (inout PersonalityProfile, [String]) -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "personality", label: label, kind: .list, note: note,
            read: { appModel in
                guard let profile = appModel.personality else { return .array([]) }
                return .array((get(profile) ?? []).map { .string($0) })
            },
            write: { appModel, value in
                let lines = try listValue(value, label)
                guard var profile = appModel.personality else {
                    throw QuietSettingError.unavailable(
                        "The personality profile has not loaded yet, so \(label.lowercased()) cannot be changed.")
                }
                set(&profile, lines)
                // `savePersonality` swallows the persistence error, so this
                // returned ok with changed:false when nothing had been saved.
                // The throwing form makes the receipt say failed, with the old
                // value still standing.
                do {
                    try await appModel.savePersonalityChecked(profile)
                } catch {
                    throw QuietSettingError.unavailable(
                        "\(label) was not saved: \(error.localizedDescription)")
                }
            }
        )
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
        rows.append(QuietSetting(
            id: "chat.model", page: "chat", label: "Chat's own model",
            kind: .text,
            liveChoices: { host in
                guard let appModel = host() else { return [] }
                return await offeredModels(appModel, providerID: appModel.chatProvider).map(\.id)
            },
            note: "Empty means Chat follows the Providers Chat group. Setting it here pins this surface only. "
                + "The choices are the models of the account Chat is on.",
            read: { appModel in .string(appModel.chatModel) },
            write: { appModel, value in
                let model = try stringValue(value, "Chat's own model")
                    .trimmingCharacters(in: .whitespaces)
                let offered = await offeredModels(appModel, providerID: appModel.chatProvider).map(\.id)
                if !model.isEmpty, !offered.isEmpty, !offered.contains(model) {
                    throw QuietSettingError.badValue(
                        "\(model) is not a model \(appModel.chatProvider), the account Chat is on, offers. "
                        + "Chat's own model takes one of: \(offered.joined(separator: ", ")), or empty to "
                        + "follow the Providers Chat group.")
                }
                appModel.chatModel = model
                try await settleChatBrain(appModel, "Chat's own model")
            }
        ))
        rows.append(QuietSetting(
            id: "chat.thinking", page: "chat", label: "Chat thinking",
            kind: .choice,
            liveChoices: { await chatEfforts($0()) },
            note: "The choices are the levels Chat's own model takes.",
            read: { appModel in .string(appModel.chatReasoningEffort) },
            write: { appModel, value in
                appModel.chatReasoningEffort = try effortValue(
                    value, "Chat thinking", await chatEfforts(appModel),
                    model: appModel.chatModel.isEmpty ? "Chat's model" : appModel.chatModel,
                    modelSetting: "chat.model")
                try await settleChatBrain(appModel, "Chat thinking")
            }
        ))
        rows.append(QuietSetting(
            id: "chat.fast_mode", page: "chat", label: "Chat fast mode",
            kind: .boolean,
            read: { appModel in .bool(appModel.chatFastMode) },
            write: { appModel, value in
                appModel.chatFastMode = try boolValue(value, "Chat fast mode")
                try await settleChatBrain(appModel, "Chat fast mode")
            }
        ))
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
            // The Settings stepper's range and default, so a size written here
            // is one Settings can show (0 read as "0 tokens" there).
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

        // ── Providers ───────────────────────────────────────────────────────
        for group in ProviderSurfaceGroups.all {
            rows.append(providerGroupModel(group))
            rows.append(providerGroupEffort(group))
            rows.append(providerGroupFast(group))
            rows.append(providerGroupAccount(group))
            rows.append(providerGroupUseChat(group))
        }
        for pin in surfacePins {
            rows.append(providerGroupModel(pin))
            rows.append(providerGroupEffort(pin))
            rows.append(providerGroupAccount(pin))
        }

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
            choices: TrustPolicyPreset.quietWritable.map(\.quietID),
            note: "Safe, Work mode and Builder — the same three buttons the Trust page shows, "
                + "applied through the page's own preset action. Full Mac is not one of them: "
                + "turning Full Mac ON is the person's alone, whatever mode this Mac is in.",
            read: { appModel in
                guard let policy = appModel.trustPolicy else { return .string("") }
                let preset = TrustPolicyPreset.allCases.first {
                    $0.plan.permissionLevel == policy.permissionLevel
                        && $0.plan.outsideDefault == (policy.filePolicy?.outsideWorkspaceDefault ?? "")
                }
                return .string(preset?.quietID ?? "")
            },
            write: { appModel, value in
                let choices = TrustPolicyPreset.quietWritable.map(\.quietID)
                let wanted = try choiceValue(value, "Trust preset", choices)
                guard let preset = TrustPolicyPreset.quietWritable.first(where: { $0.quietID == wanted }) else {
                    throw QuietSettingError.badValue("Trust preset takes one of: \(choices.joined(separator: ", ")).")
                }
                // The page's own action, which writes every axis of the preset
                // in one patch. It is called without the Full Mac
                // confirmation, so a plan that needs one is refused here
                // rather than applied — the fence the agent cannot move.
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
                // Full Mac was checked before this write was dispatched, and
                // the old write then sent back every axis of the CACHED policy
                // — permission level and outside-workspace default included —
                // so a posture the person lowered in the meantime was restored
                // to Full Mac by a developer-mode toggle. The patch is now the
                // one field, and the Full Mac check is re-run inside the same
                // locked generation the patch merges into.
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

        // ── Notifications ───────────────────────────────────────────────────
        rows.append(defaultsBool(
            id: "notifications.bots_on_rail", page: "bots",
            label: "Show Bots on the rail", key: BotsShelfPreference.key, defaultOn: true
        ))
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
            // A blanket `true` here said every delivery leaves a receipt, and
            // naming the inbox card for Telegram said every Telegram delivery
            // has one. A successful Telegram send returns receipt nil
            // (AttentionRouter) and the direct router users
            // (NativeCognitionRuntime+Notify shoulder tap) mirror no card, so
            // the honest answer names what each channel actually records.
            read: { _ in
                .string(
                    "phone=paired-device receipt; "
                    + "telegram=router ledger entry, no device receipt, inbox card only when "
                    + "the caller wrote one; "
                    + "mac=banner posted or not, no device receipt")
            }
        ))

        // ── Personality / memories ──────────────────────────────────────────
        rows.append(defaultsBool(
            id: "personality.self_improvement", page: "settings",
            label: "Weekly self-improvement pass", key: "selfImprovementEnabled", defaultOn: true
        ))
        rows.append(QuietSetting(
            id: "personality.dreams", page: "settings", label: "Dreams at night",
            kind: .boolean,
            note: "One switch over two policy gates (personalityPolicy.dream_cycle_enabled and "
                + "trainingPolicy.dream_scheduler), which move together. The read-back is the "
                + "composite, so it says whether dreams can actually run.",
            read: { appModel in .bool(await appModel.dreamEnabled()) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Dreams at night")
                guard await appModel.setDreamCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The dream setting could not be saved.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "personality.rem_cycle", page: "settings",
            label: "Weekly dream consolidation", kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Weekly dream consolidation")
                guard await appModel.setRemCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The weekly consolidation setting could not be saved.")
                }
            }
        ))
        // Phase 5 D experiment. Off leaves every opinion and interest stored
        // but inert: nothing forms, surfaces, or reaches a prompt.
        rows.append(liveBool(
            id: "personality.views_experiment", page: "personality",
            label: "Opinions and interests (experiment)",
            key: NativeCognitionRuntime.viewsExperimentKey, defaultOn: true,
            note: "Views that come back on their own on different days become opinions of yours, with "
                + "why and what would change your mind; what you explore in your hour becomes an "
                + "interest that fades unless you return to it. Off: nothing new forms or surfaces.",
            apply: { appModel, enabled in await appModel.setCognitionLane(.viewsExperiment, enabled: enabled) }
        ))
        rows.append(QuietSetting(
            id: "personality.rem_approval_mode", page: "personality",
            label: "REM approval", kind: .text,
            note: "Always manual, and not a setting: every REM proposal is staged for approval "
                + "before it changes a memory. There is no automatic mode to switch to. Shown "
                + "here so the agent can say why a REM run produced proposals and not changes.",
            read: { _ in .string("manual") }
        ))
        rows.append(personalityList(
            id: "personality.instincts", label: "Instincts",
            note: "Free-form lines on the profile. Send the whole list you want — adding and "
                + "removing are the same write.",
            get: { $0.instincts }, set: { $0.instincts = $1 }
        ))
        rows.append(personalityList(
            id: "personality.boundaries", label: "Boundaries",
            note: "Free-form lines on the profile.",
            get: { $0.boundaries }, set: { $0.boundaries = $1 }
        ))
        rows.append(personalityList(
            id: "personality.examples", label: "Examples",
            note: "Free-form lines on the profile.",
            get: { $0.examples }, set: { $0.examples = $1 }
        ))
        rows.append(personalityList(
            id: "personality.forbidden_patterns", label: "Forbidden patterns",
            note: "Free-form lines on the profile.",
            get: { $0.forbiddenPatterns }, set: { $0.forbiddenPatterns = $1 }
        ))
        rows.append(QuietSetting(
            id: "personality.studio_shelf_slots", page: "personality",
            label: "Studio shelf slots in use", kind: .number,
            note: "The shelf holds at most three slots and that cap is fixed, not a setting. The "
                + "slots themselves are written as one complete ordered list by app studio.shelf_set, "
                + "not one at a time, so this is the count only.",
            read: { appModel in
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let slots = (try? StudioWorkingShelf(dataRoot: root).selections()) ?? []
                return .int(Int64(slots.count))
            }
        ))
        rows.append(QuietSetting(
            id: "memories.knowledge_graph", page: "settings", label: "Knowledge graph",
            kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Knowledge graph")
                guard await appModel.patchMemoryPolicy(
                    knowledgeGraphEnabled: enabled, adaptivePromotion: nil, hygieneEnabled: nil) else {
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
            id: "memories.consolidation", page: "settings", label: "Memory consolidation",
            kind: .boolean,
            note: "Once a week, what keeps coming up is gathered into fewer, stronger memories offered "
                + "for review. Off also stops keeping consolidated memories without asking, as on the page.",
            read: { appModel in .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).consolidation_enabled) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Memory consolidation")
                try await saveMemoryPolicy(
                    appModel, "Memory consolidation", field: "consolidation_enabled", enabled: enabled,
                    expecting: \.consolidation_enabled)
            }
        ))
        rows.append(QuietSetting(
            id: "memories.auto_keep_consolidated", page: "settings",
            label: "Keep consolidated memories without asking", kind: .boolean,
            note: "What the consolidation pass gathers goes in without asking first. A merge only "
                + "archives the memories it replaces, never deletes them, and the whole pass waits "
                + "for the person's approval card. Needs memories.consolidation on.",
            read: { appModel in
                .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).auto_promote_consolidated)
            },
            write: { appModel, value in
                let enabled = try boolValue(value, "Keep consolidated memories without asking")
                try await saveMemoryPolicy(
                    appModel, "Keep consolidated memories without asking",
                    field: "auto_promote_consolidated", enabled: enabled,
                    expecting: \.auto_promote_consolidated)
            }
        ))
        rows.append(QuietSetting(
            id: "memories.recur_to_facts", page: "settings", label: "Memories that recur become facts",
            kind: .boolean,
            note: "What keeps coming back is proposed as a durable fact to accept.",
            read: { appModel in .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).adaptive_promotion) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Memories that recur become facts")
                guard await appModel.patchMemoryPolicy(
                    knowledgeGraphEnabled: nil, adaptivePromotion: enabled, hygieneEnabled: nil) else {
                    throw QuietSettingError.unavailable(
                        "The memory policy write did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "memories.hygiene", page: "settings", label: "Memory hygiene",
            kind: .boolean,
            note: "Tidies old, noisy and duplicate memories on a schedule.",
            read: { appModel in .bool((appModel.trustPolicy?.memoryPolicy ?? TrustMemoryPolicy()).hygiene_enabled) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Memory hygiene")
                guard await appModel.patchMemoryPolicy(
                    knowledgeGraphEnabled: nil, adaptivePromotion: nil, hygieneEnabled: enabled) else {
                    throw QuietSettingError.unavailable(
                        "The memory policy write did not take. Check \(AppToolExecutor.doorDoctor), then try again.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "personality.name", page: "personality", label: "Name",
            kind: .text,
            note: "The name the app shows and the agent goes by. A generic label is refused.",
            read: { appModel in .string(appModel.personality?.name ?? "") },
            write: { appModel, value in
                let name = try stringValue(value, "Name")
                if let problem = await appModel.savePersonalityName(name) {
                    throw QuietSettingError.badValue("The name was not saved: \(problem)")
                }
            }
        ))

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
        rows.append(defaultsBool(
            id: "settings.moments_lane", page: "settings",
            label: "Moments I keep", key: "momentsLaneEnabled", defaultOn: true,
            note: "Small things that happened between us; I pick which stay."
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

        rows.append(QuietSetting(
            id: "settings.display_timezone", page: "settings",
            label: "The clock the app speaks in", kind: .text,
            note: "An IANA zone (Europe/London). Empty means this Mac's own zone, which is what "
                + "shipped. Display only: it changes the times shown on the bots card, Today and "
                + "the morning brief's date line, and never when anything runs.",
            read: { _ in .string(DisplayTimeZone.identifier()) },
            write: { _, value in
                let raw = try stringValue(value, "The clock the app speaks in")
                    .trimmingCharacters(in: .whitespaces)
                guard raw.isEmpty || TimeZone(identifier: raw) != nil else {
                    throw QuietSettingError.badValue(
                        "\(raw) is not an IANA time zone. Empty follows this Mac.")
                }
                UserDefaults.standard.set(raw, forKey: DisplayTimeZone.key)
            }
        ))

        // ── Desk ────────────────────────────────────────────────────────────
        rows.append(QuietSetting(
            id: "desk.timeline", page: "trust", label: "Show the Desk timeline",
            kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.workshopPolicy?.showTimeline ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Show the Desk timeline")
                // The page's save (`saveWorkshopPolicyToggle`) re-sends the
                // cached posture beside this field. The one-field patch lands
                // in the same policy through the same writer, and cannot carry
                // a stale posture back with it.
                let saved: TrustPolicy
                do {
                    saved = try await TrustPolicyToolWriter.applyTrustPolicyPatch(
                        body: [WorkshopPolicyBlockVocabulary.wireKey: ["showTimeline": enabled]],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                    )
                } catch {
                    throw QuietSettingError.unavailable(
                        "Show the Desk timeline was not saved: \(error.localizedDescription). "
                        + "Check \(AppToolExecutor.doorDoctor), then try again.")
                }
                appModel.applySavedTrustPolicy(saved, status: "Desk execution policy saved")
            }
        ).onTab("features"))
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
                    throw QuietSettingError.badValue(
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
        rows.append(QuietSetting(
            id: "notifications.watched_folders", page: "notifications",
            label: "Folders watched", kind: .list,
            note: "The folders the file_watch trigger watches, one path each. Send the whole list.",
            read: { appModel in
                guard let triggers = try? await appModel.inboxTriggers() else { return .null }
                let paths = triggers.first { $0.name == "file_watch" }?.paths ?? []
                return .array(paths.map { .string($0) })
            },
            write: { appModel, value in
                let paths = try listValue(value, "Folders watched")
                do {
                    try await appModel.saveWatchedFolders(paths)
                } catch {
                    throw QuietSettingError.unavailable(
                        "The watched folders were not saved: \(error.localizedDescription). Check each "
                        + "path is a folder that exists.")
                }
            }
        ))

        // ── Bots ────────────────────────────────────────────────────────────
        rows.append(QuietSetting(
            id: "bots.minimum_interval_minutes", page: "bots",
            label: "Closest a bot may run", kind: .number,
            note: "1 to 15 minutes; 15 when unset. The floor every bot cadence is held to. "
                + "The person's, by the same rule the bot tools follow: no bot tool sets it.",
            ownerOnly: true,
            read: { _ in
                .int(Int64((BotRunLimits.minimumInterval / 60).rounded()))
            }
        ))

        rows.append(QuietSetting(
            id: "capabilities.image_model", page: "capabilities",
            label: "Image model", kind: .text,
            note: "Read-back only, because there is nothing to set: the image model is derived "
                + "from whichever account the Work group runs on, and a route that serves no "
                + "image model refuses image generation rather than substituting one. Change it "
                + "by changing providers.work_account.",
            read: { _ in
                let routing = SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                let active = await routing.activeProvidersForSurfaces()
                // The Work group's first resolved account, the same order the
                // image tools walk.
                let provider = ProviderSurfaceGroups.work.surfaces
                    .compactMap { active[$0] }
                    .first { !$0.isEmpty }
                guard let provider,
                      let route = FirstPartyModelCatalog.imageRoute(forProviderID: provider) else {
                    return .string("")
                }
                return .string(route.model)
            }
        ))

        return rows
    }()

    /// The compile-time rows, the rows that exist only because a bot does, and
    /// the lower-only switches whose state only the app can reach.
    @MainActor
    public static func all(host: (any QuietSettingsHost)?) -> [QuietSetting] {
        staticRows + botRows(host) + (host?.lowerOnlyRows ?? [])
    }

    @MainActor
    public static func settings(forPage page: String, host: (any QuietSettingsHost)?) -> [QuietSetting] {
        all(host: host).filter { $0.page == page }
    }

    @MainActor
    public static func setting(id: String, host: (any QuietSettingsHost)?) -> QuietSetting? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = all(host: host)
        return rows.first { $0.id.lowercased() == key }
            ?? rows.first { $0.label.lowercased() == key }
    }
}
