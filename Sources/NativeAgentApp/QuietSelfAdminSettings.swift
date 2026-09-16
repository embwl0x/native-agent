import Foundation
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import StandingBots

enum QuietSettingError: Error, LocalizedError {
    case badValue(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .badValue(let detail): return detail
        case .unavailable(let detail): return detail
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
enum QuietWriteDetail {
    private static var pending: [String: JSONValue] = [:]

    static func begin() { pending = [:] }

    static func record(_ key: String, _ value: JSONValue) { pending[key] = value }

    static func take() -> [String: JSONValue] {
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
struct QuietSetting: Sendable {
    enum Kind: String, Sendable {
        case boolean, text, choice, number
        /// An ordered list of lines. Read back as an array; written as an array,
        /// or as one string of newline-separated lines. Add and remove are the
        /// same operation — send the list you want.
        case list
    }

    let id: String
    let page: String
    let label: String
    let kind: Kind
    /// Non-empty for `.choice`. Stated in the catalog so a set never has to
    /// discover the allowed values by being refused.
    let choices: [String]
    /// Choices that only exist at run time — the accounts this Mac has
    /// actually connected. The catalog reports exactly what the write
    /// enforces, out of one closure, so a set can never be refused for a value
    /// `app_settings_list` had just offered.
    let liveChoices: (@MainActor @Sendable () async -> [String])?
    let note: String
    /// The person's own posture. These READ like any other setting and refuse
    /// to be written, saying why — the agent widening its own authority is the
    /// one thing self-administration must not be able to do.
    let ownerOnly: Bool
    /// Writable only while this Mac is in Full Mac, which is wide open by
    /// User's own word (2026-09-13): there the agent may lower the fence,
    /// receipted like anything else. Below Full Mac it reads and refuses. The
    /// one move no posture opens is RAISING to Full Mac.
    let fullMacOnly: Bool
    let read: @MainActor @Sendable (AppModel) async -> JSONValue
    let write: (@MainActor @Sendable (AppModel, JSONValue) async throws -> Void)?

    init(
        id: String,
        page: String,
        label: String,
        kind: Kind,
        choices: [String] = [],
        liveChoices: (@MainActor @Sendable () async -> [String])? = nil,
        note: String = "",
        ownerOnly: Bool = false,
        fullMacOnly: Bool = false,
        read: @escaping @MainActor @Sendable (AppModel) async -> JSONValue,
        write: (@MainActor @Sendable (AppModel, JSONValue) async throws -> Void)? = nil
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
        self.write = write
    }

    /// Whether a set would be accepted RIGHT NOW. `fullMac` is the posture read
    /// fresh off the saved policy, so the catalog's `writable` and the answer
    /// `app_setting_set` gives are one answer.
    func writable(fullMac: Bool) -> Bool {
        guard !ownerOnly, write != nil else { return false }
        return fullMac || !fullMacOnly
    }

    func catalogRow(fullMac: Bool) async -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id),
            "page": .string(page),
            "label": .string(label),
            "type": .string(kind.rawValue),
            "writable": .bool(writable(fullMac: fullMac)),
        ]
        let offered = await (liveChoices?() ?? choices)
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

enum QuietSettings {
    /// What a Trust posture entry says below Full Mac. It names the one line
    /// that never moves: the agent may lower its own fence, never raise it.
    static let belowFullMacRefusal =
        "Trust posture is read-only unless this Mac is already in Full Mac. Full Mac is wide open "
        + "and the agent may change these there — but only the person can turn on Full Mac."

    static let ownerOnlyRefusal =
        "This one is the person's to set. It decides what the agent is allowed to do, "
        + "so the agent can read it and report it but never change it. Ask them to set it in the app."

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
        case .int(let number): return Int(number)
        case .double(let number) where number.isFinite: return Int(number)
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
    private static func settleChatBrain(_ appModel: AppModel, _ label: String) async throws {
        switch await appModel.saveChatBrainDefaults() {
        case .saved, .unchanged:
            return
        case .failed(let message, _):
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

    /// Read-only mirror of a Trust posture control. Present so the agent can
    /// SAY what the posture is — an agent that cannot read the fence cannot
    /// explain why it just refused something.
    private static func posture(
        id: String, label: String, note: String = "",
        read: @escaping @MainActor @Sendable (AppModel) async -> JSONValue
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
        read: @escaping @MainActor @Sendable (AppModel) async -> JSONValue,
        write: @escaping @MainActor @Sendable (AppModel, JSONValue) async throws -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "trust", label: label, kind: kind, choices: choices,
            note: note, fullMacOnly: true, read: read, write: write
        )
    }

    /// The loaded policy, or a refusal. Every Trust write below starts from the
    /// policy as READ — a write that invents the fields it did not read is how
    /// a posture change loses an axis nobody was editing.
    @MainActor
    private static func loadedTrustPolicy(_ appModel: AppModel, _ label: String) throws -> TrustPolicy {
        guard let policy = appModel.trustPolicy else {
            throw QuietSettingError.unavailable(
                "The Trust policy has not loaded yet, so \(label.lowercased()) cannot be changed.")
        }
        return policy
    }

    /// One Mac-control verb, written through the page's own policy writer.
    private static func macControlVerb(
        id: String, label: String,
        get: @escaping @Sendable (TrustMacControlPolicy) -> Bool,
        set: @escaping @Sendable (inout TrustMacControlPolicy, Bool) -> Void
    ) -> QuietSetting {
        fullMacPosture(
            id: "trust.mac_control_\(id)", label: label, kind: .boolean,
            note: "Part of the Mac control policy. Written as one whole policy, the same way "
                + "the Mac Control page saves it.",
            read: { appModel in .bool((appModel.trustPolicy?.macControlPolicy).map(get) ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, label)
                let policy = try loadedTrustPolicy(appModel, label)
                guard var next = policy.macControlPolicy else {
                    throw QuietSettingError.unavailable(
                        "The Trust policy carries no Mac control block, so \(label.lowercased()) "
                        + "cannot be changed.")
                }
                set(&next, enabled)
                try await saveMacControl(appModel, next, label)
            }
        )
    }

    /// The Mac Control page's own save, with its outcome checked rather than
    /// assumed (`MacControlPermissionsView.save`).
    @MainActor
    private static func saveMacControl(
        _ appModel: AppModel, _ policy: TrustMacControlPolicy, _ label: String
    ) async throws {
        do {
            let saved = try await appModel.saveMacControlPolicy(policy)
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

    /// One group choice, written to every surface the group covers — all of
    /// them or none of them.
    ///
    /// Writing the members one transaction at a time is how a failure halfway
    /// through left Chat on the new model and Memory on the old one, with a
    /// receipt that mentioned neither. The Providers page restores every
    /// surface it had already written when one fails
    /// (`ProviderSettingsView.saveGroupSelection`); this does the same, off the
    /// snapshot taken before the first write, and records the surfaces that
    /// really changed for the receipt.
    @MainActor
    private static func writeGroupSelection(
        _ appModel: AppModel,
        group: ProviderSurfaceGroup,
        providerID: String,
        model: String,
        reasoningEffort: String,
        serviceTier: String
    ) async throws {
        let routing = SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
        // The rollback IS this snapshot. `try?` here meant an unreadable
        // routing file produced `before == nil`, every previously pinned
        // surface then read as "was inheriting", and the rollback CLEARED
        // those pins and reported them rolled back. Nothing is written until
        // there is something to put back.
        let before: ProviderRoutingSnapshot
        do {
            before = try await routing.checkedRoutingSnapshot()
        } catch {
            throw QuietSettingError.unavailable(
                "The provider routing in use could not be read, so nothing was changed and "
                + "nothing could be put back: \(error.localizedDescription)")
        }
        var written: [String] = []
        do {
            for surface in group.surfaces {
                _ = try await appModel.configureSurfaceSelection(
                    surface: surface,
                    providerID: providerID,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    serviceTier: serviceTier
                )
                written.append(surface)
            }
        } catch {
            // A restore can fail too, and `try?` used to swallow that: every
            // surface it had attempted was then reported rolled back, so a
            // receipt could say surfaces_changed: [] while a surface was still
            // sitting on the new model. Each restore is now recorded for what
            // it did, and the receipt carries both lists.
            var restored: [String] = []
            var stillChanged: [String] = []
            for surface in written.reversed() {
                let wasPinned = !(ProviderRoutingSurfaceLookup.value(
                    before.pinnedModels, surface) ?? "").isEmpty
                do {
                    if wasPinned {
                        // Restoring a pin needs the snapshot taken before the
                        // first write. Without it there is nothing to put back,
                        // so the surface is honestly still changed.
                        guard let prior = before.preferences[surface] else {
                            stillChanged.append(surface)
                            continue
                        }
                        _ = try await appModel.configureSurfaceSelection(
                            surface: surface,
                            providerID: before.activeProviders[surface] ?? providerID,
                            model: prior.model,
                            reasoningEffort: prior.reasoningEffort,
                            serviceTier: prior.serviceTier
                        )
                    } else {
                        // It was inheriting before this attempt; leave it inheriting.
                        try await appModel.clearSurfaceOverride(surface: surface)
                    }
                    restored.append(surface)
                } catch {
                    stillChanged.append(surface)
                }
            }
            QuietWriteDetail.record(
                "surfaces_changed", .array(stillChanged.reversed().map { .string($0) }))
            QuietWriteDetail.record(
                "surfaces_rolled_back", .array(restored.reversed().map { .string($0) }))
            throw error
        }
        QuietWriteDetail.record("surfaces_changed", .array(written.map { .string($0) }))
    }

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
            note: "Covers \(group.surfaces.joined(separator: ", ")). "
                + "The model id must be one the connected account offers.",
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
                let providers = await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                    .activeProvidersForSurfaces()
                let providerID = providers[lead] ?? "codex"
                try await writeGroupSelection(
                    appModel, group: group, providerID: providerID, model: model,
                    reasoningEffort: preference?.reasoningEffort ?? "high",
                    serviceTier: preference?.serviceTier ?? "default"
                )
            }
        )
    }

    private static func providerGroupEffort(_ group: ProviderSurfaceGroup) -> QuietSetting {
        let choices = ["minimal", "low", "medium", "high"]
        return QuietSetting(
            id: "providers.\(group.id)_thinking",
            page: "providers",
            label: "\(group.title) thinking",
            kind: .choice,
            choices: choices,
            note: "How hard the \(group.title) group thinks. The model must support the effort.",
            read: { _ in .string(await currentPreference(surface: group.surfaces.first ?? group.id)?.reasoningEffort ?? "") },
            write: { appModel, value in
                let effort = try choiceValue(value, "\(group.title) thinking", choices)
                let lead = group.surfaces.first ?? group.id
                guard let preference = await currentPreference(surface: lead), !preference.model.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "\(group.title) has no model chosen yet, so there is no thinking level to set.")
                }
                let providers = await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                    .activeProvidersForSurfaces()
                let providerID = providers[lead] ?? "codex"
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
            note: "Only a model whose catalog offers the fast tier can be set fast. The read-back "
                + "is the resolved value, so a model without it reads false.",
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
    /// menu applies. `app_settings_list` reports this list and the write
    /// enforces it, so the two are one list.
    @MainActor
    private static func connectedAccountIDs(_ appModel: AppModel?) async -> [String] {
        guard let appModel, let providers = try? await appModel.listProviders() else { return [] }
        return providers
            .filter { $0.auth_status.state == "ready" }
            .map(\.provider_id)
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
            liveChoices: { await connectedAccountIDs(QuietSelfAdmin.shared.appModel) },
            note: "The connected account these surfaces run on, from the same menu the page "
                + "offers — an account that is not connected is not one of them. Changing it "
                + "keeps the current model when that account serves it, and otherwise moves to "
                + "the first model the account offers.",
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
    static func cadenceText(_ cadence: BotCadence) -> String {
        switch cadence {
        case .manual: return "manual"
        case .interval(let seconds): return "interval:\(Int(seconds.rounded()))"
        case .cron(let expression, let timeZone): return "cron:\(timeZone):\(expression)"
        }
    }

    static func parseCadence(_ raw: String, _ label: String) throws -> BotCadence {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare("manual") == .orderedSame { return .manual }
        if text.lowercased().hasPrefix("interval:") {
            let tail = String(text.dropFirst("interval:".count)).trimmingCharacters(in: .whitespaces)
            guard let seconds = Double(tail), seconds.isFinite, seconds > 0 else {
                throw QuietSettingError.badValue("\(label): interval takes seconds, as interval:900.")
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
    private static func botStore(_ appModel: AppModel) -> BotDefinitionStore {
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
    private static func botRows(_ appModel: AppModel?) -> [QuietSetting] {
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
                + "feeling, damped over hours. Off leaves dark mode exactly as it is."
        ))
        rows.append(QuietSetting(
            id: "chat.model", page: "chat", label: "Chat's own model",
            kind: .text,
            note: "Empty means Chat follows the Providers Chat group. Setting it here pins this surface only.",
            read: { appModel in .string(appModel.chatModel) },
            write: { appModel, value in
                appModel.chatModel = try stringValue(value, "Chat's own model")
                    .trimmingCharacters(in: .whitespaces)
                try await settleChatBrain(appModel, "Chat's own model")
            }
        ))
        rows.append(QuietSetting(
            id: "chat.thinking", page: "chat", label: "Chat thinking",
            kind: .choice, choices: ["minimal", "low", "medium", "high"],
            read: { appModel in .string(appModel.chatReasoningEffort) },
            write: { appModel, value in
                appModel.chatReasoningEffort = try choiceValue(
                    value, "Chat thinking", ["minimal", "low", "medium", "high"])
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
            note: "Speaks new replies through the speakers. voice_render is the silent path and does not touch this."
        ))
        rows.append(defaultsInt(
            id: "chat.compaction_threshold_tokens", page: "chat",
            label: "Compaction threshold (tokens)", key: "nativeagent.compactionThresholdTokens",
            fallback: 0, minimum: 0, maximum: 1_000_000,
            note: "0 means the built-in default."
        ))

        rows.append(defaultsBool(
            id: "chat.quiet_mode", page: "chat",
            label: "Quiet mode (no audio out)", key: VoicePreference.quietKey,
            note: "On, nothing is ever spoken through the speakers, whatever else is set. "
                + "It is enforced at the one place both voice routes pass through, so it holds "
                + "for read-aloud and for anything added later. voice_render still writes files."
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
        }

        // ── Trust (read everything, change nothing that widens authority) ────
        rows.append(posture(
            id: "trust.permission_level", label: "Permission level",
            note: "strict and locked_down are Safe; balanced is Work; wide_open_receipts and "
                + "full_mac_os are Builder and Full Mac. Read-only as an axis of its own — the "
                + "level moves with the whole preset, so trust.preset is what changes it, and "
                + "only while this Mac is already in Full Mac.",
            read: { appModel in .string(appModel.trustPolicy?.permissionLevel ?? "") }
        ))
        rows.append(posture(
            id: "trust.agent_access_mode", label: "Agent access",
            read: { appModel in
                guard let policy = appModel.trustPolicy else { return .string("") }
                return .string(AppModel.agentAccessMode(from: policy))
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
                // The page's own action. It is called without the Full Mac
                // confirmation, so a plan that needs one is refused here rather
                // than applied — the fence the agent cannot move.
                switch await TrustPolicyPresetAction.apply(preset, appModel: appModel) {
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
                // The page's own writer. It swallows its failure into
                // statusText, so the saved policy is what is checked.
                await appModel.saveEnableAutonomy(enabled)
                guard appModel.trustPolicy?.enableAutonomy == enabled else {
                    throw QuietSettingError.unavailable(
                        "Unattended work was not saved: \(appModel.statusText)")
                }
            }
        ))
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
                    saved = try await NativeClient.applyTrustPolicyPatch(
                        body: ["developerMode": enabled],
                        dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
                        guardedByLockedPolicy: { locked in
                            guard AppChatToolDispatcher.lockedPolicyIsFullMac(locked) else {
                                throw QuietSettingError.unavailable(belowFullMacRefusal)
                            }
                        }
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
                let policy = try loadedTrustPolicy(appModel, "Mac control")
                var next = policy.macControlPolicy ?? TrustMacControlPolicy()
                next.enabled = enabled
                try await saveMacControl(appModel, next, "Mac control")
            }
        ))
        rows.append(macControlVerb(
            id: "applescript", label: "Mac control: AppleScript",
            get: { $0.applesScriptAllowed }, set: { $0.applesScriptAllowed = $1 }))
        rows.append(macControlVerb(
            id: "jxa", label: "Mac control: JXA",
            get: { $0.jxaAllowed }, set: { $0.jxaAllowed = $1 }))
        rows.append(macControlVerb(
            id: "shortcuts", label: "Mac control: Shortcuts",
            get: { $0.shortcutsAllowed }, set: { $0.shortcutsAllowed = $1 }))
        rows.append(macControlVerb(
            id: "accessibility", label: "Mac control: Accessibility",
            get: { $0.accessibilityAllowed }, set: { $0.accessibilityAllowed = $1 }))
        rows.append(macControlVerb(
            id: "system_control", label: "Mac control: System control",
            get: { $0.systemControlAllowed }, set: { $0.systemControlAllowed = $1 }))
        rows.append(macControlVerb(
            id: "file_ops", label: "Mac control: File operations",
            get: { $0.fileOpsAllowed }, set: { $0.fileOpsAllowed = $1 }))
        rows.append(macControlVerb(
            id: "shell", label: "Mac control: Shell",
            get: { $0.shellAllowed }, set: { $0.shellAllowed = $1 }))
        rows.append(macControlVerb(
            id: "notifications", label: "Mac control: Notifications",
            get: { $0.notificationsAllowed }, set: { $0.notificationsAllowed = $1 }))
        rows.append(macControlVerb(
            id: "spotlight", label: "Mac control: Spotlight",
            get: { $0.spotlightAllowed }, set: { $0.spotlightAllowed = $1 }))
        rows.append(macControlVerb(
            id: "remote_from_iphone", label: "Mac control: Remote from iPhone",
            get: { $0.remoteFromIosAllowed }, set: { $0.remoteFromIosAllowed = $1 }))
        rows.append(posture(
            id: "trust.outside_workspace_files", label: "Files outside the workspace",
            read: { appModel in .string(appModel.trustPolicy?.filePolicy?.outsideWorkspaceDefault ?? "") }
        ))
        rows.append(QuietSetting(
            id: "trust.cloud_voice", page: "trust", label: "Use the cloud voice for reading aloud",
            kind: .boolean,
            note: "Off reads with the Mac voice. This is the route, not whether anything is spoken.",
            read: { appModel in .bool(appModel.trustPolicy?.multimodalPolicy?.tts_openai ?? false) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Use the cloud voice for reading aloud")
                // The same two steps the Trust page's own toggle takes
                // (TrustPermissionsViews.saveVoiceOutputPolicy): the loaded
                // policy is the only base, so a write can never invent the
                // five multimodal fields it did not read.
                guard var next = appModel.trustPolicy?.multimodalPolicy else {
                    throw QuietSettingError.unavailable(
                        "The Trust policy has not loaded yet, so the voice route cannot be changed.")
                }
                next.tts_openai = enabled
                guard await appModel.saveMultimodalPolicy(next) else {
                    throw QuietSettingError.unavailable("The Trust policy write did not take.")
                }
            }
        ))
        for integration in MacIntegrationID.all {
            let name = MacIntegrationID.displayName(for: integration)
            rows.append(QuietSetting(
                id: "trust.mac_integration_\(integration)", page: "trust",
                label: "\(name) access", kind: .text,
                note: "Reported as read and write. Granting a Mac service is the person's.",
                ownerOnly: true,
                read: { _ in
                    let store = MacIntegrationPermissionStore.shared
                    let canRead = await store.allows(integration, mode: .read)
                    let canWrite = await store.allows(integration, mode: .write)
                    return .string("read=\(canRead) write=\(canWrite)")
                }
            ))
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
            id: "personality.self_improvement", page: "personality",
            label: "Personal growth runs on its own", key: "selfImprovementEnabled"
        ))
        rows.append(QuietSetting(
            id: "personality.dreams", page: "personality", label: "Dreams at night",
            kind: .boolean,
            note: "One switch over two policy gates (personalityPolicy.dream_cycle_enabled and "
                + "trainingPolicy.dream_scheduler), which move together. The read-back is the "
                + "composite, so it says whether dreams can actually run.",
            read: { appModel in .bool(await appModel.client.swiftDreamCompositeEnabled()) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Dreams at night")
                guard await appModel.setDreamCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The dream setting could not be saved.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "personality.rem_cycle", page: "personality",
            label: "Weekly dream consolidation (REM)", kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Weekly dream consolidation (REM)")
                guard await appModel.setRemCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The weekly consolidation setting could not be saved.")
                }
            }
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
                + "slots themselves are written as one complete ordered list by studio_shelf_set, "
                + "not one at a time, so this is the count only.",
            read: { appModel in
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let slots = (try? StudioWorkingShelf(dataRoot: root).selections()) ?? []
                return .int(Int64(slots.count))
            }
        ))
        rows.append(QuietSetting(
            id: "memories.knowledge_graph", page: "memories", label: "Knowledge graph",
            kind: .boolean,
            read: { appModel in .bool(appModel.trustPolicy?.memoryPolicy?.knowledge_graph_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Knowledge graph")
                guard await appModel.patchMemoryPolicy(knowledgeGraphEnabled: enabled) else {
                    throw QuietSettingError.unavailable("The memory policy write did not take.")
                }
            }
        ))

        // ── Settings ────────────────────────────────────────────────────────
        rows.append(defaultsBool(
            id: "settings.dark_mode", page: "settings",
            label: "Dark appearance", key: "nativeagent.darkMode"
        ))
        rows.append(defaultsBool(
            id: "settings.classic_sidebar", page: "settings",
            label: "Use the classic sidebar", key: NativeAgentShellPreference.classicShellKey
        ))
        rows.append(defaultsBool(
            id: "settings.developer_surfaces", page: "settings",
            label: "Show developer surfaces", key: "showDeveloperSurfaces"
        ))
        rows.append(defaultsBool(
            id: "settings.global_hotkey", page: "settings",
            label: "Global hotkey", key: "globalHotkeyEnabled"
        ))
        rows.append(defaultsBool(
            id: "settings.show_tour", page: "settings",
            label: "Show the tour", key: "nativeagent.showTour"
        ))
        rows.append(defaultsBool(
            id: "settings.inner_life", page: "settings",
            label: "An inner life", key: "cognitiveSubstrateEnabled", defaultOn: true
        ))
        rows.append(defaultsBool(
            id: "settings.inner_life_capsule", page: "settings",
            label: "Inner life in the chat header", key: "cognitiveSubstrateCapsuleEnabled"
        ))
        rows.append(defaultsBool(
            id: "settings.inner_life_background", page: "settings",
            label: "Inner life keeps running in the background", key: "cognitiveSubstrateBackgroundEnabled"
        ))
        rows.append(defaultsBool(
            id: "settings.reflection", page: "settings",
            label: "Reflection", key: "cognitiveSubstrateReflectionEnabled"
        ))
        rows.append(defaultsInt(
            id: "settings.daily_reflection_budget", page: "settings",
            label: "Daily reflection budget", key: "cognitiveSubstrateDailyReflectionBudget",
            fallback: 0, minimum: 0, maximum: 500
        ))
        rows.append(defaultsBool(
            id: "settings.organism_kernel", page: "settings",
            label: "Organism kernel", key: "organismKernelEnabled"
        ))
        rows.append(defaultsChoice(
            id: "settings.memory_in_every_reply", page: "settings",
            label: "Memory in every reply", key: "contextFlowMode",
            choices: ["off", "fast", "full"], fallback: "fast"
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

        // ── Capabilities / diagnostics ──────────────────────────────────────
        rows.append(defaultsBool(
            id: "capabilities.show_mcp_builder", page: "capabilities",
            label: "Show the MCP builder", key: "capabilitiesShowMCPBuilder"
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

    /// The compile-time rows plus the rows that exist only because a bot does.
    @MainActor
    static var all: [QuietSetting] {
        staticRows + botRows(QuietSelfAdmin.shared.appModel)
    }

    @MainActor
    static func settings(forPage page: String) -> [QuietSetting] {
        all.filter { $0.page == page }
    }

    @MainActor
    static func setting(id: String) -> QuietSetting? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = all
        return rows.first { $0.id.lowercased() == key }
            ?? rows.first { $0.label.lowercased() == key }
    }
}
