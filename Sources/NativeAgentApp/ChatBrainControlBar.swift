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

struct ChatBrainControlBar: View {
    @Environment(AppModel.self) private var appModel
    @State private var showFullMacAccessConfirm = false
    @State private var previousAccessMode = "auto"
    @State private var pendingProviderSelection: String? = nil
    @State private var isSavingProviderSelection = false

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
        guard let policy = appModel.trustPolicy else { return false }
        return policy.permissionLevel == "full_mac_os"
            || policy.permissionLevel == "wide_open_receipts"
            || policy.filePolicy?.outsideWorkspaceDefault == "allow"
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
                Image(systemName: "brain")
                    .foregroundStyle(NativeAgentBrand.accentDeep)
                    .accessibilityLabel("Conversation settings")

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

            if selectedModelIsUnavailable {
                Label("Choose a replacement", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("OpenRouter's latest catalog no longer contains the selected model. NativeAgent will not silently use another model.")
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
                    appModel.chatFileAccess = "full"
                    Task { @MainActor in
                        await appModel.saveAgentAccessMode("full")
                    }
                }
                Button("Cancel", role: .cancel) {
                    appModel.chatFileAccess = previousAccessMode
                }
            } message: {
                Text("This gives the agent outside-workspace file access and Mac app control. Shell, system control, and file move/trash still require Developer Mode.")
            }

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
                Task {
                    await appModel.refreshModelCatalog()
                    await appModel.loadProvidersForChat()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh providers + model catalog")
            .accessibilityLabel("Refresh")

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await appModel.loadProvidersForChat()
        }
    }

    private var chatAccessBinding: Binding<String> {
        Binding(
            get: { appModel.chatFileAccess },
            set: { newValue in
                let normalized = AppModel.normalizedAgentAccessMode(newValue)
                if normalized == "full", AppModel.normalizedAgentAccessMode(appModel.chatFileAccess) != "full" {
                    if trustPolicyAlreadyFullMac {
                        appModel.chatFileAccess = "full"
                        Task { @MainActor in
                            await appModel.saveAgentAccessMode("full")
                        }
                        return
                    }
                    previousAccessMode = AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
                    showFullMacAccessConfirm = true
                    return
                }
                appModel.chatFileAccess = normalized
                Task { @MainActor in
                    await appModel.saveAgentAccessMode(normalized)
                }
            }
        )
    }
}

// PATCH-2026-05-07: chat-context-fill Compact context-window indicator.
// Reads session context after each chat send, plus on tab appear. Bar fills
// proportionally; turns orange at 60%, red at 80%, with a "Compact now"
// affordance once compaction makes sense. Auto-compaction is runtime-side at
// 75% — this is visibility + manual override.
