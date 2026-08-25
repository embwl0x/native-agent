import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
import ProviderRouting
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// State machine for the conversation header's access picker. The picker can
/// optimistically show ordinary changes, but Full Mac is a two-step action
/// unless the persisted policy has already granted that exact authority.
enum ChatAccessPickerPolicy {
    enum Action: Equatable {
        case unchanged
        case save(mode: String, rollbackMode: String)
        case requiresFullMacConfirmation(previousMode: String)
    }

    static func trustPolicyAlreadyFullMac(
        permissionLevel: String?,
        outsideWorkspaceDefault: String?
    ) -> Bool {
        permissionLevel == "full_mac_os"
            || permissionLevel == "wide_open_receipts"
            || outsideWorkspaceDefault == "allow"
    }

    static func action(
        requestedMode: String,
        currentMode: String,
        trustPolicyAlreadyFullMac: Bool
    ) -> Action {
        let requested = AppModel.normalizedAgentAccessMode(requestedMode)
        let current = AppModel.normalizedAgentAccessMode(currentMode)
        guard requested != current else { return .unchanged }
        if requested == "full", !trustPolicyAlreadyFullMac {
            return .requiresFullMacConfirmation(previousMode: current)
        }
        return .save(mode: requested, rollbackMode: current)
    }

    /// The picker must return to the last durable selection if the write fails;
    /// a status toast alone is not enough when the selected value implies an
    /// authority the store never granted.
    static func visibleMode(afterSaving mode: String, rollbackMode: String, succeeded: Bool) -> String {
        succeeded
            ? AppModel.normalizedAgentAccessMode(mode)
            : AppModel.normalizedAgentAccessMode(rollbackMode)
    }
}

struct ChatConversationSettingsModelWarning: Equatable {
    enum Kind: Equatable {
        case unavailable
        case staleCatalog
    }

    let kind: Kind
    let text: String

    /// A missing provider row or an empty advertised model list means the
    /// catalog has not arrived yet. Do not call the saved selection stale from
    /// absence alone; that would turn an unavailable refresh into a false
    /// claim that the model has been retired.
    static func make(
        providerName: String,
        selectedModel: String,
        advertisedModelIDs: [String],
        isExplicitlyUnavailable: Bool
    ) -> Self? {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }

        if isExplicitlyUnavailable {
            return Self(
                kind: .unavailable,
                text: "\(model) is no longer available. Choose a replacement before sending."
            )
        }

        guard !advertisedModelIDs.isEmpty,
              !advertisedModelIDs.contains(model) else {
            return nil
        }
        let provider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = provider.isEmpty ? "the selected provider" : provider
        return Self(
            kind: .staleCatalog,
            text: "\(model) is not in \(source)'s current model catalog. Choose a replacement before sending."
        )
    }
}

/// The conversation controls must distinguish a completed refresh from a
/// carried-over picker. `AppModel.statusText` is global and may not be visible
/// beside this compact control, so this is the local, user-observable receipt.
enum ChatCatalogRefreshPresentation: Equatable {
    case refreshed
    case catalogUnavailable
    case providersUnavailable
    case catalogAndProvidersUnavailable

    static func resolve(catalogRefreshed: Bool, providersFresh: Bool) -> Self {
        switch (catalogRefreshed, providersFresh) {
        case (true, true): return .refreshed
        case (false, true): return .catalogUnavailable
        case (true, false): return .providersUnavailable
        case (false, false): return .catalogAndProvidersUnavailable
        }
    }

    var message: String {
        switch self {
        case .refreshed:
            "Providers and model catalog refreshed."
        case .catalogUnavailable:
            "Model catalog could not refresh. Showing existing choices."
        case .providersUnavailable:
            "Providers could not refresh. Showing existing choices."
        case .catalogAndProvidersUnavailable:
            "Providers and model catalog could not refresh. Showing existing choices."
        }
    }

    var isFailure: Bool {
        self != .refreshed
    }
}

struct ChatCatalogRefreshState: Equatable {
    private(set) var isRefreshing = false
    private(set) var presentation: ChatCatalogRefreshPresentation?

    /// A repeated click while both production reads are in flight is a no-op;
    /// it cannot create an older completion that overwrites the newest receipt.
    mutating func begin() -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        return true
    }

    mutating func finish(catalogRefreshed: Bool, providersFresh: Bool) {
        isRefreshing = false
        presentation = ChatCatalogRefreshPresentation.resolve(
            catalogRefreshed: catalogRefreshed,
            providersFresh: providersFresh
        )
    }
}

struct ChatBrainControlBar: View {
    @Environment(AppModel.self) private var appModel
    @State private var showFullMacAccessConfirm = false
    @State private var previousAccessMode = "auto"
    @State private var isSavingAccessMode = false
    @State private var accessSaveGeneration: UInt = 0
    @State private var pendingProviderSelection: String? = nil
    @State private var isSavingProviderSelection = false
    @State private var catalogRefresh = ChatCatalogRefreshState()

    /// Models for the currently-selected chat provider. Falls back to the
    /// catalog default (GPT names) for providers that don't expose a model
    /// list (local, codex CLI).
    private var providerModels: [ModelCatalogItem] {
        if let p = appModel.providersList.first(where: { $0.provider_id == appModel.chatProvider }),
           !p.models.isEmpty {
            return p.models.map { providerModel in
                let catalogModel = appModel.modelCatalog?.models.first(where: { $0.id == providerModel.id })
                // Provider-scoped capabilities are authoritative. The global
                // catalog intentionally contains duplicate ids for transports
                // with different contracts (for example public GPT-5.6 None–
                // Max versus ChatGPT OAuth Low–Ultra), so replacing this row
                // wholesale from the global catalog would expose invalid
                // Think/Fast controls for the selected provider.
                return ModelCatalogItem(
                    id: providerModel.id,
                    displayName: providerModel.name,
                    description: catalogModel?.description,
                    defaultReasoningEffort: providerModel.default_reasoning_effort
                        ?? catalogModel?.defaultReasoningEffort
                        ?? "high",
                    supportedReasoningEfforts: providerModel.supported_reasoning_efforts
                        ?? catalogModel?.supportedReasoningEfforts
                        ?? ["low", "medium", "high", "xhigh"],
                    supportsFast: providerModel.supports_fast ?? catalogModel?.supportsFast,
                    priority: catalogModel?.priority ?? 0
                )
            }
        }
        let options = modelOptions(from: appModel.modelCatalog, current: appModel.chatModel)
        return options
    }

    private var efforts: [ReasoningEffortOption] {
        let fallback = ["low", "medium", "high", "xhigh"]
        let supported = providerModels.first(where: { $0.id == appModel.chatModel })?
            .supportedReasoningEfforts ?? fallback
        let catalogOptions = Dictionary(
            uniqueKeysWithValues: (appModel.modelCatalog?.reasoningEfforts ?? []).map { ($0.id, $0) }
        )
        return supported.map { effort in
            catalogOptions[effort] ?? ReasoningEffortOption(
                id: effort,
                label: effort == "xhigh" ? "XHigh" : effort.capitalized,
                description: nil
            )
        }
    }

    private var selectedModelSupportsFast: Bool {
        providerModels.first(where: { $0.id == appModel.chatModel })?.supportsFast == true
    }

    private var selectedModelIsUnavailable: Bool {
        appModel.chatProvider == "openrouter"
            && OpenRouterModelCatalog.cachedAvailability(
                of: appModel.chatModel,
                dataRoot: PersistenceCore.defaultDataRoot()
            ) == .unavailable
    }

    private var selectedModelWarning: ChatConversationSettingsModelWarning? {
        let provider = appModel.providersList.first {
            $0.provider_id == appModel.chatProvider
        }
        return ChatConversationSettingsModelWarning.make(
            providerName: provider?.display_name ?? appModel.chatProvider,
            selectedModel: appModel.chatModel,
            advertisedModelIDs: provider?.models.map(\.id) ?? [],
            isExplicitlyUnavailable: selectedModelIsUnavailable
        )
    }

    /// Compact picker label: vendor name only ("Anthropic (OAuth /
    /// Setup-Token)" → "Anthropic"). When two listed providers share a
    /// vendor they must stay distinguishable in a Picker (closed control
    /// and menu rows share text), so each keeps a compacted flavor —
    /// the parenthetical's first token: "Anthropic · OAuth" vs
    /// "Anthropic · API key".
    private func compactProviderLabel(_ provider: ProviderInfo) -> String {
        func split(_ s: String) -> (vendor: String, flavor: String?) {
            guard let open = s.range(of: " (") else { return (s, nil) }
            let vendor = String(s[..<open.lowerBound])
            var flavor = String(s[open.upperBound...])
            if flavor.hasSuffix(")") { flavor.removeLast() }
            let first = flavor.split(separator: "/").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return (vendor, (first?.isEmpty == false) ? first : nil)
        }
        let mine = split(provider.display_name)
        let collisions = providerOptions.filter { split($0.display_name).vendor == mine.vendor }
        guard collisions.count > 1 else { return mine.vendor }
        guard let flavor = mine.flavor else { return provider.display_name }
        return "\(mine.vendor) · \(flavor)"
    }

    /// Provider list — sorted: ready first (no warning), then non-ready.
    private var providerOptions: [ProviderInfo] {
        appModel.providersList.filter {
            $0.provider_id == "codex" || $0.auth_status.state == "ready" || $0.provider_id == appModel.chatProvider
        }.sorted { lhs, rhs in
            let lhsReady = lhs.auth_status.state == "ready"
            let rhsReady = rhs.auth_status.state == "ready"
            if lhsReady != rhsReady { return lhsReady && !rhsReady }
            return lhs.display_name < rhs.display_name
        }
    }

    private var trustPolicyAlreadyFullMac: Bool {
        ChatAccessPickerPolicy.trustPolicyAlreadyFullMac(
            permissionLevel: appModel.trustPolicy?.permissionLevel,
            outsideWorkspaceDefault: appModel.trustPolicy?.filePolicy?.outsideWorkspaceDefault
        )
    }

    private var providerSelectionBinding: Binding<String> {
        Binding(
            get: { pendingProviderSelection ?? appModel.chatProvider },
            set: { newProvider in
                guard newProvider != (pendingProviderSelection ?? appModel.chatProvider) else { return }
                let previous = appModel.chatProvider
                pendingProviderSelection = newProvider
                isSavingProviderSelection = true
                Task { @MainActor in
                    let saved = await appModel.setChatProvider(newProvider, previous: previous)
                    if saved {
                        if !providerModels.contains(where: { $0.id == appModel.chatModel }),
                           let first = providerModels.first {
                            appModel.chatModel = first.id
                        }
                    }
                    pendingProviderSelection = nil
                    isSavingProviderSelection = false
                }
            }
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // This visible detail label is the evidence that the header
                // toggle opened the real brain-control row, not merely that a
                // local Boolean flipped on an otherwise empty container.
                Label("Conversation settings", systemImage: "brain")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(NativeAgentBrand.accentDeep)
                    .accessibilityIdentifier("chat.conversation-settings-detail")

            // Provider picker. If the providers list hasn't loaded yet, we
            // synthesize a single tag for the currently-selected id so the
            // picker still has something to render (otherwise SwiftUI shows
            // an empty 30px-wide control).
            Text("Provider")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: providerSelectionBinding) {
                let selectedProvider = pendingProviderSelection ?? appModel.chatProvider
                if !providerOptions.contains(where: { $0.provider_id == selectedProvider }) {
                    Text(selectedProvider).tag(selectedProvider)
                }
                ForEach(providerOptions) { provider in
                    let ready = provider.auth_status.state == "ready"
                    Text(compactProviderLabel(provider) + (ready ? "" : " ⚠️"))
                        .tag(provider.provider_id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
            .help("Which provider the agent uses for chat (ChatGPT OAuth, Anthropic, etc.). Changes save automatically.")
            .disabled(isSavingProviderSelection)

            // Model picker (provider-scoped). Auto-saves on selection so
            // refreshAll() can't snap it back to the daemon's stale saved
            // value. PATCH-2026-05-07: model-autosave Without this, the
            // routing.current.chat.model overwrite on every refresh would
            // silently undo the user's picker selection.
            Text("Model")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Picker("Model", selection: Bindable(appModel).chatModel) {
                if !providerModels.contains(where: { $0.id == appModel.chatModel }) {
                    Text(appModel.chatModel + (selectedModelIsUnavailable ? " — Unavailable" : ""))
                        .tag(appModel.chatModel)
                }
                ForEach(providerModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .frame(minWidth: 140, idealWidth: 170, maxWidth: 220)
            .help("Specific model within the active provider. Saves automatically when changed.")
            .onChange(of: appModel.chatModel) { _, _ in
                let options = efforts
                if !options.contains(where: { $0.id == appModel.chatReasoningEffort }) {
                    appModel.chatReasoningEffort = providerModels
                        .first(where: { $0.id == appModel.chatModel })?
                        .defaultReasoningEffort ?? options.first?.id ?? "high"
                }
                if !selectedModelSupportsFast { appModel.chatFastMode = false }
                Task { @MainActor in await appModel.saveChatBrainDefaults() }
            }

            if let warning = selectedModelWarning {
                Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("chat.conversation-settings.stale-model-warning")
                    .accessibilityLabel("Selected model warning: \(warning.text)")
                    .accessibilityValue(
                        warning.kind == .unavailable ? "Unavailable" : "Stale catalog"
                    )
                    .help("NativeAgent will not silently substitute a different model.")
            }

            Text("Think")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Picker("Think", selection: Bindable(appModel).chatReasoningEffort) {
                ForEach(efforts) { effort in
                    Text(effort.label).tag(effort.id)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 390)
            .disabled(selectedModelIsUnavailable)
            .help("Reasoning effort supported by the selected model, from Low through Max or Ultra where available.")
            .onChange(of: appModel.chatReasoningEffort) { _, _ in
                Task { @MainActor in await appModel.saveChatBrainDefaults() }
            }

            if selectedModelSupportsFast {
                Toggle(isOn: Bindable(appModel).chatFastMode) {
                    Label("Fast", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .help("Fast mode requests priority processing when the selected provider/model supports it.")
                .onChange(of: appModel.chatFastMode) { _, _ in
                    Task { @MainActor in await appModel.saveChatBrainDefaults() }
                }
            }

            Picker("Access", selection: chatAccessBinding) {
                Text("Auto").tag("auto")
                Text("Read").tag("read_only")
                Text("Workspace").tag("workspace")
                Text("Full Mac").tag("full")
            }
            .frame(width: 130)
            .help("Shared agent access policy. Full Mac maps to the Trust policy's full_mac_os mode.")
            .alert("Enable Full Mac access?", isPresented: $showFullMacAccessConfirm) {
                Button("Enable Full Mac", role: .destructive) {
                    saveAccessModeFromPicker("full", rollbackMode: previousAccessMode)
                }
                Button("Cancel", role: .cancel) {
                    appModel.chatFileAccess = previousAccessMode
                }
            } message: {
                Text("This gives the agent outside-workspace file access and Mac app control. Shell, system control, and file move/trash still require Developer Mode.")
            }
            .disabled(isSavingAccessMode)

            // PATCH-2026-05-08: wave2-chat-ux — Persona quick-switch
            Text("Voice")
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
            Picker("Persona", selection: Bindable(appModel).chatPersona) {
                let baseKinds = ["Male", "Female", "AI", "Custom"]
                let current = appModel.chatPersona.trimmingCharacters(in: .whitespacesAndNewlines)
                let kinds = current.isEmpty || baseKinds.contains(current) ? baseKinds : [current] + baseKinds
                ForEach(kinds, id: \.self) { p in Text(p).tag(p) }
            }
            .labelsHidden()
            .frame(minWidth: 100, maxWidth: 140)
            .help("Active persona for chat turns")

            Button {
                Task { await refreshConversationCatalog() }
            } label: {
                if catalogRefresh.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("Refresh providers + model catalog")
            .accessibilityLabel("Refresh")
            .accessibilityValue(catalogRefresh.isRefreshing ? "Refreshing" : "Ready")
            .disabled(catalogRefresh.isRefreshing)

            if let presentation = catalogRefresh.presentation {
                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(presentation.isFailure ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("chat.conversation-settings.catalog-refresh-status")
            }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await appModel.loadProvidersForChat()
        }
    }

    private func refreshConversationCatalog() async {
        guard catalogRefresh.begin() else { return }
        let catalogRefreshed = await appModel.refreshModelCatalog()
        let providersFresh = await appModel.loadProvidersForChat()
        catalogRefresh.finish(
            catalogRefreshed: catalogRefreshed,
            providersFresh: providersFresh
        )
    }

    private var chatAccessBinding: Binding<String> {
        Binding(
            get: { appModel.chatFileAccess },
            set: { newValue in
                switch ChatAccessPickerPolicy.action(
                    requestedMode: newValue,
                    currentMode: appModel.chatFileAccess,
                    trustPolicyAlreadyFullMac: trustPolicyAlreadyFullMac
                ) {
                case .unchanged:
                    return
                case .requiresFullMacConfirmation(let previousMode):
                    previousAccessMode = previousMode
                    showFullMacAccessConfirm = true
                case .save(let mode, let rollbackMode):
                    saveAccessModeFromPicker(mode, rollbackMode: rollbackMode)
                }
            }
        )
    }

    private func saveAccessModeFromPicker(_ mode: String, rollbackMode: String) {
        let normalizedMode = AppModel.normalizedAgentAccessMode(mode)
        let normalizedRollback = AppModel.normalizedAgentAccessMode(rollbackMode)
        accessSaveGeneration &+= 1
        let generation = accessSaveGeneration
        isSavingAccessMode = true
        appModel.chatFileAccess = normalizedMode
        Task { @MainActor in
            let succeeded = await appModel.saveAgentAccessMode(normalizedMode)
            guard generation == accessSaveGeneration else { return }
            isSavingAccessMode = false
            appModel.chatFileAccess = ChatAccessPickerPolicy.visibleMode(
                afterSaving: normalizedMode,
                rollbackMode: normalizedRollback,
                succeeded: succeeded
            )
        }
    }
}

// PATCH-2026-05-07: chat-context-fill Compact context-window indicator.
// Reads session context after each chat send, plus on tab appear. Bar fills
// proportionally; turns orange at 60%, red at 80%, with a "Compact now"
// affordance once compaction makes sense. Auto-compaction is runtime-side at
// 75% — this is visibility + manual override.
