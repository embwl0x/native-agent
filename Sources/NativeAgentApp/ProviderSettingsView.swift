// PATCH-2026-05-07: model-providers v1 — ProviderSettingsView: Models & Providers settings sub-section
// PATCH-2026-05-07: leftover-2 per-surface active provider picker (Mac side)
import SwiftUI
import Foundation
import ProviderRouting
import PersistenceCore

enum ProviderSurfaceRowLayout {
    // Includes the field label, the longest current value ("No Think"), and
    // the macOS menu-picker chrome without truncating the active selection.
    static let reasoningPickerWidth: CGFloat = 148
    static let fastToggleWidth: CGFloat = 88
}

/// Presentation truth for the Providers refresh control. Missing provider
/// rows are a normal first-run result only after a successful refresh; a
/// failed authority read must remain distinguishable from that empty state.
enum ProviderSettingsRefreshPresentation: Equatable {
    case empty
    case unavailable(String)
    case available

    static func resolve(providerCount: Int, loadError: String?) -> Self {
        guard providerCount == 0 else { return .available }
        guard let loadError,
              !loadError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        return .unavailable(loadError)
    }
}

/// The provider picker receives routing identifiers from `ProviderRouting`.
/// Keep their customer-facing names explicit: a new routing surface must not
/// silently appear as a prettified storage key in Settings.
enum ProviderSettingsSurfaceLabel: Equatable, Sendable {
    case named(String)
    case unrecognized(String)
    case malformed

    private static let namedLabels: [String: String] = [
        "chat": "Chat",
        "ios": "iPhone",
        "telegram": "Telegram",
        "slack": "Slack",
        "desk": "Desk",
        "workshop": "Workshop",
        // Old persisted rows are folded to `workshop` before presentation,
        // but retain an honest title if an older in-memory caller reaches us.
        "missions": "Workshop",
        "autonomy": "Autonomy",
        "swarms": "Swarms",
        "dream": "Dream",
        "rem": "REM",
        "training": "Training",
        "memory": "Memory",
        "heartbeat": "Heartbeat",
        "diagnostics": "Diagnostics",
        "cognition_reflection": "Cognition Reflection",
        "compaction": "Compaction",
        "self_improvement": "Self-Improvement",
        // Personality depth item 9 (2026-09-02): her own hour has its own row.
        "studio_wander": "Studio Wandering",
    ]

    static func presentation(for rawSurface: String) -> Self {
        let trimmed = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == rawSurface, rawSurface == rawSurface.lowercased() else {
            return .malformed
        }
        guard let label = namedLabels[rawSurface] else {
            return .unrecognized(rawSurface)
        }
        return .named(label)
    }

    var text: String {
        switch self {
        case .named(let label):
            return label
        case .unrecognized(let surface):
            return "Unrecognized surface (\(surface))"
        case .malformed:
            return "Surface label unavailable"
        }
    }
}

// MARK: - Main View

struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var providers: [ProviderInfo] = []
    @State private var isLoading = false
    /// The refresh control must distinguish an authority-read failure from a
    /// genuinely empty provider catalog. Kept separate from the general
    /// status line because save/configure actions also write that line.
    @State private var providerLoadError: String?
    @State private var configureSheet: ProviderInfo? = nil
    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test
    @State private var statusText = ""

    // Per-surface active provider selection state (surface → provider_id)
    @State private var activeSurface: [String: String] = [:]
    @State private var activeSurfaceSaveTokens: [String: UUID] = [:]
    @State private var activeSurfaceSaveTasks: [String: Task<Void, Never>] = [:]
    @State private var savingSurfaces: Set<String> = []

    // PATCH-2026-05-28 (per-surface model): per-surface model selection state.
    // The model list shown for a surface is scoped to the provider selected
    // for that surface (so OpenRouter shows its live catalog, Anthropic its Claude
    // models, etc.). Falls back to the global catalog for providers that
    // expose no provider-specific list.
    @State private var surfaceModel: [String: String] = [:]
    @State private var surfaceModelSaveTokens: [String: UUID] = [:]
    @State private var surfaceModelSaveTasks: [String: Task<Void, Never>] = [:]
    @State private var savingSurfaceModels: Set<String> = []
    @State private var surfaceReasoningEffort: [String: String] = [:]
    @State private var surfaceFastMode: [String: Bool] = [:]
    @State private var catalogModels: [ModelCatalogItem] = []
    @State private var rowSet = ProviderSurfaceRowSet(
        surfacePreferenceKeys: [],
        activeProviderKeys: []
    )

    // The visible rows remain the routing registry's canonical order. The
    // store-backed audit below makes an unregistered persisted key visible as
    // a repair state instead of quietly leaving it unpinnable.
    private var surfaces: [String] { rowSet.visibleSurfaces }

    private struct SurfaceModelChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let defaultReasoningEffort: String
        let supportedReasoningEfforts: [String]
        let supportsFast: Bool
        let isUnavailable: Bool
    }

    private struct SurfaceBrainSelection {
        let model: String
        let reasoningEffort: String
        let fastMode: Bool
    }

    private func modelsForProvider(_ providerId: String) -> [SurfaceModelChoice] {
        if let prov = providers.first(where: { $0.provider_id == providerId }), !prov.models.isEmpty {
            return prov.models.map {
                SurfaceModelChoice(
                    id: $0.id,
                    name: $0.name,
                    defaultReasoningEffort: $0.default_reasoning_effort ?? "high",
                    supportedReasoningEfforts: $0.supported_reasoning_efforts
                        ?? ["low", "medium", "high", "xhigh"],
                    supportsFast: $0.supports_fast == true,
                    isUnavailable: false
                )
            }
        }
        return catalogModels.map {
            SurfaceModelChoice(
                id: $0.id,
                name: $0.displayName,
                defaultReasoningEffort: $0.defaultReasoningEffort ?? "high",
                supportedReasoningEfforts: $0.supportedReasoningEfforts
                    ?? ["low", "medium", "high", "xhigh"],
                supportsFast: $0.supportsFast == true,
                isUnavailable: false
            )
        }
    }

    /// Providers whose catalogue is fetched rather than compiled in. Their
    /// `models` list can be a two-entry offline fallback served when no live
    /// catalogue has ever arrived, so its silence about a model is not
    /// evidence of anything.
    private static let dynamicCatalogProviders: Set<String> = ["openrouter", "moonshot"]

    /// Whether a LIVE catalogue for this provider says the saved model is gone.
    ///
    /// 2026-09-06: the old test was "the choice list is non-empty", and
    /// `modelsForProvider` substitutes the provider-neutral global catalogue
    /// whenever a provider's own list is empty — so a dynamic provider with no
    /// catalogue yet borrowed someone else's list and the saved model was
    /// labelled Unavailable on it. Evidence now has to come from the provider
    /// itself: OpenRouter's own live-backed cache (`.unknown` until one exists),
    /// or a static provider's compiled-in list, which is the whole truth about
    /// that provider. Moonshot has no live/fallback discriminator, so it never
    /// convicts. Anything unproven shows the saved model plainly.
    private func savedModelIsKnownAbsent(providerId: String, model: String) -> Bool {
        if providerId == "openrouter" {
            // User, 2026-09-06: this read the DEFAULT data root while the rest
            // of the screen works off the model's scoped one, so under an
            // override the verdict came from a catalog belonging to another
            // root — including the "Unavailable" label on a saved model.
            return OpenRouterModelCatalog.cachedAvailability(
                of: model,
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            ) == .unavailable
        }
        guard !Self.dynamicCatalogProviders.contains(providerId) else { return false }
        guard let provider = providers.first(where: { $0.provider_id == providerId }),
              !provider.models.isEmpty else {
            return false
        }
        return !provider.models.contains(where: { $0.id == model })
    }

    /// Models offered for a surface, scoped to the provider selected for it.
    private func modelsForSurface(_ surface: String) -> [SurfaceModelChoice] {
        let pid = activeSurface[surface] ?? "codex"
        var choices = modelsForProvider(pid)
        let current = surfaceModel[surface] ?? ""
        // 2026-09-06: this used to be an OpenRouter-only repair, so every other
        // provider whose catalogue did not list the SAVED model rendered the
        // first model in the list instead — a row that says one thing and
        // routes to another, with nothing saved and no label. The saved
        // selection is always shown; it is only CALLED unavailable on the
        // evidence of a live catalogue for that provider.
        if !current.isEmpty, !choices.contains(where: { $0.id == current }) {
            let unavailable = savedModelIsKnownAbsent(providerId: pid, model: current)
            choices.insert(SurfaceModelChoice(
                id: current,
                name: unavailable ? "\(current) — Unavailable" : current,
                defaultReasoningEffort: surfaceReasoningEffort[surface] ?? "high",
                supportedReasoningEfforts: [surfaceReasoningEffort[surface] ?? "high"],
                supportsFast: false,
                isUnavailable: unavailable
            ), at: 0)
        }
        return choices
    }

    private func reconciledBrainForProvider(surface: String, providerId: String) -> SurfaceBrainSelection? {
        let choices = modelsForProvider(providerId)
        guard let first = choices.first else { return nil }
        let current = surfaceModel[surface] ?? ""
        let choice = choices.first(where: { $0.id == current }) ?? first
        let defaultEffort = choice.supportedReasoningEfforts.contains(choice.defaultReasoningEffort)
            ? choice.defaultReasoningEffort
            : (choice.supportedReasoningEfforts.first ?? "high")
        let currentEffort = surfaceReasoningEffort[surface] ?? defaultEffort
        let effort = choice.supportedReasoningEfforts.contains(currentEffort)
            ? currentEffort
            : defaultEffort
        return SurfaceBrainSelection(
            model: choice.id,
            reasoningEffort: effort,
            fastMode: choice.supportsFast && (surfaceFastMode[surface] ?? false)
        )
    }

    private func selectedModelChoice(for surface: String) -> SurfaceModelChoice? {
        let choices = modelsForSurface(surface)
        let model = surfaceModel[surface] ?? ""
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
        let activeIds = Set(activeSurface.values)
        return providers.filter {
            $0.provider_id == "codex"
            || $0.auth_status.state == "ready"
            || activeIds.contains($0.provider_id)
        }
    }

    var body: some View {
        // PATCH-2026-06-06: 2-column layout — the accounts and their sign-ins
        // on the left (~360pt cap), what each surface uses on the right (flex).
        // The right column is what a person uses daily; it stays visible while
        // clicking around the sign-in cards on the left. The seam between the
        // two is air, not a drawn rule.
        HStack(alignment: .top, spacing: 32) {
            providerListColumn
                .frame(maxWidth: 360)

            perSurfacePickerColumn
        }
        .sheet(item: $configureSheet) { provider in
            ProviderConfigSheet(provider: provider) {
                configureSheet = nil
                Task { await loadProviders() }
            }
            .environment(appModel)
        }
        .task { await loadProviders() }
    }

    /// Left column: what the lead sentence says, the sign-ins, and the list of
    /// accounts. Everything that is not the per-surface picker.
    @ViewBuilder
    private var providerListColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Pick the account behind each surface. \(AgentVoice.live.subject) \(AgentVoice.live.verb("use")) ChatGPT unless you say otherwise.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ProviderSection(label: "Sign in") {
                    VStack(alignment: .leading, spacing: 8) {
                        // A2.2 close-out (2026-07-24): title/copy said sign-in
                        // ran through Codex's device flow — stale since the
                        // 2026-07-05 codex-free loopback cutover. The codex
                        // device flow remains the alternative path (its
                        // in-flight UI renders below).
                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "ChatGPT",
                                    line: "Sign in with your ChatGPT Plus or Pro account in the browser. The codex command-line device flow is still there as an alternative."
                                )
                                OAuthSignInButton(provider: .chatgpt) {
                                    Task { await loadProviders() }
                                }
                                if let login = appModel.codexDeviceLogin {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Open \(login.url ?? "https://auth.openai.com/codex/device")")
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.text)
                                        Text(login.code ?? "waiting")
                                            .font(ProviderType.code)
                                            .foregroundStyle(NativeAgentShell.text)
                                        if let home = login.codexHome, !home.isEmpty {
                                            Text(home)
                                                .font(ProviderType.code)
                                                .foregroundStyle(NativeAgentShell.secondary)
                                        }
                                        HStack(spacing: 8) {
                                            Button("Cancel") {
                                                Task { await appModel.cancelCodexDeviceLogin() }
                                            }
                                            Button("Clear") {
                                                Task { await appModel.clearCodexDeviceLogin() }
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .font(ShellType.labelMedium)
                                    }
                                    .textSelection(.enabled)
                                }
                            }
                        }

                        // PATCH-2026-05-07: anthropic-oauth-direct — direct
                        // OAuth to Anthropic (no Claude Code CLI dependency).
                        // Same public client_id Claude Code CLI uses, so tokens
                        // stay compatible if you use both.
                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "Anthropic",
                                    line: "Two ways in. A setup token is the route Anthropic recommends for outside apps; make one at console.anthropic.com, under Settings then OAuth."
                                )
                                OAuthSignInButton(provider: .anthropic) {
                                    Task { await loadProviders() }
                                }
                                AnthropicSetupTokenInput {
                                    Task { await loadProviders() }
                                }
                            }
                        }

                        ProviderCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ProviderCardTitle(
                                    title: "xAI",
                                    line: "Sign in with xAI to use Grok models. This is separate from the X connector; the token stays in this app's own store."
                                )
                                OAuthSignInButton(provider: .xai) {
                                    Task { await loadProviders() }
                                }
                            }
                        }
                    }
                }

                // Dead-weight sweep 2026-07-03: the inline TelegramBotSetupInput
                // panel duplicated the Telegram settings surface — two write
                // paths to telegram/config.json that didn't refresh each other.
                // Telegram settings own the config; this is now a pointer.
                ProviderSection(label: "Telegram") {
                    ProviderCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ProviderCardTitle(
                                title: "Telegram lives on its own page",
                                line: "The bot token, who may write in, and the model it answers with are all on the Telegram page."
                            )
                            Button("Open Telegram") {
                                let receipt = NativeAgentAppCoordinator.shared.request(.sidebar(.telegram))
                                let presentation = ProviderTelegramSettingsButtonPresentation.presentation(for: receipt)
                                statusText = presentation.statusText
                            }
                            .buttonStyle(.bordered)
                            .font(ShellType.labelMedium)
                        }
                    }
                }

                ProviderSection(label: "Accounts") {
                    VStack(alignment: .leading, spacing: 8) {
                        if isLoading {
                            ProviderCard {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Reading the accounts…")
                                        .font(ShellType.label)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                }
                            }
                        } else if case let .unavailable(detail) = ProviderSettingsRefreshPresentation.resolve(
                            providerCount: providers.count,
                            loadError: providerLoadError
                        ) {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProviderCardTitle(
                                        title: "The accounts could not be read",
                                        line: detail
                                    )
                                }
                            }
                        } else if providers.isEmpty {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "No accounts yet",
                                    line: "Sign in above, or press Refresh to read what is already on this Mac."
                                )
                            }
                        } else {
                            ForEach(providers.indices, id: \.self) { index in
                                let provider = providers[index]
                                ProviderCard {
                                    ProviderRowView(provider: provider) {
                                        configureSheet = provider
                                    }
                                }
                            }
                        }

                        Button(isLoading ? "Refreshing…" : "Refresh") {
                            Task { await loadProviders(refreshCatalog: true) }
                        }
                        .buttonStyle(.bordered)
                        .font(ShellType.labelMedium)
                        .disabled(isLoading)
                        // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test
                    }
                }

                // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test (results panel)

                if let status = ProviderSettingsStatusTextPresentation.state(for: statusText) {
                    Text(status.text)
                        .font(ShellType.caption)
                        .foregroundStyle(statusColor(status.tone))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(status.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name.
        .navigationTitle("Providers")
    }

    /// Right column: which account and model each surface uses. Pinned so the
    /// chat model can be changed without scrolling past the sign-in cards.
    @ViewBuilder
    private var perSurfacePickerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProviderSection(label: "What each surface uses") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !rowSet.unsupportedStoredKeys.isEmpty {
                            ProviderNote(
                                text: "Saved settings need repair: " + rowSet.unsupportedStoredKeys.joined(separator: ", "),
                                color: NativeAgentShell.trouble
                            )
                        }
                        if !rowSet.retiredStoredKeys.isEmpty {
                            ProviderNote(
                                text: "Retired saved settings are ignored: " + rowSet.retiredStoredKeys.joined(separator: ", "),
                                color: NativeAgentShell.trouble
                            )
                        }
                        if pickerProviders.isEmpty {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "Nothing to choose from yet",
                                    line: "Sign in to an account, then each surface can be pointed at one."
                                )
                            }
                        } else {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(surfaces, id: \.self) { surface in
                                        surfaceRow(surface)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 32)
        }
    }

    /// One surface: its name, the account behind it, the model, how hard it
    /// thinks, and whether it runs on the priority tier.
    @ViewBuilder
    private func surfaceRow(_ surface: String) -> some View {
        let surfModels = modelsForSurface(surface)
        let selectedChoice = selectedModelChoice(for: surface)
        let supportedEfforts = selectedChoice?.supportedReasoningEfforts
            ?? ["low", "medium", "high", "xhigh"]
        HStack(spacing: 8) {
            Text(surfaceLabel(surface))
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.text)
                .frame(width: 112, alignment: .leading)

            Picker("Provider", selection: Binding(
                get: { activeSurface[surface] ?? "codex" },
                set: { newVal in
                    requestSetActiveSurface(surface: surface, providerId: newVal)
                }
            )) {
                ForEach(pickerProviders) { provider in
                    let ready = provider.auth_status.state == "ready"
                    Text(provider.display_name + (ready ? "" : " — needs attention"))
                        .tag(provider.provider_id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(ShellType.label)
            .frame(width: 210)
            .disabled(savingSurfaces.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) provider")

            // PATCH-2026-05-28 (per-surface model): model picker scoped to the
            // provider chosen for THIS surface. Plain dropdown (no search) even
            // for OpenRouter's long list.
            Picker("Model", selection: Binding(
                get: {
                    let cur = surfaceModel[surface] ?? ""
                    if surfModels.contains(where: { $0.id == cur }) { return cur }
                    return surfModels.first?.id ?? cur
                },
                set: { newVal in
                    requestSetSurfaceModel(surface: surface, model: newVal)
                }
            )) {
                if surfModels.isEmpty {
                    Text("—").tag("")
                } else {
                    ForEach(surfModels) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(ShellType.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(surfModels.isEmpty || savingSurfaceModels.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) model")

            Picker("Think", selection: Binding(
                get: {
                    let current = surfaceReasoningEffort[surface]
                        ?? selectedChoice?.defaultReasoningEffort
                        ?? "high"
                    return supportedEfforts.contains(current)
                        ? current
                        : (supportedEfforts.first ?? "high")
                },
                set: { newVal in
                    requestSetSurfaceReasoning(surface: surface, effort: newVal)
                }
            )) {
                ForEach(supportedEfforts, id: \.self) { effort in
                    Text(reasoningLabel(effort)).tag(effort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(ShellType.label)
            .frame(width: ProviderSurfaceRowLayout.reasoningPickerWidth)
            .disabled(selectedChoice?.isUnavailable == true
                || supportedEfforts.isEmpty
                || savingSurfaceModels.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) reasoning effort")

            Toggle("Fast", isOn: Binding(
                get: { surfaceFastMode[surface] ?? false },
                set: { enabled in
                    requestSetSurfaceFastMode(surface: surface, enabled: enabled)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(ShellType.label)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: ProviderSurfaceRowLayout.fastToggleWidth)
            .disabled(selectedChoice?.isUnavailable == true
                || selectedChoice?.supportsFast != true
                || savingSurfaceModels.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) Fast mode")
            .help(selectedChoice?.supportsFast == true
                ? "Use the account's priority service tier for this surface."
                : "This account and model do not offer a priority tier.")
        }
        .frame(height: 48)
    }

    private func loadProviders(refreshCatalog: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await ProviderSettingsRefreshAction.perform(
            appModel: appModel,
            refreshCatalog: refreshCatalog
        ) {
        case let .loaded(snapshot):
            providers = snapshot.providers
            rowSet = snapshot.rowSet
            if let catalog = snapshot.catalog {
                catalogModels = catalog.models
            }
            for surface in surfaces {
                if let pid = snapshot.activeProviders[surface] {
                    activeSurface[surface] = pid
                } else if activeSurface[surface] == nil {
                    activeSurface[surface] = "codex"
                }
            }
            // PATCH-2026-05-28 (per-surface model): load the global catalog
            // (fallback model source) and the live per-surface model picks.
            for surface in surfaces {
                if let preference = snapshot.preferences[surface] {
                    surfaceModel[surface] = preference.model
                    surfaceReasoningEffort[surface] = preference.reasoningEffort
                    surfaceFastMode[surface] = preference.serviceTier == "priority"
                } else if let choice = modelsForSurface(surface).first {
                    surfaceModel[surface] = choice.id
                    surfaceReasoningEffort[surface] = choice.supportedReasoningEfforts
                        .contains(choice.defaultReasoningEffort)
                        ? choice.defaultReasoningEffort
                        : (choice.supportedReasoningEfforts.first ?? "high")
                    surfaceFastMode[surface] = false
                }
            }
            // User, 2026-09-06: Refresh reloads the model catalog too, and a
            // catalog read that never reached the provider was overwritten
            // here with a flat "Providers loaded". The read says where its
            // rows came from; so does this line.
            let catalogNote: String? = {
                guard refreshCatalog else { return nil }
                switch snapshot.catalog?.catalogFreshness
                    .flatMap(ModelCatalogFreshness.init(rawValue:)) {
                case .staleAfterFailedRefresh:
                    return "model catalog refresh failed, showing the cached list"
                case .builtInAfterFailedRefresh:
                    return "model catalog refresh failed, showing the built-in list"
                case .cached:
                    return "model catalog unchanged, showing the cached list"
                case .builtIn:
                    return "model catalog showing the built-in list"
                case .liveIncomplete:
                    return "model catalog refreshed; the provider's list may be partial"
                case .live, .none:
                    return nil
                }
            }()
            let loadedText = rowSet.unsupportedStoredKeys.isEmpty
                ? "Providers loaded at \(shortTime())"
                : "Provider settings need repair before every saved surface can be configured."
            statusText = catalogNote.map { "\(loadedText) — \($0)" } ?? loadedText
            providerLoadError = nil
        case let .failed(detail):
            providerLoadError = detail
            statusText = "Load failed: \(detail)"
        }
    }

    private func statusColor(_ tone: ProviderSettingsStatusTextPresentation.Tone) -> Color {
        switch tone {
        case .info, .progress: return NativeAgentShell.secondary
        case .success: return NativeAgentShell.calm
        // The shell palette carries one attention colour. A warning and a
        // failure both wear it; the sentence says which it is.
        case .warning, .failure: return NativeAgentShell.trouble
        }
    }

    private func requestSetActiveSurface(surface: String, providerId: String) {
        let previous = activeSurface[surface] ?? "codex"
        let previousBrain = SurfaceBrainSelection(
            model: surfaceModel[surface] ?? "",
            reasoningEffort: surfaceReasoningEffort[surface] ?? "high",
            fastMode: surfaceFastMode[surface] ?? false
        )
        let token = UUID()
        activeSurface[surface] = providerId
        let nextBrain = reconciledBrainForProvider(surface: surface, providerId: providerId)
        if let nextBrain {
            surfaceModel[surface] = nextBrain.model
            surfaceReasoningEffort[surface] = nextBrain.reasoningEffort
            surfaceFastMode[surface] = nextBrain.fastMode
        }
        activeSurfaceSaveTokens[surface] = token
        savingSurfaces.insert(surface)
        statusText = "Saving \(surfaceLabel(surface))..."
        surfaceModelSaveTasks[surface]?.cancel()
        surfaceModelSaveTasks.removeValue(forKey: surface)
        surfaceModelSaveTokens.removeValue(forKey: surface)
        savingSurfaceModels.remove(surface)
        activeSurfaceSaveTasks[surface]?.cancel()
        activeSurfaceSaveTasks[surface] = Task {
            await setActiveSurface(
                surface: surface,
                providerId: providerId,
                previousProviderId: previous,
                nextBrain: nextBrain,
                previousBrain: previousBrain,
                token: token
            )
        }
    }

    private func setActiveSurface(
        surface: String,
        providerId: String,
        previousProviderId: String,
        nextBrain: SurfaceBrainSelection?,
        previousBrain: SurfaceBrainSelection,
        token: UUID
    ) async {
        guard activeSurfaceSaveTokens[surface] == token else { return }
        do {
            if let nextBrain {
                _ = try await appModel
                    .configureSurfaceSelection(
                        surface: surface,
                        providerID: providerId,
                        model: nextBrain.model,
                        reasoningEffort: nextBrain.reasoningEffort,
                        serviceTier: nextBrain.fastMode ? "priority" : "default"
                    )
            } else {
                _ = try await appModel
                    .setActiveProvider(surface: surface, providerId: providerId)
            }
            guard activeSurfaceSaveTokens[surface] == token else { return }
            savingSurfaces.remove(surface)
            activeSurfaceSaveTokens.removeValue(forKey: surface)
            activeSurfaceSaveTasks.removeValue(forKey: surface)
            if let nextBrain {
                statusText = "\(surfaceLabel(surface)) → \(providerId), \(nextBrain.model) / \(reasoningLabel(nextBrain.reasoningEffort))\(nextBrain.fastMode ? " / Fast" : "") saved"
            } else {
                statusText = "\(surfaceLabel(surface)) → \(providerId) saved"
            }
        } catch {
            guard activeSurfaceSaveTokens[surface] == token else { return }
            if !previousBrain.model.isEmpty {
                _ = try? await appModel.configureSurfaceSelection(
                    surface: surface,
                    providerID: previousProviderId,
                    model: previousBrain.model,
                    reasoningEffort: previousBrain.reasoningEffort,
                    serviceTier: previousBrain.fastMode ? "priority" : "default"
                )
            } else {
                _ = try? await appModel
                    .setActiveProvider(surface: surface, providerId: previousProviderId)
            }
            guard activeSurfaceSaveTokens[surface] == token else { return }
            activeSurface[surface] = previousProviderId
            surfaceModel[surface] = previousBrain.model
            surfaceReasoningEffort[surface] = previousBrain.reasoningEffort
            surfaceFastMode[surface] = previousBrain.fastMode
            savingSurfaces.remove(surface)
            activeSurfaceSaveTokens.removeValue(forKey: surface)
            activeSurfaceSaveTasks.removeValue(forKey: surface)
            statusText = "Set active failed: \(error.localizedDescription)"
        }
    }

    private func requestSetSurfaceModel(surface: String, model: String) {
        guard !model.isEmpty, surfaceModel[surface] != model else { return }
        let previous = SurfaceBrainSelection(
            model: surfaceModel[surface] ?? "",
            reasoningEffort: surfaceReasoningEffort[surface] ?? "high",
            fastMode: surfaceFastMode[surface] ?? false
        )
        guard let choice = modelsForSurface(surface).first(where: { $0.id == model }) else { return }
        let defaultEffort = choice.supportedReasoningEfforts.contains(choice.defaultReasoningEffort)
            ? choice.defaultReasoningEffort
            : (choice.supportedReasoningEfforts.first ?? "high")
        let currentEffort = surfaceReasoningEffort[surface] ?? defaultEffort
        let nextEffort = choice.supportedReasoningEfforts.contains(currentEffort)
            ? currentEffort
            : defaultEffort
        let token = UUID()
        surfaceModel[surface] = model
        surfaceReasoningEffort[surface] = nextEffort
        surfaceFastMode[surface] = choice.supportsFast && (surfaceFastMode[surface] ?? false)
        surfaceModelSaveTokens[surface] = token
        savingSurfaceModels.insert(surface)
        statusText = "Saving \(surfaceLabel(surface)) model…"
        activeSurfaceSaveTasks[surface]?.cancel()
        activeSurfaceSaveTasks.removeValue(forKey: surface)
        activeSurfaceSaveTokens.removeValue(forKey: surface)
        savingSurfaces.remove(surface)
        surfaceModelSaveTasks[surface]?.cancel()
        surfaceModelSaveTasks[surface] = Task {
            await saveSurfaceBrain(surface: surface, previous: previous, token: token)
        }
    }

    private func requestSetSurfaceReasoning(surface: String, effort: String) {
        guard surfaceReasoningEffort[surface] != effort else { return }
        guard selectedModelChoice(for: surface)?.supportedReasoningEfforts.contains(effort) == true else {
            return
        }
        let previous = SurfaceBrainSelection(
            model: surfaceModel[surface] ?? "",
            reasoningEffort: surfaceReasoningEffort[surface] ?? "high",
            fastMode: surfaceFastMode[surface] ?? false
        )
        surfaceReasoningEffort[surface] = effort
        requestSaveSurfaceBrain(surface: surface, previous: previous)
    }

    private func requestSetSurfaceFastMode(surface: String, enabled: Bool) {
        guard surfaceFastMode[surface] != enabled else { return }
        guard selectedModelChoice(for: surface)?.supportsFast == true else { return }
        let previous = SurfaceBrainSelection(
            model: surfaceModel[surface] ?? "",
            reasoningEffort: surfaceReasoningEffort[surface] ?? "high",
            fastMode: surfaceFastMode[surface] ?? false
        )
        surfaceFastMode[surface] = enabled
        requestSaveSurfaceBrain(surface: surface, previous: previous)
    }

    private func requestSaveSurfaceBrain(surface: String, previous: SurfaceBrainSelection) {
        let token = UUID()
        surfaceModelSaveTokens[surface] = token
        savingSurfaceModels.insert(surface)
        statusText = "Saving \(surfaceLabel(surface)) brain…"
        activeSurfaceSaveTasks[surface]?.cancel()
        activeSurfaceSaveTasks.removeValue(forKey: surface)
        activeSurfaceSaveTokens.removeValue(forKey: surface)
        savingSurfaces.remove(surface)
        surfaceModelSaveTasks[surface]?.cancel()
        surfaceModelSaveTasks[surface] = Task {
            await saveSurfaceBrain(surface: surface, previous: previous, token: token)
        }
    }

    private func saveSurfaceBrain(
        surface: String,
        previous: SurfaceBrainSelection,
        token: UUID
    ) async {
        guard surfaceModelSaveTokens[surface] == token else { return }
        let model = surfaceModel[surface] ?? ""
        let effort = surfaceReasoningEffort[surface] ?? "high"
        let fastMode = surfaceFastMode[surface] ?? false
        guard !model.isEmpty else {
            surfaceModel[surface] = previous.model
            surfaceReasoningEffort[surface] = previous.reasoningEffort
            surfaceFastMode[surface] = previous.fastMode
            savingSurfaceModels.remove(surface)
            surfaceModelSaveTokens.removeValue(forKey: surface)
            surfaceModelSaveTasks.removeValue(forKey: surface)
            statusText = "Set brain failed: no model is available for this provider."
            return
        }
        do {
            // The Providers row is already scoped to an explicit provider.
            // Never infer a different auth route from a bare model id here.
            let providerID = activeSurface[surface] ?? "codex"
            _ = try await appModel
                .configureSurfaceSelection(
                    surface: surface,
                    providerID: providerID,
                    model: model,
                    reasoningEffort: effort,
                    serviceTier: fastMode ? "priority" : "default"
                )
            guard surfaceModelSaveTokens[surface] == token else { return }
            savingSurfaceModels.remove(surface)
            surfaceModelSaveTokens.removeValue(forKey: surface)
            surfaceModelSaveTasks.removeValue(forKey: surface)
            statusText = "\(surfaceLabel(surface)) → \(model) / \(reasoningLabel(effort))\(fastMode ? " / Fast" : "") saved"
        } catch {
            guard surfaceModelSaveTokens[surface] == token else { return }
            surfaceModel[surface] = previous.model
            surfaceReasoningEffort[surface] = previous.reasoningEffort
            surfaceFastMode[surface] = previous.fastMode
            savingSurfaceModels.remove(surface)
            surfaceModelSaveTokens.removeValue(forKey: surface)
            surfaceModelSaveTasks.removeValue(forKey: surface)
            statusText = "Set brain failed: \(error.localizedDescription)"
        }
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test

    private func shortTime() -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f.string(from: Date())
    }

    private func surfaceLabel(_ surface: String) -> String {
        ProviderSettingsSurfaceLabel.presentation(for: surface).text
    }
}

// MARK: - Provider Row
// A provider row carries no surface of its own: the card it sits in is the
// surface.

// internal (was private) so the onboarding provider-connect step can reuse the
// SAME row + config sheet as the working Providers settings panel (User,
// 2026-07-04: "show all the options we have — go off the working app").
struct ProviderRowView: View {
    let provider: ProviderInfo
    let onConfigure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: providerIcon(provider.provider_id))
                .font(ShellType.body)
                .foregroundStyle(NativeAgentShell.tertiary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.display_name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                Text(provider.auth_modes.joined(separator: " / "))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ProviderStatusWord(
                text: statusLabel(provider.auth_status.state),
                kind: statusBadgeKind(provider.auth_status.state)
            )
            Button("Set up") {
                onConfigure()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(ShellType.labelMedium)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerIcon(_ id: String) -> String {
        switch id {
        case "codex":             return "sparkles"
        case "anthropic", "anthropic_mcp", "anthropic_oauth_direct": return "brain"
        case "xai", "xai_oauth_direct": return "sparkles"
        case "openrouter":        return "shuffle"
        case "moonshot":          return "moon.stars.fill"
        case "kimi-code":         return "curlybraces"
        case "openai":            return "cpu"
        default:                  return "server.rack"
        }
    }

    private func statusLabel(_ state: String) -> String {
        switch state {
        case "ready":       return "Ready"
        case "needs_key":   return "Needs a key"
        case "needs_oauth": return "Needs a sign-in"
        case "error":       return "Not working"
        default:            return "Not set up"
        }
    }

    private func statusBadgeKind(_ state: String) -> String {
        switch state {
        case "ready":  return "ok"
        case "error":  return "error"
        default:       return "warn"
        }
    }
}

// MARK: - Configure Sheet

// FIRSTRUN-2 (2026-08-01): Save writes a key to disk and used to report a flat
// "Saved." Readiness everywhere downstream is inferred from file presence
// (NativeClient+Providers.swift synthesizes `hasToken` from the file), so a
// typo'd or revoked key read as a working provider until the first chat failed.
//
// Writing a key is not proof the key works. Save now moves the sheet into
// `savedUnverified` and the copy says exactly that; only a passing Test
// Connection promotes it to `verified`. Validation is never auto-fired on save
// — the user presses Test Connection.
enum ProviderCredentialVerification: Equatable {
    /// Nothing written or tested in this sheet session.
    case idle
    /// Credential written to disk, never checked against the service.
    case savedUnverified
    /// Credential written, and this provider has no live probe to check it
    /// with (`tested:false` from testProvider — e.g. Anthropic has no free
    /// probe endpoint). NOT a failure: without this state a working key could
    /// never leave "test failed" (gpt-5.5 review BLOCKING).
    case savedNoProbe
    /// Test Connection came back OK.
    case verified
    /// Test Connection ran and did not come back OK.
    case verificationFailed

    /// Save only ever means "written to disk".
    static func afterSave() -> ProviderCredentialVerification { .savedUnverified }

    /// Test Connection is the only transition that can claim the key works —
    /// and only a probe that actually RAN can claim it failed.
    static func afterTest(_ result: ProviderTestResult) -> ProviderCredentialVerification {
        if result.tested {
            return result.status == "ok" ? .verified : .verificationFailed
        }
        // No live probe ran. "error" means the attempt itself found something
        // wrong before probing (no key on disk) — a real failure. Anything
        // else means the provider is untestable, which must not read as failed.
        return result.status == "error" ? .verificationFailed : .savedNoProbe
    }

    /// Clearing credentials drops any earlier claim.
    static func afterClear() -> ProviderCredentialVerification { .idle }

    /// Short plain-English line shown under the panels. `providerNote` is an
    /// optional provider-specific addendum; it must never claim the key works.
    func statusText(providerNote: String? = nil) -> String {
        let base: String
        switch self {
        case .idle:
            base = ""
        case .savedUnverified:
            base = "Saved to this Mac. Not checked yet — press Test Connection to confirm it works."
        case .savedNoProbe:
            base = "Saved to this Mac. This provider has no connection test — the key is checked on your first real request."
        case .verified:
            base = "Saved and tested. This provider is working."
        case .verificationFailed:
            base = "Saved, but the test failed. Check the key, then test again."
        }
        guard let note = providerNote, !note.isEmpty else { return base }
        return base.isEmpty ? note : "\(base) \(note)"
    }

    /// Header badge override, or `nil` to keep the provider's own auth status.
    /// A file-presence "ready" badge must not sit above an untested key.
    var badge: (text: String, status: String)? {
        switch self {
        case .idle: return nil
        case .savedUnverified: return ("saved · not tested", "warn")
        case .savedNoProbe: return ("saved · no test available", "ok")
        case .verified: return ("tested · working", "ok")
        case .verificationFailed: return ("test failed", "error")
        }
    }
}

/// A provider default is not a per-surface model pin. The sheet may write the
/// former only after the selected catalog item is still advertised; an absent
/// or stale default remains visible for replacement rather than being silently
/// coerced into an unrelated model.
enum ProviderConfigModelPickerPresentation: Equatable {
    case noCatalog
    case selected
    case staleSelection(String)

    static func resolve(selectedModel: String, advertisedModelIDs: [String]) -> Self {
        guard !advertisedModelIDs.isEmpty else { return .noCatalog }
        return advertisedModelIDs.contains(selectedModel)
            ? .selected
            : .staleSelection(selectedModel)
    }

    var needsReplacement: Bool {
        if case .staleSelection = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .noCatalog:
            return "Model catalog unavailable. Any saved default remains unchanged until models can be loaded."
        case .selected:
            return nil
        case let .staleSelection(model):
            return "Saved default \(model) is not in this provider's current model catalog. Choose a replacement before saving."
        }
    }
}

/// The provider catalog is the auth-mode authority for the configuration
/// sheet. Normalize its wire values once so a stale persisted mode cannot
/// become an untagged Picker selection or be written back as an unsupported
/// route.
struct ProviderAuthModePickerState: Equatable {
    let supportedModes: [String]
    let selectedMode: String
    let repairedSavedMode: String?

    var canSave: Bool { supportedModes.contains(selectedMode) }
}

enum ProviderAuthModePickerPresentation {
    private static let knownModes: Set<String> = ["api_key", "oauth"]

    static func resolve(
        advertisedModes: [String],
        savedMode: String?,
        providerIsReady: Bool
    ) -> ProviderAuthModePickerState {
        var seen = Set<String>()
        let supportedModes = advertisedModes.compactMap { raw -> String? in
            let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownModes.contains(mode), seen.insert(mode).inserted else { return nil }
            return mode
        }
        let normalizedSavedMode = savedMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let normalizedSavedMode, supportedModes.contains(normalizedSavedMode) {
            return ProviderAuthModePickerState(
                supportedModes: supportedModes,
                selectedMode: normalizedSavedMode,
                repairedSavedMode: nil
            )
        }
        let fallback = providerIsReady && supportedModes.contains("oauth")
            ? "oauth"
            : (supportedModes.first ?? "")
        return ProviderAuthModePickerState(
            supportedModes: supportedModes,
            selectedMode: fallback,
            repairedSavedMode: normalizedSavedMode?.isEmpty == false ? normalizedSavedMode : nil
        )
    }
}

struct ProviderConfigSheet: View {
    let provider: ProviderInfo
    let onDone: () -> Void

    @Environment(AppModel.self) private var appModel
    @State private var apiKey = ""
    @State private var authMode: String
    @State private var selectedModel = ""
    @State private var availableModels: [ProviderModelInfo]
    @State private var testResult: ProviderTestResult? = nil
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var statusText = ""
    @State private var showRemoveCredentialsConfirm = false
    /// FIRSTRUN-2: tracks whether the credential in this sheet has actually
    /// been proven against the service, independent of the file-presence
    /// readiness the provider row reports.
    @State private var verification: ProviderCredentialVerification = .idle

    private var authModePickerState: ProviderAuthModePickerState {
        ProviderAuthModePickerPresentation.resolve(
            advertisedModes: provider.auth_modes,
            savedMode: provider.auth_mode,
            providerIsReady: provider.auth_status.state == "ready"
        )
    }

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider
        self.onDone = onDone
        let authModeState = ProviderAuthModePickerPresentation.resolve(
            advertisedModes: provider.auth_modes,
            savedMode: provider.auth_mode,
            providerIsReady: provider.auth_status.state == "ready"
        )
        _authMode = State(initialValue: authModeState.selectedMode)
        let savedModel = provider.default_model?.trimmingCharacters(in: .whitespacesAndNewlines)
        _selectedModel = State(initialValue: savedModel?.isEmpty == false ? savedModel! : (provider.models.first?.id ?? ""))
        _availableModels = State(initialValue: provider.models)
    }

    private var modelPickerPresentation: ProviderConfigModelPickerPresentation {
        ProviderConfigModelPickerPresentation.resolve(
            selectedModel: selectedModel,
            advertisedModelIDs: availableModels.map(\.id)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.display_name)
                        .font(ShellType.title)
                        .foregroundStyle(NativeAgentShell.text)
                    // FIRSTRUN-2: an unverified save must not inherit the
                    // file-presence "ready" badge.
                    if let badge = verification.badge {
                        ProviderStatusWord(text: badge.text, kind: badge.status)
                    } else {
                        ProviderStatusWord(
                            text: provider.auth_status.state == "ready" ? "Ready" : "Not set up",
                            kind: provider.auth_status.state == "ready" ? "ok" : "warn"
                        )
                    }
                }
                Spacer(minLength: 8)
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .font(ShellType.labelMedium)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if authModePickerState.supportedModes.isEmpty {
                        ProviderSection(label: "How to sign in") {
                            ProviderCard {
                                ProviderCardTitle(
                                    title: "No way in was offered",
                                    line: "This account did not name a sign-in method. Refresh the accounts, or repair its configuration, before saving."
                                )
                            }
                        }
                    } else if authModePickerState.supportedModes.count > 1 {
                        ProviderSection(label: "How to sign in") {
                            ProviderCard {
                                Picker("Mode", selection: $authMode) {
                                    ForEach(authModePickerState.supportedModes, id: \.self) { mode in
                                        Text(authModeLabel(mode)).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                    }

                    if let repaired = authModePickerState.repairedSavedMode,
                       !authModePickerState.supportedModes.isEmpty {
                        ProviderNote(
                            text: "The saved sign-in method is no longer offered, so \(authModeLabel(authMode)) is being used instead.",
                            color: NativeAgentShell.trouble
                        )
                        .accessibilityLabel("The saved sign-in method \(repaired) is no longer offered.")
                    }

                    // API Key input (shown when api_key mode or provider only supports api_key)
                    if authMode == "api_key" {
                        ProviderSection(label: "Key") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SecureField("Paste the key here", text: $apiKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(ProviderType.code)
                                    ProviderNote(text: "The key is kept on this Mac only, readable by you alone, and is never written to a log.")
                                }
                            }
                        }
                    }

                    if authMode == "oauth" {
                        ProviderSection(label: "Sign in") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    if provider.provider_id == "anthropic" {
                                        Text("Use your Claude Pro or Max subscription through the Claude command-line tool instead of paying for credits.")
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let userInfo = provider.auth_status.user_info {
                                            ProviderNote(text: userInfo["version"] ?? "claude command-line tool")
                                        }
                                    } else if provider.provider_id == "anthropic_mcp" {
                                        AnthropicMCPStatusPanel(provider: provider, appModel: appModel)
                                    } else if provider.provider_id == "anthropic_oauth_direct" {
                                        AnthropicOAuthDirectPanel()
                                    } else if provider.provider_id == "xai_oauth_direct" {
                                        Text("Sign in to xAI for Grok models.")
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.text)
                                        OAuthSignInButton(provider: .xai) {
                                            Task { await appModel.loadProvidersForChat() }
                                        }
                                    }
                                    ProviderNote(text: provider.auth_status.detail)
                                }
                            }
                        }
                    }

                    if !availableModels.isEmpty {
                        ProviderSection(label: "Model it falls back to") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Model", selection: $selectedModel) {
                                        ForEach(availableModels) { model in
                                            Text(model.name).tag(model.id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                    .font(ShellType.label)
                                    ProviderNote(text: "This is the model used by a surface that is assigned to this provider and has not pinned one of its own. Surface assignments and pins are set on the Providers page.")
                                    if let message = modelPickerPresentation.message {
                                        ProviderNote(text: message, color: NativeAgentShell.trouble)
                                    }
                                    if let model = availableModels.first(where: { $0.id == selectedModel }) {
                                        HStack(spacing: 12) {
                                            capabilityPill("Streaming", ok: model.supports_streaming)
                                            capabilityPill("Vision", ok: model.supports_vision)
                                            capabilityPill("Tools", ok: model.supports_tools)
                                            capabilityPill("JSON", ok: model.supports_json_mode)
                                        }
                                    }
                                }
                            }
                        }
                    } else if !selectedModel.isEmpty,
                              let message = modelPickerPresentation.message {
                        ProviderSection(label: "Model it falls back to") {
                            ProviderCard {
                                ProviderNote(text: message, color: NativeAgentShell.trouble)
                            }
                        }
                    }

                    if let result = testResult {
                        ProviderSection(label: "Connection test") {
                            ProviderCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    if result.tested {
                                        if let response = result.response {
                                            Text(response)
                                                .font(ShellType.label)
                                                .foregroundStyle(NativeAgentShell.text)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let error = result.error {
                                            ProviderNote(text: error, color: NativeAgentShell.trouble)
                                        }
                                        if let model = result.model_used {
                                            ProviderNote(text: model)
                                        }
                                    } else {
                                        ProviderNote(text: result.detail ?? "The test did not run.")
                                    }
                                }
                            }
                        }
                    }

                    if !statusText.isEmpty {
                        ProviderNote(text: statusText)
                    }

                    HStack(spacing: 8) {
                        Button(isSaving ? "Saving…" : "Save") {
                            Task { await saveConfig() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || modelPickerPresentation.needsReplacement || !authModePickerState.canSave)

                        Button(isTesting ? "Testing…" : "Test the connection") {
                            Task { await runTest() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)

                        Spacer(minLength: 8)

                        Button("Remove the key", role: .destructive) {
                            showRemoveCredentialsConfirm = true
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(ShellType.labelMedium)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .confirmationDialog(
            "Remove the \(provider.display_name) key?",
            isPresented: $showRemoveCredentialsConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove the key", role: .destructive) {
                Task { await clearConfig() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects the account and removes its saved key from this Mac. Surfaces using it stop working until another account is chosen.")
        }
    }

    private func saveConfig() async {
        guard authModePickerState.supportedModes.contains(authMode) else {
            statusText = "Save failed: choose a supported authentication method first."
            return
        }
        isSaving = true
        do {
            _ = try await appModel.configureProvider(
                provider.provider_id,
                apiKey: authMode == "api_key" ? apiKey : nil,
                authMode: authMode,
                defaultModel: selectedModel
            )
            let refreshed = try await appModel.listProviders()
            if let current = refreshed.first(where: { $0.provider_id == provider.provider_id }) {
                availableModels = current.models
            }
            await appModel.loadProvidersForChat()
            // FIRSTRUN-2: the key is on disk, nothing more. Any earlier
            // "verified" claim is stale now that the credential changed.
            verification = .afterSave()
            testResult = nil
            statusText = verification.statusText(providerNote: {
                switch provider.provider_id {
                case "moonshot":
                    return "Moonshot model choices are ready."
                case "kimi-code":
                    return "Kimi Code model choices are ready; the server accepts the tiers your subscription allows."
                default:
                    return nil
                }
            }())
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func runTest() async {
        isTesting = true
        testResult = nil
        // User, 2026-09-06: test what the sheet is showing. A key typed here and
        // not saved yet is the credential the person is asking about; testing
        // the saved one instead let a bad draft read "Saved and tested" off the
        // old key, and made a valid pasted key report "no api key configured"
        // on a fresh install. A draft result never touches `verification` —
        // that state describes the SAVED credential, and nothing was saved.
        let draftKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let testsDraft = authMode == "api_key" && !draftKey.isEmpty
        do {
            let result = try await appModel.testProvider(
                provider.provider_id,
                apiKeyOverride: testsDraft ? draftKey : nil
            )
            testResult = result
            if testsDraft {
                if result.tested && result.status == "ok" {
                    statusText = "Tested the key typed here and it works. It is not saved yet — press Save to keep it."
                } else if result.tested {
                    statusText = "Tested the key typed here and it did not work. It is not saved."
                } else {
                    statusText = "This provider has no connection test, so the key typed here was not checked. Press Save to keep it."
                }
            } else {
                // FIRSTRUN-2: Test Connection is the only thing that can clear
                // the saved-but-unverified state.
                verification = .afterTest(result)
                statusText = verification.statusText(
                    providerNote: "This tested the key saved on this Mac."
                )
            }
        } catch {
            if !testsDraft {
                verification = .verificationFailed
            }
            statusText = "Test error: \(error.localizedDescription)"
        }
        isTesting = false
    }

    private func clearConfig() async {
        do {
            _ = try await appModel.clearProvider(provider.provider_id)
            // User, 2026-09-06: for an OAuth provider the credential does not
            // live in providers/<id>.json — ChatGPT's is in codex_home/auth.json
            // and the others in their adapters' own token files — so removing
            // the registry row left the account connected while the sheet said
            // it had been disconnected. Go through the same path the OAuth
            // "Sign out" button uses; it no-ops for non-OAuth providers.
            _ = NativeOAuthFlow.clearTokens(
                providerId: provider.provider_id,
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            )
            apiKey = ""
            verification = .afterClear()
            testResult = nil
            // The shared ~/.codex/auth.json belongs to the Codex CLI and is
            // never deleted here, so say so rather than claiming a removal
            // that did not happen (same wording the Sign out button uses).
            // User, 2026-09-06: this asked `isSignedIn`, which reads the auth
            // path chat will USE — and the removal just flipped CLI adoption to
            // declined, so the normal case answered false and reported
            // "Credentials removed" with the shared file still on disk. The
            // disclosure now keys off the shared file itself.
            statusText = NativeOAuthFlow.sharedCodexCLISessionRemains(
                providerId: provider.provider_id
            )
                ? "Shared Codex auth is still signed in. Sign out from Codex to remove it."
                : "Credentials removed."
            // S.5: propagate cleared credentials to the provider list so the
            // parent ProviderSettingsView and the chat brain bar reflect the
            // new auth_status (needs_key / needs_oauth) immediately.
            await appModel.loadProvidersForChat()
        } catch {
            statusText = "Clear failed: \(error.localizedDescription)"
        }
    }

    private func authModeLabel(_ mode: String) -> String {
        switch mode {
        case "api_key": return "A key"
        case "oauth":   return "A sign-in"
        default:        return "Something else"
        }
    }

    /// What the model can do, said in words. Calm when it can, quiet when it
    /// cannot — no plate under either.
    @ViewBuilder
    private func capabilityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(ShellType.caption)
            .foregroundStyle(ok ? NativeAgentShell.calm : NativeAgentShell.tertiary)
    }
}

// MARK: - PATCH-2026-05-07: anthropic-mcp status panel

/// A local Claude CLI presence check is the only evidence this panel has for
/// its persistent-MCP connection claim. Do not manufacture readiness from a
/// provider-list payload that may have been collected before the CLI moved or
/// was removed.
enum AnthropicMCPCLIProbe {
    enum Availability: Equatable {
        case checking
        case available(path: String)
        case unavailable(reason: String)
    }

    static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Availability {
        guard let path = environment["PATH"], !path.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH is unavailable.")
        }
        let directories = path.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        guard !directories.isEmpty else {
            return .unavailable(reason: "Claude CLI could not be checked because PATH has no absolute directories.")
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("claude")
                .path
            if isExecutable(candidate) {
                return .available(path: candidate)
            }
        }
        return .unavailable(reason: "Claude CLI was not found on PATH. Install or restore Claude Code, then test again.")
    }
}

struct AnthropicMCPStatusPresentation: Equatable {
    enum ProcessStatus: Equatable {
        case alive
        case notRunning
        case unavailable

        var label: String {
            switch self {
            case .alive: "Process alive"
            case .notRunning: "Not running"
            case .unavailable: "Process status unavailable"
            }
        }

        var badgeStatus: String {
            switch self {
            case .alive: "ok"
            case .notRunning, .unavailable: "warn"
            }
        }
    }

    let headline: String?
    let cliBadge: String
    let cliBadgeStatus: String
    let detail: String?
    let version: String?
    let mode: String?
    let processStatus: ProcessStatus?

    static func make(
        availability: AnthropicMCPCLIProbe.Availability,
        userInfo: [String: String]?
    ) -> Self {
        switch availability {
        case .checking:
            return Self(
                headline: nil,
                cliBadge: "Checking Claude CLI…",
                cliBadgeStatus: "warn",
                detail: nil,
                version: nil,
                mode: nil,
                processStatus: nil
            )
        case .unavailable(let reason):
            return Self(
                headline: nil,
                cliBadge: "Claude CLI unavailable",
                cliBadgeStatus: "error",
                detail: reason,
                version: nil,
                mode: nil,
                processStatus: nil
            )
        case .available:
            let mode = userInfo?["mode"]
            let processStatus: ProcessStatus
            switch userInfo?["mcp_process_alive"]?.lowercased() {
            case "true": processStatus = .alive
            case "false": processStatus = .notRunning
            default: processStatus = .unavailable
            }
            return Self(
                headline: processStatus == .alive
                    ? "Persistent connection via Claude CLI"
                    : nil,
                cliBadge: "Claude CLI available",
                cliBadgeStatus: "ok",
                detail: processStatus == .alive
                    ? nil
                    : "Claude CLI is available, but no persistent MCP process is confirmed.",
                version: userInfo?["version"],
                mode: mode == "mcp_server" ? "MCP server" : "per-call stream",
                processStatus: processStatus
            )
        }
    }
}

private struct AnthropicMCPStatusPanel: View {
    let provider: ProviderInfo
    let appModel: AppModel

    @State private var testResult: String = ""
    @State private var isTesting = false
    @State private var cliAvailability: AnthropicMCPCLIProbe.Availability = .checking

    var body: some View {
        let presentation = AnthropicMCPStatusPresentation.make(
            availability: cliAvailability,
            userInfo: provider.auth_status.user_info
        )
        VStack(alignment: .leading, spacing: 8) {
            if let headline = presentation.headline {
                Text(headline)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
            }
            HStack(spacing: 12) {
                ProviderStatusWord(text: presentation.cliBadge, kind: presentation.cliBadgeStatus)
                if let version = presentation.version {
                    Text(version)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                if let mode = presentation.mode {
                    Text(mode)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                if let processStatus = presentation.processStatus {
                    ProviderStatusWord(text: processStatus.label, kind: processStatus.badgeStatus)
                }
            }
            if let detail = presentation.detail {
                ProviderNote(text: detail)
            }
            Button(isTesting ? "Testing…" : "Test the connection") {
                Task { await runPersistentTest() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(ShellType.labelMedium)
            .disabled(isTesting)
            if !testResult.isEmpty {
                ProviderNote(text: testResult)
            }
        }
        .task(id: provider.auth_status.last_checked_at) {
            cliAvailability = AnthropicMCPCLIProbe.probe()
        }
    }

    private func runPersistentTest() async {
        isTesting = true
        testResult = ""
        cliAvailability = AnthropicMCPCLIProbe.probe()
        if case .unavailable(let reason) = cliAvailability {
            testResult = reason
            isTesting = false
            return
        }
        do {
            let result = try await appModel.testProvider(provider.provider_id)
            if result.tested {
                testResult = result.response ?? result.error ?? "ok"
            } else {
                testResult = result.detail ?? result.status
            }
        } catch {
            testResult = "Error: \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - PATCH-2026-05-07: anthropic-oauth-direct panel

enum AnthropicOAuthDirectPanelPresentation {
    static let title = "Connect via Anthropic OAuth"
    static let detail = "Full capability API access (streaming, vision, tools) using your own OAuth credentials."
}

struct AnthropicOAuthDirectPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AnthropicOAuthDirectPanelPresentation.title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            ProviderNote(text: AnthropicOAuthDirectPanelPresentation.detail)
            // Provider list rows are a snapshot. The canonical sign-in control
            // reads the same root it writes, so this panel cannot keep offering
            // Connect after the browser flow committed or claim authorization
            // from a stale provider-list response.
            OAuthSignInButton(provider: .anthropic)
        }
    }
}

// MARK: - Page kit
//
// The page's own small vocabulary: an eyebrow over a run, the card a group of
// controls sits in, the card's own headline, one quiet line, and the one word
// that says how an account stands.

/// 13 monospaced, for a value that is a code. `ShellType` carries no
/// monospaced face, so this derives one from the token size.
private enum ProviderType {
    static let code = Font.system(size: ShellType.labelSize, design: .monospaced)
}

private struct ProviderSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
            content
        }
    }
}

private struct ProviderCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(TodayPalette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
            )
    }
}

private struct ProviderCardTitle: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ShellType.bodySemibold)
                .foregroundStyle(NativeAgentShell.text)
            Text(line)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderNote: View {
    let text: String
    var color: Color = NativeAgentShell.secondary

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// How an account stands, in one word, in one of the two colours the shell
/// palette carries for state. No plate: a coloured word on the card is enough.
private struct ProviderStatusWord: View {
    let text: String
    /// "ok", "warn" or "error", as the presentation types already spell it.
    let kind: String

    var body: some View {
        Text(text)
            .font(ShellType.captionSemibold)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var color: Color {
        switch kind {
        case "ok": NativeAgentShell.calm
        // The shell palette has one attention colour; a warning and a failure
        // both wear it, and the word says which it is.
        case "warn", "error": NativeAgentShell.trouble
        default: NativeAgentShell.secondary
        }
    }
}
