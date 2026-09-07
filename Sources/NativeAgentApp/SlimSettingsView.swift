// Move-only extraction (tightness Wave C) from SidebarFlattenViews.swift

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore
// Personality depth item 9: the `studioWanderEnabled` key lives with the lane
// law, so the switch and the lane can never disagree about its spelling.
import BackgroundLoops

/// One canonical owner for each live operational control. Views consume these
/// labels rather than repeating storage-oriented wording, which keeps a
/// control from quietly acquiring a second settings home.
enum OperationalSettingsControlPresentation {
    enum Control: CaseIterable, Hashable, Sendable {
        case providerRoute
        case macIntegrationPermission
        case subconsciousMaster
        case fluidContext
        case softwareUpdate
        case globalHotkey
    }

    enum Owner: String, Hashable, Sendable {
        case providers
        case macIntegration
        case settings
    }

    static func owner(for control: Control) -> Owner {
        switch control {
        case .providerRoute: .providers
        case .macIntegrationPermission: .macIntegration
        case .subconsciousMaster, .fluidContext, .softwareUpdate, .globalHotkey: .settings
        }
    }

    static func title(for control: Control) -> String {
        switch control {
        case .providerRoute: "Provider"
        case .macIntegrationPermission: "Mac Integration"
        case .subconsciousMaster: "Subconscious"
        case .fluidContext: "Fluid Context"
        case .softwareUpdate: "Software Update"
        case .globalHotkey: "Global Shortcut"
        }
    }

    static func fluidContextLabel(_ mode: ContextFlowMode) -> String {
        switch mode {
        case .active: "Active"
        case .shadow: "Observe Only"
        case .off: "Off"
        }
    }
}

/// The About panel must distinguish a live runtime read from the unrelated
/// most-recent UI action. `AppModel.statusText` is intentionally a broad
/// activity feed, so showing it as "Status" could claim an old save result
/// describes the runtime now.
enum SlimSettingsStatusLinePresentation {
    enum Tone: Equatable {
        case neutral
        case success
        case warning
        case failure
    }

    struct State: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        let systemImage: String
    }

    static func runtimeState(runtimeOK: Bool?, lastRefreshError: String?) -> State {
        let error = normalized(lastRefreshError)

        switch runtimeOK {
        case true:
            if let error {
                return State(
                    text: "Runtime is online; some app data is unavailable",
                    detail: "Last refresh error: \(bounded(error))",
                    tone: .warning,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            return State(
                text: "Runtime is online",
                detail: nil,
                tone: .success,
                systemImage: "checkmark.circle.fill"
            )
        case false:
            return State(
                text: "Runtime reported a problem",
                detail: error.map { "Last refresh error: \(bounded($0))" },
                tone: .failure,
                systemImage: "xmark.octagon.fill"
            )
        case nil:
            if let error {
                return State(
                    text: "Runtime status is unavailable",
                    detail: "Last refresh error: \(bounded(error))",
                    tone: .failure,
                    systemImage: "xmark.octagon.fill"
                )
            }
            return State(
                text: "Runtime status has not been checked",
                detail: nil,
                tone: .neutral,
                systemImage: "questionmark.circle"
            )
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private static func bounded(_ text: String) -> String {
        let maximumVisibleCharacters = 240
        guard text.count > maximumVisibleCharacters else { return text }
        return String(text.prefix(maximumVisibleCharacters)) + "…"
    }
}

/// The updater has two independent facts: whether this build has a published
/// feed at all, and whether Sparkle can start another manual check right now.
/// Keep them separate so a release build that is mid-check never looks like a
/// locally built copy, and a development build never looks checkable.
enum SoftwareUpdateRowPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
        let status: String
        let systemImage: String
        let actionEnabled: Bool
    }

    static func resolve(
        availableVersion: String?,
        updatesAreAvailable: Bool,
        canCheckForUpdates: Bool,
        unavailableDetail: String
    ) -> State {
        if let version = availableVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return State(
                title: "NativeAgent \(version) is available",
                detail: "Select Update Available to review and install the signed release.",
                status: "ok",
                systemImage: "arrow.down.circle.fill",
                actionEnabled: true
            )
        }
        guard updatesAreAvailable else {
            return State(
                title: "Automatic updates aren’t available in this build",
                detail: unavailableDetail,
                status: "warn",
                systemImage: "info.circle",
                actionEnabled: true
            )
        }
        guard canCheckForUpdates else {
            return State(
                title: "An update check is already in progress",
                detail: "Wait for the current signed-feed check to finish before starting another one.",
                status: "info",
                systemImage: "arrow.triangle.2.circlepath",
                actionEnabled: false
            )
        }
        return State(
            title: "Automatic updates are ready",
            detail: "NativeAgent checks the signed release feed automatically. You can also check now.",
            status: "ok",
            systemImage: "checkmark.circle",
            actionEnabled: true
        )
    }
}

struct SoftwareUpdateRow: View {
    let state: SoftwareUpdateRowPresentation.State
    let actionTitle: String
    let onCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(ShellType.labelSemibold)
                .foregroundStyle(SettingsInk.status(state.status))
            Text(state.detail)
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button(actionTitle, action: onCheck)
                .disabled(!state.actionEnabled)
                .accessibilityIdentifier("settings.softwareUpdate.check")
        }
        .accessibilityIdentifier("settings.softwareUpdate.row")
    }
}

/// The page's colour roles. `NativeAgentTheme` still answers in SwiftUI's own
/// green/orange/red, which are not the shell's felt-state colours and do not
/// carry their light-appearance contrast work — every status word on this page
/// goes through here instead.
private enum SettingsInk {
    static func status(_ status: String?) -> Color {
        switch status {
        case "ok": NativeAgentShell.calm
        case "warn", "fail": NativeAgentShell.trouble
        default: NativeAgentShell.secondary
        }
    }
}

// MARK: - Slim Settings (the new "Settings" primary tab)

struct SlimSettingsView: View {
    /// One-line, paste-into-a-bug-report identity of the running bytes:
    /// `0.3.7 (abc1234, modified)`. The revision is shown short; `modified` is
    /// shown whenever the builder did not stamp clean-source truth, because an
    /// unstamped bundle is exactly the case that must not be read as exact
    /// proof of a commit (see NativeAgentBuildIdentity).
    static func buildIdentityLine(_ identity: NativeAgentBuildIdentity) -> String {
        var line = identity.version
        var parenthetical: [String] = []
        if let revision = identity.sourceRevision, !revision.isEmpty {
            parenthetical.append(String(revision.prefix(7)))
        }
        if identity.sourceDirty {
            parenthetical.append("modified")
        }
        if !parenthetical.isEmpty {
            line += " (\(parenthetical.joined(separator: ", ")))"
        }
        if identity.build != identity.version {
            line += " build \(identity.build)"
        }
        return line
    }

    @Environment(AppModel.self) private var appModel
    // The app menu and Settings use one Sparkle scheduler/controller.
    @State private var updateController = UpdateController.shared
    @AppStorage("nativeagent.showTour") private var showTour = false
    @State private var tourReplayCoordinator = OnboardingTourReplayCoordinator.shared
    @AppStorage("nativeagent.darkMode") private var preferDark = true
    // User-selected transcript threshold ceiling. The shared compactor clamps
    // this to 40% of the active model window so smaller-window models compact
    // before the configured ceiling becomes unsafe.
    @AppStorage("nativeagent.compactionThresholdTokens") private var compactionThresholdTokens = 200_000
    // B2.2: gate developer/internal sidebar surfaces (Turn Inspector, MCP,
    // Cognition, …) behind an explicit preference. Off on fresh installs. Purely
    // a UI-visibility preference — NOT Trust Center's developerMode policy.
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    // 2026-07-23 B2.6c: Subconscious + Embeddings are power-user internals a
    // stranger never touches; they collapse behind this persisted Advanced
    // disclosure. Attention flags let an error/partial state still surface a
    // warn badge on the collapsed header (CapabilitiesView collapsedCard idiom).
    @AppStorage("nativeagent.settingsShowAdvanced") private var showAdvancedSettings = false
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var embeddingsAttention = false
    @State private var subconsciousAttention = false
    @State private var dataLimitsFailure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink(value: SlimSettingsPairDeviceLink.destination) {
                        Text(SlimSettingsPairDeviceLink.title)
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                    }
                    .accessibilityHint(SlimSettingsPairDeviceLink.accessibilityHint)
                } header: {
                    SettingsEyebrow("Devices")
                }

                Section {
                    let telegramLink = SlimSettingsTelegramLink.presentation
                    NavigationLink(value: telegramLink.destination) {
                        Text(telegramLink.title)
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                    }
                    .accessibilityHint(telegramLink.accessibilityHint)
                    .accessibilityIdentifier("settings.telegram-link")
                } header: {
                    SettingsEyebrow("Integrations")
                }

                Section {
                    SettingsSwitch("Prefer Dark Appearance", isOn: $preferDark)
                    // User, 2026-09-04: the new shell shows every surface; the
                    // switch only means something on the classic sidebar.
                    if classicShell {
                        SettingsSwitch("Show Developer Surfaces", isOn: $showDeveloperSurfaces)
                    }
                    // ui-simplify 2026-09-02 (Lane A): the kill switch, made
                    // reachable. ON restores the previous sidebar, session
                    // list, chat chrome and composer exactly as they were.
                    SettingsSwitch("Use the classic sidebar", isOn: $classicShell)
                        .accessibilityIdentifier("settings.classic-shell-toggle")
                        .accessibilityHint("Restores the previous sidebar, session list, and chat layout")
                } header: {
                    SettingsEyebrow("Appearance")
                } footer: {
                    SettingsFootnote("Developer surfaces reveal the internal pages — Capabilities, Knowledge Graph, Dreams, Diagnostics, Inbox Policy and MCP — under Advanced and in the command palette. Off by default; a deep link to one still resolves.")
                }

                Section {
                    HotkeyControlView()
                } header: {
                    SettingsEyebrow("Global shortcut")
                }

                Section {
                    HStack(spacing: 8) {
                        Text("Auto-compact threshold")
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                            .accessibilityHidden(true)
                        Spacer(minLength: 8)
                        Text(formatThresholdTokens(compactionThresholdTokens))
                            .font(ShellType.label.monospaced())
                            .foregroundStyle(NativeAgentShell.secondary)
                            .accessibilityHidden(true)
                        Stepper("Auto-compact threshold",
                                value: $compactionThresholdTokens,
                                in: 50_000...500_000,
                                step: 10_000)
                            .labelsHidden()
                            // NSStepper exposes its two visual arrows as
                            // separate, unnamed AX buttons unless SwiftUI is
                            // told to present the control as one adjustable
                            // element. VoiceOver now lands once, announces the
                            // setting and value, and can increment/decrement it.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Auto-compact threshold")
                            .accessibilityValue(formatThresholdTokens(compactionThresholdTokens))
                            .accessibilityHint("Adjusts the maximum chat transcript size before automatic compaction")
                    }
                } header: {
                    SettingsEyebrow("Chat")
                } footer: {
                    SettingsFootnote("The largest a transcript grows before it is compacted. A model with a smaller context window compacts earlier, at 40% of that window. The default ceiling is 200k.")
                }

                Section {
                    Button("Replay the onboarding tour") {
                        showTour = true
                        tourReplayCoordinator.requestReplay()
                    }
                    Button {
                        let outcome = SlimSettingsDataLimitsReference.open(
                            resourceLookup: { name, ext, subdirectory in
                                Bundle.main.url(
                                    forResource: name,
                                    withExtension: ext,
                                    subdirectory: subdirectory
                                )
                            },
                            opener: { NSWorkspace.shared.open($0) }
                        )
                        if let failure = outcome.failureMessage {
                            dataLimitsFailure = failure
                        }
                    } label: {
                        Text("Show data limits")
                    }
                } header: {
                    SettingsEyebrow("Help and reference")
                }

                Section {
                    // Sweep R4 C13: NativeAgentBuildIdentity already computes
                    // version + source revision + dirty truth and no View
                    // rendered it, so a dev build and a release build looked
                    // identical and a bug report could not name the bytes.
                    // Copyable, because the point is pasting it into a report.
                    let identity = NativeAgentBuildIdentity.current
                    HStack(spacing: 8) {
                        Text("Version")
                            .font(ShellType.labelSemibold)
                            .foregroundStyle(NativeAgentShell.text)
                        Spacer(minLength: 8)
                        Text(Self.buildIdentityLine(identity))
                            .font(ShellType.label.monospaced())
                            .foregroundStyle(NativeAgentShell.secondary)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button("Copy build identity") {
                            ChatClipboard.copy(Self.buildIdentityLine(identity))
                        }
                    }
                    let updateState = SoftwareUpdateRowPresentation.resolve(
                        availableVersion: updateController.status.availableVersion,
                        updatesAreAvailable: updateController.updatesAreAvailable,
                        canCheckForUpdates: updateController.canCheckForUpdates,
                        unavailableDetail: updateController.settingsDetail
                    )
                    SoftwareUpdateRow(
                        state: updateState,
                        actionTitle: updateController.menuTitle,
                        onCheck: { updateController.checkForUpdates() }
                    )
                    let runtimeStatus = SlimSettingsStatusLinePresentation.runtimeState(
                        runtimeOK: appModel.health?.ok,
                        lastRefreshError: appModel.lastRefreshError
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Runtime")
                                .font(ShellType.labelSemibold)
                                .foregroundStyle(NativeAgentShell.text)
                            Spacer(minLength: 8)
                            Text(runtimeStatus.text)
                                .font(ShellType.label)
                                .foregroundStyle(runtimeStatusColor(runtimeStatus.tone))
                                .multilineTextAlignment(.trailing)
                        }
                        if let detail = runtimeStatus.detail {
                            Text(detail)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Runtime status: \(runtimeStatus.text)")
                } header: {
                    SettingsEyebrow("About")
                }

                // ui-simplify 2026-09-02 (Lane A): ONE Advanced door, at the
                // bottom, and everything that used to compete for sidebar space
                // is behind it — the four setup pages that were primary tabs
                // (Skills & Tools, Providers, Trust, Mac Integration), the old
                // Advanced group, and the two power-user blocks that were
                // already collapsed here. Nothing was removed and no view was
                // forked: each row pushes the SAME page ContentView renders,
                // and the Developer Surfaces gate is unchanged.
                // User, 2026-09-04: the Advanced door exists for the classic
                // sidebar; the new shell's Settings page carries every card.
                if classicShell {
                Section {
                    Button {
                        withAnimation(
                            NativeAgentMotion.respecting(
                                ShellFoldMotion.open,
                                reduceMotion: reduceMotion
                            )
                        ) { showAdvancedSettings.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Advanced")
                                .font(ShellType.labelSemibold)
                                .foregroundStyle(NativeAgentShell.text)
                            Spacer(minLength: 8)
                            if !showAdvancedSettings, embeddingsAttention || subconsciousAttention {
                                StatusBadge(text: "Needs attention", status: "warn")
                            }
                            Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                                .foregroundStyle(NativeAgentShell.tertiary)
                                .font(ShellType.captionSemibold)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.naFeel)
                    .accessibilityIdentifier("settings.advanced.disclosure")
                    .accessibilityValue(
                        SidebarAdvancedDisclosurePresentation
                            .accessibilityValue(isExpanded: showAdvancedSettings)
                    )

                    // User, 2026-09-04: the new shell's pages are on the rail;
                    // only the classic sidebar still opens them from here.
                    if showAdvancedSettings, classicShell {
                        ForEach(
                            SidebarItem.visibleAdvancedItems(
                                developerSurfacesEnabled: showDeveloperSurfaces
                            )
                        ) { item in
                            NavigationLink(
                                value: SlimSettingsNavigationDestination.advanced(item)
                            ) {
                                Text(item.displayName)
                                    .font(ShellType.labelSemibold)
                                    .foregroundStyle(NativeAgentShell.text)
                            }
                            .accessibilityIdentifier("settings.advanced.page.\(item.rawValue)")
                        }
                    }
                } footer: {
                    SettingsFootnote(classicShell
                        ? "Skills, providers, trust, Mac access, and the internals. Set once; most people never come back."
                        : "Embeddings and the subconscious. Set once; most people never come back.")
                }
                }

                // User, 2026-09-04: in the new shell these live on the Settings
                // page as cards; the classic sidebar keeps them here.
                if showAdvancedSettings, classicShell {
                    EmbeddingsSettingsSection(attention: $embeddingsAttention)
                    SubconsciousSettingsSection(attention: $subconsciousAttention)
                }
            }
            .formStyle(.grouped)
            // The page renders inside the shell's room as well as in the
            // Settings window; without this the Form paints its own slab over
            // the glass (`ShellPageFrame`, SetupView.swift).
            .scrollContentBackground(.hidden)
            .navigationDestination(for: SlimSettingsNavigationDestination.self) { destination in
                SlimSettingsDestinationView(destination: destination)
            }
            .navigationTitle("Settings")
            // Seed the Embeddings attention badge while the Advanced block is
            // collapsed (the child section that normally detects fail-closed /
            // failed-install isn't mounted then). Subconscious defaults off and
            // only turns partial via interaction, which mounts its child — so
            // only Embeddings needs a collapsed seed. (B2.6c)
            .task(id: showAdvancedSettings) {
                guard !showAdvancedSettings else { return }
                await seedEmbeddingsAttention()
            }
            .alert(
                "Can’t open data limits",
                isPresented: Binding(
                    get: { dataLimitsFailure != nil },
                    set: { if !$0 { dataLimitsFailure = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dataLimitsFailure ?? "The data-limits reference is unavailable.")
            }
        }
    }

    @MainActor
    private func seedEmbeddingsAttention() async {
        do {
            let s = try await appModel.fetchEmbeddingsStatus()
            embeddingsAttention = s.effectiveBackend == "unavailable"
                || s.installState?.state == "failed"
                || s.reindexState?.state == "failed"
        } catch {
            embeddingsAttention = true
        }
    }

    private func runtimeStatusColor(_ tone: SlimSettingsStatusLinePresentation.Tone) -> Color {
        switch tone {
        case .neutral: NativeAgentShell.secondary
        case .success: NativeAgentShell.calm
        case .warning, .failure: NativeAgentShell.trouble
        }
    }

    private func formatThresholdTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%dk",  n / 1_000) }
        return "\(n)"
    }
}

/// The one mounted destination seam for the macOS Settings scene. Tests mount
/// this exact view with each typed route so a Settings entry cannot retain a
/// valid-looking route while its visible destination drifts elsewhere.
struct SlimSettingsDestinationView: View {
    let destination: SlimSettingsNavigationDestination

    var body: some View {
        switch destination.content {
        case .macPairing:
            MacPairingView()
        case .telegramSettings:
            TelegramView()
        case .advancedPage(let item):
            AdvancedSettingsPage(item: item)
        }
    }
}

/// ui-simplify 2026-09-02 (Lane A): the pages that left the sidebar, rendered
/// unchanged. This is deliberately a one-to-one map onto the SAME views
/// ContentView's detail switch renders — moving a page behind the Advanced door
/// must not fork it into a second implementation. Anything not in the Advanced
/// set falls back to Settings' own root rather than inventing a page.
struct AdvancedSettingsPage: View {
    let item: SidebarItem
    /// Skills & Tools owns a two-way segment. Behind the Advanced door it keeps
    /// working; a `.constant` binding would freeze it on Skills.
    @SceneStorage("advancedSkillsToolsSection") private var skillsSectionRaw = SkillsToolsSection.skills.rawValue

    private var skillsSection: Binding<SkillsToolsSection> {
        Binding(
            get: { SkillsToolsSection(rawValue: skillsSectionRaw) ?? .skills },
            set: { skillsSectionRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            switch item.normalized {
            case .skills: SkillsToolsView(selection: skillsSection)
            case .providers: ProviderSettingsView()
            case .trust: TrustCenterView()
            case .macIntegration: MacIntegrationView()
            case .personality: PersonalityView()
            case .connectors: ConnectorsView()
            case .capabilities: CapabilitiesView()
            case .knowledge: KnowledgeGraphView()
            case .dreams: DreamsView()
            case .diagnostics: DiagnosticsView()
            case .inboxPolicy: InboxSettingsView()
            case .mcp: MCPHubView()
            default:
                NativeEmptyState(
                    title: "That page moved",
                    detail: "It is reachable from the command palette (Command-K).",
                    systemImage: "questionmark.circle"
                )
            }
        }
        .navigationTitle(item.displayName)
    }
}

// MARK: - Subconscious section

private struct SubconsciousSettingsSection: View {
    private struct ReflectionModelChoice: Identifiable, Equatable {
        let id: String
        let providerID: String
        let modelID: String
        let label: String
        let providerReady: Bool
    }

    @Environment(AppModel.self) private var appModel
    // 2026-07-23 B2.6c: reports an attention signal up to the Advanced
    // disclosure so a partial/errored Subconscious still surfaces a warn badge
    // when the block is collapsed.
    @Binding var attention: Bool
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = false
    @AppStorage("cognitiveSubstrateCapsuleEnabled") private var capsuleEnabled = true
    @AppStorage("cognitiveSubstrateBackgroundEnabled") private var backgroundEnabled = true
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("cognitiveSubstrateDailyReflectionBudget") private var reflectionBudget = 2
    @AppStorage("organismKernelEnabled") private var organismEnabled = false
    @AppStorage("contextFlowMode") private var contextFlowMode = ContextFlowMode.shadow.rawValue
    @AppStorage("cognitiveSubstrateReflectionModel") private var subconsciousModel = "claude-opus-4-8"
    @AppStorage("cognitiveSubstrateReflectionProvider") private var subconsciousProvider = ""
    // Personality depth item 9 — HER HOUR. Default false, deliberately, in
    // every build: an install that never opened this page never spends an hour
    // of hers, and a public-safe build before onboarding cannot install the lane
    // at all (NativeAgentPublicSafety, checked again at the lane).
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false
    @State private var savingToggle = false
    @State private var savingContextFlow = false
    @State private var savingModel = false
    @State private var errorMessage: String?
    @State private var contextFlowStatus: NativeContextFlowModeStatus?
    @State private var reflectionRouteStatus: NativeReflectionRouteStatus?
    @State private var subconsciousRuntimeState: NativeSubconsciousRuntimeState?
    @State private var pendingReflectionChoiceID: String?

    var body: some View {
        Section {
            SettingsSwitch("Subconscious", isOn: Binding(
                get: { subconsciousEnabled },
                set: { enabled in Task { await setSubconsciousEnabled(enabled) } }
            ))
            .disabled(savingToggle)

            // HER HOUR (personality depth item 9; User, 2026-09-02: "give it to
            // her"). A plain switch, no schedule to configure and no cadence to
            // tune — those are hers, not settings. Off means the lane is NOT
            // INSTALLED, not silently skipped: nothing is read and nothing is
            // written while this is off. Disabled with the master because the
            // hour is background cognition and cannot outlive it.
            SettingsSwitch("\(appModel.agentDisplayName)'s hour", isOn: Binding(
                get: { studioWanderEnabled },
                set: { enabled in
                    studioWanderEnabled = enabled
                    Task { await NativeCognitionRuntime.reloadStudioWanderInstallation() }
                }
            ))
            .disabled(savingToggle || !subconsciousEnabled)

            SettingsFootnote("At most once a day, when nothing is happening, \(appModel.agentDisplayName) spends an hour on something of \(appModel.agentDisplayName)'s own choosing — or decides not to. Nothing is scheduled, nothing is required, and nothing is written unless \(appModel.agentDisplayName) writes it. Pick the model under Providers ▸ Studio Wandering.")

            Picker(OperationalSettingsControlPresentation.title(for: .fluidContext), selection: $contextFlowMode) {
                ForEach([ContextFlowMode.active, .shadow, .off], id: \.self) { mode in
                    Text(contextFlowModeLabel(mode)).tag(mode.rawValue)
                }
            }
            .font(ShellType.label)
            .disabled(savingToggle || savingContextFlow)
            .onChange(of: contextFlowMode) { _, rawMode in
                Task { await saveContextFlowMode(rawMode) }
            }

            if let contextFlowStatusText {
                SettingsFootnote(contextFlowStatusText)
            }

            if reflectionModelChoices.isEmpty {
                HStack(spacing: 8) {
                    Text("The mind for reflection")
                        .font(ShellType.labelSemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Spacer(minLength: 8)
                    Text("Connect a provider to choose one")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                }
            } else {
                Picker("The mind for reflection", selection: Binding(
                    get: { pendingReflectionChoiceID ?? currentReflectionChoiceID },
                    set: { choiceID in
                        guard let choice = reflectionModelChoices.first(where: { $0.id == choiceID }) else {
                            return
                        }
                        pendingReflectionChoiceID = choiceID
                        Task { await saveSubconsciousSelection(choice) }
                    }
                )) {
                    ForEach(reflectionModelChoices) { choice in
                        Text(choice.label + (choice.providerReady ? "" : " ⚠️"))
                            .tag(choice.id)
                    }
                }
                .font(ShellType.label)
                .disabled(savingToggle || savingModel)
            }

            HStack(spacing: 8) {
                let status = statusPresentation
                Text(status.text)
                    .font(ShellType.label)
                    .foregroundStyle(statusColor(status.tone))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if savingToggle || savingContextFlow || savingModel {
                    ProgressView().controlSize(.small)
                }
            }

            if let detail = statusPresentation.detail {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(statusColor(statusPresentation.tone))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } header: {
            SettingsEyebrow("Subconscious")
        } footer: {
            SettingsFootnote("When on, \(appModel.agentDisplayName) keeps bounded background loops running and uses the selected mind for budgeted reflection.")
        }
        .task {
            if appModel.modelCatalog == nil {
                await appModel.refreshModelCatalog()
            }
            _ = await appModel.loadProvidersForChat()
            contextFlowStatus = await NativeContextFlowRuntime.shared.modeStatus()
            await refreshSubconsciousRuntimeState()
            await refreshReflectionRouteStatus()
            attention = attentionState
        }
        .onChange(of: attentionState) { _, newValue in
            attention = newValue
        }
    }

    private var reflectionModelChoices: [ReflectionModelChoice] {
        var choices: [ReflectionModelChoice] = []
        var seen: Set<String> = []
        for provider in appModel.providersList {
            let ready = provider.auth_status.state == "ready"
            for model in provider.models {
                let id = reflectionChoiceID(providerID: provider.provider_id, modelID: model.id)
                guard seen.insert(id).inserted else { continue }
                choices.append(ReflectionModelChoice(
                    id: id,
                    providerID: provider.provider_id,
                    modelID: model.id,
                    label: "\(model.name) · \(provider.display_name)",
                    providerReady: ready
                ))
            }
        }

        let currentProvider = effectiveSubconsciousProvider
        let currentID = reflectionChoiceID(
            providerID: currentProvider,
            modelID: effectiveSubconsciousModel
        )
        if !effectiveSubconsciousModel.isEmpty, !currentProvider.isEmpty,
           seen.insert(currentID).inserted {
            let provider = appModel.providersList.first { $0.provider_id == currentProvider }
            choices.append(ReflectionModelChoice(
                id: currentID,
                providerID: currentProvider,
                modelID: effectiveSubconsciousModel,
                label: "\(effectiveSubconsciousModel) · \(provider?.display_name ?? currentProvider) — Unavailable",
                providerReady: false
            ))
        }
        return choices.sorted { lhs, rhs in
            if lhs.id == currentID { return true }
            if rhs.id == currentID { return false }
            if lhs.providerReady != rhs.providerReady { return lhs.providerReady && !rhs.providerReady }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private var effectiveSubconsciousProvider: String {
        // User, 2026-09-06: the routing snapshot is the authority for BOTH
        // halves of this row. Preferring the stored preference key here while
        // the model reader preferred the live route paired a stale provider
        // with the live model, so the picker named a combination that never
        // runs. Same order as `effectiveSubconsciousModel` now.
        if let live = reflectionRouteStatus?.providerID, !live.isEmpty { return live }
        let stored = subconsciousProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return NativeCognitionRuntime.inferredReflectionProvider(for: effectiveSubconsciousModel)
    }

    private var effectiveSubconsciousModel: String {
        if let live = reflectionRouteStatus?.model, !live.isEmpty { return live }
        return subconsciousModel
    }

    private var currentReflectionChoiceID: String {
        reflectionChoiceID(providerID: effectiveSubconsciousProvider, modelID: effectiveSubconsciousModel)
    }

    private func reflectionChoiceID(providerID: String, modelID: String) -> String {
        providerID + "\u{1f}" + modelID
    }

    private var statusPresentation: SlimSettingsSubconsciousStatusLine.State {
        SlimSettingsSubconsciousStatusLine.state(
            runtime: subconsciousRuntimeState,
            reflectionRoute: reflectionRouteStatus
        )
    }

    // Attention = a real runtime warning/unavailability or an operation error.
    // Surfaced as a badge on the collapsed Advanced disclosure (B2.6c).
    private var attentionState: Bool {
        statusPresentation.requiresAttention || errorMessage != nil
    }

    private func statusColor(_ tone: SlimSettingsSubconsciousStatusLine.Tone) -> Color {
        switch tone {
        case .neutral, .progress:
            NativeAgentShell.secondary
        case .healthy:
            NativeAgentShell.calm
        case .warning, .unavailable:
            NativeAgentShell.trouble
        }
    }

    @MainActor
    private func setSubconsciousEnabled(_ enabled: Bool) async {
        savingToggle = true
        defer { savingToggle = false }
        if enabled, !(await ensureReflectionRouteForEnable()) {
            subconsciousEnabled = false
            errorMessage = reflectionRouteStatus?.detail
                ?? "Connect a provider or choose an available LLM before enabling Subconscious."
            appModel.statusText = "Subconscious needs a ready reflection LLM"
            return
        }
        subconsciousEnabled = enabled
        capsuleEnabled = enabled
        backgroundEnabled = enabled
        reflectionEnabled = enabled
        organismEnabled = enabled
        if enabled && reflectionBudget <= 0 {
            reflectionBudget = 2
        }
        let actual = await NativeCognitionRuntime.shared.setSubconsciousMasterEnabled(
            enabled,
            reflectionBudget: enabled ? max(1, reflectionBudget) : 0
        )
        // Her hour cannot outlive the master, and installation is CACHED — so
        // the master moving in either direction has to drop that cache or a
        // lane that is no longer permitted keeps running on a stale
        // `.installed` for the rest of the session. Turning the master off is
        // the direction that matters; turning it on is invalidated for the same
        // reason in reverse, so the switch below it takes effect immediately.
        await NativeCognitionRuntime.reloadStudioWanderInstallation()
        await refreshReflectionRouteStatus()
        applySubconsciousRuntimeState(actual)
        let fullyActive = actual.enabled && actual.capsuleEnabled
            && actual.backgroundEnabled && actual.reflectionEnabled
            && actual.reflectionBudget > 0 && actual.organismEnabled
            && reflectionRouteStatus?.isReady == true
        if enabled && !fullyActive {
            errorMessage = "Some Subconscious lanes are held off by setup, safety, or provider health."
            appModel.statusText = "Subconscious is only partially active"
        } else {
            errorMessage = nil
            appModel.statusText = enabled
                ? "Subconscious running with \(effectiveSubconsciousModel)"
                : "Subconscious disabled"
        }
    }

    @MainActor
    private func saveContextFlowMode(_ rawMode: String) async {
        guard let requested = ContextFlowMode(rawValue: rawMode) else {
            contextFlowMode = ContextFlowMode.shadow.rawValue
            return
        }
        savingContextFlow = true
        defer { savingContextFlow = false }
        let status = await NativeContextFlowRuntime.shared.setMode(requested)
        contextFlowStatus = status
        errorMessage = nil
        appModel.statusText = status.effectiveMode == requested
            ? "Fluid Context set to \(contextFlowModeLabel(status.effectiveMode))"
            : "Fluid Context is effectively \(contextFlowModeLabel(status.effectiveMode))"
    }

    private var contextFlowStatusText: String? {
        guard let status = contextFlowStatus else { return nil }
        if status.setupForcedOff {
            return "Effective: Off until setup is complete."
        }
        if status.environmentManaged {
            return "Effective: \(contextFlowModeLabel(status.effectiveMode)) · managed by the launch environment."
        }
        if status.effectiveMode.rawValue != contextFlowMode {
            return "Effective: \(contextFlowModeLabel(status.effectiveMode))."
        }
        return status.effectiveMode == .shadow
            ? "Observe Only measures selection without supplying it to replies."
            : nil
    }

    private func applySubconsciousRuntimeState(_ state: NativeSubconsciousRuntimeState) {
        subconsciousRuntimeState = state
        subconsciousEnabled = state.enabled
        capsuleEnabled = state.capsuleEnabled
        backgroundEnabled = state.backgroundEnabled
        reflectionEnabled = state.reflectionEnabled
        reflectionBudget = state.reflectionBudget
        organismEnabled = state.organismEnabled
    }

    private func contextFlowModeLabel(_ mode: ContextFlowMode) -> String {
        OperationalSettingsControlPresentation.fluidContextLabel(mode)
    }

    @MainActor
    @discardableResult
    private func saveSubconsciousSelection(
        _ choice: ReflectionModelChoice,
        updateStatus: Bool = true
    ) async -> Bool {
        savingModel = true
        defer { savingModel = false }
        do {
            try await NativeCognitionRuntime.shared.setReflectionSelection(
                model: choice.modelID,
                provider: choice.providerID
            )
            subconsciousModel = choice.modelID
            subconsciousProvider = choice.providerID
            pendingReflectionChoiceID = nil
            await refreshReflectionRouteStatus()
            errorMessage = nil
            if updateStatus {
                appModel.statusText = reflectionRouteStatus?.isReady == true
                    ? "Subconscious LLM saved: \(choice.modelID)"
                    : "Subconscious LLM saved, but its provider is not ready"
            }
            return true
        } catch {
            pendingReflectionChoiceID = nil
            errorMessage = "Subconscious LLM save failed: \(error.localizedDescription)"
            appModel.statusText = errorMessage ?? appModel.statusText
            return false
        }
    }

    @MainActor
    private func refreshReflectionRouteStatus() async {
        reflectionRouteStatus = await NativeCognitionRuntime.shared.reflectionRouteStatus()
    }

    @MainActor
    private func refreshSubconsciousRuntimeState() async {
        subconsciousRuntimeState = await NativeCognitionRuntime.shared.subconsciousRuntimeState()
    }

    @MainActor
    private func ensureReflectionRouteForEnable() async -> Bool {
        _ = await appModel.loadProvidersForChat()
        let defaults = UserDefaults.standard
        let hasExplicitSelection = defaults.object(
            forKey: NativeCognitionRuntime.reflectionModelKey
        ) != nil || defaults.object(
            forKey: NativeCognitionRuntime.reflectionProviderKey
        ) != nil

        if hasExplicitSelection {
            await refreshReflectionRouteStatus()
            return reflectionRouteStatus?.isReady == true
        }

        let readyProviders = appModel.providersList.filter { $0.auth_status.state == "ready" }
        let chatProvider = readyProviders.first { $0.provider_id == appModel.chatProvider }
        let preferred: ReflectionModelChoice? = {
            if let chatProvider {
                let model = chatProvider.models.first { $0.id == appModel.chatModel }
                    ?? chatProvider.models.first
                if let model {
                    return ReflectionModelChoice(
                        id: reflectionChoiceID(providerID: chatProvider.provider_id, modelID: model.id),
                        providerID: chatProvider.provider_id,
                        modelID: model.id,
                        label: "\(model.name) · \(chatProvider.display_name)",
                        providerReady: true
                    )
                }
            }
            guard let provider = readyProviders.first,
                  let model = provider.models.first else { return nil }
            return ReflectionModelChoice(
                id: reflectionChoiceID(providerID: provider.provider_id, modelID: model.id),
                providerID: provider.provider_id,
                modelID: model.id,
                label: "\(model.name) · \(provider.display_name)",
                providerReady: true
            )
        }()
        guard let preferred else {
            await refreshReflectionRouteStatus()
            return false
        }
        return await saveSubconsciousSelection(preferred, updateStatus: false)
            && reflectionRouteStatus?.isReady == true
    }
}

// MARK: - Embeddings backend section
// Swift-native CoreML status for semantic memory retrieval. The Python
// sentence-transformers installer path is retired; this view reports whether
// the bundled CoreML MiniLM model is active, the user explicitly disabled
// embeddings (mock), the developer-test env var is opted in (mock), or the
// runtime is fail-closed because the MiniLM bundle is missing / failed to
// load.

/// Shared state/action mapping for the embeddings controls. The SwiftUI view
/// owns task lifetime, while this value owner keeps retry/release eligibility
/// and the post-action truth in one place.
struct EmbeddingsSettingsActionPresentation {
    struct Controls: Equatable {
        let showsRetryMemoryStatus: Bool
        let showsRetryStatus: Bool
        let showsReleaseNow: Bool
    }

    struct Update {
        let status: EmbeddingsStatus?
        let errorMessage: String?
    }

    static func controls(status: EmbeddingsStatus?, errorMessage: String?) -> Controls {
        Controls(
            showsRetryMemoryStatus: errorMessage != nil,
            showsRetryStatus: status?.installState?.state == "failed",
            showsReleaseNow: status?.modelState?.loaded == true
        )
    }

    static func refreshed(_ status: EmbeddingsStatus) -> Update {
        Update(status: status, errorMessage: nil)
    }

    static func refreshFailed(_ error: any Error, preserving status: EmbeddingsStatus?) -> Update {
        Update(
            status: status,
            errorMessage: "Status check failed: \(error.localizedDescription)"
        )
    }

    static func released(_ result: EmbeddingsToggleResult) -> Update {
        Update(
            status: result.status,
            errorMessage: result.ok == false
                ? (result.error ?? "Embedding memory release could not be confirmed.")
                : result.error
        )
    }

    static func releaseFailed(_ error: any Error, preserving status: EmbeddingsStatus?) -> Update {
        Update(
            status: status,
            errorMessage: "Release failed: \(error.localizedDescription)"
        )
    }
}

/// Shared read-only mapping for the embeddings status panel. It receives the
/// root-scoped runtime status and gives the view its selected mode and the
/// human-facing explanation without reconstructing either from defaults.
struct EmbeddingsSettingsStatusPresentation: Equatable {
    let memoryMode: String
    let memoryModeLabel: String
    let memoryModeDescription: String

    init(status: EmbeddingsStatus) {
        let mode = Self.normalizedMemoryMode(status.memoryMode)
        self.memoryMode = mode
        switch mode {
        case "performance":
            memoryModeLabel = "Fast"
        case "low_memory":
            memoryModeLabel = "Low"
        default:
            memoryModeLabel = "Balanced"
        }
        if let detail = status.memoryModeDetail?.detail, !detail.isEmpty {
            memoryModeDescription = detail
        } else {
            switch mode {
            case "performance":
                memoryModeDescription = "Keeps the model hot for fastest recall."
            case "low_memory":
                memoryModeDescription = "Allows the model to release sooner when idle."
            default:
                memoryModeDescription = "Balances recall speed and memory use."
            }
        }
    }

    static func normalizedMemoryMode(_ raw: String?) -> String {
        let value = raw ?? "balanced"
        switch value {
        case "performance", "balanced", "low_memory":
            return value
        default:
            return "balanced"
        }
    }
}

struct EmbeddingsSettingsSection: View {
    struct ActionOverrides {
        var fetchStatus: (@MainActor () async throws -> EmbeddingsStatus)?
        var releaseMemory: (@MainActor () async throws -> EmbeddingsToggleResult)?
    }

    @Environment(AppModel.self) private var appModel
    // 2026-07-23 B2.6c: reports fail-closed / failed-install / status-error up
    // to the Advanced disclosure so the error state surfaces a warn badge when
    // this block is collapsed.
    @Binding var attention: Bool
    @State private var status: EmbeddingsStatus?
    @State private var loading = false
    @State private var memoryModeSaving = false
    @State private var releasingMemory = false
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    private let actionOverrides: ActionOverrides

    init(
        attention: Binding<Bool>,
        actionOverrides: ActionOverrides = .init(fetchStatus: nil, releaseMemory: nil)
    ) {
        _attention = attention
        self.actionOverrides = actionOverrides
    }

    var body: some View {
        Section {
            if let s = status {
                rows(for: s)
            } else if loading {
                Text("Checking the memory backend.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                Text("The memory backend did not report a status.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let err = errorMessage, actionControls.showsRetryMemoryStatus {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry memory status") {
                        Task { await refreshStatus() }
                    }
                    .buttonStyle(.naFeel)
                    .font(ShellType.label)
                    .disabled(loading)
                    .accessibilityIdentifier("settings.embeddings.retry-memory-status")
                }
            }
        } header: {
            SettingsEyebrow("Memory")
        } footer: {
            SettingsFootnote("Semantic embeddings run inside the app for richer memory retrieval. No Python runtime or external install is required.")
        }
        .task {
            await refreshStatus()
            attention = attentionState
        }
        .onChange(of: attentionState) { _, newValue in
            attention = newValue
        }
        .onDisappear { pollTask?.cancel() }
    }

    // Attention = fail-closed backend, failed install/reindex, or a status
    // fetch error. Surfaced as a badge on the collapsed Advanced disclosure.
    private var attentionState: Bool {
        if errorMessage != nil { return true }
        guard let s = status else { return false }
        if s.effectiveBackend == "unavailable" { return true }
        if s.installState?.state == "failed" { return true }
        if s.reindexState?.state == "failed" { return true }
        return false
    }

    private var actionControls: EmbeddingsSettingsActionPresentation.Controls {
        EmbeddingsSettingsActionPresentation.controls(status: status, errorMessage: errorMessage)
    }

    @ViewBuilder
    private func rows(for s: EmbeddingsStatus) -> some View {
        let installState = s.installState?.state ?? "idle"
        let reindexState = s.reindexState?.state ?? "idle"

        // Row 1 — top-line status.
        HStack(spacing: 8) {
            Text("Advanced semantic embeddings")
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.text)
            Spacer(minLength: 8)
            statusBadge(for: s, installState: installState)
        }

        // Row 2 — model status and memory mode.
        // gpt-5.5 review-4 STILL-NEEDS-FIX: branch on `effectiveBackend` not
        // `libraryAvailable`. When config opts out (mock) but CoreML resources
        // happen to be missing, libraryAvailable == false but effective is
        // "hash" (mock) — the row should show the model/mode row, not the
        // fail-closed unavailable row. NativeClient maps effectiveBackend to:
        //   "local"       → CoreML active
        //   "hash"        → explicit mock (config opt-out OR env opt-in)
        //   "unavailable" → fail-closed (resources missing / load failed)
        switch installState {
        case "installing":
            installProgressView(state: s.installState)
        case "failed":
            failedInstallView(state: s.installState)
        default:
            if s.effectiveBackend == "unavailable" {
                modelUnavailableRow(for: s)
            } else {
                coreMLStatusRow(for: s)
                memoryModeRow(for: s)
            }
        }

        if s.requestedEnabled || reindexState == "running" || reindexState == "failed" {
            reindexStatusView(state: s.reindexState, active: s.effectiveBackend == "local")
        }
    }

    @ViewBuilder
    private func statusBadge(for s: EmbeddingsStatus, installState: String) -> some View {
        let reindexState = s.reindexState?.state ?? "idle"
        switch installState {
        case "installing":
            Text("Preparing…")
                .font(ShellType.captionSemibold)
                .foregroundStyle(NativeAgentShell.secondary)
        case "failed":
            Text("Unavailable")
                .font(ShellType.captionSemibold)
                .foregroundStyle(NativeAgentShell.trouble)
        default:
            // gpt-5.5 review-4 STILL-NEEDS-FIX: badge branches on
            // `effectiveBackend` directly, not on `libraryAvailable`. The four
            // states map cleanly:
            //   "unavailable" → Fail-closed (only when resources missing AND
            //                   not explicitly opted out)
            //   "local"       → Active (CoreML running)
            //   "hash"        → Mock (explicit opt-out via config OR env
            //                   NATIVE_AGENT_EMBEDDING_MOCK opt-in)
            //   otherwise     → Off (catch-all for runtime-not-wired)
            if s.effectiveBackend == "unavailable" {
                // UI-6 (2026-08-01): "Fail-closed" is an internal term for the
                // same thing the install-failure branch above already calls
                // "Unavailable". One word, and it is the plain one.
                Text("Unavailable")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.trouble)
            } else if reindexState == "running" {
                Text("Indexing…")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else if s.effectiveBackend == "local" {
                Text("Active")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.calm)
            } else if s.effectiveBackend == "hash" {
                Text("Test vectors")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            } else {
                Text("Off")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelUnavailableRow(for s: EmbeddingsStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // gpt-5.5 review-2 follow-up: the runtime fails closed when the
            // CoreML resources aren't on disk — embed() throws rather than
            // returning mock vectors. UI string matches that behavior.
            // UI-6 (2026-08-01): the headline says what the user lost; the
            // model identifiers moved down into the secondary line below,
            // which NativeClient fills from EmbeddingPlainCopy.technicalDetail.
            Text(EmbeddingPlainCopy.headline(.modelMissing))
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = s.reindexState?.detail, !detail.isEmpty {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private func installProgressView(state: EmbeddingsInstallState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step = state?.currentStep, !step.isEmpty {
                Text(step)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let detail = state?.detail, !detail.isEmpty {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            let progress = max(0, min(100, state?.progress ?? 0))
            ProgressView(value: Double(progress), total: 100)
            HStack(spacing: 8) {
                Text("\(progress)%")
                Spacer(minLength: 8)
                Text("Safe to keep the app open while the model prepares.")
            }
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)
        }
    }

    @ViewBuilder
    private func failedInstallView(state: EmbeddingsInstallState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = state?.error {
                Text("Install error: \(err)")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = state?.detail, !detail.isEmpty {
                Text(detail)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if actionControls.showsRetryStatus {
                Button("Retry status") {
                    Task { await refreshStatus() }
                }
                .accessibilityIdentifier("settings.embeddings.retry-status")
            }
        }
    }

    @ViewBuilder
    private func coreMLStatusRow(for s: EmbeddingsStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("CoreML embeddings")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                Text(s.modelName)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            // gpt-5.5 review-5 + review-6 STILL-NEEDS-FIX: branches keyed on
            // `effectiveBackend` (the badge layer's source of truth). The
            // final 'local' branch is explicit so an unknown future backend
            // value falls into a safe 'status unknown' string instead of
            // silently asserting "CoreML is running."
            // UI-6 (2026-08-01): plain headline per state. The Core ML /
            // MiniLM / env-var identifiers still ship — one line down, in the
            // technical caption, and in the model name row above.
            if s.effectiveBackend == "unavailable" {
                Text(EmbeddingPlainCopy.headline(.modelFailed))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = EmbeddingPlainCopy.technicalDetail(.modelFailed) {
                    Text(detail)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            } else if s.effectiveBackend == "hash" {
                Text(EmbeddingPlainCopy.headline(.testVectors))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = EmbeddingPlainCopy.technicalDetail(.testVectors) {
                    Text(detail)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            } else if s.effectiveBackend == "local" {
                Text(EmbeddingPlainCopy.headline(.byMeaning))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            } else {
                Text("The embedding backend did not report a status.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
        }
    }

    @ViewBuilder
    private func memoryModeRow(for s: EmbeddingsStatus) -> some View {
        let presentation = EmbeddingsSettingsStatusPresentation(status: s)
        let currentMode = presentation.memoryMode
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Memory mode")
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Spacer(minLength: 8)
                if memoryModeSaving || releasingMemory {
                    ProgressView().controlSize(.small)
                }
            }
            Picker("Memory mode", selection: Binding(
                get: { currentMode },
                set: { mode in Task { await setMemoryMode(mode) } }
            )) {
                Text("Fast").tag("performance")
                Text("Balanced").tag("balanced")
                Text("Low").tag("low_memory")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(memoryModeSaving || releasingMemory)

            HStack(spacing: 8) {
                Text(presentation.memoryModeDescription)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if actionControls.showsReleaseNow {
                    Button("Release now") {
                        Task { await releaseMemoryNow() }
                    }
                    .buttonStyle(.naFeel)
                    .font(ShellType.label)
                    .disabled(releasingMemory)
                    .accessibilityIdentifier("settings.embeddings.release-now")
                }
            }
        }
    }

    @ViewBuilder
    private func reindexStatusView(state: EmbeddingsInstallState?, active: Bool) -> some View {
        let phase = state?.state ?? "idle"
        switch phase {
        case "running":
            VStack(alignment: .leading, spacing: 8) {
                Text(state?.currentStep ?? "Indexing existing memories")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                ProgressView(value: Double(max(0, min(100, state?.progress ?? 0))), total: 100)
                HStack(spacing: 8) {
                    Text("\(max(0, min(100, state?.progress ?? 0)))%")
                    if let embedded = state?.embedded, let candidates = state?.candidates {
                        Text("Updated \(embedded)/\(candidates)")
                    }
                    Spacer(minLength: 8)
                }
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
            }
        case "failed":
            VStack(alignment: .leading, spacing: 4) {
                Text("The memory index update failed.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
                if let detail = state?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        case "complete":
            if active {
                Group {
                    if let embedded = state?.embedded, let skipped = state?.skipped {
                        Text("Existing memory index ready. Updated \(embedded), skipped \(skipped).")
                    } else {
                        Text("Existing memory index ready.")
                    }
                }
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    @MainActor
    private func refreshStatus() async {
        loading = (status == nil)
        defer { loading = false }
        do {
            let update = EmbeddingsSettingsActionPresentation.refreshed(try await fetchStatus())
            status = update.status
            errorMessage = update.errorMessage
            guard let fresh = update.status else { return }
            // If model prep or indexing is running, keep polling for progress.
            if fresh.installState?.state == "installing" || fresh.reindexState?.state == "running" {
                startPollingIfNeeded()
            }
        } catch {
            let update = EmbeddingsSettingsActionPresentation.refreshFailed(error, preserving: status)
            status = update.status
            errorMessage = update.errorMessage
            if status == nil {
                startPollingIfNeeded(recoveringStatusError: update.errorMessage)
            }
        }
    }

    private func startPollingIfNeeded(recoveringStatusError: String? = nil) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Poll every 2s for up to 10 minutes.
            for _ in 0..<300 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                do {
                    let fresh = try await fetchStatus()
                    guard !Task.isCancelled else { return }
                    let update = EmbeddingsSettingsActionPresentation.refreshed(fresh)
                    status = update.status
                    // 2026-09-06: retire only the recovered read error, preserving newer action failures.
                    if let recoveringStatusError, errorMessage == recoveringStatusError {
                        errorMessage = update.errorMessage
                    }
                    let installState = fresh.installState?.state ?? "idle"
                    let reindexState = fresh.reindexState?.state ?? "idle"
                    if installState != "installing" && reindexState != "running" {
                        return
                    }
                } catch {
                    // Network blip — keep polling unless cancelled.
                    continue
                }
            }
            // Codex review caught: polling timeout would silently exit
            // with the UI stuck on the installing state. Surface what
            // happened so the user knows and can choose to refresh.
            errorMessage = "Memory status is taking longer than expected. Refresh the status and check app logs if it persists."
            await refreshStatus()
        }
    }

    @MainActor
    private func setMemoryMode(_ mode: String) async {
        memoryModeSaving = true
        defer { memoryModeSaving = false }
        do {
            let result = try await appModel.setEmbeddingsMemoryMode(mode: mode)
            status = result.status
            if let err = result.error {
                errorMessage = result.detail.map { "\(err): \($0)" } ?? err
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = "Memory mode update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func releaseMemoryNow() async {
        releasingMemory = true
        defer { releasingMemory = false }
        do {
            let update = EmbeddingsSettingsActionPresentation.released(
                try await releaseEmbeddingsMemory()
            )
            status = update.status
            errorMessage = update.errorMessage
        } catch {
            let update = EmbeddingsSettingsActionPresentation.releaseFailed(error, preserving: status)
            status = update.status
            errorMessage = update.errorMessage
        }
    }

    @MainActor
    private func fetchStatus() async throws -> EmbeddingsStatus {
        if let fetchStatus = actionOverrides.fetchStatus {
            return try await fetchStatus()
        }
        return try await appModel.fetchEmbeddingsStatus()
    }

    @MainActor
    private func releaseEmbeddingsMemory() async throws -> EmbeddingsToggleResult {
        if let releaseMemory = actionOverrides.releaseMemory {
            return try await releaseMemory()
        }
        return try await appModel.releaseEmbeddingsMemory()
    }
}

// MARK: - The kit
//
// Advanced page kit, 2026-09-03. This page is also the macOS Settings window
// (Command-comma), so it keeps its Form — the shell frame hides the Form's
// slab (`ShellPageFrame`, SetupView.swift). Everything ON it is the kit:
// eyebrow section heads, `ShellType` throughout, colour from
// `NativeAgentShell`, no glyph doing a word's job.

/// A section head: 13 semibold, uppercase, tracked, secondary — the same one
/// the Advanced list wears.
private struct SettingsEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.labelSemibold)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.secondary)
    }
}

/// The quiet line under a section: 11, tertiary, wraps rather than truncates.
private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(ShellType.caption)
            .foregroundStyle(NativeAgentShell.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One switch row, said the way Setup says it: a 13 semibold title and the
/// house switch, teal on-track and all (`SetupSwitchCard`, SetupView.swift).
/// The body is the Toggle itself, so a caller's accessibility identifier and
/// hint still land on the control.
private struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(ShellType.labelSemibold)
                .foregroundStyle(NativeAgentShell.text)
        }
        .toggleStyle(.switch)
        .tint(NativeAgentBrand.accent)
    }
}
