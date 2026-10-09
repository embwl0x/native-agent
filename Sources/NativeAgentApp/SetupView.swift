// Lane B (2026-09-02, ui-simplify): THE SETUP PAGE.
//
// "Four things make up <name>. The rest is below."
//
// This page owns no settings of its own. Every switch here writes exactly the
// same storage the old Settings controls wrote — the Subconscious master and
// Fluid Context (SlimSettingsView ▸ Advanced ▸ Subconscious), the moments lane
// switch (MomentsLaneSetting), the agent's hour (StudioWanderLane.enabledDefaultsKey),
// and the Mac Integration permission store. Nothing on the
// top half of this page names an internal: no "Subconscious", no "Fluid
// Context", no "organism", no "YOLO". User, 2026-09-04: the features those
// words stood for are cards further down this page now, said in plain words.

import SwiftUI
import AppToolRuntime
import Context
import ContextFlow
import MacIntegration
import NativeAgentCore
import ProviderRouting
// The hour's switch key lives with the lane law so the two can never disagree
// about its spelling.
import BackgroundLoops
import Cognition

// MARK: - Links to the rail

/// Settings opens the rail's own pages; it never pushes a copy of one. Simple
/// and Agent view have no rail, so a link lands in Advanced, as Simple's
/// "More settings…" does.
@MainActor
enum SettingsLink {
    static func open(_ item: SidebarItem, tab: String? = nil) {
        let mode = SimpleViewMode.resolved(UserDefaults.standard.string(forKey: SimpleViewMode.key) ?? "")
        if mode != SimpleViewMode.advanced {
            UserDefaults.standard.set(SimpleViewMode.advanced, forKey: SimpleViewMode.key)
        }
        NativeAgentAppCoordinator.shared.request(.sidebar(item))
        // The route lands on the page's first tab, synchronously, so the tab
        // is chosen after it.
        if let tab { UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(item)) }
    }
}

/// THE HOUSE, WORN FROM THE OUTSIDE. Every page behind Advanced is the page it
/// always was — none of their internals are rewritten here. This puts the room
/// under them, a title in the shell's hand, and one way back, so opening one
/// no longer reads as leaving the app.
///
/// It also quiets the default chrome those pages carry: `scrollContentBackground`
/// hidden so their Lists and Forms show the glass, and the brand tint set once
/// so every control in the subtree agrees on its accent.
struct ShellPageFrame<Content: View>: View {
    let title: String
    /// One plain sentence under the title, in the agent's own voice — the line
    /// Today, Memories and the Desk already carry. Nil leaves the title alone.
    var subtitle: String?
    /// What the back row says. The pages under Setup all came from Settings.
    var backLabel: String = "Settings"
    /// A page reached from the rail has nowhere to go back to.
    var showsBack: Bool = true
    /// User, 2026-09-04: Providers is two columns of controls; at the 920
    /// measure its model menu had no width left. A wide page takes the room.
    var wide: Bool = false
    /// Alive glass (User, 2026-09-23): the serif header, whose one sentence the
    /// page's content hands up through `alivePageLine`, in place of the
    /// display title and the fixed subtitle.
    var alive: Bool = false
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var aliveLine: AlivePageLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back is `dismiss()` again, and this is safe ONLY because the
            // stack above it is UNBOUND — see `SetupView.body`. On an unbound
            // stack SwiftUI owns the path, so a surplus dismiss (a click that
            // lands on a frame already leaving, which stays hit-testable
            // through the transition) is a no-op with nothing to write back.
            // Bound, the same surplus killed the app four times on 2026-09-03.
            if showsBack {
                Button(action: { dismiss() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(ShellType.labelSemibold)
                        Text(backLabel)
                            .font(ShellType.labelMedium)
                    }
                    .foregroundStyle(NativeAgentShell.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shell.page.back")
            }

            if alive {
                AlivePageHeader(title: title, line: aliveLine?.text ?? subtitle,
                                lineID: aliveLine?.id ?? "shell.page.subtitle")
                    .padding(.top, showsBack ? 6 : 0)
            } else {
                Text(title)
                    .font(ShellType.display)
                    .foregroundStyle(NativeAgentShell.text)
                    .padding(.top, 6)
                    .padding(.bottom, subtitle == nil ? 14 : 4)
                    .accessibilityAddTraits(.isHeader)

                if let subtitle {
                    Text(subtitle)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("shell.page.subtitle")
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // The header's 20pt gap, as a soft edge scrolled rows fade
                // across rather than a line that slices them.
                .aliveTopDissolve(alive ? 20 : 0)
                .pageScrollColumn()
                // A page pushed inside a tab draws its own actions.
                .environment(\.shellTabRowHostsActions, false)
        }
        .padding(.horizontal, NativeAgentSpacing.pageInset)
        .padding(.top, alive && !showsBack ? TodayMetrics.topPadding : 20)
        .onPreferenceChange(AlivePageLineKey.self) { aliveLine = $0 }
        .frame(maxWidth: wide ? .infinity : TodayMetrics.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The pages' own Lists and Forms paint a slab by default; this is the
        // one line that lets the room through them.
        .scrollContentBackground(.hidden)
        // User, 2026-09-03: the frame used to tint the whole page teal, so every
        // bordered button on every Advanced page wore the waiting colour. The
        // teal has one job. Buttons take the text colour; a control with an
        // "on" state wears the haze itself (`hazeTinted`, WindowHaze.swift).
        .tint(NativeAgentShell.text)
        .background { ShellRoomBackdrop() }
        // The NavigationStack still owns the back gesture; only its chrome is
        // hidden, because a painted bar on glass reads as another app's.
        .navigationTitle(title)
        .navigationBarBackButtonHidden(true)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

// MARK: - Setup

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    // AN INNER LIFE — the Subconscious master plus the lanes it owns. Same
    // keys SlimSettingsView's Subconscious section binds, so the two surfaces
    // can never show different truth.
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = true
    @AppStorage("cognitiveSubstrateCapsuleEnabled") private var capsuleEnabled = true
    @AppStorage("cognitiveSubstrateBackgroundEnabled") private var backgroundEnabled = true
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("cognitiveSubstrateDailyReflectionBudget") private var reflectionBudget = 2
    @AppStorage("organismKernelEnabled") private var organismEnabled = false

    // MOMENTS THE AGENT KEEPS
    @AppStorage(MomentsLaneSetting.defaultsKey) private var momentsEnabled = true

    // THE AGENT'S HOUR
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false

    @AppStorage("nativeagent.darkMode") private var preferDark = true

    @State private var savingInnerLife = false
    @State private var innerLifeError: String?
    /// What the inner life is ACTUALLY doing — the runtime's lanes and the
    /// reflection route — not what the switch asked for.
    private var subconsciousRuntime: NativeSubconsciousRuntimeState? {
        get { appModel.engine.cognitionView.subconsciousRuntime }
        nonmutating set { appModel.engine.cognitionView.subconsciousRuntime = newValue }
    }
    private var reflectionRoute: NativeReflectionRouteStatus? {
        get { appModel.engine.cognitionView.reflectionRoute }
        nonmutating set { appModel.engine.cognitionView.reflectionRoute = newValue }
    }
    @State private var macPermissions: [String: MacIntegrationPermission] = [:]
    @State private var macPermissionsLoaded = false
    @State private var macPermissionsUnavailable = false
    /// Every sentence on this page is built out of this: the agent's name,
    /// never a gender.
    private var voice: AgentVoice {
        AgentVoice(name: appModel.agentDisplayName)
    }

    var body: some View {
        ScrollView {
            // Alive glass (2026-09-23): the page's sections, each ONE
            // group card of rows under an eyebrow, where every setting
            // used to be its own card.
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AlivePageHeader(
                    title: "Settings",
                    line: "These make up who I am. Everything else I carry is below."
                )
                .accessibilityElement(children: .combine)
                if let innerLifeError {
                    Text(innerLifeError)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
                section("Who I am") { fourThings }
                // User, 2026-09-05: the everyday controls come first; the
                // fourteen feature switches sit below them.
                // The trust level and the chat model are the composer's
                // and the rail's (Trust, Providers); Telegram, iPhone and
                // Senses are rail tabs. Settings does not copy them.
                section("And the rest") {
                    appearanceRow
                    // User, 2026-09-04: no All settings door. What lived
                    // there is here, as rows (SetupRestRows).
                    SetupRestRows(part: .everyday)
                }
                SetupRestRows(part: .app)
                // User, 2026-09-04: "a switch for each of her features,
                // all here, simple." One row per feature, wired to the
                // key the feature actually reads (SetupFeatureRows). The
                // inner life's master heads its own card.
                SetupFeatureRows { innerLifeControls }
            }
            .padding(.top, TodayMetrics.topPadding)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The shared page column, as Today and every framed page.
        .pageScrollColumn()
        .padding(.horizontal, 20)
        .frame(maxWidth: TodayMetrics.contentWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Settings")
        // Coming back from Providers or minds is when a recovery lands.
        .liveOnAppear { Task { await refreshInnerLifeStatus() } }
        // A lane switched below (reflection, moods) moves the runtime, and
        // the runtime says so: re-read the status on every change.
        .liveTask {
            let changes = await appModel.engine.cognitionView.changes()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await refreshInnerLifeStatus()
            }
        }
        .liveTask {
            await refreshMacPermissions()
            // LIVE STATE, NOT DEFAULTS: `.settings` is the sidebar item whose
            // refresh this page's rows read (AppModel+ChatSessions).
            await appModel.refreshForSidebarItem(.settings)
            // The dream, REM and memory switches read the trust policy. A
            // swallowed failure here left the PREVIOUS policy on screen and
            // nothing said so. Say so.
            do {
                appModel.engine.trust.policy = try await appModel.engine.trust.load()
            } catch {
                innerLifeError = "I couldn't read the trust policy just now, so what this page shows may be out of date."
            }
        }
        // A screenshot's offscreen copy reads the Mac grants too (a read,
        // counted so the capture waits), instead of drawing "Checking…".
        .quietReadTask(live: false) { await refreshMacPermissions() }
    }

    // MARK: Header

    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        AdvancedSection(title: title, content: rows)
    }

    // MARK: The four things

    @ViewBuilder
    private var fourThings: some View {
        SetupSwitchCard(
            title: "Moments I keep",
            sentence: "Small things that happened between us. I pick which stay.",
            isOn: Binding(
                get: { momentsEnabled },
                set: { enabled in
                    momentsEnabled = enabled
                    appModel.statusText = enabled
                        ? "I keep moments again"
                        : "I am no longer keeping moments"
                }
            )
        )

        SetupSwitchCard(
            title: "\(voice.Possessive) hour",
            sentence: "Once a day, when nothing is happening, an hour with no task set.",
            isOn: Binding(
                get: { studioWanderEnabled },
                set: { enabled in
                    studioWanderEnabled = enabled
                    Task { await NativeCognitionRuntime.reloadStudioWanderInstallation() }
                }
            ),
            // The hour is background cognition and cannot outlive the
            // inner life, exactly as the old switch could not.
            disabled: savingInnerLife || !subconsciousEnabled
        )
        // The hour's provider/model pickers moved to Advanced ▸ minds.

        // User, 2026-09-04: this was a switch bound to a constant. Each
        // capability is its own grant and macOS asks again on first use,
        // so there is nothing one switch could honestly do. The card
        // says what is granted and opens the rail's Trust ▸ Mac
        // integration, where the grants are.
        SetupInfoCard(
            title: "Use my Mac",
            detail: macPermissionsUnavailable
                ? "Can't read this right now. Open Mac settings for details."
                : macPermissionsLoaded
                    ? (anyMacCapabilityEnabled
                        ? "On — macOS still asks for each app."
                        : "Off. Choose what I may reach.")
                    : "Checking…",
            open: { SettingsLink.open(.macIntegration) }
        )
    }

    private var innerLifeControls: some View {
        SetupSwitchCard(
            title: "An inner life",
            sentence: "I feel, remember what happened, and carry it between conversations. On, this also turns on reflection, moods, and memory in every reply below.",
            isOn: Binding(
                get: { subconsciousEnabled },
                set: { enabled in Task { await setInnerLife(enabled) } }
            ),
            disabled: savingInnerLife
        ) {
            // NO MIND ON THIS PAGE. The reflection-mind picker is on
            // Personality ▸ My minds (SetupMindsView); this card is a switch.
            innerLifeStatus
        }
    }

    /// The runtime's own receipt, and the one way back when it is not
    /// running as asked: set up a connection, choose a ready reflection mind,
    /// or enable again. Nothing while it is simply off or still being read.
    @ViewBuilder
    private var innerLifeStatus: some View {
        let status = SlimSettingsSubconsciousStatusLine.state(
            runtime: subconsciousRuntime,
            reflectionRoute: reflectionRoute
        )
        if status.tone != .neutral, status.tone != .progress {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(status.text)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(innerLifeStatusColor(status.tone))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("setup.innerLife.status")
                    Spacer(minLength: 8)
                    switch status.recovery {
                    case .configureProvider:
                        Button("Set up a connection") { SettingsLink.open(.providers) }
                    case .selectModel:
                        Button("Choose my reflection mind") { SettingsLink.open(.personality, tab: "minds") }
                    case .reapply:
                        Button("Enable again") { Task { await setInnerLife(true) } }
                            .disabled(savingInnerLife)
                    case nil:
                        EmptyView()
                    }
                }
                .buttonStyle(.bordered)
                .tint(NativeAgentShell.text)
                .controlSize(.small)
                if let detail = status.detail {
                    Text(detail)
                        .font(ShellType.rowDetail)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        }
    }

    private func innerLifeStatusColor(_ tone: SlimSettingsSubconsciousStatusLine.Tone) -> Color {
        switch tone {
        case .neutral, .progress: NativeAgentShell.secondary
        case .healthy: NativeAgentShell.calm
        case .warning, .unavailable: NativeAgentShell.trouble
        }
    }

    @MainActor
    private func refreshInnerLifeStatus() async {
        await appModel.engine.cognitionView.refreshVitals()
    }

    private var anyMacCapabilityEnabled: Bool {
        macPermissions.values.contains { $0.read || $0.write }
    }

    private var appearanceRow: some View {
        SetupRow(
            title: "Appearance",
            detail: "Prefer the dark window, whatever the system is doing."
        ) {
            Toggle("Prefer Dark Appearance", isOn: $preferDark)
                .labelsHidden()
                .toggleStyle(.switch)
                .hazeTinted()
        }
    }

    /// Active when turning on. Turning off leaves Fluid Context where the user
    /// put it: the switch above it is not a licence to undo an unrelated
    /// choice.
    @MainActor
    private func setInnerLife(_ enabled: Bool) async {
        savingInnerLife = true
        defer { savingInnerLife = false }
        innerLifeError = nil
        subconsciousEnabled = enabled

        let (state, problem) = await appModel.setInnerLifeEnabled(enabled)
        subconsciousEnabled = state.enabled
        capsuleEnabled = state.capsuleEnabled
        backgroundEnabled = state.backgroundEnabled
        reflectionEnabled = state.reflectionEnabled
        reflectionBudget = state.reflectionBudget
        organismEnabled = state.organismEnabled
        innerLifeError = problem
    }

    @MainActor
    private func refreshMacPermissions() async {
        do {
            macPermissions = try await MacIntegrationPermissionStore.shared.currentChecked()
            macPermissionsUnavailable = false
        } catch {
            macPermissions = [:]
            macPermissionsUnavailable = true
        }
        macPermissionsLoaded = true
    }

}

// MARK: - Rows

/// ONE HEIGHT FOR EVERY ROW. User, 2026-09-02: the column read ragged because
/// every card was as tall as its own copy. A fixed frame, not a minimum — a
/// minimum drifts the moment a sentence or a name changes length.
enum SetupMetrics {
    /// A 14pt title plus up to two 12pt lines ("Full Mac" needs the second
    /// one to say plainly what full run means).
    static let rowContentHeight: CGFloat = 50
}

/// THE ONE ROW SHAPE on the settings pages: a 14pt medium title, one 12pt
/// secondary sentence (two lines at most), and the control on the right.
struct SetupRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SetupRowText(title: title, detail: detail)
            Spacer(minLength: 12)
            control
        }
    }
}

/// The text half of a row, held to the one row height.
struct SetupRowText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(ShellType.rowTitle)
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(ShellType.rowDetail)
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
        .frame(minHeight: SetupMetrics.rowContentHeight, alignment: .leading)
    }
}

/// One of the four, as a row: a title, one plain sentence, a switch on the
/// right, and whatever the switch reveals underneath it.
struct SetupSwitchCard<Detail: View>: View {
    let title: String
    let sentence: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    @ViewBuilder var detail: Detail

    init(
        title: String,
        sentence: String,
        isOn: Binding<Bool>,
        disabled: Bool = false,
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) {
        self.title = title
        self.sentence = sentence
        self._isOn = isOn
        self.disabled = disabled
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // The fixed box every row shares.
                SetupRowText(title: title, detail: sentence)
                Spacer(minLength: 12)
                switchFace
            }
            detail
        }
    }

    private var switchFace: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            // A grey track reads the same on and off, in either appearance and
            // in an inactive window. The on-track wears the haze's colour.
            .hazeTinted()
            .disabled(disabled)
            .accessibilityLabel(title)
            .accessibilityHint(sentence)
    }
}

struct SetupInfoCard: View {
    let title: String
    let detail: String
    /// Opens the rail page the card is about (`SettingsLink`).
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            SetupRow(title: title, detail: detail) {
                Image(systemName: "chevron.right")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(detail)")
    }
}

// MARK: - Provider, then model

/// Two menus, not one list of everything. The first names a provider that is
/// actually connected; the second lists that provider's models, the way the
/// Providers page does. User, 2026-09-05: "it even shows stuff I don't have API
/// keys on; pick provider, then another box shows models." Changing the
/// provider selects its first model at once so the pair never disagrees;
/// the model menu then narrows it.
struct ProviderThenModelPicker: View {
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        var supportedEfforts: [String]? = nil
        var supportsFast: Bool? = nil
    }
    struct Provider: Identifiable, Equatable {
        let id: String
        let name: String
        let ready: Bool
        let models: [Model]
    }

    let providers: [Provider]
    let currentProviderID: String
    let currentModelID: String
    let disabled: Bool
    let onSelect: (Provider, Model) -> Void
    var integrated: Bool = false

    private var visibleProviders: [Provider] {
        var list = providers.filter(\.ready).map { provider in
            Provider(id: provider.id, name: provider.name + (provider.models.isEmpty ? " · no models available" : ""),
                ready: provider.ready, models: provider.models)
        }
        if !currentProviderID.isEmpty, !list.contains(where: { $0.id == currentProviderID }) {
            // The saved provider lost its key: keep it selectable so the
            // control never claims someone else's mind is current.
            let stale = providers.first(where: { $0.id == currentProviderID })
            list.insert(Provider(
                id: currentProviderID,
                name: (stale?.name ?? currentProviderID) + " · not connected",
                ready: false,
                models: stale?.models ?? []
            ), at: 0)
        }
        return list.sorted { lhs, rhs in
            if lhs.ready != rhs.ready { return lhs.ready }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedProvider: Provider? {
        visibleProviders.first(where: { $0.id == currentProviderID })
    }

    /// "Anthropic (OAuth / Setup-Token)" is a wiring detail, not a name. The
    /// parenthetical is dropped so the row reads "Anthropic · Opus 5".
    static func plainProviderName(_ displayName: String) -> String {
        guard let open = displayName.range(of: " (") else { return displayName }
        return String(displayName[..<open.lowerBound])
    }

    private var visibleModels: [Model] {
        var models = selectedProvider?.models ?? []
        if !currentModelID.isEmpty, !models.contains(where: { $0.id == currentModelID }) {
            models.insert(Model(id: currentModelID, name: currentModelID + " — unavailable"), at: 0)
        }
        return models
    }

    var body: some View {
        if integrated {
            Menu {
                ForEach(providers.filter(\.ready)) { provider in
                    Section(provider.name) {
                        if provider.models.isEmpty { Text("No models available") }
                        ForEach(provider.models) { model in
                            Button("\(provider.name) · \(model.name)") { onSelect(provider, model) }
                                .disabled(!provider.ready)
                        }
                    }
                }
            } label: {
                Text(currentModelID.isEmpty ? "Choose model" : "\(selectedProvider?.name ?? currentProviderID) · \(visibleModels.first(where: { $0.id == currentModelID })?.name ?? currentModelID)")
            }
            .disabled(disabled).accessibilityLabel("Model and provider")
        } else {
        HStack(spacing: 8) {
            Picker("Provider", selection: Binding(
                get: { currentProviderID },
                set: { id in
                    guard id != currentProviderID,
                          let provider = visibleProviders.first(where: { $0.id == id }),
                          let first = provider.models.first(where: { $0.id == currentModelID }) ?? provider.models.first
                    else { return }
                    onSelect(provider, first)
                }
            )) {
                ForEach(visibleProviders) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(disabled)

            Picker("Model", selection: Binding(
                get: { currentModelID },
                set: { id in
                    guard id != currentModelID,
                          let provider = selectedProvider,
                          let model = provider.models.first(where: { $0.id == id })
                    else { return }
                    onSelect(provider, model)
                }
            )) {
                ForEach(visibleModels) { model in
                    Text(model.name).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(disabled || selectedProvider == nil)
        }
        }
    }
}

// MARK: - Reflection model picker

/// The same reflection selection the Subconscious section owns: it writes
/// through `NativeCognitionRuntime.setReflectionSelection`, which is what
/// persists `cognitiveSubstrateReflectionModel` / `…Provider`.
struct SetupReflectionModelPicker: View {
    private struct Choice: Identifiable, Equatable {
        let id: String
        let providerID: String
        let modelID: String
        let label: String
        let ready: Bool
    }

    @Environment(AppModel.self) private var appModel
    @State private var reflectionModel = ""
    @State private var reflectionProvider = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var pendingProviderID: String?
    @State private var pendingModelID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if appModel.engine.providers.connections.isEmpty {
                Text("Connect a provider to choose the mind I reflect with.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ProviderThenModelPicker(
                    providers: appModel.engine.providers.connections.map { provider in
                        ProviderThenModelPicker.Provider(
                            id: provider.provider_id,
                            name: ProviderThenModelPicker.plainProviderName(provider.display_name),
                            ready: provider.auth_status.state == "ready",
                            models: provider.models.map { ProviderThenModelPicker.Model(id: $0.id, name: $0.name) }
                        )
                    },
                    currentProviderID: pendingProviderID ?? currentProviderID,
                    currentModelID: pendingModelID ?? reflectionModel,
                    disabled: saving
                ) { provider, model in
                    pendingProviderID = provider.id
                    pendingModelID = model.id
                    Task {
                        await save(Choice(
                            id: choiceID(provider.id, model.id),
                            providerID: provider.id,
                            modelID: model.id,
                            label: "\(model.name) · \(provider.name)",
                            ready: provider.ready
                        ))
                    }
                }
                .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            let root = appModel.engine.providers.dataRoot
            await ViewFileRefreshTask.run(paths: ["providers/surfaces.json", "providers/active.json",
                "providers/pending-surface-configuration.json"].map { root.appendingPathComponent($0) }) {
                await load()
            }
        }
    }

    private var currentProviderID: String {
        reflectionProvider
    }

    @MainActor
    private func load() async {
        do {
            let snapshot = try await appModel.engine.providers.routing.checkedProviderSnapshot()
            appModel.engine.providers.connections = try ProvidersFacade.connections(from: snapshot)
            reflectionModel = snapshot.routing.preferences["cognition_reflection"]?.model ?? ""
            reflectionProvider = snapshot.routing.activeProviders["cognition_reflection"] ?? ""
            errorMessage = nil
            loaded = true
        } catch {
            reflectionModel = ""
            reflectionProvider = ""
            loaded = false
            errorMessage = UserFacingError.message(error, action: "load the mind settings")
        }
    }

    private func choiceID(_ providerID: String, _ modelID: String) -> String {
        providerID + "\u{1f}" + modelID
    }

    @MainActor
    private func save(_ choice: Choice) async {
        saving = true
        defer { saving = false }
        do {
            try await NativeAgentEngine.liveCognition.setReflectionSelection(
                model: choice.modelID,
                provider: choice.providerID
            )
            await load()
        } catch {
            errorMessage = UserFacingError.message(error, action: "save that mind")
        }
        pendingProviderID = nil
        pendingModelID = nil
    }
}

// MARK: - The hour's provider picker

/// The hour's effective Memory and mind choice, rendered where the switch is.
/// Writes the whole group through the same transaction Providers uses.
struct SetupStudioWanderPicker: View {
    @Environment(AppModel.self) private var appModel
    @State private var providers: [ProviderInfo] = []
    @State private var activeProvider = ""
    @State private var model = ""
    @State private var reasoningEffort = "high"
    @State private var serviceTier: String?
    @State private var loaded = false
    @State private var saving = false
    @State private var errorMessage: String?

    private let surface = NativeCognitionRuntime.studioWanderSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !loaded {
                ProgressView().controlSize(.small)
            } else if providers.isEmpty {
                Text("Connect a provider to choose the mind my hour is spent with.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    Picker("\(AgentVoice.live.possessive) hour — provider", selection: Binding(
                        get: { activeProvider },
                        set: { newValue in
                            activeProvider = newValue
                            let first = models(for: newValue).first?.id ?? ""
                            model = first
                            Task { await save() }
                        }
                    )) {
                        ForEach(providers) { provider in
                            let ready = provider.auth_status.state == "ready"
                            Text(provider.display_name + (ready ? "" : " ⚠️"))
                                .tag(provider.provider_id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Picker("\(AgentVoice.live.possessive) hour — model", selection: Binding(
                        get: { model },
                        set: { newValue in
                            model = newValue
                            Task { await save() }
                        }
                    )) {
                        if model.isEmpty { Text("No model selected").tag("") }
                        if !model.isEmpty, !models(for: activeProvider).contains(where: { $0.id == model }) {
                            Text(model + " — unavailable").tag(model)
                        }
                        ForEach(models(for: activeProvider)) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .disabled(saving)
                .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        .task {
            let root = appModel.engine.providers.dataRoot
            await ViewFileRefreshTask.run(paths: ["providers/surfaces.json", "providers/active.json",
                "providers/pending-surface-configuration.json"].map { root.appendingPathComponent($0) }) {
                await load()
            }
        }
    }

    private func models(for providerID: String) -> [ProviderModelInfo] {
        providers.first { $0.provider_id == providerID }?.models ?? []
    }

    @MainActor
    private func load() async {
        do {
            let snapshot = try await appModel.engine.providers.routing.checkedProviderSnapshot()
            providers = try ProvidersFacade.connections(from: snapshot)
            activeProvider = snapshot.routing.activeProviders[surface] ?? ""
            if let preference = snapshot.routing.preferences[surface] {
                model = preference.model
                reasoningEffort = preference.reasoningEffort
                serviceTier = preference.serviceTier
            } else {
                model = ""
            }
            errorMessage = nil
            loaded = true
        } catch {
            loaded = false
            errorMessage = UserFacingError.message(error, action: "load the mind settings")
        }
    }

    @MainActor
    private func save() async {
        guard !activeProvider.isEmpty, !model.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let result = try await appModel.saveProviderGroupSelection(
                group: ProviderSurfaceGroups.mind,
                providerID: activeProvider,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
            activeProvider = result.snapshot.activeProviders[surface] ?? ""
            if let preference = result.snapshot.preferences[surface] {
                model = preference.model
                reasoningEffort = preference.reasoningEffort
                serviceTier = preference.serviceTier
            }
            errorMessage = nil
            appModel.statusText = "Memory and mind → \(model) saved"
        } catch {
            await load()
            errorMessage = UserFacingError.message(error, action: "save the mind for my hour")
        }
    }
}

// MARK: - Minds (Advanced)

/// WHERE THE MINDS ARE: Personality ▸ My minds. The chat mind is the
/// composer's and Providers'. The reflection mind and the hour's mind are
/// still exactly the pickers they were (`SetupReflectionModelPicker`,
/// `SetupStudioWanderPicker`), writing the same storage.
struct SetupMindsView: View {
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = true
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AdvancedSection(
                    title: "The mind I reflect with",
                    card: .single,
                    note: subconsciousEnabled
                        ? "Used by my inner life, between conversations."
                        : "My inner life is off, so nothing reflects with this yet."
                ) {
                    SetupReflectionModelPicker()
                }

                AdvancedSection(
                    title: "\(AgentVoice.live.possessive) hour",
                    card: .single,
                    note: studioWanderEnabled
                        ? "The provider and model for Memory and mind, including reflection and my daily hour."
                        : "The provider and model for Memory and mind, including reflection. My daily hour is off."
                ) {
                    SetupStudioWanderPicker()
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(AgentVoice.live.possessive) minds")
    }
}

// MARK: - Advanced rows
