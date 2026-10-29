import SwiftUI
import Foundation
import NativeAgentShared
import ProviderRouting
import EngineRuntime
import PersistenceCore
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import StandingBots
import AppKit
import AppToolRuntime
// Blueprint: | `ProviderActivityChoices.swift` | Grouped activity model choices and pending-write lifecycle use ProvidersFacade routing transactions and inline receipts |

/// Keep related choices together, stacking individual fields in narrow panes.
struct ModelChoiceRow<Provider: View, Model: View, Think: View, Fast: View>: View {
    @ViewBuilder var provider: () -> Provider
    @ViewBuilder var model: () -> Model
    @ViewBuilder var think: () -> Think
    @ViewBuilder var fast: () -> Fast

    private var identity: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Room for the account's display name and native menu chrome.
            field("Provider", content: provider).frame(width: 260)
            field("Model", content: model).frame(width: 150)
        }
    }
    private var options: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field("Think", content: think).frame(width: 90)
            fast().frame(minHeight: 24)
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 8) { identity; options }
            VStack(alignment: .leading, spacing: 6) { identity; options }
            VStack(alignment: .leading, spacing: 6) {
                field("Provider", content: provider)
                field("Model", content: model)
                field("Think", content: think)
                fast()
            }
        }
        .font(ShellType.rowDetail.weight(.medium))
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // SwiftUI's hierarchical .secondary is a fraction of primary and
            // cannot answer for itself on a card; the measured token can.
            Text(title).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Routing identifiers need explicit customer-facing names.
extension ProviderSurfaceLabel {
    var text: String {
        switch self {
        case .named(let label):
            return label
        case .unrecognized(let surface):
            return "Unrecognized activity (\(surface))"
        case .malformed:
            return "Activity name unavailable"
        }
    }
}

extension ProviderSettingsView {
    private var explicitSurfaces: Set<String> {
        appModel.engine.providers.settings.map { ProvidersFacade.explicitSurfaces(in: $0.routing) } ?? []
    }
    private var overrideReadFailed: Bool { appModel.engine.providers.settingsError != nil }
    /// Resolver reasons explain unusable saved picks without silently replacing their models.
    private var unusablePicks: [String: String] { appModel.engine.providers.settings?.routing.unusablePicks ?? [:] }
    struct SaveReceipt {
        let id = UUID()
        let text: String
    }

    private var surfaceGroups: [ProviderSurfaceGroup] {
        ProviderSurfaceGroups.rows(visible: surfaces)
    }

    /// What one surface currently routes to. Equality across a group's
    /// surfaces is what makes the group's row a single honest choice.
    private func selection(of surface: String) -> ProviderTurnChoice {
        pendingSelections[surface] ?? appModel.engine.providers.selection(for: surface)
    }

    private var surfaceSelections: [String: ProviderTurnChoice] {
        Dictionary(uniqueKeysWithValues: surfaces.map { ($0, selection(of: $0)) })
    }

    private var exceptionSummary: String {
        let chatChoice = selection(of: "chat")
        let different = surfaceGroups.filter { group in
            group.id != ProviderSurfaceGroups.chat.id
                && group.surfaces.contains { selection(of: $0) != chatChoice }
        }
        guard !different.isEmpty else { return "All activities match Chat" }
        let names = different.map(\.title).joined(separator: " and ")
        return names + (different.count == 1 ? " differs from Chat" : " differ from Chat")
    }

    /// Choices come from saved overrides or Chat; mismatches must not claim "Same as Chat".
    private func selectionOrigin(_ group: ProviderSurfaceGroup) -> String {
        if overrideReadFailed { return "Saved choice source unavailable" }
        if group.surfaces.contains(where: { explicitSurfaces.contains($0) }) { return "Custom choice" }
        if group.id == ProviderSurfaceGroups.chat.id { return "Chat's own route" }
        let chat = selection(of: "chat")
        return group.surfaces.allSatisfy { selection(of: $0) == chat } ? "Same as Chat" : "Built-in default"
    }

    /// "Chat, iPhone, Telegram and Slack" — the group's membership in the
    /// same words the rest of the app uses for those activities.
    static func listPhrase(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    private static let countWords = ["", "one", "two", "three", "four", "five", "six",
                                     "seven", "eight", "nine", "ten"]
    static func countPhrase(_ count: Int) -> String {
        count > 0 && count < countWords.count ? countWords[count] : String(count)
    }

    private func surfaceNames(_ surfaces: [String]) -> [String] {
        surfaces.map { ProviderSurfaceLabel.presentation(for: $0).text }
    }

    /// Name unavailable saved picks without substituting another model.
    private func retiredPickNotice(_ group: ProviderSurfaceGroup) -> String? {
        for surface in group.surfaces {
            if let problem = unusablePicks[surface] { return problem }
        }
        return nil
    }

    private func membershipCaption(_ group: ProviderSurfaceGroup, mixed: Bool) -> String {
        let all = Self.listPhrase(surfaceNames(group.surfaces))
        guard mixed else { return all }
        let lead = ProvidersFacade.leadSurface(group, selections: surfaceSelections)
        let leadChoice = selection(of: lead)
        let differing = group.surfaces.filter { selection(of: $0) != leadChoice }
        let leadName = ProviderSurfaceLabel.presentation(for: lead).text
        let names = Self.listPhrase(surfaceNames(differing))
        let verb = differing.count == 1 ? "differs" : "differ"
        let reach = "Choosing here sets all \(Self.countPhrase(group.surfaces.count))."
        guard !differing.isEmpty else { return all }
        return "Showing \(leadName)'s choice; \(names) \(verb). \(reach)"
    }
    private static let fallbackReasoningEfforts = ["low", "medium", "high", "xhigh"]

    private var catalogModels: [ModelCatalogItem] { appModel.engine.providers.catalog?.models ?? [] }
    var rowSet: ProviderSurfaceRowSet {
        appModel.engine.providers.settings?.rowSet ?? ProviderSurfaceRowSet(surfacePreferenceKeys: [], activeProviderKeys: [])
    }

    // Canonical row order exposes unregistered stored keys as a repair state.
    private var surfaces: [String] { rowSet.visibleSurfaces }

    /// Models offered for a surface, scoped to the provider selected for it.
    private func modelsForSurface(_ surface: String) -> [ProvidersFacade.SurfaceModelChoice] {
        let selected = selection(of: surface)
        let pid = selected.provider
        var choices = ProvidersFacade.modelsForProvider(pid, providers: providers, catalogModels: catalogModels)
        let current = selected.model
        // Retain saved models; only a live catalog proves one unavailable.
        if !current.isEmpty, !choices.contains(where: { $0.id == current }) {
            let unavailable = pendingSelections[surface] == nil && appModel.engine.providers.settings?.unavailableModels[surface] == true
            choices.insert(ProvidersFacade.SurfaceModelChoice(
                id: current,
                name: unavailable ? "\(current) — Unavailable" : current,
                defaultReasoningEffort: selected.reasoningEffort.isEmpty ? "high" : selected.reasoningEffort,
                supportedReasoningEfforts: [selected.reasoningEffort.isEmpty ? "high" : selected.reasoningEffort],
                supportsFast: false,
                isUnavailable: unavailable
            ), at: 0)
        }
        return choices
    }

    private func selectedModelChoice(for surface: String) -> ProvidersFacade.SurfaceModelChoice? {
        let choices = modelsForSurface(surface)
        let model = selection(of: surface).model
        return choices.first(where: { $0.id == model }) ?? choices.first
    }

    private func reasoningLabel(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "XHigh"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort.capitalized
        }
    }

    /// Provider options for the picker. Ready providers are selectable, and
    /// currently pinned providers stay visible even if auth needs repair.
    private var pickerProviders: [ProviderInfo] {
        ProvidersFacade.pickerProviders(providers, selections: surfaceSelections)
    }

    /// Activity choices stay visible beside account setup.
    @ViewBuilder
    var perSurfacePickerColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !rowSet.unsupportedStoredKeys.isEmpty {
                            ProviderNote(
                                text: "Saved settings need repair: " + rowSet.unsupportedStoredKeys.joined(separator: ", "),
                                color: NativeAgentShell.trouble
                            )
                        }
                        // Settings left by an earlier version are ignored and need nothing from
                        // the person, so the page does not name their internal keys.
                        if pickerProviders.isEmpty {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "Nothing to choose from yet",
                                    line: "Sign in to an account to choose a chat model."
                                )
                            }
                        } else {
                            AliveGroupCard {
                                ForEach(surfaceGroups.filter { $0.id == ProviderSurfaceGroups.chat.id }) { group in
                                    groupRow(group)
                                }
                            }
                        }
                    }
                }

                if !pickerProviders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(exceptionSummary).font(ShellType.caption).foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        // Every other surface in ONE card, hairlines between.
                        AliveGroupCard {
                            ForEach(surfaceGroups.filter { $0.id != ProviderSurfaceGroups.chat.id }) { group in
                                groupRow(group)
                            }
                        }
                    }
                    .font(ShellType.labelMedium)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
    }

    /// One group: its name, the account behind it, the model, how hard it
    /// thinks, and whether it runs on the priority tier. Each control writes
    /// its changed fields to every surface the group covers.
    @ViewBuilder
    private func groupRow(_ group: ProviderSurfaceGroup) -> some View {
        let lead = ProvidersFacade.leadSurface(group, selections: surfaceSelections)
        let selected = selection(of: lead)
        let isChatGroup = group.id == ProviderSurfaceGroups.chat.id
        let mixed = ProvidersFacade.groupIsMixed(group, selections: surfaceSelections, explicitSurfaces: explicitSurfaces)
        let saving = savingGroups.contains(group.id)
        let surfModels = modelsForSurface(lead)
        let selectedChoice = selectedModelChoice(for: lead)
        let supportedEfforts = selectedChoice?.supportedReasoningEfforts
            ?? Self.fallbackReasoningEfforts
        let clearable = ProvidersFacade.groupHasOverride(group, explicitSurfaces: explicitSurfaces)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(ShellType.rowTitle.weight(.semibold))
                .foregroundStyle(NativeAgentShell.text)
            if mixed {
                Text("Mixed").font(ShellType.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isChatGroup {
                Text(selectionOrigin(group)).font(ShellType.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if clearable, !overrideReadFailed {
                Button("Use Chat's choice") {
                    Task { await clearGroupOverride(group) }
                }
                .controlSize(.small)
                .disabled(isLoading || saving)
                .accessibilityLabel("Use Chat's choice for \(group.title)")
            }
            }
            // Membership is otherwise invisible: the row's name is a group,
            // and nothing else on the page says which activities it covers.
            Text(membershipCaption(group, mixed: mixed))
                .font(ShellType.caption).foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            // Retired model picks are named rather than silently replaced.
            if let gone = retiredPickNotice(group) {
                Text(gone)
                    .font(ShellType.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModelChoiceRow {
            Menu {
                ForEach(pickerProviders.filter { $0.auth_status.eligible }) { provider in
                    // One name per account, page-wide: the Accounts list's own
                    // display name, never a second alias for the same row.
                    Button(provider.display_name) {
                        requestSetGroupProvider(group: group, lead: lead, providerId: provider.provider_id)
                    }
                }
            } label: {
                let id = selected.provider
                let account = providers.first { $0.provider_id == id }
                let name = account?.display_name ?? (id.isEmpty ? "Choose an account" : id)
                let suffix = id.isEmpty || account?.auth_status.eligible == true ? "" : " · not connected"
                Text(name + suffix)
                    .lineLimit(1)
                    .help(name + suffix)
            }
            .font(ShellType.label)
            .disabled(saving)
            } model: {
            // Scope the model picker to this group's chosen provider.
            Picker("Model", selection: Binding(
                get: {
                    let cur = selected.model
                    if surfModels.contains(where: { $0.id == cur }) { return cur }
                    // Unset or unavailable model picks remain unset rather than selecting an unchosen model.
                    return ""
                },
                set: { newVal in
                    requestSetGroupModel(group: group, lead: lead, model: newVal)
                }
            )) {
                if surfModels.isEmpty {
                    Text("—").tag("")
                } else {
                    // The unset state needs a row of its own, or the menu has no
                    // entry matching the selection and renders a blank label.
                    if !surfModels.contains(where: { $0.id == selected.model }) {
                        Text("Choose a model").tag("")
                    }
                    ForEach(surfModels) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
            .pickerStyle(.menu)

            .font(ShellType.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(surfModels.isEmpty || saving)
            } think: {
                Picker("Think", selection: Binding(
                    get: {
                        let current = selected.reasoningEffort.isEmpty
                            ? (selectedChoice?.defaultReasoningEffort ?? "high") : selected.reasoningEffort
                        return supportedEfforts.contains(current)
                            ? current
                            : (supportedEfforts.first ?? "high")
                    },
                    set: { newVal in
                        requestSetGroupReasoning(group: group, lead: lead, effort: newVal)
                    }
                )) {
                    ForEach(supportedEfforts, id: \.self) { effort in
                        Text(reasoningLabel(effort)).tag(effort)
                    }
                }
                .pickerStyle(.menu)

                .font(ShellType.label)
                .disabled(selectedChoice?.isUnavailable == true
                    || supportedEfforts.isEmpty
                    || saving)
            } fast: {
                if selectedChoice?.supportsFast == true {
                Toggle("Fast", isOn: Binding(
                    get: { selected.fast },
                    set: { enabled in
                        requestSetGroupFastMode(group: group, lead: lead, enabled: enabled)
                    }
                ))
                .toggleStyle(.switch)
                .hazeTinted()
                .controlSize(.small)
                .font(ShellType.label)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(selectedChoice?.isUnavailable == true
                    || selectedChoice?.supportsFast != true
                    || saving)
                .help(selectedChoice?.supportsFast == true
                    ? "Use the account's priority service tier for these activities."
                    : "This account and model do not offer a priority tier.")
                }
            }
            // Below the controls, not inside the Provider field: a caption in
            // the field would push Model, Think and Fast off the baseline.
            if let caption = ProviderToolCapability.caption(providerID: selected.provider) {
                Text(caption).font(.caption).foregroundStyle(NativeAgentShell.secondary)
            }
            if let note = providers.first(where: { $0.provider_id == selected.provider })?.models_note {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let receipt = inlineReceipts[group.id] {
                Text(receipt.text).font(.caption).foregroundStyle(NativeAgentShell.secondary)
                    .task(id: receipt.id) {
                        // One presentation deadline, cancelled when this receipt leaves the view.
                        do { try await ContinuousClock().sleep(for: .seconds(4)) } catch { return }
                        if inlineReceipts[group.id]?.id == receipt.id { inlineReceipts[group.id] = nil }
                    }
            }
        }
    }

    /// Restore inheritance from Chat for every surface in the group. `chat`
    /// itself is the root the others inherit from, so it is never cleared.
    private func clearGroupOverride(_ group: ProviderSurfaceGroup) async {
        guard !isLoading, !savingGroups.contains(group.id) else { return }
        savingGroups.insert(group.id)
        defer { savingGroups.remove(group.id) }
        do {
            guard let routingGroup = ProviderSurfaceGroups.all.first(where: { $0.id == group.id }) else {
                throw ProviderRoutingError.invalidRequest
            }
            _ = try await appModel.engine.saveProviderGroupSelection(group: routingGroup, clearOverride: true)
            if providerLoadError == nil, !overrideReadFailed {
                status = ("\(group.title) → default restored", .success)
                inlineReceipts[group.id] = SaveReceipt(text: status.text)
            }
        } catch {
            status = (UserFacingError.message(error, action: "restore the default"), .error)
        }
    }

    private func requestSetGroupProvider(
        group: ProviderSurfaceGroup,
        lead: String,
        providerId: String
    ) {
        let selected = selection(of: lead)
        let brain = ProvidersFacade.reconciledBrainForProvider(
            providerId: providerId, model: selected.model,
            reasoningEffort: selected.reasoningEffort.isEmpty ? nil : selected.reasoningEffort, fastMode: selected.fast,
            providers: providers, catalogModels: catalogModels
        )
        requestSetGroupSelection(
            group: group, providerID: providerId, model: brain?.model,
            reasoningEffort: brain?.reasoningEffort, serviceTier: brain.map { $0.fast ? "priority" : "default" }
        )
    }

    private func requestSetGroupModel(
        group: ProviderSurfaceGroup,
        lead: String,
        model: String
    ) {
        let selected = selection(of: lead)
        guard !model.isEmpty, selected.model != model || ProvidersFacade.groupIsMixed(group, selections: surfaceSelections, explicitSurfaces: explicitSurfaces) else { return }
        guard let choice = modelsForSurface(lead).first(where: { $0.id == model }) else { return }
        let nextEffort = normalizedReasoningEffort(
            options: choice.supportedReasoningEfforts, preferred: choice.defaultReasoningEffort,
            selected: selected.reasoningEffort.isEmpty ? choice.defaultReasoningEffort : selected.reasoningEffort
        )
        requestSetGroupSelection(group: group, providerID: selected.provider, model: model,
            reasoningEffort: nextEffort, serviceTier: choice.supportsFast && selected.fast ? "priority" : "default")
    }

    private func requestSetGroupReasoning(
        group: ProviderSurfaceGroup,
        lead: String,
        effort: String
    ) {
        let selected = selection(of: lead)
        guard selected.reasoningEffort != effort || ProvidersFacade.groupIsMixed(group, selections: surfaceSelections, explicitSurfaces: explicitSurfaces) else { return }
        guard selectedModelChoice(for: lead)?.supportedReasoningEfforts.contains(effort) == true else {
            return
        }
        requestSetGroupSelection(group: group, reasoningEffort: effort)
    }

    private func requestSetGroupFastMode(
        group: ProviderSurfaceGroup,
        lead: String,
        enabled: Bool
    ) {
        let selected = selection(of: lead)
        guard selected.fast != enabled || ProvidersFacade.groupIsMixed(group, selections: surfaceSelections, explicitSurfaces: explicitSurfaces) else { return }
        guard selectedModelChoice(for: lead)?.supportsFast == true else { return }
        requestSetGroupSelection(group: group, serviceTier: enabled ? "priority" : "default")
    }

    /// Only submitted fields overlay each member; ProviderRouting commits them together.
    private func requestSetGroupSelection(
        group: ProviderSurfaceGroup,
        providerID: String? = nil, model: String? = nil,
        reasoningEffort: String? = nil, serviceTier: String? = nil
    ) {
        for surface in group.surfaces {
            let prior = selection(of: surface)
            pendingSelections[surface] = .init(
                provider: providerID ?? prior.provider, model: model ?? prior.model,
                reasoningEffort: reasoningEffort ?? prior.reasoningEffort,
                fast: serviceTier.map { $0 == "priority" } ?? prior.fast
            )
        }
        let token = UUID()
        groupSaveTokens[group.id] = token
        savingGroups.insert(group.id)
        status = ("Saving \(group.title)…", .info)
        groupSaveTasks[group.id]?.cancel()
        groupSaveTasks[group.id] = Task {
            await saveGroupSelection(
                group: group, providerID: providerID, model: model,
                reasoningEffort: reasoningEffort, serviceTier: serviceTier, token: token
            )
        }
    }

    private func saveGroupSelection(
        group: ProviderSurfaceGroup,
        providerID: String?, model: String?, reasoningEffort: String?, serviceTier: String?,
        token: UUID
    ) async {
        guard groupSaveTokens[group.id] == token else { return }
        if model?.isEmpty == true {
            finishGroupSave(group)
            status = ("Model settings could not be saved: no model is available for this provider.", .error)
            return
        }
        // A model choice replaces divergent saved per-surface models.
        let clearedDivergentPicks = group.surfaces.contains { surface in
            let selected = selection(of: surface)
            return model != nil && surface != ProvidersFacade.leadSurface(group, selections: surfaceSelections)
                && !selected.model.isEmpty && selected.model != model
        }
        do {
            guard let routingGroup = ProviderSurfaceGroups.all.first(where: { $0.id == group.id }) else {
                throw ProviderRoutingError.invalidRequest
            }
            _ = try await appModel.engine.saveProviderGroupSelection(
                group: routingGroup, providerID: providerID, model: model,
                reasoningEffort: reasoningEffort, serviceTier: serviceTier
            )
            guard groupSaveTokens[group.id] == token else { return }
            let detail = [model, reasoningEffort.map(reasoningLabel),
                          serviceTier.map { $0 == "priority" ? "Fast" : "Standard" }]
                .compactMap { $0 }.joined(separator: " / ")
            status = ("\(group.title) → \(detail.isEmpty ? "provider" : detail) saved", .success)
            if clearedDivergentPicks {
                status.text += " · cleared an old per-app pick"
            }
            inlineReceipts[group.id] = SaveReceipt(text: status.text)
            finishGroupSave(group)
        } catch {
            // A newer edit owns this group now; its writes must not be undone.
            guard groupSaveTokens[group.id] == token else { return }
            finishGroupSave(group)
            status = (UserFacingError.message(error, action: "save model settings"), .error)
        }
    }

    private func finishGroupSave(_ group: ProviderSurfaceGroup) {
        for surface in group.surfaces { pendingSelections.removeValue(forKey: surface) }
        savingGroups.remove(group.id)
        groupSaveTokens.removeValue(forKey: group.id)
        groupSaveTasks.removeValue(forKey: group.id)
    }
}
