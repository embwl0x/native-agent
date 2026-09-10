// PATCH-2026-05-07: model-providers v1 — ProviderSettingsView: Models & Providers settings sub-section
// PATCH-2026-05-07: leftover-2 per-surface active provider picker (Mac side)
import SwiftUI
import Foundation
import ProviderRouting
import PersistenceCore

/// Two indivisible pairs: a narrow container can wrap once, never three times.
struct ModelChoiceRow<Provider: View, Model: View, Think: View, Fast: View>: View {
    @ViewBuilder var provider: () -> Provider
    @ViewBuilder var model: () -> Model
    @ViewBuilder var think: () -> Think
    @ViewBuilder var fast: () -> Fast

    private var identity: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field("Provider", content: provider).frame(width: 160)
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
        }
        .font(.system(size: 12, weight: .medium))
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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
        "workshop": "Task execution",
        // Old persisted rows are folded to `workshop` before presentation,
        // but retain an honest title if an older in-memory caller reaches us.
        "missions": "Task execution",
        "autonomy": "Independent tasks",
        "swarms": "Coordinated tasks",
        "dream": "Memory review",
        "rem": "Personal growth",
        "training": "Skill practice",
        "memory": "Memory",
        "heartbeat": "Background check-ins",
        "diagnostics": "Diagnostics",
        "cognition_reflection": "Reflection",
        "compaction": "Conversation summaries",
        "self_improvement": "Learning",
        "studio_wander": "Creative exploration",
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var explicitSurfaces: Set<String> = []
    @State private var overrideReadFailed = false
    private struct SaveReceipt {
        let id = UUID()
        let text: String
    }
    @State private var inlineReceipts: [String: SaveReceipt] = [:]
    private var loadsOnAppear = true

    init() {}

    #if DEBUG
    init(snapshot: ProviderSettingsRefreshAction.Snapshot, explicitSurfaces: Set<String>, savedReceipt: String? = nil) {
        _providers = State(initialValue: snapshot.providers)
        _rowSet = State(initialValue: snapshot.rowSet)
        _activeSurface = State(initialValue: snapshot.activeProviders)
        _surfaceModel = State(initialValue: snapshot.preferences.mapValues(\.model))
        _surfaceReasoningEffort = State(initialValue: snapshot.preferences.mapValues(\.reasoningEffort))
        _surfaceFastMode = State(initialValue: snapshot.preferences.mapValues { $0.serviceTier == "priority" })
        _explicitSurfaces = State(initialValue: explicitSurfaces)
        _inlineReceipts = State(initialValue: savedReceipt.map { ["ios": SaveReceipt(text: $0)] } ?? [:])
        _statusText = State(initialValue: savedReceipt ?? "")
        loadsOnAppear = false
    }
    #endif

    // Opaque local surfaces keep secondary text legible over the shell wallpaper.
    private var secondaryInk: Color { colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.28) }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(16).settingsCardSurface()
    }

    private var exceptionSummary: String {
        let different = surfaces.filter { surface in
            surface != "chat" && (activeSurface[surface] != activeSurface["chat"]
                || surfaceModel[surface] != surfaceModel["chat"]
                || surfaceReasoningEffort[surface] != surfaceReasoningEffort["chat"]
                || surfaceFastMode[surface] != surfaceFastMode["chat"])
        }
        guard !different.isEmpty else { return "All activities match Chat" }
        let fastOnly = different.filter {
            activeSurface[$0] == activeSurface["chat"] && surfaceModel[$0] == surfaceModel["chat"]
                && surfaceReasoningEffort[$0] == surfaceReasoningEffort["chat"]
                && surfaceFastMode[$0] == true && surfaceFastMode["chat"] != true
        }
        if !fastOnly.isEmpty {
            let names = fastOnly.prefix(2).map(surfaceLabel).joined(separator: " and ")
            let moreFast = fastOnly.count > 2 ? " and \(fastOnly.count - 2) more" : ""
            let other = different.count - fastOnly.count
            return names + moreFast + " use Fast" + (other > 0 ? " · \(other) other differences" : "")
        }
        let names = different.prefix(2).map(surfaceLabel).joined(separator: " and ")
        let remainder = different.count > 2 ? " and \(different.count - 2) more" : ""
        return names + remainder + " differ from Chat"
    }

    private func selectionOrigin(_ surface: String) -> String {
        if overrideReadFailed { return "Saved choice source unavailable" }
        return Self.selectionOrigin(isExplicit: explicitSurfaces.contains(surface))
    }

    static func selectionOrigin(isExplicit: Bool) -> String {
        isExplicit ? "Explicit override" : "Inherited default"
    }
    private static let fallbackReasoningEfforts = ["low", "medium", "high", "xhigh"]
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
                        ?? Self.fallbackReasoningEfforts,
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
                    ?? Self.fallbackReasoningEfforts,
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
        // Keep account setup and ordinary chat visible together; other model
        // choices are optional and start folded away.
        HStack(alignment: .top, spacing: 20) {
            providerListColumn
                .frame(maxWidth: 280)

            perSurfacePickerColumn
                // Reserve the complete control row, including card insets,
                // without taking the account column's share of the page.
                .frame(minWidth: 530)
        }
        .sheet(item: $configureSheet) { provider in
            VStack(alignment: .leading, spacing: 12) {
                if provider.provider_id == "openai_oauth_direct" || provider.provider_id == "codex" {
                    DisclosureGroup(provider.auth_status.state == "ready" ? "Reconnect ChatGPT account" : "Sign in with ChatGPT") {
                        OAuthSignInButton(provider: .chatgpt) {
                            Task { await loadProviders() }
                        }
                    }
                    .padding([.top, .horizontal], 20)
                }
            ProviderConfigSheet(provider: provider) {
                configureSheet = nil
                Task { await loadProviders() }
            }
            }
            .environment(appModel)
        }
        .task { if loadsOnAppear { await loadProviders() } }
    }

    @ViewBuilder
    private func accountRow(_ provider: ProviderInfo) -> some View {
        if provider.auth_status.state != "ready" {
            Button {
                configureSheet = provider
            } label: {
                HStack {
                    Text(provider.display_name).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(provider.auth_modes.contains("api_key") ? "API key" : "Sign in")
                        .foregroundStyle(secondaryInk)
                    Image(systemName: "chevron.right").foregroundStyle(secondaryInk)
                }
                .font(ShellType.label)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set up \(provider.display_name), \(provider.auth_modes.contains("api_key") ? "API key" : "account sign-in")")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(provider.display_name).font(ShellType.labelSemibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(provider.auth_status.state == "ready" ? "Manage" : "Set up") {
                        configureSheet = provider
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("\(provider.auth_status.state == "ready" ? "Manage" : "Set up") \(provider.display_name)")
                }
                Text(provider.auth_status.state == "ready" ? "Connected · account available" : "Not connected")
                    .font(ShellType.caption).foregroundStyle(secondaryInk)
                Text(provider.auth_modes.map { mode in
                    switch mode {
                    case "api_key": "API key"
                    case "oauth": "Account sign-in"
                    default: mode.replacingOccurrences(of: "_", with: " ")
                    }
                }.joined(separator: " · "))
                    .font(ShellType.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Left column: what the lead sentence says, the sign-ins, and the list of
    /// accounts. Everything that is not the per-surface picker.
    @ViewBuilder
    private var providerListColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose an account and a chat model. Model changes save immediately.")
                    .font(ShellType.label)
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCardSurface()

                ProviderSection(label: "Accounts & API keys") {
                    VStack(alignment: .leading, spacing: 8) {
                        if isLoading {
                            card {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Reading the accounts…")
                                        .font(ShellType.label)
                                        .foregroundStyle(secondaryInk)
                                }
                            }
                        } else if case let .unavailable(detail) = ProviderSettingsRefreshPresentation.resolve(
                            providerCount: providers.count,
                            loadError: providerLoadError
                        ) {
                            card {
                                VStack(alignment: .leading, spacing: 8) {
                                    ProviderCardTitle(
                                        title: "The accounts could not be read",
                                        line: detail
                                    )
                                }
                            }
                        } else if providers.isEmpty {
                            card {
                                ProviderCardTitle(
                                    title: "No accounts yet",
                                    line: "Expand Sign in below, or press Refresh to read accounts on this Mac."
                                )
                            }
                        } else {
                            card {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(providers.sorted { ($0.auth_status.state == "ready" ? 0 : 1, $0.display_name) < ($1.auth_status.state == "ready" ? 0 : 1, $1.display_name) }) { provider in
                                        accountRow(provider)
                                        Divider()
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

                DisclosureGroup("Sign in, reconnect or add an account") {
                    VStack(alignment: .leading, spacing: 8) {
                        // A2.2 close-out (2026-07-24): title/copy said sign-in
                        // ran through Codex's device flow — stale since the
                        // 2026-07-05 codex-free loopback cutover. The codex
                        // device flow remains the alternative path (its
                        // in-flight UI renders below).
                        card {
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
                                                .foregroundStyle(secondaryInk)
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
                        card {
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

                        card {
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
                    card {
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
                            card {
                                ProviderCardTitle(
                                    title: "Nothing to choose from yet",
                                    line: "Sign in to an account to choose a chat model."
                                )
                            }
                        } else {
                            card {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(surfaces.filter { $0 == "chat" }, id: \.self) { surface in
                                        surfaceRow(surface)
                                    }
                                }
                            }
                        }
                    }
                }

                if !pickerProviders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(exceptionSummary).font(ShellType.caption).foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Defaults can differ from Chat. Changes save an explicit choice; Use default restores inheritance.")
                            .font(ShellType.caption)
                            .foregroundStyle(secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        card {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(surfaces.filter { $0 != "chat" }, id: \.self) { surface in
                                    surfaceRow(surface)
                                }
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

    /// One surface: its name, the account behind it, the model, how hard it
    /// thinks, and whether it runs on the priority tier.
    @ViewBuilder
    private func surfaceRow(_ surface: String) -> some View {
        let surfModels = modelsForSurface(surface)
        let selectedChoice = selectedModelChoice(for: surface)
        let supportedEfforts = selectedChoice?.supportedReasoningEfforts
            ?? Self.fallbackReasoningEfforts
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(surfaceLabel(surface))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(NativeAgentShell.text)
            if surface != "chat" {
                Text(selectionOrigin(surface)).font(ShellType.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if explicitSurfaces.contains(surface), !overrideReadFailed {
                    Button("Use default") {
                        Task { await clearSurfaceOverride(surface) }
                    }
                    .controlSize(.small)
                    .disabled(isLoading || savingSurfaces.contains(surface) || savingSurfaceModels.contains(surface))
                    .accessibilityLabel("Use default for \(surfaceLabel(surface))")
                }
            }
            }

            ModelChoiceRow {
            Menu {
                ForEach(pickerProviders.filter { $0.auth_status.state == "ready" }) { provider in
                    Button(provider.provider_id == "codex" ? "OpenAI (subscription)" : provider.display_name) {
                        requestSetActiveSurface(surface: surface, providerId: provider.provider_id)
                    }
                }
            } label: {
                let id = activeSurface[surface] ?? "codex"
                let account = providers.first { $0.provider_id == id }
                let name = id == "codex" ? "OpenAI (subscription)" : (account?.display_name ?? id)
                Text(name + (account?.auth_status.state == "ready" ? "" : " · not connected"))
                    .lineLimit(1)
                    .help(name + (account?.auth_status.state == "ready" ? "" : " · not connected"))
            }
            .font(ShellType.label)
            .disabled(savingSurfaces.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) provider")
            if let caption = ProviderToolCapability.caption(providerID: activeSurface[surface] ?? "codex") {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            } model: {
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

            .font(ShellType.label)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(surfModels.isEmpty || savingSurfaceModels.contains(surface))
            .accessibilityLabel("\(surfaceLabel(surface)) model")
            } think: {
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

                .font(ShellType.label)
                .disabled(selectedChoice?.isUnavailable == true
                    || supportedEfforts.isEmpty
                    || savingSurfaceModels.contains(surface))
                .accessibilityLabel("\(surfaceLabel(surface)) reasoning effort")
            } fast: {
                if selectedChoice?.supportsFast == true {
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
                .disabled(selectedChoice?.isUnavailable == true
                    || selectedChoice?.supportsFast != true
                    || savingSurfaceModels.contains(surface))
                .accessibilityLabel("\(surfaceLabel(surface)) Fast mode")
                .help(selectedChoice?.supportsFast == true
                    ? "Use the account's priority service tier for this surface."
                    : "This account and model do not offer a priority tier.")
                }
            }
            if let receipt = inlineReceipts[surface] {
                Text(receipt.text).font(.caption).foregroundStyle(.secondary)
                    .task(id: receipt.id) {
                        // One presentation deadline, cancelled when this receipt leaves the view.
                        do { try await ContinuousClock().sleep(for: .seconds(4)) } catch { return }
                        if inlineReceipts[surface]?.id == receipt.id { inlineReceipts[surface] = nil }
                    }
            }
        }
        .padding(.vertical, 7)
    }

    private func clearSurfaceOverride(_ surface: String) async {
        guard surface != "chat", !isLoading,
              !savingSurfaces.contains(surface), !savingSurfaceModels.contains(surface) else { return }
        savingSurfaces.insert(surface)
        savingSurfaceModels.insert(surface)
        defer {
            savingSurfaces.remove(surface)
            savingSurfaceModels.remove(surface)
        }
        do {
            try await appModel.clearSurfaceOverride(surface: surface)
            await loadProviders()
            if providerLoadError == nil, !overrideReadFailed {
                statusText = "\(surfaceLabel(surface)) → default restored"
                inlineReceipts[surface] = SaveReceipt(text: statusText)
            }
        } catch {
            statusText = "Default could not be restored: \(error.localizedDescription)"
        }
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
            do {
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let routing = try await SwiftNativeProviderRouting(dataRoot: root).checkedRoutingSnapshot()
                // Include legacy effort/tier-only overrides too, not just model pins.
                // The checked snapshot above validates/reconciles this authority first.
                let path = root.appendingPathComponent("providers/surfaces.json")
                let storedKeys: Set<String>
                do {
                    let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: path))
                    storedKeys = Set(value.keys.map(canonicalRoutingSurface))
                } catch CocoaError.fileReadNoSuchFile {
                    storedKeys = []
                }
                explicitSurfaces = storedKeys.union(routing.pinnedModels.keys).union(routing.activeProviders.keys)
                overrideReadFailed = false
            } catch {
                overrideReadFailed = true
            }
            providers = snapshot.providers
            rowSet = snapshot.rowSet
            if let catalog = snapshot.catalog {
                catalogModels = catalog.models
            }
            for surface in surfaces {
                if let pid = snapshot.activeProviders[surface] {
                    activeSurface[surface] = pid
                } else {
                    activeSurface[surface] = snapshot.preferences[surface]
                        .flatMap { NativeClient.inferProviderID(forModel: $0.model) } ?? "codex"
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
            explicitSurfaces.insert(surface)
            savingSurfaces.remove(surface)
            activeSurfaceSaveTokens.removeValue(forKey: surface)
            activeSurfaceSaveTasks.removeValue(forKey: surface)
            if let nextBrain {
                statusText = "\(surfaceLabel(surface)) → \(nextBrain.model) / \(reasoningLabel(nextBrain.reasoningEffort))\(nextBrain.fastMode ? " / Fast" : "") saved"
            } else {
                statusText = "\(surfaceLabel(surface)) → provider saved"
            }
            inlineReceipts[surface] = SaveReceipt(text: statusText)
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
        statusText = "Saving \(surfaceLabel(surface)) model settings…"
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
            statusText = "Model settings could not be saved: no model is available for this provider."
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
            explicitSurfaces.insert(surface)
            statusText = "\(surfaceLabel(surface)) → \(model) / \(reasoningLabel(effort))\(fastMode ? " / Fast" : "") saved"
            inlineReceipts[surface] = SaveReceipt(text: statusText)
        } catch {
            guard surfaceModelSaveTokens[surface] == token else { return }
            surfaceModel[surface] = previous.model
            surfaceReasoningEffort[surface] = previous.reasoningEffort
            surfaceFastMode[surface] = previous.fastMode
            savingSurfaceModels.remove(surface)
            surfaceModelSaveTokens.removeValue(forKey: surface)
            surfaceModelSaveTasks.removeValue(forKey: surface)
            statusText = "Model settings could not be saved: \(error.localizedDescription)"
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
