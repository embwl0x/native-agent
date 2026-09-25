// Lane B (2026-09-02, ui-simplify): THE SETUP PAGE.
//
// "Four things make up <name>. The rest is below."
//
// This page owns no settings of its own. Every switch here writes exactly the
// same storage the old Settings controls wrote — the Subconscious master and
// Fluid Context (SlimSettingsView ▸ Advanced ▸ Subconscious), the moments lane
// switch (MomentsLaneSetting), the agent's hour (StudioWanderLane.enabledDefaultsKey),
// the Mac Integration permission store, and the Trust presets. Nothing on the
// top half of this page names an internal: no "Subconscious", no "Fluid
// Context", no "organism", no "YOLO". User, 2026-09-04: the features those
// words stood for are cards further down this page now, said in plain words.

import SwiftUI
import Context
import MacIntegration
import NativeAgentCore
import ProviderRouting
// The hour's switch key lives with the lane law so the two can never disagree
// about its spelling.
import BackgroundLoops

// MARK: - Routes

/// Everything Setup can push. Typed so a row cannot keep a valid-looking
/// destination while the view it opens drifts elsewhere.
enum SetupRoute: Hashable, Sendable {
    /// Where the reflection mind and the hour's mind went when Setup was cut
    /// down to one. Nothing was deleted: both pickers live here now.
    case minds
    case providers
    case telegram
    case pairDevice
    case macIntegration
    case trust
    case personality
    case connectors
    case capabilities
    case knowledgeGraph
    case dreams
    case diagnostics
    case inboxPolicy
    case mcp
    case skillsAndTools
    /// The remaining existing settings sections — devices, embeddings/memory
    /// mode, chat compaction, global shortcut, updates, help, about — reused
    /// exactly as they are rather than rewritten.
}

extension SetupRoute {
    /// What the page is called when you are standing on it. One spelling for
    /// the row that opens it and the title at the top of it.
    var displayName: String {
        switch self {
        case .minds: "\(AgentVoice.live.possessive) minds"
        case .providers: "Providers"
        case .telegram: "Telegram"
        case .pairDevice: "iPhone"
        case .macIntegration: "Mac integration"
        case .trust: "Trust"
        case .personality: "Personality"
        case .connectors: "Connectors"
        case .capabilities: "Capabilities"
        case .knowledgeGraph: "Knowledge graph"
        case .dreams: "Dreams"
        case .diagnostics: "Diagnostics"
        case .inboxPolicy: "Notifications"
        case .mcp: "MCP"
        case .skillsAndTools: "Skills & tools"
        }
    }

    /// What the page is FOR, in plain words. The Advanced list's second line;
    /// no internals, no jargon.
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
        }
        .padding(.horizontal, 20)
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

struct SetupRouteView: View {
    let route: SetupRoute
    /// What the back row says. The page one step down the stack, so a page
    /// opened from Advanced says "Advanced" and one opened from Setup says
    /// "Settings" — the word always names where back actually lands.
    var backLabel: String = "Settings"
    @State private var skillsSection: SkillsToolsSection = .skills

    var body: some View {
        ShellPageFrame(title: route.displayName, backLabel: backLabel, alive: route == .inboxPolicy || Self.aliveRoutes.contains(route)) {
            page
        }
    }

    /// The settings-type pages rebuilt in the Alive style (2026-09-23).
    private static let aliveRoutes: Set<SetupRoute> = [
        .providers, .trust, .personality, .connectors, .capabilities, .diagnostics, .minds,
    ]

    @ViewBuilder
    private var page: some View {
        switch route {
        case .minds: SetupMindsView()
        case .providers: ProviderSettingsView()
        case .telegram: TelegramView()
        case .pairDevice: MacPairingView()
        case .macIntegration: MacIntegrationView()
        case .trust: TrustCenterView()
        case .personality: PersonalityView()
        case .connectors: ConnectorsView()
        case .capabilities: CapabilitiesView()
        case .knowledgeGraph: KnowledgeGraphView()
        case .dreams: DreamsView()
        case .diagnostics: DiagnosticsView()
        case .inboxPolicy: InboxSettingsView()
        case .mcp: MCPHubView()
        case .skillsAndTools: SkillsToolsView(selection: $skillsSection)
        }
    }
}

// MARK: - Setup

struct SetupView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.colorScheme) private var colorScheme

    // AN INNER LIFE — the Subconscious master plus the lanes it owns. Same
    // keys SlimSettingsView's Subconscious section binds, so the two surfaces
    // can never show different truth.
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = false
    @AppStorage("cognitiveSubstrateCapsuleEnabled") private var capsuleEnabled = true
    @AppStorage("cognitiveSubstrateBackgroundEnabled") private var backgroundEnabled = true
    @AppStorage("cognitiveSubstrateReflectionEnabled") private var reflectionEnabled = false
    @AppStorage("cognitiveSubstrateDailyReflectionBudget") private var reflectionBudget = 2
    @AppStorage("organismKernelEnabled") private var organismEnabled = false
    @AppStorage("contextFlowMode") private var contextFlowMode = ContextFlowMode.shadow.rawValue

    // MOMENTS THE AGENT KEEPS
    @AppStorage(MomentsLaneSetting.defaultsKey) private var momentsEnabled = true

    // THE AGENT'S HOUR
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false

    @AppStorage("nativeagent.darkMode") private var preferDark = true

    @State private var savingInnerLife = false
    @State private var innerLifeError: String?
    @State private var macPermissions: [String: MacIntegrationPermission] = [:]
    @State private var macPermissionsLoaded = false
    @State private var macPermissionsUnavailable = false
    @State private var peerPaired = false
    @State private var applyingPosture = false
    @State private var confirmEverything = false
    /// Every sentence on this page is built out of this: the agent's name,
    /// never a gender.
    private var voice: AgentVoice {
        AgentVoice(name: appModel.agentDisplayName)
    }

    // THE STACK OWNS ITS PATH. Do not bind one here.
    //
    // Crash 2026-09-03, four EXC_BREAKPOINTs on the same page (last:
    // NativeAgentApp-2026-09-03-191023.ips). Every report is the same stack:
    // `NavigationColumnState.boundPathChange(to:environment:)` →
    // `swift_unexpectedError`, under `NavigationAuthority.flushRequestQueue`.
    // `boundPathChange` only exists when the path is BOUND. With a binding,
    // SwiftUI flushes a queued request (every `NavigationLink(value:)`, every
    // `dismiss()`) against whatever the path holds NOW, and when the program
    // has written that path in the same cycle the write-back throws inside
    // SwiftUI's own `try!` — nothing in app code can catch it. Guarding the
    // writes (47b4efba) narrowed the window; it did not close it.
    //
    // Unbound, that code path does not run at all. The price is that no one
    // can write the path, so every push on this page is a NavigationLink
    // back is `dismiss()`, and reset-to-root is a remount — ContentView
    // hangs `.id(settingsRootRouteVersion)` on this view.
    var body: some View {
        NavigationStack {
            ScrollView {
                // Alive glass (2026-09-23): the page's sections, each ONE
                // group card of rows under an eyebrow, where every setting
                // used to be its own card.
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    AlivePageHeader(
                        title: appModel.agentDisplayName,
                        line: "Four things make up who I am. Everything else I carry is below."
                    )
                    .accessibilityElement(children: .combine)
                    section("Four things") { fourThings }
                    // User, 2026-09-05: the everyday controls come first; the
                    // fourteen feature switches sit below them.
                    section("And the rest") {
                        postureRow
                        mindRow
                        // User's call, 2026-09-02: the switch a person flips
                        // most sits above the connection rows.
                        appearanceRow
                        // User, 2026-09-04: no All settings door. What lived
                        // there is here, as rows (SetupRestRows).
                        SetupRestRows(part: .everyday)
                    }
                    section("Connections") { connectionRows }
                    SetupRestRows(part: .app)
                    // User, 2026-09-04: "a switch for each of her features,
                    // all here, simple." One row per feature, wired to the
                    // key the feature actually reads (SetupFeatureRows).
                    SetupFeatureRows()
                }
                .padding(.horizontal, 20)
                .padding(.top, TodayMetrics.topPadding)
                .padding(.bottom, 32)
                .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Settings")
            // The registration sits at the root and is unconditional, so a
            // link anywhere in the stack always finds its destination.
            .navigationDestination(for: SetupRoute.self) { route in
                SetupRouteView(route: route)
            }
        }
        .liveTask {
            await refreshMacPermissions()
            peerPaired = SignedPeerEvidenceStore.load(dataRoot: NativeAgentPaths.dataRoot) != nil
            // LIVE STATE, NOT DEFAULTS. Nothing on this page was pulling
            // Telegram's status, so the tile rendered the `false` default while
            // the bot was up. `.settings` is the sidebar item whose refresh
            // fetches `getTelegramStatus()` (AppModel+ChatSessions), and the
            // trust policy is fetched here too — without it `liveAccessMode`
            // falls back to the `chatFileAccess` default and the posture
            // control shows a grant the policy may not actually hold.
            await appModel.refreshForSidebarItem(.settings)
            // A swallowed failure here left the PREVIOUS policy on screen — the
            // posture control would show a grant the policy may not hold, and
            // nothing said so. Say so.
            do {
                appModel.trustPolicy = try await appModel.getTrustPolicy()
            } catch {
                innerLifeError = "I couldn't read the trust policy just now, so what this page shows may be out of date."
            }
            // Ungated: the providers list may be populated but `chatProvider`
            // stale, and this is the call that re-reads providers/active.json.
            await appModel.loadProvidersForChat()
        }
    }

    // MARK: Header

    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        SetupSection(title: title, rows: rows)
    }

    // MARK: The four things

    @ViewBuilder
    private var fourThings: some View {
        SetupSwitchCard(
            title: "An inner life",
            sentence: "I feel, remember what happened, and carry it between conversations. On, this also turns on reflection, moods, and memory in every reply below.",
            isOn: Binding(
                get: { subconsciousEnabled },
                set: { enabled in Task { await setInnerLife(enabled) } }
            ),
            disabled: savingInnerLife
        ) {
            // ONE MIND ON THIS PAGE. The reflection-mind picker moved to
            // Advanced ▸ minds (SetupMindsView); this card is a switch.
            if let innerLifeError {
                Text(innerLifeError)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }

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
        // says what is granted and opens the page where the grants are.
        SetupInfoCard(
            title: "Use my Mac",
            detail: macPermissionsUnavailable
                ? "Can't read this right now. Open Mac settings for details."
                : macPermissionsLoaded
                    ? (anyMacCapabilityEnabled
                        ? "On — macOS still asks for each app."
                        : "Off. Choose what I may reach.")
                    : "Checking…",
            route: .macIntegration
        )
    }

    private var anyMacCapabilityEnabled: Bool {
        macPermissions.values.contains { $0.read || $0.write }
    }

    // MARK: Posture

    private var postureRow: some View {
        let live = SetupPosture.resolve(
            accessMode: liveAccessMode,
            outsideWorkspaceDefault: appModel.trustPolicy?.filePolicy?.outsideWorkspaceDefault
        )
        // The control is always on the page. Full Mac is not one of these three
        // words, so it selects the nearest (Trusted) and says underneath what is
        // actually granted rather than hiding the control behind a link.
        return VStack(alignment: .leading, spacing: 6) {
            SetupRow(
                title: "What I do without asking",
                detail: live?.sentence(voice)
                    ?? "More than any of these: I have full run of this Mac right now."
            ) {
                Picker("What I do without asking", selection: Binding(
                    get: { live ?? .trusted },
                    set: { posture in
                        // `live` is optional, so at Full Mac every segment —
                        // Trusted included — differs from it and applies.
                        guard posture != live else { return }
                        // The one segment that is one click from full run
                        // of the Mac asks first.
                        if posture == .everything {
                            confirmEverything = true
                        } else {
                            Task { await applyPosture(posture) }
                        }
                    }
                )) {
                    ForEach(SetupPosture.allCases) { posture in
                        Text(posture.title).tag(posture)
                    }
                }
                .pickerStyle(.segmented)
                // The selected segment wears the haze, like the switches
                // above (User, 2026-09-23: system blue clashed with it).
                .hazeTinted(.segments)
                .labelsHidden()
                .fixedSize()
                .confirmationDialog(
                    "Turn on Full Mac?",
                    isPresented: $confirmEverything,
                    titleVisibility: .visible
                ) {
                    Button("Turn on Full Mac", role: .destructive) {
                        // The dialog IS the confirmation; without the flag
                        // the apply asked for it again and did nothing.
                        Task { await applyPosture(.everything, confirmed: true) }
                    }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("I will be able to change anything on this Mac without asking. You can pick another level any time.")
                }
                .disabled(applyingPosture)
            }
            if live == nil {
                Text("Choosing a level replaces the current permissions. Review the details on the Trust page.")
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveAccessMode: String {
        if let policy = appModel.trustPolicy {
            return AppModel.agentAccessMode(from: policy, fallback: appModel.chatFileAccess)
        }
        return AppModel.normalizedAgentAccessMode(appModel.chatFileAccess)
    }

    @MainActor
    private func applyPosture(_ posture: SetupPosture, confirmed: Bool = false) async {
        applyingPosture = true
        defer { applyingPosture = false }
        let outcome = await TrustPolicyPresetAction.apply(
            posture.preset, appModel: appModel, fullMacConfirmed: confirmed
        )
        appModel.statusText = TrustPolicyPresetActionPresentation.statusText(for: outcome)
    }

    // MARK: The one mind

    /// ONE MIND, ONE ROW. This replaces the old Provider tile (whose summary
    /// string was the thing truncating mid-word) and is the only model choice
    /// on this page. It drives the primary chat provider — the same
    /// `setChatProvider` + `saveChatBrainDefaults` pair the chat brain bar uses.
    private var mindRow: some View {
        SetupRow(
            title: "I think with",
            detail: "The mind behind every reply in Chat."
        ) {
            SetupChatMindPicker()
        }
    }

    // MARK: Telegram / iPhone

    @ViewBuilder
    private var connectionRows: some View {
        SetupInfoCard(
            title: "Telegram",
            // The live status, not the launch-time default: `telegramStatus`
            // is what the Settings refresh actually fetches.
            detail: telegramConnected ? "Connected" : "Not set up",
            route: .telegram
        )
        SetupInfoCard(
            title: "iPhone",
            detail: peerPaired ? "Paired" : "Not paired",
            route: .pairDevice
        )
    }

    private var telegramConnected: Bool {
        appModel.telegramStatus?.tokenConfigured ?? appModel.telegramTokenConfigured
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

        let state = await NativeCognitionRuntime.shared.setSubconsciousMasterEnabled(
            enabled,
            reflectionBudget: enabled ? max(1, reflectionBudget) : 0
        )
        subconsciousEnabled = state.enabled
        capsuleEnabled = state.capsuleEnabled
        backgroundEnabled = state.backgroundEnabled
        reflectionEnabled = state.reflectionEnabled
        reflectionBudget = state.reflectionBudget
        organismEnabled = state.organismEnabled

        // The hour cannot outlive the master, and installation is cached —
        // the master moving in either direction has to drop that cache.
        await NativeCognitionRuntime.reloadStudioWanderInstallation()

        if enabled {
            // User, 2026-09-06: this used to force Fluid Context to Active on
            // every enable, silently undoing an Observe Only / Off the user had
            // chosen. The identical switch in Slim Settings leaves the mode
            // alone, so the two disagreed. Only an UNSET preference gets the
            // Active default; an existing choice stands, and the warning below
            // now compares against what was actually asked for.
            let stored = UserDefaults.standard.string(
                forKey: NativeContextFlowConfiguration.modeDefaultsKey
            ).flatMap(ContextFlowMode.init(rawValue:))
            let preferred = stored ?? .active
            let status: NativeContextFlowModeStatus
            if stored == nil {
                status = await NativeContextFlowRuntime.shared.setMode(.active)
                contextFlowMode = ContextFlowMode.active.rawValue
            } else {
                status = await NativeContextFlowRuntime.shared.modeStatus()
            }
            if status.effectiveMode != preferred {
                innerLifeError = "Some of my inner life is held off by setup, safety, or provider health."
            }
        }

        if enabled && !state.enabled {
            innerLifeError = "Connect a provider, or choose my reflection mind under Personality ▸ \(voice.possessive) minds, before turning this on."
        }
        appModel.statusText = state.enabled
            ? "I have an inner life again"
            : "My inner life is off"
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

/// An eyebrow and ONE group card holding the section's rows, hairlines
/// between them (Alive glass, 2026-09-23). Rows carry no chrome of their own.
struct SetupSection<Rows: View>: View {
    let title: String
    let rows: Rows

    init(title: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            AliveGroupCard { rows }
        }
    }
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(NativeAgentShell.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
        .frame(height: SetupMetrics.rowContentHeight, alignment: .leading)
    }
}

/// One of the four, as a row: a title, one plain sentence, a switch on the
/// right, and whatever the switch reveals underneath it.
struct SetupSwitchCard<Detail: View>: View {
    let title: String
    let sentence: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    /// Where the card LEADS, if it leads anywhere. A card with a route has no
    /// setting of its own: its switch is a NavigationLink to this page, which is how a card can navigate on a stack that owns its
    /// own path (see `SetupView.body`).
    var route: SetupRoute? = nil
    @ViewBuilder var detail: Detail

    init(
        title: String,
        sentence: String,
        isOn: Binding<Bool>,
        disabled: Bool = false,
        route: SetupRoute? = nil,
        @ViewBuilder detail: () -> Detail = { EmptyView() }
    ) {
        self.title = title
        self.sentence = sentence
        self._isOn = isOn
        self.disabled = disabled
        self.route = route
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // The fixed box every row shares.
                SetupRowText(title: title, detail: sentence)
                Spacer(minLength: 12)
                if let route {
                    // Same switch, same hit target, but it TRAVELS: the
                    // toggle is only the face, the link takes the click.
                    NavigationLink(value: route) {
                        switchFace.allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                } else {
                    switchFace
                }
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
    /// The page the card opens. A value, not a closure: see `SetupView.body`.
    let route: SetupRoute

    var body: some View {
        NavigationLink(value: route) {
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
        var list = providers.filter { $0.ready && !$0.models.isEmpty }
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

// MARK: - The one mind

/// "<name> thinks with" — one picker, one row, plain words. Writes the primary
/// chat provider through `setChatProvider` and the model through
/// `saveChatBrainDefaults`: exactly the pair the chat brain bar uses, so the
/// two surfaces edit one selection.
struct SetupChatMindPicker: View {
    private struct Choice: Identifiable, Equatable {
        let id: String
        let providerID: String
        let modelID: String
        let label: String
        let ready: Bool
        /// Carried so a model change can reconcile effort and Fast the way
        /// the chat brain bar does; nil means "unknown, keep what is set".
        var supportedEfforts: [String]? = nil
        var supportsFast: Bool? = nil
    }

    @Environment(AppModel.self) private var appModel
    @State private var saving = false
    @State private var pendingProviderID: String?
    @State private var pendingModelID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if providers.isEmpty {
                Text("Connect a provider first.")
                    .font(ShellType.labelMedium)
                    .foregroundStyle(.orange)
            } else {
                ProviderThenModelPicker(
                    providers: providers,
                    currentProviderID: pendingProviderID ?? appModel.chatProvider,
                    currentModelID: pendingModelID ?? appModel.chatModel,
                    disabled: saving
                ) { provider, model in
                    pendingProviderID = provider.id
                    pendingModelID = model.id
                    Task {
                        await save(Choice(
                            id: choiceID(provider.id, model.id),
                            providerID: provider.id,
                            modelID: model.id,
                            label: "\(provider.name) · \(model.name)",
                            ready: provider.ready,
                            supportedEfforts: model.supportedEfforts,
                            supportsFast: model.supportsFast
                        ))
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var providers: [ProviderThenModelPicker.Provider] {
        appModel.providersList.map { provider in
            ProviderThenModelPicker.Provider(
                id: provider.provider_id,
                name: Self.plainProviderName(provider.display_name),
                ready: provider.auth_status.state == "ready",
                models: provider.models.map {
                    ProviderThenModelPicker.Model(
                        id: $0.id,
                        name: $0.name,
                        supportedEfforts: $0.supported_reasoning_efforts,
                        supportsFast: $0.supports_fast
                    )
                }
            )
        }
    }

    /// "Anthropic (OAuth / Setup-Token)" is a wiring detail, not a name. The
    /// parenthetical is dropped so the row reads "Anthropic · Opus 5".
    static func plainProviderName(_ displayName: String) -> String {
        guard let open = displayName.range(of: " (") else { return displayName }
        return String(displayName[..<open.lowerBound])
    }

    private var currentChoiceID: String {
        choiceID(appModel.chatProvider, appModel.chatModel)
    }

    private func choiceID(_ providerID: String, _ modelID: String) -> String {
        providerID + "\u{1f}" + modelID
    }

    @MainActor
    private func save(_ choice: Choice) async {
        saving = true
        defer { saving = false }
        let previous = appModel.chatProvider
        if choice.providerID != previous {
            guard await appModel.setChatProvider(choice.providerID, previous: previous) else {
                errorMessage = "That mind could not be saved."
                pendingProviderID = nil
                pendingModelID = nil
                return
            }
        }
        appModel.chatModel = choice.modelID
        // Same reconcile as ChatBrainControlBar: an effort the new model does
        // not support falls back, and Fast is cleared where unsupported.
        if let efforts = choice.supportedEfforts, !efforts.isEmpty,
           !efforts.contains(appModel.chatReasoningEffort) {
            appModel.chatReasoningEffort = efforts.contains("high") ? "high" : efforts[0]
        }
        if choice.supportsFast == false { appModel.chatFastMode = false }
        let result = await appModel.saveChatBrainDefaults()
        switch result {
        case .failed:
            errorMessage = result.userMessage
        default:
            errorMessage = nil
        }
        pendingProviderID = nil
        pendingModelID = nil
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
    // Empty: reflection runs on the Memory and mind choice unless a person
    // deliberately pins something here (2026-09-13).
    @AppStorage("cognitiveSubstrateReflectionModel") private var reflectionModel = ""
    @AppStorage("cognitiveSubstrateReflectionProvider") private var reflectionProvider = ""
    @State private var saving = false
    @State private var pendingProviderID: String?
    @State private var pendingModelID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appModel.providersList.isEmpty {
                Text("Connect a provider to choose the mind I reflect with.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ProviderThenModelPicker(
                    providers: appModel.providersList.map { provider in
                        ProviderThenModelPicker.Provider(
                            id: provider.provider_id,
                            name: SetupChatMindPicker.plainProviderName(provider.display_name),
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
            if appModel.providersList.isEmpty {
                _ = await appModel.loadProvidersForChat()
            }
        }
    }

    private var currentProviderID: String {
        let provider = reflectionProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty
            ? NativeCognitionRuntime.inferredReflectionProvider(for: reflectionModel)
            : provider
    }

    private var currentChoiceID: String {
        choiceID(currentProviderID, reflectionModel)
    }

    private func choiceID(_ providerID: String, _ modelID: String) -> String {
        providerID + "\u{1f}" + modelID
    }

    @MainActor
    private func save(_ choice: Choice) async {
        saving = true
        defer { saving = false }
        do {
            try await NativeCognitionRuntime.shared.setReflectionSelection(
                model: choice.modelID,
                provider: choice.providerID
            )
            reflectionModel = choice.modelID
            reflectionProvider = choice.providerID
            errorMessage = nil
        } catch {
            errorMessage = "That mind could not be saved: \(error.localizedDescription)"
        }
        pendingProviderID = nil
        pendingModelID = nil
    }
}

// MARK: - The hour's provider picker

/// The existing `studio_wander` routing row, rendered where the switch is.
/// Writes through the same `configureSurfaceSelection` seam Providers uses, so
/// the two surfaces edit one row.
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
                        get: {
                            let available = models(for: activeProvider)
                            if available.contains(where: { $0.id == model }) { return model }
                            return available.first?.id ?? model
                        },
                        set: { newValue in
                            model = newValue
                            Task { await save() }
                        }
                    )) {
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
        .task { await load() }
    }

    private func models(for providerID: String) -> [ProviderModelInfo] {
        providers.first { $0.provider_id == providerID }?.models ?? []
    }

    @MainActor
    private func load() async {
        switch await ProviderSettingsRefreshAction.perform(appModel: appModel, refreshCatalog: false) {
        case let .loaded(snapshot):
            providers = snapshot.providers
            activeProvider = snapshot.activeProviders[surface]
                ?? snapshot.providers.first?.provider_id
                ?? ""
            if let preference = snapshot.preferences[surface] {
                model = preference.model
                reasoningEffort = preference.reasoningEffort
                serviceTier = preference.serviceTier
            } else {
                model = models(for: activeProvider).first?.id ?? ""
            }
            errorMessage = nil
        case let .failed(detail):
            errorMessage = detail
        }
        loaded = true
    }

    @MainActor
    private func save() async {
        guard !activeProvider.isEmpty, !model.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await appModel.configureSurfaceSelection(
                surface: surface,
                providerID: activeProvider,
                model: model,
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
            errorMessage = nil
            appModel.statusText = "My hour → \(model) saved"
        } catch {
            errorMessage = "The mind for my hour could not be saved: \(error.localizedDescription)"
        }
    }
}

// MARK: - Minds (Advanced)

/// WHERE THE OTHER TWO MINDS WENT. Setup shows one mind — the chat one. The
/// reflection mind and the hour's mind are still exactly the pickers they were
/// (`SetupReflectionModelPicker`, `SetupStudioWanderPicker`), writing the same
/// storage; they are simply not on the simple page any more.
struct SetupMindsView: View {
    @AppStorage("cognitiveSubstrateEnabled") private var subconsciousEnabled = false
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                SetupKitSection(
                    label: "The mind I reflect with",
                    note: subconsciousEnabled
                        ? "Used by my inner life, between conversations."
                        : "My inner life is off, so nothing reflects with this yet."
                ) {
                    SetupReflectionModelPicker()
                }

                SetupKitSection(
                    label: "\(AgentVoice.live.possessive) hour",
                    note: studioWanderEnabled
                        ? "The provider and model for my daily hour."
                        : "My hour is off, so this selection is not in use yet."
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

/// An eyebrow, one card of controls, and the quiet line under it — the shape
/// every group on an Advanced page takes.
private struct SetupKitSection<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(label)

            AliveGroupCard {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
            }

            if let note {
                Text(note)
                    .font(.system(size: 12))
                    // Secondary, not tertiary: tertiary fails where the haze peaks.
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - Advanced rows
