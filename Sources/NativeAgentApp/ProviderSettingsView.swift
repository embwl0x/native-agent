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
            // Wide enough for the longest account name plus the menu chrome:
            // a chosen account is never shown abbreviated.
            field("Provider", content: provider).frame(width: 180)
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
            // SwiftUI's hierarchical .secondary is a fraction of primary and
            // cannot answer for itself on a card; the measured token can.
            Text(title).font(.system(size: 10)).foregroundStyle(NativeAgentShell.secondary)
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
        "dream": "Dreams",
        "rem": "REM",
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

/// Fifteen per-activity rows were fifteen decisions nobody made. The page
/// offers three: the surfaces a person talks to, the working lanes, and the
/// memory/mind lanes. Grouping is presentation only — routing storage stays
/// per surface, and a registered surface that belongs to no group still gets
/// its own row, so a new one can never become unpinnable by omission.
struct ProviderSettingsSurfaceGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let surfaces: [String]

    static let chat = ProviderSettingsSurfaceGroup(
        id: "chat", title: "Chat",
        surfaces: ["chat", "ios", "telegram", "slack"]
    )
    static let work = ProviderSettingsSurfaceGroup(
        id: "work", title: "Work",
        surfaces: ["desk", "workshop", "autonomy", "swarms", "training", "heartbeat", "diagnostics"]
    )
    static let mind = ProviderSettingsSurfaceGroup(
        id: "memory_and_mind", title: "Memory and mind",
        surfaces: ["memory", "dream", "rem", "cognition_reflection", "compaction",
                   "self_improvement", "studio_wander"]
    )
    static let known: [ProviderSettingsSurfaceGroup] = [.chat, .work, .mind]

    /// The rows to render for a visible surface set: the three groups, each
    /// narrowed to the surfaces actually mounted, then one row per mounted
    /// surface no group claims.
    static func rows(visible: [String]) -> [ProviderSettingsSurfaceGroup] {
        var rows = known.compactMap { group -> ProviderSettingsSurfaceGroup? in
            let members = group.surfaces.filter(visible.contains)
            guard !members.isEmpty else { return nil }
            return ProviderSettingsSurfaceGroup(id: group.id, title: group.title, surfaces: members)
        }
        let claimed = Set(known.flatMap(\.surfaces))
        for surface in visible where !claimed.contains(surface) {
            rows.append(ProviderSettingsSurfaceGroup(
                id: surface,
                title: ProviderSettingsSurfaceLabel.presentation(for: surface).text,
                surfaces: [surface]
            ))
        }
        return rows
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
        _inlineReceipts = State(initialValue: savedReceipt.map {
            [ProviderSettingsSurfaceGroup.chat.id: SaveReceipt(text: $0)]
        } ?? [:])
        _statusText = State(initialValue: savedReceipt ?? "")
        loadsOnAppear = false
    }
    #endif

    // Opaque local surfaces keep secondary text legible over the shell wallpaper.
    private var secondaryInk: Color { colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.28) }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(16).settingsCardSurface()
    }

    private var surfaceGroups: [ProviderSettingsSurfaceGroup] {
        ProviderSettingsSurfaceGroup.rows(visible: surfaces)
    }

    /// What one surface currently routes to. Equality across a group's
    /// surfaces is what makes the group's row a single honest choice.
    private struct SurfaceSelection: Hashable {
        let provider: String
        let model: String
        let reasoningEffort: String
        let fastMode: Bool
    }

    private func selection(of surface: String) -> SurfaceSelection {
        SurfaceSelection(
            provider: activeSurface[surface] ?? "codex",
            model: surfaceModel[surface] ?? "",
            reasoningEffort: surfaceReasoningEffort[surface] ?? "",
            fastMode: surfaceFastMode[surface] ?? false
        )
    }

    /// The surface a group's row reads from: the most common choice among its
    /// surfaces, ties going to the group's first surface — so the Chat group
    /// keeps speaking for `chat`.
    private func leadSurface(_ group: ProviderSettingsSurfaceGroup) -> String {
        // Chat is the root the others inherit from, so its group always shows Chat's own choice.
        if group.surfaces.contains("chat") { return "chat" }
        guard var lead = group.surfaces.first else { return "chat" }
        var counts: [SurfaceSelection: Int] = [:]
        for surface in group.surfaces { counts[selection(of: surface), default: 0] += 1 }
        var best = counts[selection(of: lead)] ?? 0
        for surface in group.surfaces.dropFirst() {
            let count = counts[selection(of: surface)] ?? 0
            if count > best { best = count; lead = surface }
        }
        return lead
    }

    /// A group whose surfaces are all inheriting is not mixed even when their
    /// unpinned seeds differ (dream and REM seed cheaper than chat by design).
    /// Mixed means somebody's saved choice put the group's surfaces at odds.
    private func groupIsMixed(_ group: ProviderSettingsSurfaceGroup) -> Bool {
        guard groupHasOverride(group), let first = group.surfaces.first.map(selection(of:)) else {
            return false
        }
        return group.surfaces.dropFirst().contains { selection(of: $0) != first }
    }

    /// Whether the group holds a saved choice that "Use default" would clear.
    /// `chat` is the root everything else inherits from and never clears.
    private func groupHasOverride(_ group: ProviderSettingsSurfaceGroup) -> Bool {
        group.surfaces.contains { $0 != "chat" && explicitSurfaces.contains($0) }
    }

    private var exceptionSummary: String {
        let chatChoice = selection(of: "chat")
        let different = surfaceGroups.filter { group in
            group.id != ProviderSettingsSurfaceGroup.chat.id
                && group.surfaces.contains { selection(of: $0) != chatChoice }
        }
        guard !different.isEmpty else { return "All activities match Chat" }
        let names = different.map(\.title).joined(separator: " and ")
        return names + (different.count == 1 ? " differs from Chat" : " differ from Chat")
    }

    /// Where the row's choice comes from: a saved override, Chat's own route,
    /// or the app's built-in choice for these activities (memory and mind seed
    /// cheaper than Chat by design). Says the source, never just "inherited".
    private func selectionOrigin(_ group: ProviderSettingsSurfaceGroup) -> String {
        if overrideReadFailed { return "Saved choice source unavailable" }
        if group.surfaces.contains(where: { explicitSurfaces.contains($0) }) { return "Explicit override" }
        if group.id == ProviderSettingsSurfaceGroup.chat.id { return "Chat's own route" }
        let chat = selection(of: "chat")
        return group.surfaces.allSatisfy { selection(of: $0) == chat } ? "Same as Chat" : "Built-in default"
    }

    static func selectionOrigin(isExplicit: Bool) -> String {
        isExplicit ? "Explicit override" : "Inherited default"
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
        surfaces.map { ProviderSettingsSurfaceLabel.presentation(for: $0).text }
    }

    /// The one quiet line under a group's title. Normally it names what the
    /// row sets. When the group is mixed it says whose choice the controls
    /// are showing, which surfaces disagree, and how far a change reaches.
    private func membershipCaption(_ group: ProviderSettingsSurfaceGroup, mixed: Bool) -> String {
        let all = Self.listPhrase(surfaceNames(group.surfaces))
        guard mixed else { return all }
        let lead = leadSurface(group)
        let leadChoice = selection(of: lead)
        let differing = group.surfaces.filter { selection(of: $0) != leadChoice }
        let leadName = ProviderSettingsSurfaceLabel.presentation(for: lead).text
        let names = Self.listPhrase(surfaceNames(differing))
        let verb = differing.count == 1 ? "differs" : "differ"
        let reach = "Choosing here sets all \(Self.countPhrase(group.surfaces.count))."
        guard !differing.isEmpty else { return all }
        return "Showing \(leadName)'s choice; \(names) \(verb). \(reach)"
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

    // Per-surface active provider selection state (surface → provider_id).
    // Storage stays per surface; a group row writes every surface it covers.
    @State private var activeSurface: [String: String] = [:]
    @State private var groupSaveTokens: [String: UUID] = [:]
    @State private var groupSaveTasks: [String: Task<Void, Never>] = [:]
    @State private var savingGroups: Set<String> = []

    // PATCH-2026-05-28 (per-surface model): per-surface model selection state.
    // The model list shown for a surface is scoped to the provider selected
    // for that surface (so OpenRouter shows its live catalog, Anthropic its Claude
    // models, etc.). Falls back to the global catalog for providers that
    // expose no provider-specific list.
    @State private var surfaceModel: [String: String] = [:]
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
                Text(ProviderAccountStateLinePresentation.line(
                    state: provider.auth_status.state,
                    detail: provider.auth_status.detail))
                    .font(ShellType.caption).foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
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
                                    ForEach(surfaceGroups.filter { $0.id == ProviderSettingsSurfaceGroup.chat.id }) { group in
                                        groupRow(group)
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
                                ForEach(surfaceGroups.filter { $0.id != ProviderSettingsSurfaceGroup.chat.id }) { group in
                                    groupRow(group)
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

    /// One group: its name, the account behind it, the model, how hard it
    /// thinks, and whether it runs on the priority tier. Every control writes
    /// the same choice to each surface the group covers.
    @ViewBuilder
    private func groupRow(_ group: ProviderSettingsSurfaceGroup) -> some View {
        let lead = leadSurface(group)
        let isChatGroup = group.id == ProviderSettingsSurfaceGroup.chat.id
        let mixed = groupIsMixed(group)
        let saving = savingGroups.contains(group.id)
        let surfModels = modelsForSurface(lead)
        let selectedChoice = selectedModelChoice(for: lead)
        let supportedEfforts = selectedChoice?.supportedReasoningEfforts
            ?? Self.fallbackReasoningEfforts
        let clearable = groupHasOverride(group)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.title)
                .font(.system(size: 14, weight: .bold))
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
                Button("Use default") {
                    Task { await clearGroupOverride(group) }
                }
                .controlSize(.small)
                .disabled(isLoading || saving)
                .accessibilityLabel("Use default for \(group.title)")
            }
            }
            // Membership is otherwise invisible: the row's name is a group,
            // and nothing else on the page says which activities it covers.
            Text(membershipCaption(group, mixed: mixed))
                .font(ShellType.caption).foregroundStyle(secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            ModelChoiceRow {
            Menu {
                ForEach(pickerProviders.filter { $0.auth_status.state == "ready" }) { provider in
                    // One name per account, page-wide: the Accounts list's own
                    // display name, never a second alias for the same row.
                    Button(provider.display_name) {
                        requestSetGroupProvider(group: group, lead: lead, providerId: provider.provider_id)
                    }
                }
            } label: {
                let id = activeSurface[lead] ?? "codex"
                let account = providers.first { $0.provider_id == id }
                let name = account?.display_name ?? id
                Text(name + (account?.auth_status.state == "ready" ? "" : " · not connected"))
                    .lineLimit(1)
                    .help(name + (account?.auth_status.state == "ready" ? "" : " · not connected"))
            }
            .font(ShellType.label)
            .disabled(saving)
            .accessibilityLabel("\(group.title) provider")
            } model: {
            // PATCH-2026-05-28 (per-surface model): model picker scoped to the
            // provider chosen for THIS group. Plain dropdown (no search) even
            // for OpenRouter's long list.
            Picker("Model", selection: Binding(
                get: {
                    let cur = surfaceModel[lead] ?? ""
                    if surfModels.contains(where: { $0.id == cur }) { return cur }
                    return surfModels.first?.id ?? cur
                },
                set: { newVal in
                    requestSetGroupModel(group: group, lead: lead, model: newVal)
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
            .disabled(surfModels.isEmpty || saving)
            .accessibilityLabel("\(group.title) model")
            } think: {
                Picker("Think", selection: Binding(
                    get: {
                        let current = surfaceReasoningEffort[lead]
                            ?? selectedChoice?.defaultReasoningEffort
                            ?? "high"
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
                .accessibilityLabel("\(group.title) reasoning effort")
            } fast: {
                if selectedChoice?.supportsFast == true {
                Toggle("Fast", isOn: Binding(
                    get: { surfaceFastMode[lead] ?? false },
                    set: { enabled in
                        requestSetGroupFastMode(group: group, lead: lead, enabled: enabled)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(ShellType.label)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(selectedChoice?.isUnavailable == true
                    || selectedChoice?.supportsFast != true
                    || saving)
                .accessibilityLabel("\(group.title) Fast mode")
                .help(selectedChoice?.supportsFast == true
                    ? "Use the account's priority service tier for these activities."
                    : "This account and model do not offer a priority tier.")
                }
            }
            // Below the controls, not inside the Provider field: a caption in
            // the field would push Model, Think and Fast off the baseline.
            if let caption = ProviderToolCapability.caption(providerID: activeSurface[lead] ?? "codex") {
                Text(caption).font(.caption).foregroundStyle(NativeAgentShell.secondary)
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
        .padding(.vertical, 7)
    }

    /// Restore inheritance from Chat for every surface in the group. `chat`
    /// itself is the root the others inherit from, so it is never cleared.
    private func clearGroupOverride(_ group: ProviderSettingsSurfaceGroup) async {
        guard !isLoading, !savingGroups.contains(group.id) else { return }
        savingGroups.insert(group.id)
        defer { savingGroups.remove(group.id) }
        var cleared: [String] = []
        do {
            for surface in group.surfaces where surface != "chat" {
                try await appModel.clearSurfaceOverride(surface: surface)
                cleared.append(surface)
            }
            await loadProviders()
            if providerLoadError == nil, !overrideReadFailed {
                statusText = "\(group.title) → default restored"
                inlineReceipts[group.id] = SaveReceipt(text: statusText)
            }
        } catch {
            // Put back what was already cleared so the group is all-or-nothing,
            // then reload so the page shows the real state either way.
            for surface in cleared {
                let model = surfaceModel[surface] ?? ""
                if model.isEmpty {
                    _ = try? await appModel.setActiveProvider(surface: surface, providerId: activeSurface[surface] ?? "")
                } else {
                    _ = try? await appModel.configureSurfaceSelection(
                        surface: surface, providerID: activeSurface[surface] ?? "", model: model,
                        reasoningEffort: surfaceReasoningEffort[surface] ?? "",
                        serviceTier: (surfaceFastMode[surface] ?? false) ? "priority" : "default")
                }
            }
            await loadProviders()
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

    private func requestSetGroupProvider(
        group: ProviderSettingsSurfaceGroup,
        lead: String,
        providerId: String
    ) {
        let brain = reconciledBrainForProvider(surface: lead, providerId: providerId)
        requestSetGroupSelection(
            group: group,
            target: SurfaceSelection(
                provider: providerId,
                model: brain?.model ?? "",
                reasoningEffort: brain?.reasoningEffort ?? "high",
                fastMode: brain?.fastMode ?? false
            ),
            // No model list for this account yet: pin the account only, the way
            // the single-surface row did, instead of failing the whole save.
            providerOnly: brain == nil
        )
    }

    private func requestSetGroupModel(
        group: ProviderSettingsSurfaceGroup,
        lead: String,
        model: String
    ) {
        guard !model.isEmpty, surfaceModel[lead] != model || groupIsMixed(group) else { return }
        guard let choice = modelsForSurface(lead).first(where: { $0.id == model }) else { return }
        let defaultEffort = choice.supportedReasoningEfforts.contains(choice.defaultReasoningEffort)
            ? choice.defaultReasoningEffort
            : (choice.supportedReasoningEfforts.first ?? "high")
        let currentEffort = surfaceReasoningEffort[lead] ?? defaultEffort
        let nextEffort = choice.supportedReasoningEfforts.contains(currentEffort)
            ? currentEffort
            : defaultEffort
        requestSetGroupSelection(group: group, target: SurfaceSelection(
            provider: activeSurface[lead] ?? "codex",
            model: model,
            reasoningEffort: nextEffort,
            fastMode: choice.supportsFast && (surfaceFastMode[lead] ?? false)
        ))
    }

    private func requestSetGroupReasoning(
        group: ProviderSettingsSurfaceGroup,
        lead: String,
        effort: String
    ) {
        guard surfaceReasoningEffort[lead] != effort || groupIsMixed(group) else { return }
        guard selectedModelChoice(for: lead)?.supportedReasoningEfforts.contains(effort) == true else {
            return
        }
        requestSetGroupSelection(group: group, target: SurfaceSelection(
            provider: activeSurface[lead] ?? "codex",
            model: surfaceModel[lead] ?? "",
            reasoningEffort: effort,
            fastMode: surfaceFastMode[lead] ?? false
        ))
    }

    private func requestSetGroupFastMode(
        group: ProviderSettingsSurfaceGroup,
        lead: String,
        enabled: Bool
    ) {
        guard surfaceFastMode[lead] != enabled || groupIsMixed(group) else { return }
        guard selectedModelChoice(for: lead)?.supportsFast == true else { return }
        requestSetGroupSelection(group: group, target: SurfaceSelection(
            provider: activeSurface[lead] ?? "codex",
            model: surfaceModel[lead] ?? "",
            reasoningEffort: surfaceReasoningEffort[lead] ?? "high",
            fastMode: enabled
        ))
    }

    /// One choice, written to every surface the group covers. The optimistic
    /// local state moves first so the row reads as settled; a failure restores
    /// each surface to exactly what it had, including its inheritance.
    private func requestSetGroupSelection(
        group: ProviderSettingsSurfaceGroup,
        target: SurfaceSelection,
        providerOnly: Bool = false
    ) {
        let previous = Dictionary(uniqueKeysWithValues: group.surfaces.map { ($0, selection(of: $0)) })
        let previouslyExplicit = explicitSurfaces
        for surface in group.surfaces {
            activeSurface[surface] = target.provider
            if !providerOnly {
                surfaceModel[surface] = target.model
                surfaceReasoningEffort[surface] = target.reasoningEffort
                surfaceFastMode[surface] = target.fastMode
            }
        }
        let token = UUID()
        groupSaveTokens[group.id] = token
        savingGroups.insert(group.id)
        statusText = "Saving \(group.title)…"
        groupSaveTasks[group.id]?.cancel()
        groupSaveTasks[group.id] = Task {
            await saveGroupSelection(
                group: group,
                target: target,
                providerOnly: providerOnly,
                previous: previous,
                previouslyExplicit: previouslyExplicit,
                token: token
            )
        }
    }

    private func saveGroupSelection(
        group: ProviderSettingsSurfaceGroup,
        target: SurfaceSelection,
        providerOnly: Bool,
        previous: [String: SurfaceSelection],
        previouslyExplicit: Set<String>,
        token: UUID
    ) async {
        guard groupSaveTokens[group.id] == token else { return }
        if !providerOnly, target.model.isEmpty {
            for (surface, prior) in previous {
                surfaceModel[surface] = prior.model
                surfaceReasoningEffort[surface] = prior.reasoningEffort
                surfaceFastMode[surface] = prior.fastMode
            }
            finishGroupSave(group)
            statusText = "Model settings could not be saved: no model is available for this provider."
            return
        }
        do {
            for surface in group.surfaces {
                if providerOnly {
                    _ = try await appModel
                        .setActiveProvider(surface: surface, providerId: target.provider)
                } else {
                    _ = try await appModel.configureSurfaceSelection(
                        surface: surface,
                        providerID: target.provider,
                        model: target.model,
                        reasoningEffort: target.reasoningEffort,
                        serviceTier: target.fastMode ? "priority" : "default"
                    )
                }
            }
            guard groupSaveTokens[group.id] == token else { return }
            explicitSurfaces.formUnion(group.surfaces)
            finishGroupSave(group)
            statusText = providerOnly
                ? "\(group.title) → provider saved"
                : "\(group.title) → \(target.model) / \(reasoningLabel(target.reasoningEffort))\(target.fastMode ? " / Fast" : "") saved"
            inlineReceipts[group.id] = SaveReceipt(text: statusText)
        } catch {
            // A newer edit owns this group now; its writes must not be undone.
            guard groupSaveTokens[group.id] == token else { return }
            for (surface, prior) in previous {
                if previouslyExplicit.contains(surface) || surface == "chat" {
                    if prior.model.isEmpty {
                        _ = try? await appModel
                            .setActiveProvider(surface: surface, providerId: prior.provider)
                    } else {
                        _ = try? await appModel.configureSurfaceSelection(
                            surface: surface,
                            providerID: prior.provider,
                            model: prior.model,
                            reasoningEffort: prior.reasoningEffort,
                            serviceTier: prior.fastMode ? "priority" : "default"
                        )
                    }
                } else {
                    // It was inheriting before this attempt; leave it inheriting.
                    try? await appModel.clearSurfaceOverride(surface: surface)
                }
            }
            guard groupSaveTokens[group.id] == token else { return }
            for (surface, prior) in previous {
                activeSurface[surface] = prior.provider
                surfaceModel[surface] = prior.model
                surfaceReasoningEffort[surface] = prior.reasoningEffort
                surfaceFastMode[surface] = prior.fastMode
            }
            explicitSurfaces = previouslyExplicit
            finishGroupSave(group)
            statusText = "Model settings could not be saved: \(error.localizedDescription)"
        }
    }

    private func finishGroupSave(_ group: ProviderSettingsSurfaceGroup) {
        savingGroups.remove(group.id)
        groupSaveTokens.removeValue(forKey: group.id)
        groupSaveTasks.removeValue(forKey: group.id)
    }

    // SUBSYSTEM #17 (2026-05-31): retired diagnostic UI + /v1/providers/self_test

    private func shortTime() -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f.string(from: Date())
    }
}
