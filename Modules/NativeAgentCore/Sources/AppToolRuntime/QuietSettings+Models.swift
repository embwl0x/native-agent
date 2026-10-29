import Cognition
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import AgentConversations
import AuthoredCapabilities
import ChatToolRuntime
import MacIntegration
import PersonaEngine
import Senses
import ToolRegistry
import MultimodalTTS
import ChatSessionWork
import Context
import AttentionRouting
import DeviceSync
import TrustCenter
import AgentWorkspace
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
import Studio
// Blueprint: | `QuietSettings+Models.swift` | QuietSettings model/account/effort choices and provider-group transactions; thinking and fast writes preserve model/account inheritance |

extension QuietSettings {
    /// Wait for the chat brain's saved outcome before reporting the setting as changed.
    @MainActor
    private static func settleChatBrain(_ appModel: any QuietSettingsHost, _ label: String) async throws {
        if let message = await appModel.saveChatBrainDefaultsFailure() {
            throw QuietSettingError.unavailable("\(label) was not saved: \(message)")
        }
    }

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
            let result = try await appModel.saveProviderGroupSelection(
                group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
                serviceTier: serviceTier, clearOverride: clearOverride
            )
            QuietWriteDetail.record("undo_unavailable", .string("This receipt's old value does not contain the group's previous model choices; set those choices explicitly to restore them."))
            return result
        } catch let failure as ProviderGroupWriteFailure {
            QuietWriteDetail.record("surfaces_changed", failure.surfacesPendingRecovery.isEmpty ? .array([]) : .null)
            QuietWriteDetail.record("surfaces_rolled_back", .array(failure.surfacesRolledBack.map { .string($0) }))
            QuietWriteDetail.record("surfaces_pending_recovery", .array(failure.surfacesPendingRecovery.map { .string($0) }))
            throw failure
        }
    }

    /// The row's "Use Chat's choice" (`ProviderSettingsView.clearGroupOverride`): every member but Chat itself drops its own pick and
    /// follows Chat again, all of them or none. Model/account inheritance is owned by the routing snapshot.
    private static func providerGroupUseChat(_ group: ProviderSurfaceGroup) -> QuietSetting {
        let label = "\(group.title): use Chat's choice"
        @Sendable func hasOwnChoice(_ snapshot: ProviderRoutingSnapshot) -> Bool {
            group.surfaces.contains { $0 != "chat" && snapshot.modelOverrideSurfaces.contains($0) }
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

    /// The two activities that keep a model of their own outside the Providers page: the Telegram page's Model, and the Settings picker for
    /// my hour (`SetupStudioWanderPicker`). Each is a one-member group, so it is pinned through the same rows and the same all-or-nothing
    /// write as a whole group. (The Settings reflection picker is not here: it writes the whole Memory and mind group, which
    /// providers.memory_and_mind_* is.)
    private static let surfacePins: [ProviderSurfaceGroup] = [
        ProviderSurfaceGroup(id: "telegram", title: "Telegram", members: [.init("telegram", "Telegram")]),
        ProviderSurfaceGroup(
            id: "her_hour", title: "My hour",
            members: [.init(NativeCognitionRuntime.studioWanderSurface, "My hour")]),
    ]

    /// The three activity groups are the whole of the Providers page's model choice (`ProviderSurfaceGroups`), and a group's pick is
    /// written to every surface it claims — exactly what `requestSetGroupSelection` does when a person changes the picker.
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
                // A fetched catalogue that has not loaded lists nothing, and its silence is not evidence against the id.
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
                let result = try await writeProviderGroup(
                    appModel, group: group, providerID: nil, model: nil,
                    reasoningEffort: effort, serviceTier: nil, clearOverride: false
                )
                QuietWriteDetail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// Fast is not a flag of its own anywhere: it is `serviceTier == "priority"`, which is exactly what the Providers row's Fast toggle
    /// writes. Registering it as a boolean saves the agent from having to know that, while the value that lands is identical to the
    /// person's own click.
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
                // The same gate the row applies before it offers the toggle at all (`selectedChoice?.supportsFast == true`). A route whose
                // catalog this build does not ship is not second-guessed.
                if enabled, let descriptor = routeDescriptor(preference.model, providerID: providerID),
                   !descriptor.supportsFast {
                    throw QuietSettingError.badValue(
                        "\(preference.model) does not offer a fast tier on \(providerID), so "
                        + "\(group.title) cannot be set fast. Choose a model that does.")
                }
                // A tier change is a partial transaction: the resolved model and account checked above are not new selections.
                let result = try await writeProviderGroup(
                    appModel, group: group, providerID: nil, model: nil,
                    reasoningEffort: nil, serviceTier: enabled ? "priority" : "default",
                    clearOverride: false
                )
                QuietWriteDetail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// The accounts the Providers page's own account menu offers — every eligible provider, by the same test the menu applies (a rejected
    /// key reads needs_key). `app_settings_list` reports this list and the write enforces it, so the two are one list.
    @MainActor
    private static func connectedAccountIDs(_ appModel: (any QuietSettingsHost)?) async -> [String] {
        guard let appModel, let providers = try? await appModel.listQuietProviderAccounts() else { return [] }
        return providers
            .filter(\.eligible)
            .map(\.id)
    }

    /// A group's connected account and a model that account serves, reconciled in one group transaction.
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
                // Accept only the page's connected accounts.
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
                // Without a shipped catalog, carry the current model only after checking the fetched list.
                guard !catalog.isEmpty else {
                    guard let preference else {
                        throw QuietSettingError.unavailable(
                            "\(group.title) has no model recorded to carry to \(account), and "
                            + "this build has no model list for that account.")
                    }
                    // An unloaded model list cannot confirm the account serves this model.
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
                // Through the same helper as every other group write, so a failure halfway cannot leave half the group on a new account.
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

    /// The models an account offers, each with the thinking levels it takes — the list the Providers page and the composer pick from. Empty
    /// when the account's list could not be read.
    @MainActor
    private static func offeredModels(
        _ appModel: (any QuietSettingsHost)?, providerID: String
    ) async -> [QuietProviderModel] {
        guard let appModel, let accounts = try? await appModel.listQuietProviderAccounts() else { return [] }
        return accounts.first { $0.id == providerID }?.models ?? []
    }

    /// The Think menu beside a group's model on the Providers page. A saved model the account does not list keeps only its own level, as
    /// the page shows it.
    @MainActor
    private static func groupEfforts(
        _ group: ProviderSurfaceGroup, _ appModel: (any QuietSettingsHost)?
    ) async -> [String] {
        guard let preference = await currentPreference(surface: group.surfaces.first ?? group.id),
              !preference.model.isEmpty else { return [] }
        let offered = await offeredModels(appModel, providerID: await leadProvider(group))
        return offered.first { $0.id == preference.model }?.efforts ?? [preference.reasoningEffort]
    }

    /// The composer's Think menu: the levels Chat's own model takes, or the composer's fallback when the model is not in its account's list
    /// (`ChatComposerSettings.efforts`).
    @MainActor
    private static func chatEfforts(_ appModel: (any QuietSettingsHost)?) async -> [String] {
        guard let appModel else { return [] }
        let offered = await offeredModels(appModel, providerID: appModel.chatProvider)
        return offered.first { $0.id == appModel.chatModel }?.efforts ?? ["low", "medium", "high", "xhigh"]
    }

    /// A thinking level the model actually takes. The refusal names the levels and where a model with others is chosen.
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

    static let chatModelRows: [QuietSetting] = {
        var rows: [QuietSetting] = []
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
        return rows
    }()

    static let providerRows: [QuietSetting] = {
        var rows: [QuietSetting] = []
        // ── Providers ───────────────────────────────────────────────────────
        rows.append(QuietSetting(
            id: "providers.routing_repair", page: "providers", label: "Reconstruct provider routing", kind: .text,
            note: "Read the three BaseHash values and preserved source bytes (base64). Set JSON text with those same hashes and complete surfaces and active objects, including Chat. Choose every model/account explicitly; omitted overrides are removed. Original bytes are retained by digest. No credentials change.",
            read: { host in
                do {
                    let input = try await SwiftNativeProviderRouting(dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()).routingRepairInput()
                    return .string(try input.serialize(pretty: false))
                } catch { return .string(error.localizedDescription) }
            },
            write: { host, value in
                let input = try JSONValue.parse(Data(try stringValue(value, "Provider routing reconstruction").utf8))
                try await SwiftNativeProviderRouting(dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()).reconstructRouting(input)
                QuietWriteDetail.record("undo_unavailable", .string("Original routing bytes are retained beside each file by digest; reconstruct explicitly to restore them."))
            }
        ))
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
        return rows
    }()

    static let imageModel = QuietSetting(
        id: "capabilities.image_model", page: "capabilities",
        label: "Image model", kind: .text,
        note: "Read-back only, because there is nothing to set: the image model is derived "
            + "from whichever account the Work group runs on, and a route that serves no "
            + "image model refuses image generation rather than substituting one. Change it "
            + "by changing providers.work_account.",
        read: { _ in
            let routing = SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
            let active = await routing.activeProvidersForSurfaces()
            // The Work group's first resolved account, the same order the image tools walk.
            let provider = ProviderSurfaceGroups.work.surfaces
                .compactMap { active[$0] }
                .first { !$0.isEmpty }
            guard let provider,
                  let route = FirstPartyModelCatalog.imageRoute(forProviderID: provider) else {
                return .string("")
            }
            return .string(route.model)
        }
    )
}
