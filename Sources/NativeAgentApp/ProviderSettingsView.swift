// PATCH-2026-05-07: model-providers v1 — ProviderSettingsView: Models & Providers settings sub-section
// PATCH-2026-05-07: leftover-2 per-surface active provider picker (Mac side)
import SwiftUI
import ProviderRouting

private enum ProviderSurfaceRowLayout {
    // Includes the field label, the longest current value ("No Think"), and
    // the macOS menu-picker chrome without truncating the active selection.
    static let reasoningPickerWidth: CGFloat = 148
    static let fastToggleWidth: CGFloat = 88
}

// MARK: - Main View

struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var providers: [ProviderInfo] = []
    @State private var isLoading = false
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

    // Single source of truth (2026-06-10): the canonical surface list lives
    // in ProviderRouting.MODEL_SURFACES. The previous hardcoded copy here
    // had already drifted — it was missing "rem", so the REM surface was
    // unpinnable from this panel despite being picker-routed since 06-05.
    private let surfaces = MODEL_SURFACES

    private struct SurfaceModelChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let defaultReasoningEffort: String
        let supportedReasoningEfforts: [String]
        let supportsFast: Bool
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
                    supportsFast: $0.supports_fast == true
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
                supportsFast: $0.supportsFast == true
            )
        }
    }

    /// Models offered for a surface, scoped to the provider selected for it.
    private func modelsForSurface(_ surface: String) -> [SurfaceModelChoice] {
        let pid = activeSurface[surface] ?? "codex"
        return modelsForProvider(pid)
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
        // PATCH-2026-06-06: 2-column layout — provider list + OAuth on the left
        // (~360pt cap), per-surface picker on the right (flex). The picker is
        // what the user uses daily; it stays visible while clicking around the
        // OAuth/provider panels on the left.
        HStack(alignment: .top, spacing: 16) {
            providerListColumn
                .frame(maxWidth: 360)

            Divider()

            perSurfacePickerColumn
        }
        .padding()
        .sheet(item: $configureSheet) { provider in
            ProviderConfigSheet(provider: provider) {
                configureSheet = nil
                Task { await loadProviders() }
            }
            .environment(appModel)
        }
        .task { await loadProviders() }
    }

    /// Left column: header blurb + OAuth panels + Telegram + Providers list.
    /// Everything that's not the per-surface picker.
    @ViewBuilder
    private var providerListColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativePanel(title: "Models & Providers", systemImage: "cpu.fill") {
                    Text("Choose which LLM provider powers each surface. Codex (ChatGPT OAuth) is the default — existing behavior is unchanged unless you override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // A2.2 close-out (2026-07-24): title/copy said sign-in ran
                // through Codex's device flow — stale since the 2026-07-05
                // codex-free loopback cutover. The codex device flow remains
                // the alternative path (its in-flight UI renders below).
                NativePanel(title: "ChatGPT", systemImage: "person.crop.circle.badge.checkmark") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in with your ChatGPT Plus/Pro account in your browser — no extra tools needed. The codex CLI device flow remains available as an alternative.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        OAuthSignInButton(provider: .chatgpt) {
                            Task { await loadProviders() }
                        }
                        if let login = appModel.codexDeviceLogin {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Open \(login.url ?? "https://auth.openai.com/codex/device")")
                                    .font(.caption)
                                Text("Code: \(login.code ?? "pending")")
                                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                                if let home = login.codexHome, !home.isEmpty {
                                    Text("CODEX_HOME: \(home)")
                                        .font(NativeAgentFont.mono)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Button("Cancel", systemImage: "xmark.circle") {
                                        Task { await appModel.cancelCodexDeviceLogin() }
                                    }
                                    Button("Clear", systemImage: "eraser") {
                                        Task { await appModel.clearCodexDeviceLogin() }
                                    }
                                }
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                        }
                    }
                }
                // PATCH-2026-05-07: anthropic-oauth-direct Sign-in panel — direct
                // OAuth to Anthropic (no Claude Code CLI dependency). Same
                // public client_id Claude Code CLI uses, so tokens stay
                // compatible if you use both.
                NativePanel(title: "Anthropic (OAuth direct)", systemImage: "brain.head.profile") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Two ways to authenticate with Anthropic. Setup-token is the path Anthropic recommends for third-party tools (NativeAgent counts as one); generate it at console.anthropic.com → Settings → OAuth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        OAuthSignInButton(provider: .anthropic) {
                            Task { await loadProviders() }
                        }
                        Divider()
                        AnthropicSetupTokenInput {
                            Task { await loadProviders() }
                        }
                    }
                }

                NativePanel(title: "xAI Grok (OAuth direct)", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in with xAI to use Grok models as a NativeAgent model provider. This is separate from the X connector; tokens stay in NativeAgent's provider store.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        OAuthSignInButton(provider: .xai) {
                            Task { await loadProviders() }
                        }
                    }
                }

                // Dead-weight sweep 2026-07-03: the inline TelegramBotSetupInput
                // panel duplicated the Telegram settings surface — two write
                // paths to telegram/config.json that didn't refresh each other.
                // Telegram settings own the config; this is now a pointer.
                NativePanel(title: "Telegram Bot", systemImage: "paperplane.fill") {
                    HStack {
                        Text("Bot token, allowlist, and model live in Telegram settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Telegram Settings", systemImage: "arrow.right.circle") {
                            NotificationCenter.default.post(name: .openTelegramRequest, object: nil)
                        }
                    }
                }

                NativePanel(title: "Providers", systemImage: "server.rack") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading providers…").font(NativeAgentFont.label).foregroundStyle(.secondary)
                        }
                    } else if providers.isEmpty {
                        NativeEmptyState(
                            title: "No Providers",
                            detail: "Tap Refresh to load available providers.",
                            systemImage: "server.rack"
                        )
                        .frame(minHeight: 120)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(providers.indices, id: \.self) { index in
                                let provider = providers[index]
                                ProviderRowView(provider: provider) {
                                    configureSheet = provider
                                }
                                if index < providers.index(before: providers.endIndex) {
                                    Divider()
                                        .padding(.leading, 44)
                                }
                            }
                        }
                        .background(
                            Color(nsColor: .controlBackgroundColor).opacity(0.45),
                            in: RoundedRectangle(
                                cornerRadius: NativeAgentRadius.control,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: NativeAgentRadius.control,
                                style: .continuous
                            )
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                        }
                    }
                    HStack {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await loadProviders(refreshCatalog: true) }
                        }
                        // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test
                    }
                }

                // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test (results panel)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        // ui-taste-sweep 2026-06-07: was falling back to the bundle name.
        .navigationTitle("Providers")
    }

    /// Right column: per-surface provider + model picker. Pinned so the user can
    /// switch the chat model without scrolling past the OAuth panels.
    @ViewBuilder
    private var perSurfacePickerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NativePanel(title: "Active per Surface", systemImage: "square.3.layers.3d.top.filled") {
                    if pickerProviders.isEmpty {
                        Text("Load providers first to configure per-surface overrides.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(surfaces, id: \.self) { surface in
                                HStack(spacing: 8) {
                                    Text(surfaceLabel(surface))
                                        .frame(width: 112, alignment: .leading)
                                        .font(.callout)
                                    Picker("Provider", selection: Binding(
                                        get: { activeSurface[surface] ?? "codex" },
                                        set: { newVal in
                                            requestSetActiveSurface(surface: surface, providerId: newVal)
                                        }
                                    )) {
                                        ForEach(pickerProviders) { provider in
                                            let ready = provider.auth_status.state == "ready"
                                            Text(provider.display_name + (ready ? "" : " ⚠️"))
                                                .tag(provider.provider_id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 210)
                                    .disabled(savingSurfaces.contains(surface))
                                    .accessibilityLabel("\(surfaceLabel(surface)) provider")

                                    // PATCH-2026-05-28 (per-surface model):
                                    // model picker scoped to the provider chosen
                                    // for THIS surface. Plain dropdown (no search)
                                    // even for OpenRouter's long list.
                                    let surfModels = modelsForSurface(surface)
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .disabled(surfModels.isEmpty || savingSurfaceModels.contains(surface))
                                    .accessibilityLabel("\(surfaceLabel(surface)) model")

                                    let selectedChoice = selectedModelChoice(for: surface)
                                    let supportedEfforts = selectedChoice?.supportedReasoningEfforts
                                        ?? ["low", "medium", "high", "xhigh"]
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
                                    .frame(width: ProviderSurfaceRowLayout.reasoningPickerWidth)
                                    .disabled(supportedEfforts.isEmpty || savingSurfaceModels.contains(surface))
                                    .accessibilityLabel("\(surfaceLabel(surface)) reasoning effort")

                                    Toggle("Fast", isOn: Binding(
                                        get: { surfaceFastMode[surface] ?? false },
                                        set: { enabled in
                                            requestSetSurfaceFastMode(surface: surface, enabled: enabled)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(width: ProviderSurfaceRowLayout.fastToggleWidth)
                                    .disabled(selectedChoice?.supportsFast != true || savingSurfaceModels.contains(surface))
                                    .accessibilityLabel("\(surfaceLabel(surface)) Fast mode")
                                    .help(selectedChoice?.supportsFast == true
                                        ? "Use the account-advertised priority service tier for this surface."
                                        : "Fast is not advertised for this provider/model.")
                                }
                                .padding(.vertical, 3)
                                if surface != surfaces.last {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadProviders(refreshCatalog: Bool = false) async {
        isLoading = true
        do {
            if refreshCatalog {
                _ = try await appModel.getModelCatalog(refresh: true)
            }
            providers = try await appModel.listProviders()
            // Read the canonical active-provider store so the picker and
            // execution route share one owner. Damaged state fails the whole
            // refresh and preserves the prior visible values.
            let liveAps = try await fetchLiveActivePerSurface()
            for surface in surfaces {
                if let pid = liveAps[surface] {
                    activeSurface[surface] = pid
                } else if activeSurface[surface] == nil {
                    activeSurface[surface] = "codex"
                }
            }
            // PATCH-2026-05-28 (per-surface model): load the global catalog
            // (fallback model source) and the live per-surface model picks.
            if let catalog = try? await appModel.getModelCatalog(refresh: false) {
                catalogModels = catalog.models
            }
            let liveModels = try await fetchLiveSurfacePreferences()
            for surface in surfaces {
                if let preference = liveModels[surface] {
                    surfaceModel[surface] = preference.model
                    surfaceReasoningEffort[surface] = preference.reasoningEffort
                    surfaceFastMode[surface] = preference.fastMode
                } else if let choice = modelsForSurface(surface).first {
                    surfaceModel[surface] = choice.id
                    surfaceReasoningEffort[surface] = choice.supportedReasoningEfforts
                        .contains(choice.defaultReasoningEffort)
                        ? choice.defaultReasoningEffort
                        : (choice.supportedReasoningEfforts.first ?? "high")
                    surfaceFastMode[surface] = false
                }
            }
            statusText = "Providers loaded at \(shortTime())"
        } catch {
            statusText = "Load failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Read the per-surface active-provider map from the SAME on-disk file
    /// the save path writes to: `<dataRoot>/providers/active.json`. Returns
    /// Missing is empty; damaged authority state throws so the panel retains
    /// its prior values and reports a failed refresh instead of showing fake
    /// Codex defaults.
    ///
    /// SAVE/READ UNIFICATION (eval E03 fix): the save side
    /// (`NativeClient.setActiveProvider`) persists to `providers/active.json`
    /// via flock-protected writeActiveProvider. Reading from
    /// `trust.providerPolicy.active_per_surface` (the prior path) was an
    /// independent source that never reflected the new on-disk state, so the
    /// UI's picker drifted off the actual routing decision after every save.
    private func fetchLiveActivePerSurface() async throws -> [String: String] {
        try await NativeClient.readActiveProvidersFromDisk()
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

    // Read the complete per-surface brain selection from the Swift provider
    // router so Providers shows the same model/Think/Fast values execution uses.
    private func fetchLiveSurfacePreferences() async throws -> [String: SurfaceBrainSelection] {
        try await SwiftNativeProviderRouting()
            .computeModelPreferences()
            .reduce(into: [String: SurfaceBrainSelection]()) { out, pair in
                out[pair.key] = SurfaceBrainSelection(
                    model: pair.value.model,
                    reasoningEffort: pair.value.reasoningEffort,
                    fastMode: pair.value.serviceTier == "priority"
                )
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
        switch surface {
        case "chat":      return "Chat"
        case "ios":       return "iPhone"
        case "missions":  return "Workshop"
        case "training":  return "Training"
        case "dream":     return "Dream"
        case "telegram":  return "Telegram"
        case "slack":     return "Slack"
        case "autonomy":  return "Autonomy"
        case "swarms":    return "Swarms"
        case "rem":       return "REM"
        case "memory":    return "Memory"
        case "heartbeat": return "Heartbeat"
        case "diagnostics": return "Diagnostics"
        case "cognition_reflection": return "Cognition Reflection"
        default:          return surface.capitalized
        }
    }
}

// MARK: - Provider Row
// Provider rows are plain grouped-list content because the parent NativePanel
// already provides the containing surface.

// internal (was private) so the onboarding provider-connect step can reuse the
// SAME row + config sheet as the working Providers settings panel (User,
// 2026-07-04: "show all the options we have — go off the working app").
struct ProviderRowView: View {
    let provider: ProviderInfo
    let onConfigure: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: providerIcon(provider.provider_id))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.display_name)
                    .font(NativeAgentFont.section)
                    .lineLimit(1)
                Text(provider.auth_modes.joined(separator: " / "))
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(
                text: statusLabel(provider.auth_status.state),
                status: statusBadgeKind(provider.auth_status.state)
            )
            Button("Configure", systemImage: "slider.horizontal.3") {
                onConfigure()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, NativeAgentSpacing.sm)
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
        case "needs_key":   return "Needs key"
        case "needs_oauth": return "Needs OAuth"
        case "error":       return "Error"
        default:            return state
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

    init(provider: ProviderInfo, onDone: @escaping () -> Void) {
        self.provider = provider
        self.onDone = onDone
        let savedMode = provider.auth_mode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackMode = provider.auth_modes.contains("oauth") && provider.auth_status.state == "ready"
            ? "oauth"
            : (provider.auth_modes.first ?? "api_key")
        _authMode = State(initialValue: (savedMode?.isEmpty == false ? savedMode! : fallbackMode))
        let savedModel = provider.default_model?.trimmingCharacters(in: .whitespacesAndNewlines)
        _selectedModel = State(initialValue: savedModel?.isEmpty == false ? savedModel! : (provider.models.first?.id ?? ""))
        _availableModels = State(initialValue: provider.models)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.display_name)
                        .font(.title2).bold()
                    StatusBadge(
                        text: provider.auth_status.state,
                        status: provider.auth_status.state == "ready" ? "ok" : "warn"
                    )
                }
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Auth mode
                    if provider.auth_modes.count > 1 {
                        NativePanel(title: "Authentication Mode", systemImage: "key.fill") {
                            Picker("Mode", selection: $authMode) {
                                ForEach(provider.auth_modes, id: \.self) { mode in
                                    Text(authModeLabel(mode)).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // API Key input (shown when api_key mode or provider only supports api_key)
                    if authMode == "api_key" || provider.auth_modes == ["api_key"] {
                        NativePanel(title: "API Key", systemImage: "lock.fill") {
                            SecureField("Paste API key here…", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(NativeAgentFont.mono)
                            Text("Stored at ~/Library/Application Support/NativeAgent/providers/\(provider.provider_id).json with 0600 permissions. Never logged.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // OAuth info
                    if authMode == "oauth" {
                        NativePanel(title: "OAuth / Subscription", systemImage: "person.crop.circle.badge.checkmark") {
                            if provider.provider_id == "anthropic" {
                                Text("Use your Claude Pro/Max subscription via the Claude Code CLI instead of paying for API credits.")
                                    .font(.callout)
                                if let userInfo = provider.auth_status.user_info {
                                    InfoPill(text: userInfo["version"] ?? "claude CLI", systemImage: "terminal")
                                }
                            } else if provider.provider_id == "anthropic_mcp" {
                                AnthropicMCPStatusPanel(provider: provider, appModel: appModel)
                            } else if provider.provider_id == "anthropic_oauth_direct" {
                                AnthropicOAuthDirectPanel(provider: provider, appModel: appModel)
                            } else if provider.provider_id == "xai_oauth_direct" {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("NativeAgent-owned xAI OAuth for Grok model access.")
                                        .font(.callout)
                                    OAuthSignInButton(provider: .xai) {
                                        Task { await appModel.loadProvidersForChat() }
                                    }
                                }
                            }
                            Text(provider.auth_status.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Model selection
                    if !availableModels.isEmpty {
                        NativePanel(title: "Default Model", systemImage: "cpu") {
                            Picker("Model", selection: $selectedModel) {
                                ForEach(availableModels) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            if let model = availableModels.first(where: { $0.id == selectedModel }) {
                                HStack(spacing: 8) {
                                    capabilityPill("Streaming", ok: model.supports_streaming)
                                    capabilityPill("Vision", ok: model.supports_vision)
                                    capabilityPill("Tools", ok: model.supports_tools)
                                    capabilityPill("JSON", ok: model.supports_json_mode)
                                }
                            }
                        }
                    }

                    // Test result
                    if let result = testResult {
                        NativePanel(
                            title: "Connection Test",
                            systemImage: result.status == "ok" ? "checkmark.circle.fill" : "xmark.circle.fill",
                            tint: result.status == "ok" ? .green : .red
                        ) {
                            if result.tested {
                                if let response = result.response {
                                    Text("Response: \(response)").font(.callout)
                                }
                                if let error = result.error {
                                    Text("Error: \(error)").font(.callout).foregroundStyle(.red)
                                }
                                if let model = result.model_used {
                                    InfoPill(text: model, systemImage: "cpu")
                                }
                            } else {
                                Text(result.detail ?? result.status)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    // Actions
                    HStack {
                        Button(isSaving ? "Saving…" : "Save", systemImage: "checkmark.circle") {
                            Task { await saveConfig() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)

                        Button(isTesting ? "Testing…" : "Test Connection", systemImage: "network") {
                            Task { await runTest() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)

                        Spacer()

                        Button("Remove Credentials", systemImage: "trash", role: .destructive) {
                            showRemoveCredentialsConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .confirmationDialog(
            "Remove \(provider.display_name) credentials?",
            isPresented: $showRemoveCredentialsConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Credentials", role: .destructive) {
                Task { await clearConfig() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This disconnects the provider and removes its saved credential from this Mac. Surfaces using it may be unavailable until another provider is selected.")
        }
    }

    private func saveConfig() async {
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
                if !availableModels.contains(where: { $0.id == selectedModel }) {
                    selectedModel = availableModels.first?.id ?? ""
                }
            }
            await appModel.loadProvidersForChat()
            statusText = {
                switch provider.provider_id {
                case "moonshot":
                    return "Saved. Moonshot model choices are ready; use Test Connection to verify the key."
                case "kimi-code":
                    return "Saved. Kimi Code model choices are ready; the server accepts the tiers your subscription allows."
                default:
                    return "Saved."
                }
            }()
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func runTest() async {
        isTesting = true
        testResult = nil
        do {
            testResult = try await appModel.testProvider(provider.provider_id)
        } catch {
            statusText = "Test error: \(error.localizedDescription)"
        }
        isTesting = false
    }

    private func clearConfig() async {
        do {
            _ = try await appModel.clearProvider(provider.provider_id)
            apiKey = ""
            statusText = "Credentials removed."
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
        case "api_key": return "API Key"
        case "oauth":   return "OAuth / Subscription"
        default:        return mode
        }
    }

    @ViewBuilder
    private func capabilityPill(_ label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ok ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(ok ? Color.green : Color.secondary)
    }
}

// MARK: - PATCH-2026-05-07: anthropic-mcp status panel

private struct AnthropicMCPStatusPanel: View {
    let provider: ProviderInfo
    let appModel: AppModel

    @State private var testResult: String = ""
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Persistent connection via Claude CLI")
                .font(.callout).bold()
            if let ui = provider.auth_status.user_info {
                HStack(spacing: 8) {
                    InfoPill(text: ui["version"] ?? "claude", systemImage: "terminal")
                    let mode = ui["mode"] ?? "per_call_stream"
                    InfoPill(
                        text: mode == "mcp_server" ? "MCP server" : "per-call stream",
                        systemImage: mode == "mcp_server" ? "antenna.radiowaves.left.and.right" : "arrow.clockwise"
                    )
                    let alive = ui["mcp_process_alive"] == "true"
                    StatusBadge(text: alive ? "Process alive" : "Not running", status: alive ? "ok" : "warn")
                }
            }
            HStack(spacing: 8) {
                Button(isTesting ? "Testing…" : "Test Connection", systemImage: "network") {
                    Task { await runPersistentTest() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)
            }
            if !testResult.isEmpty {
                Text(testResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runPersistentTest() async {
        isTesting = true
        testResult = ""
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

private struct AnthropicOAuthDirectPanel: View {
    let provider: ProviderInfo
    let appModel: AppModel

    @State private var isConnecting = false
    @State private var statusMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect via Anthropic OAuth")
                .font(.callout).bold()
            Text("Full capability API access (streaming, vision, tools) using your own OAuth credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let hasToken = provider.auth_status.state == "ready"
            if !hasToken {
                Button(isConnecting ? "Waiting for authorization…" : "Connect", systemImage: "safari") {
                    Task { await startOAuth() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            } else {
                // Already connected
                if let ui = provider.auth_status.user_info, !ui.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(ui.prefix(3)), id: \.key) { kv in
                            InfoPill(text: "\(kv.key): \(kv.value)", systemImage: "person.fill")
                        }
                    }
                }
                StatusBadge(text: "Authorized", status: "ok")
            }

            if isConnecting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(statusMessage.isEmpty ? "Waiting for browser authorization…" : statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            if isConnecting { isConnecting = false }
        }
    }

    // Swift-native cutover (2026-06-02): drive the Anthropic Connect button through the
    // in-process NativeOAuthFlow (same path as OAuthSignInButton). The public
    // client id belongs to the canonical provider config; users never need to
    // supply a second, ignored identifier here.
    @MainActor
    private func startOAuth() async {
        isConnecting = true
        statusMessage = "Opening browser…"
        let result = await NativeOAuthFlow.startOAuthFlow(
            providerId: "anthropic_oauth_direct"
        )
        isConnecting = false
        if result.ok {
            statusMessage = "Authorization complete."
            await appModel.loadProvidersForChat()
        } else {
            statusMessage = "Error: \(result.error ?? "unknown")"
        }
    }
}
