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
// Blueprint: | `QuietSettings+Models.swift` | Group model/account/effort transactions retain inheritance |

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
        serviceTier: String,
        context: QuietSettingWrite
    ) async throws {
        let result = try await writeProviderGroup(appModel, group: group, providerID: providerID,
            model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier, clearOverride: false, context: context)
        context.detail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
    }

    @MainActor private static func writeProviderGroup(
        _ appModel: any QuietSettingsHost, group: ProviderSurfaceGroup, providerID: String?,
        model: String?, reasoningEffort: String?, serviceTier: String?, clearOverride: Bool, context: QuietSettingWrite
    ) async throws -> ProviderGroupWriteResult {
        do {
            let result = try await appModel.saveProviderGroupSelection(
                group: group, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
                serviceTier: serviceTier, clearOverride: clearOverride
            )
            context.detail.record("undo_unavailable", .string("""
                This receipt's old value does not contain the group's previous model choices; set those choices explicitly to restore them.
                """))
            return result
        } catch let failure as ProviderGroupWriteFailure {
            context.detail.record("surfaces_changed", .null)
            context.detail.record("forward_intent", failure.forwardIntent)
            context.detail.record("intent_status", .string(failure.intentStatus))
            context.detail.record("projections_committed", .array(failure.projectionsCommitted.map(JSONValue.string)))
            context.detail.record("projections_pending", .array(failure.projectionsPending.map(JSONValue.string)))
            context.detail.record("projections_unknown", .array(failure.projectionsUnknown.map(JSONValue.string)))
            context.detail.record("surfaces_pending_recovery", .array(failure.surfacesPendingRecovery.map { .string($0) }))
            throw failure
        }
    }

    /// Clearing a group override restores Chat inheritance atomically across all non-Chat members via the routing snapshot.
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
                let snapshot = try await SwiftNativeProviderRouting(
                    dataRoot: PersistenceCore.defaultDataRoot()).checkedRoutingSnapshot()
                return .bool(!hasOwnChoice(snapshot))
            },
            write: { appModel, value, context in
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
                    reasoningEffort: nil, serviceTier: nil, clearOverride: true, context: context
                )
                context.detail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// Telegram and studio hour are single-member groups so they share all-or-nothing group writes; reflection uses Memory and mind.
    private static let surfacePins: [ProviderSurfaceGroup] = [
        ProviderSurfaceGroup(id: "telegram", title: "Telegram", members: [.init("telegram", "Telegram")]),
        ProviderSurfaceGroup(
            id: "wander_hour", title: "My hour",
            members: [.init(NativeCognitionRuntime.studioWanderSurface, "My hour")]),
    ]

    /// Each provider group writes every surface it owns, matching the page's requestSetGroupSelection transaction.
    private static func providerGroupModel(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_model",
            page: "providers",
            label: "\(group.title) model",
            kind: .text,
            liveChoices: { host in
                try await offeredModels(host(), providerID: try await leadProvider(group)).map(\.id)
            },
            note: "Covers \(group.surfaces.joined(separator: ", ")). Another account's models need providers.\(group.id)_account first.",
            read: { _ in
                guard let preference = try await currentPreference(surface: group.surfaces.first ?? group.id) else {
                    return .string("")
                }
                return .string(preference.model)
            },
            write: { appModel, value, context in
                let model = try stringValue(value, "\(group.title) model")
                    .trimmingCharacters(in: .whitespaces)
                guard !model.isEmpty else {
                    throw QuietSettingError.badValue("\(group.title) model takes a model id.")
                }
                let lead = group.surfaces.first ?? group.id
                guard let preference = try await currentPreference(surface: lead) else {
                    throw QuietSettingError.unavailable("""
                        \(group.title)'s current choice is unavailable. Choose its account, model and controls together in Providers.
                        """)
                }
                let providerID = try await leadProvider(group)
                let effort = preference.reasoningEffort
                let tier = preference.serviceTier
                let offered = try await offeredModels(appModel, providerID: providerID)
                guard !offered.isEmpty else {
                    throw QuietSettingError.unavailable("\(providerID)'s model catalog is unavailable. Refresh it in Providers before changing models.")
                }
                guard let choice = offered.first(where: { $0.id == model }) else {
                    throw QuietSettingError.badValue(
                        "\(model) is not a model \(providerID) offers. \(group.title) model takes one "
                        + "of: \(offered.map(\.id).joined(separator: ", ")). For another account's "
                        + "models, set providers.\(group.id)_account first.")
                }
                guard choice.reasoningCapabilitiesKnown else {
                    throw QuietSettingError.unavailable("""
                        \(model)'s thinking capabilities have not been read. Refresh its provider catalog before changing this model.
                        """)
                }
                guard choice.efforts.contains(effort)
                    || (providerID == "openrouter" && choice.efforts.isEmpty && (effort.isEmpty || effort == "default")) else {
                    throw QuietSettingError.badValue("""
                        \(model) does not support the saved Think level '\(effort)'. Choose model and controls together in Providers; no setting changed.
                        """)
                }
                if tier == "priority", !choice.supportsFast {
                    throw QuietSettingError.badValue("""
                        \(model) does not support the saved Fast choice. Choose model and controls together in Providers; no setting changed.
                        """)
                }
                try await writeGroupSelection(
                    appModel, group: group, providerID: providerID, model: model,
                    reasoningEffort: effort, serviceTier: tier, context: context
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
            liveChoices: { try await groupEfforts(group, $0()) },
            read: { _ in .string(try await currentPreference(surface: group.surfaces.first ?? group.id)?.reasoningEffort ?? "") },
            write: { appModel, value, context in
                let lead = group.surfaces.first ?? group.id
                guard let preference = try await currentPreference(surface: lead), !preference.model.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "\(group.title) has no model chosen yet, so there is no thinking level to set. "
                        + "Set providers.\(group.id)_model first.")
                }
                let effort = try effortValue(
                    value, "\(group.title) thinking", try await groupEfforts(group, appModel),
                    model: preference.model, modelSetting: "providers.\(group.id)_model")
                let result = try await writeProviderGroup(
                    appModel, group: group, providerID: nil, model: nil,
                    reasoningEffort: effort, serviceTier: nil, clearOverride: false, context: context
                )
                context.detail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// Fast projects serviceTier == priority as a boolean so the agent and page use the same persisted choice.
    private static func providerGroupFast(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_fast",
            page: "providers",
            label: "\(group.title) fast",
            kind: .boolean,
            note: "Only a model with a fast tier can be fast; others read false.",
            read: { _ in
                .bool(try await currentPreference(surface: group.surfaces.first ?? group.id)?
                    .serviceTier == "priority")
            },
            write: { appModel, value, context in
                let enabled = try boolValue(value, "\(group.title) fast")
                let lead = group.surfaces.first ?? group.id
                let routing = SwiftNativeProviderRouting(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                let snapshot = try await routing.checkedRoutingSnapshot()
                guard let preference = snapshot.preferences[lead], !preference.model.isEmpty,
                      let providerID = snapshot.activeProviders[lead] else {
                    throw QuietSettingError.unavailable("\(group.title)'s model and account are unavailable. Choose them in Providers.")
                }
                if enabled {
                    let catalog = try routing.checkedCatalogModels(for: providerID)
                    guard let model = catalog.first(where: { $0.id == preference.model }),
                          let fast = model.supports_fast else {
                        throw QuietSettingError.unavailable("""
                            Fast capability for \(preference.model) on \(providerID) is unknown. Refresh its models in Providers.
                            """)
                    }
                    guard fast else {
                        throw QuietSettingError.badValue("""
                            \(preference.model) does not offer a fast tier on \(providerID). Choose a model that does in Providers.
                            """)
                    }
                }
                // A tier change is a partial transaction: the resolved model and account checked above are not new selections.
                let result = try await writeProviderGroup(
                    appModel, group: group, providerID: nil, model: nil,
                    reasoningEffort: nil, serviceTier: enabled ? "priority" : "default",
                    clearOverride: false, context: context
                )
                context.detail.record("surfaces_changed", .array(result.surfacesChanged.map { .string($0) }))
            }
        )
    }

    /// Account choices and validation share the Providers menu's eligibility rules; rejected keys remain needs_key.
    @MainActor
    private static func connectedAccountIDs(_ appModel: (any QuietSettingsHost)?) async throws -> [String] {
        guard let appModel else { throw QuietSettingError.unavailable("The provider settings owner is unavailable. Open Providers again.") }
        let providers = try await appModel.listQuietProviderAccounts()
        return providers
            .filter(\.eligible)
            .map(\.id)
    }

    /// Reconcile a group's connected account and served model in one transaction.
    private static func providerGroupAccount(_ group: ProviderSurfaceGroup) -> QuietSetting {
        QuietSetting(
            id: "providers.\(group.id)_account",
            page: "providers",
            label: "\(group.title) account",
            kind: .choice,
            liveChoices: { try await connectedAccountIDs($0()) },
            note: "Keeps the chosen model, Think and Fast only if the new account supports that exact choice; otherwise choose the full choice in Providers.",
            read: { _ in
                let providers = try await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
                    .activeProvidersForSurfacesChecked()
                return .string(providers[group.surfaces.first ?? group.id] ?? "")
            },
            write: { appModel, value, context in
                // Reject accounts the page does not offer.
                let connected = try await connectedAccountIDs(appModel)
                guard !connected.isEmpty else {
                    throw QuietSettingError.unavailable(
                        "No account is connected, so \(group.title) has nothing to run on. "
                        + "The person connects one in Providers.")
                }
                let account = try choiceValue(value, "\(group.title) account", connected)
                let routing = SwiftNativeProviderRouting(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                let catalog = try routing.checkedCatalogModels(for: account)
                let snapshot = try await routing.checkedRoutingSnapshot()
                let lead = group.surfaces.first ?? group.id
                guard let preference = snapshot.preferences[lead], !preference.model.isEmpty else {
                    throw QuietSettingError.unavailable("\(group.title) has no model selected. Choose its account and model together in Providers.")
                }
                guard let model = catalog.first(where: { $0.id == preference.model }) else {
                    throw QuietSettingError.badValue("""
                        \(account) does not offer \(preference.model). Choose the account and model together in Providers; no setting changed.
                        """)
                }
                guard let efforts = model.supported_reasoning_efforts else {
                    throw QuietSettingError.unavailable("Think controls for \(preference.model) on \(account) are unknown. Refresh its models in Providers.")
                }
                guard efforts.contains(preference.reasoningEffort)
                    || (account == "openrouter" && efforts.isEmpty && (preference.reasoningEffort.isEmpty || preference.reasoningEffort == "default")) else {
                    throw QuietSettingError.badValue("""
                        Think level '\(preference.reasoningEffort)' is unsupported for \(preference.model) on \(account). Choose a supported level in \
                        Providers; no setting changed.
                        """)
                }
                if preference.serviceTier == "priority", model.supports_fast != true {
                    throw QuietSettingError.badValue("""
                        Fast is unsupported or unknown for \(preference.model) on \(account). Choose a supported tier in Providers; no setting changed.
                        """)
                }
                try await writeGroupSelection(
                    appModel, group: group, providerID: account, model: preference.model,
                    reasoningEffort: preference.reasoningEffort, serviceTier: preference.serviceTier, context: context
                )
            }
        )
    }

    private static func leadProvider(_ group: ProviderSurfaceGroup) async throws -> String {
        let providers = try await SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
            .activeProvidersForSurfacesChecked()
        guard let provider = providers[group.surfaces.first ?? group.id], !provider.isEmpty else {
            throw QuietSettingError.unavailable("\(group.title)'s account is unavailable. Choose it in Providers.")
        }
        return provider
    }

    /// Model choices require the account's checked catalog.
    @MainActor
    private static func offeredModels(
        _ appModel: (any QuietSettingsHost)?, providerID: String
    ) async throws -> [QuietProviderModel] {
        guard let appModel else { throw QuietSettingError.unavailable("The provider settings owner is unavailable. Open Providers again.") }
        let accounts = try await appModel.listQuietProviderAccounts()
        guard let account = accounts.first(where: { $0.id == providerID }) else {
            throw QuietSettingError.unavailable("\(providerID)'s account is not in the checked provider catalog. Read Providers and refresh its accounts.")
        }
        return account.models
    }

    /// The Think menu contains the selected model's checked descriptor. A missing descriptor is unavailable; a declared empty list offers no levels.
    @MainActor
    private static func groupEfforts(
        _ group: ProviderSurfaceGroup, _ appModel: (any QuietSettingsHost)?
    ) async throws -> [String] {
        guard let preference = try await currentPreference(surface: group.surfaces.first ?? group.id),
              !preference.model.isEmpty else { return [] }
        let offered = try await offeredModels(appModel, providerID: try await leadProvider(group))
        guard let model = offered.first(where: { $0.id == preference.model }), model.reasoningCapabilitiesKnown else {
            throw QuietSettingError.unavailable("\(preference.model)'s capabilities are unavailable. Refresh its provider catalog before changing thinking.")
        }
        return model.efforts
    }

    /// Only the selected model's declared thinking levels may appear in the menu.
    @MainActor
    private static func chatEfforts(_ appModel: (any QuietSettingsHost)?) async throws -> [String] {
        guard let appModel else { throw QuietSettingError.unavailable("The chat settings owner is unavailable. Open Chat again.") }
        let offered = try await offeredModels(appModel, providerID: appModel.chatProvider)
        guard let model = offered.first(where: { $0.id == appModel.chatModel }), model.reasoningCapabilitiesKnown else {
            throw QuietSettingError.unavailable("\(appModel.chatModel)'s capabilities are unavailable. Refresh its provider catalog before changing thinking.")
        }
        return model.efforts
    }

    /// Thinking refusals name supported levels and the control for choosing another model.
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

    private static func currentPreference(surface: String) async throws -> SurfacePreference? {
        let routing = SwiftNativeProviderRouting(dataRoot: PersistenceCore.defaultDataRoot())
        let snapshot = try await routing.checkedRoutingSnapshot()
        return snapshot.preferences[surface]
    }

    static let chatModelRows: [QuietSetting] = {
        var rows: [QuietSetting] = []
        rows.append(QuietSetting(
            id: "chat.model", page: "chat", label: "Chat's own model",
            kind: .text,
            liveChoices: { host in
                guard let appModel = host() else { return [] }
                return try await offeredModels(appModel, providerID: appModel.chatProvider).map(\.id)
            },
            note: "Empty means Chat follows the Providers Chat group. Setting it here pins this surface only. "
                + "The choices are the models of the account Chat is on.",
            read: { appModel in .string(appModel.chatModel) },
            write: { appModel, value, context in
                let model = try stringValue(value, "Chat's own model")
                    .trimmingCharacters(in: .whitespaces)
                let offered = try await offeredModels(appModel, providerID: appModel.chatProvider).map(\.id)
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
            liveChoices: { try await chatEfforts($0()) },
            note: "The choices are the levels Chat's own model takes.",
            read: { appModel in .string(appModel.chatReasoningEffort) },
            write: { appModel, value, context in
                appModel.chatReasoningEffort = try effortValue(
                    value, "Chat thinking", try await chatEfforts(appModel),
                    model: appModel.chatModel.isEmpty ? "Chat's model" : appModel.chatModel,
                    modelSetting: "chat.model")
                try await settleChatBrain(appModel, "Chat thinking")
            }
        ))
        rows.append(QuietSetting(
            id: "chat.fast_mode", page: "chat", label: "Chat fast mode",
            kind: .boolean,
            read: { appModel in .bool(appModel.chatFastMode) },
            write: { appModel, value, context in
                appModel.chatFastMode = try boolValue(value, "Chat fast mode")
                try await settleChatBrain(appModel, "Chat fast mode")
            }
        ))
        return rows
    }()

    static let providerRows: [QuietSetting] = {
        var rows: [QuietSetting] = []
        rows.append(QuietSetting(
            id: "providers.routing_repair", page: "providers", label: "Reconstruct provider routing", kind: .text,
            note: """
                Read the three BaseHash values and preserved source bytes (base64). Set JSON text with those same hashes and complete surfaces and active \
                objects, including Chat. Choose every model/account explicitly; omitted overrides are removed. Original bytes are retained by digest. No \
                credentials change.
                """,
            read: { host in
                do {
                    let input = try await SwiftNativeProviderRouting(dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()).routingRepairInput()
                    return .string(try input.serialize(pretty: false))
                } catch { return .string(error.localizedDescription) }
            },
            write: { host, value, context in
                let input = try JSONValue.parse(Data(try stringValue(value, "Provider routing reconstruction").utf8))
                try await SwiftNativeProviderRouting(dataRoot: host.dataRootOverride ?? PersistenceCore.defaultDataRoot()).reconstructRouting(input)
                context.detail.record("undo_unavailable", .string("""
                    Original routing bytes are retained beside each file by digest; reconstruct explicitly to restore them.
                    """))
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
            let active = try await routing.activeProvidersForSurfacesChecked()
            // Work resolves its first account in the same order as image tools.
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
