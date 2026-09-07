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
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

// PATCH-2026-05-06: ui-consolidation — default selection chat, 5 visible + Advanced disclosure sidebar
// PATCH-2026-05-10: startup-tour-gate — tour is manual only; startup must not block chat.
enum SidebarAdvancedDisclosurePresentation {
    static let preferenceKey = "sidebarShowAdvanced"
    static let developerSurfacesPreferenceKey = "showDeveloperSurfaces"

    static func isExpanded(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    static func setExpanded(_ isExpanded: Bool, in defaults: UserDefaults) {
        defaults.set(isExpanded, forKey: preferenceKey)
    }

    @discardableResult
    static func toggle(in defaults: UserDefaults) -> Bool {
        let isExpanded = !isExpanded(in: defaults)
        setExpanded(isExpanded, in: defaults)
        return isExpanded
    }

    static func accessibilityValue(isExpanded: Bool) -> String {
        isExpanded ? "Expanded" : "Collapsed"
    }

    static func visibleRows(
        isExpanded: Bool,
        developerSurfacesEnabled: Bool
    ) -> [SidebarItem] {
        guard isExpanded else { return [] }
        return SidebarItem.visibleAdvancedItems(
            developerSurfacesEnabled: developerSurfacesEnabled
        )
    }
}

struct ContentView: View {
    // Liquid Feel W4: page-switch transition respects Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selection") private var selectionRaw = SidebarItem.chat.rawValue
    @SceneStorage("skillsToolsSection") private var skillsToolsSectionRaw = SkillsToolsSection.skills.rawValue
    // ui-simplify 2026-09-02 (lane C): the classic shell drills into the
    // moment/memory review from ActivityView's own NavigationStack. Behind the
    // rail there is no such stack — Memories is its own place — so the same
    // `.activity(.memoryProposals)` route selects Memories and says which tab.
    @SceneStorage("memoryTab") private var memoryTabRaw = MemoryViewTab.active.rawValue
    @AppStorage(SidebarAdvancedDisclosurePresentation.preferenceKey) private var showAdvanced = false
    // B2.2: developer/internal surfaces (Turn Inspector, MCP, Cognition, …)
    // render only when this UI-visibility preference is on. Fresh installs
    // default OFF so a stranger cannot reach raw internals in one click.
    // Surfaced as one toggle in Settings; NOT coupled to Trust's developerMode.
    @AppStorage(SidebarAdvancedDisclosurePresentation.developerSurfacesPreferenceKey) private var showDeveloperSurfaces = false
    @AppStorage("nativeagent.showTour") private var showTour = false
    // ui-simplify 2026-09-02: the kill switch. ON restores the previous
    // List sidebar + nine primaries, unchanged.
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false
    @State private var tourReplayCoordinator = OnboardingTourReplayCoordinator.shared
    @State private var didCheckFirstRunOnboarding = false
    @State private var showFirstRunOnboarding = false
    // PATCH-2026-06-06: command-palette — Cmd+K modal sheet flag.
    @State private var showCommandPalette = false
    /// A route to Desk must reset its local DeskHub mode even when Desk is
    /// already selected (for example, when the user is viewing Schedule).
    @State private var deskRootRouteVersion = 0
    /// Same for Settings: its NavigationStack keeps its pages across visits
    /// (the detail `.id` is the sidebar item, so re-selecting Settings does not
    /// remount it), which left a visitor standing two pages deep on a fresh
    /// click. Bumped on every route to Settings; it is SetupView's `.id`, so a
    /// bump remounts the stack at its root.
    @State private var settingsRootRouteVersion = 0
    // B2.3 follow-up: Desk's New Task sheet is presented HERE, not in
    // DeskHubView — a sheet attached to NavigationSplitView detail content
    // presents only once per app run on macOS (the bridge never releases the
    // presentation seat after dismiss). ContentView-level sheets re-present
    // reliably (the command palette proves it), so the toolbar button posts
    // .newWorkshopTaskRequest and the sheet lives on this attachment point.
    @State private var showNewWorkshopTask = false
    @State private var navigationMountID: UUID?

    private var selection: Binding<SidebarItem> {
        Binding {
            // Normalize on read AND write: a saved selection or command route
            // naming a retired/alias tab ("Panels", "Self-Improvement") must
            // land on its canonical home — otherwise no sidebar row shows
            // selected and refreshForSidebarItem hits a stale branch
            // (gpt-5.5 review MED, 2026-07-03 dead-weight sweep).
            let item = (SidebarItem(rawValue: selectionRaw) ?? .chat).normalized
            // User, 2026-09-04: a saved selection naming a page that is a tab
            // now (Knowledge graph, MCP, Dreams, Telegram, Mac integration)
            // reads as its rail page, so the rail shows a row and the page
            // has its frame.
            if !classicShell, let home = SidebarItem.shellHome(for: item) { return home.parent }
            return item
        } set: {
            selectSidebarItem($0.normalized)
        }
    }

    private var skillsToolsSection: Binding<SkillsToolsSection> {
        Binding {
            SkillsToolsSection(rawValue: skillsToolsSectionRaw) ?? .skills
        } set: {
            skillsToolsSectionRaw = $0.rawValue
        }
    }

    private var activeContentItem: SidebarItem {
        let selected = selection.wrappedValue.normalized
        if selected == .skills, skillsToolsSection.wrappedValue == .tools {
            return .tools
        }
        return selected
    }

    // PATCH-2026-05-10: sidebar-flatten — pulled directly from SidebarItem
    // so order/membership is defined in one place (Models.swift).
    private var primaryItems: [SidebarItem] { SidebarItem.primaryItems }
    // B2.2: the Advanced disclosure shows consumer-only rows by default and the
    // full set (incl. developer surfaces) once showDeveloperSurfaces is on.
    private var advancedDisclosureBinding: Binding<Bool> {
        Binding(
            get: { showAdvanced },
            set: { isExpanded in
                SidebarAdvancedDisclosurePresentation.setExpanded(isExpanded, in: .standard)
                showAdvanced = isExpanded
            }
        )
    }

    private var advancedItems: [SidebarItem] {
        SidebarAdvancedDisclosurePresentation.visibleRows(
            isExpanded: showAdvanced,
            developerSurfacesEnabled: NativeAgentShellPreference.developerSurfacesShown(showDeveloperSurfaces)
        )
    }

    var body: some View {
        // Render-cost audit: make the root's invalidation rate a NUMBER, not an
        // argument. Gated behind the existing `NATIVE_AGENT_RENDER_AUDIT=1`
        // env check inside `RenderAudit` — when it is off, `bump` reads one
        // already-computed `Bool` and returns, so this costs nothing in a
        // normal run. This is the counter that proves F13 (the sidebar badge
        // scalar) actually cut root re-evaluations.
        RenderAudit.bump("contentview.body")
        return ZStack {
            ShellFrame(classic: classicShell) {
                // ui-simplify 2026-09-02 (Lane A): the rail. Five places with
                // their words under them, at a fixed 84pt. The classic List
                // sidebar is preserved unchanged behind the `uiClassicShell`
                // kill switch.
                Group {
                if !classicShell {
                    // The rail's 84pt comes from its own .frame(width:) —
                    // navigationSplitViewColumnWidth was left behind when the
                    // shell moved out of NavigationSplitView and did nothing
                    // inside an HStack but mislead the next reader.
                    // The rail carries the same queue the classic sidebar
                    // badges from — otherwise a pending approval is invisible
                    // until he happens to open Today. One dot, no number.
                    ShellSidebarRail(
                        selection: selection,
                        needsYou: Set(
                            SidebarItem.shellPrimaryItems
                                // Agent, 2026-09-02: a rail dot is a promise about the
                                // page under it. Today's dot reads what Today's waiting
                                // card reads: pending approvals and memories to review.
                                .filter { item in
                                    item.normalized == .activity
                                        ? (appModel.approvals.contains { $0.status.lowercased() == "pending" }
                                            || appModel.todayWaitingMemories > 0)
                                        : sidebarBadgeCount(for: item) > 0
                                }
                                .map(\.normalized)
                        )
                    )
                } else {
                // S.5: when onboarding overlay is shown, hide the nav content from accessibility
                // (OnboardingTourOverlay already carries .isModal; this prevents VoiceOver reaching behind it)
                // 2026-06-06 sidebar-fix v6: restored to the standard
                // List(selection:)+sidebar pattern that renders correctly.
                // .scrollDisabled broke rendering; manual ScrollView+VStack
                // broke rendering. The executions-click scroll-shift is a
                // known issue tracked separately — at least the sidebar
                // works again. isSelected is still passed for the orange
                // highlight (since List's own selection styling differs).
                List(selection: selection) {
                    Section {
                        ForEach(primaryItems) { item in
                            SidebarItemLabel(
                                item: item,
                                badgeCount: sidebarBadgeCount(for: item),
                                badgeIsStale: item == .activity && appModel.sidebarActivityRefreshStatus?.isStale == true
                            )
                            .tag(item)
                        }
                    }

                    Section {
                        DisclosureGroup(isExpanded: advancedDisclosureBinding) {
                            ForEach(advancedItems) { item in
                                SidebarItemLabel(
                                    item: item,
                                    badgeCount: sidebarBadgeCount(for: item),
                                    badgeIsStale: item == .activity && appModel.sidebarActivityRefreshStatus?.isStale == true
                                )
                                .tag(item)
                            }
                        } label: {
                            Label("Advanced", systemImage: "chevron.right.2")
                                .foregroundStyle(.secondary)
                                .togglesDisclosure(advancedDisclosureBinding)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .naInteractive(radius: NativeAgentRadius.control)
                                .accessibilityIdentifier("sidebar.advanced.disclosure")
                                .accessibilityValue(
                                    SidebarAdvancedDisclosurePresentation.accessibilityValue(
                                        isExpanded: showAdvanced
                                    )
                                )
                        }
                    }
                }
                .listStyle(.sidebar)
                }
                }
                // Both shells share the title and the badge refresh below.
                .navigationTitle("NativeAgent")
                // Keep the Activity badge honest without pulling the full
                // Activity surface while another tab is open. The full
                // ActivityView owns detailed proposal/improvement refreshes.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    let root = PersistenceCore.defaultDataRoot()
                    let memoryDatabase = root
                        .appendingPathComponent("memory", isDirectory: true)
                        .appendingPathComponent("memory.sqlite")
                    await ViewFileRefreshTask.run(paths: [
                        root.appendingPathComponent("workflows/approvals/requests.json"),
                        root.appendingPathComponent("notifications/inbox.jsonl"),
                        memoryDatabase,
                        URL(fileURLWithPath: memoryDatabase.path + "-wal"),
                    ]) {
                        await appModel.refreshSidebarActivityBadge()
                    }
                }
            } detail: {
                VStack(spacing: 0) {
                // M12 (gpt-5.5 review, 2026-07-09): the stale annotation renders
                // for EVERY panel, in one place. `refreshForSidebarItem` records
                // per-endpoint failures for whichever panel it refreshed; a panel
                // whose data is carried over from an earlier refresh says so at
                // the top instead of impersonating live state. Chat renders its
                // own copy inside its layout, so it is skipped here.
                if activeContentItem != .chat,
                   let notice = appModel.panelStaleNotice(for: activeContentItem) {
                    StalePanelNotice(text: notice)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Group {
                    // PATCH-2026-05-19: ui-pull-together — primary sidebar
                    // stays compact. Advanced/routed child surfaces remain
                    // reachable without competing as always-visible tabs.
                    switch selection.wrappedValue.normalized {
                    // ── Primary ───────────────────────────────────────────────
                    case .chat: ChatView()
                    // ui-simplify 2026-09-02: Today and Setup sit behind the
                    // rail's words; the classic shell keeps its old pages.
                    case .activity: if classicShell { ActivityView() } else { TodayView() }
                    // ui-simplify 2026-09-03 (lane M): the new shell's Memories
                    // is one centred column in her voice; the classic shell
                    // keeps the status card and its three tabs untouched.
                    case .memories:
                        if classicShell {
                            MemoryView(initialTab: MemoryViewTab(rawValue: memoryTabRaw) ?? .active)
                                // MemoryView copies initialTab into @State
                                // once; a route arriving while Memories is
                                // already mounted must remount so the Pending
                                // tab actually shows.
                                .id(memoryTabRaw)
                        } else {
                            // Memories and the knowledge graph as tabs; a
                            // moment-review request lands on the Memories tab
                            // (applyActivitySection writes the tab first).
                            MemoriesRailPage()
                        }
                    case .skills: SkillsToolsView(selection: skillsToolsSection)
                    // ui-simplify 2026-09-02 (lane D): the new shell's Desk is
                    // one centred column in her voice; the classic shell keeps
                    // the segmented hub untouched.
                    case .desk:
                        if classicShell {
                            DeskHubView(rootRouteVersion: deskRootRouteVersion)
                        } else {
                            DeskPageView(rootRouteVersion: deskRootRouteVersion)
                        }
                    // User, 2026-09-04: on the rail, with tabs. The classic
                    // shell keeps the bare pages.
                    case .personality: if classicShell { PersonalityView() } else { PersonalityRailPage() }
                    case .connectors: if classicShell { ConnectorsView() } else { ConnectorsRailPage() }
                    case .trust: if classicShell { TrustCenterView() } else { TrustRailPage() }
                    case .providers:
                        if classicShell { ProviderSettingsView() }
                        else { ShellRailPage(title: "Providers", wide: true) { ProviderSettingsView() } }
                    case .macIntegration: MacIntegrationView()
                    case .settings:
                        if classicShell {
                            SlimSettingsView()
                        } else {
                            // A route to Settings is a route to its ROOT, and
                            // the stack inside SetupView owns its own path —
                            // nothing can unwind it from out here. `.id` does
                            // it the only way an unbound stack allows: a fresh
                            // SetupView, standing on Settings.
                            SetupView().id(settingsRootRouteVersion)
                        }
                    // ── Advanced / routed child surfaces ──────────────────────
                    case .capabilities:
                        if classicShell { CapabilitiesView() }
                        else { ShellRailPage(title: "Capabilities") { CapabilitiesView() } }
                    case .knowledge: KnowledgeGraphView()
                    case .dreams: DreamsView()
                    // B2.4/B2.6 (fence-B handoff): the Observatory's surviving
                    // observational core and the Inspector now LIVE as
                    // Diagnostics segments; these routes render the segment
                    // directly so deep links keep landing on the same content.
                    // Reviewer note (accepted): a deep link here shows content
                    // with no sidebar row highlighted — deliberately the SAME
                    // behavior as any developer-gated tab reached by deep link
                    // with the gate off (pinned in b2-A's render states). One
                    // contract for all route-only surfaces.
                    case .cognition: DiagnosticsView(initialMode: .cognition)
                    case .inspector: DiagnosticsView(initialMode: .inspector)
                    case .diagnostics: if classicShell { DiagnosticsView() } else { DiagnosticsRailPage() }
                    case .telegram: TelegramView()
                    case .inboxPolicy:
                        if classicShell { InboxSettingsView() }
                        else { ShellRailPage(title: "Notifications") { InboxSettingsView() } }
                    case .mcp: MCPHubView()
                    // ── Legacy aliases (unreachable post-normalize, kept exhaustive) ───
                    // .autoImprovement → .activity and .panels → .diagnostics
                    // joined this list in the 2026-07-03 dead-weight sweep.
                    // .command/.workshop → .desk keep retired routes and saved state working.
                    case .memory, .settingsHub, .approvals, .workshop, .legacyWorkshop, .work, .skillLifecycle, .tools,
                         .autoImprovement, .panels, .command:
                        EmptyView()  // unreachable: .normalized routes these above
                    }
                }
                // Liquid Feel W4: pages settle in instead of hard-cutting.
                // id() gives each page distinct identity so the transition
                // fires on switch; state within a page is untouched while
                // its selection is stable.
                .id(selection.wrappedValue.normalized)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        )
                )
                .animation(
                    NativeAgentMotion.respecting(NativeAgentMotion.gentle, reduceMotion: reduceMotion),
                    value: selection.wrappedValue.normalized
                )
                .task(id: "\(selectionRaw)|\(skillsToolsSectionRaw)") {
                    let item = activeContentItem
                    if item.normalized == .diagnostics {
                        // Doctor owns its report; Status and Runs share the
                        // DiagnosticsView snapshot owner. Avoid racing a second
                        // navigation-level read against those mounted surfaces.
                        return
                    } else if item.normalized == .activity {
                        // Activity's five queue rows must distinguish an
                        // empty, fully-read set from a failed backing read.
                        // Its complete refresh records that receipt; the
                        // sidebar's smaller file-watch refresh remains the
                        // low-cost owner between Activity visits.
                        await appModel.refreshForSidebarItem(.activity)
                    } else {
                        await appModel.refreshForSidebarItem(item)
                    }
                }
                }
            }
            .toolbar {
                // ui-simplify 2026-09-02: the "N warnings" pill is the first
                // thing a stranger used to read — before they had said hello.
                // It moved to Diagnostics (Settings ▸ Advanced ▸ Diagnostics),
                // where someone is actually looking for it. The chat header's
                // one status dot carries the felt state now. Nothing was
                // deleted; the classic shell still shows it here.
                if classicShell {
                    ToolbarItem(placement: .primaryAction) {
                        HealthPill()
                    }
                }
            }
            // S.5: hide NavigationSplitView from VoiceOver while onboarding overlay is active
            .accessibilityHidden(showTour || showFirstRunOnboarding)

            // PATCH-2026-05-10: startup-tour-gate — only show when explicitly replayed from About.
            if showTour {
                OnboardingTourOverlay(
                    onComplete: {
                        showTour = false
                    },
                    onSelectTab: { item in
                        if item.isAdvanced {
                            showAdvanced = true
                        }
                        selectionRaw = item.rawValue
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            SystemToastBar(center: appModel.systemToasts)
        }
        .animation(
            NativeAgentMotion.respecting(.easeInOut(duration: 0.35), reduceMotion: reduceMotion),
            value: showTour
        )
        .onChange(of: tourReplayCoordinator.requestID) { _, requestID in
            presentTourReplayIfNeeded(requestID: requestID)
        }
        .onAppear {
            presentTourReplayIfNeeded(requestID: tourReplayCoordinator.requestID)
            if selectionRaw == SidebarItem.tools.rawValue {
                skillsToolsSectionRaw = SkillsToolsSection.tools.rawValue
                selectionRaw = SidebarItem.skills.rawValue
            }
            // User, 2026-09-04: a saved selection naming a page that is a tab
            // now opens its rail page ON that tab, the same path a route takes.
            if !classicShell, let saved = SidebarItem(rawValue: selectionRaw),
               let home = SidebarItem.shellHome(for: saved) {
                let tab = (home.parent == .diagnostics && home.tab == "skills"
                    && skillsToolsSectionRaw == SkillsToolsSection.tools.rawValue) ? "tools" : home.tab
                UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(home.parent))
                selectionRaw = home.parent.rawValue
            }
            guard navigationMountID == nil else { return }
            navigationMountID = NativeAgentAppCoordinator.shared.mountMainScene { destination in
                applyNavigationDestination(destination)
            }
        }
        .onDisappear {
            guard let navigationMountID else { return }
            NativeAgentAppCoordinator.shared.unmountMainScene(id: navigationMountID)
            self.navigationMountID = nil
        }
        .task {
            await checkFirstRunOnboardingIfNeeded()
        }
        // All Mac projections of chat sessions share AppModel's one canonical
        // list: Chat, detached-window titles, Status, command search, and the
        // optional project/session lineage page. Keep it current from the
        // canonical index while the app scene is active. This watcher is
        // vnode-driven, burst-coalesced, and performs no idle polling; the
        // lightweight refresh also suppresses equal observed writes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let sessionIndexPath = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("sessions.json")
            await ViewFileRefreshTask.run(
                paths: [sessionIndexPath],
                debounceDelay: .milliseconds(150)
            ) {
                await appModel.refreshChatSessionIndex()
            }
        }
        .sheet(isPresented: $showFirstRunOnboarding) {
            OnboardingWizard {
                showFirstRunOnboarding = false
                Task {
                    await OnboardingWizardCompletionRoute.complete(
                        selectChat: { selectionRaw = SidebarItem.chat.rawValue },
                        refreshChat: { await appModel.refreshForSidebarItem(.chat) },
                        // Fire the first-run welcome right when onboarding finishes
                        // and chat is loaded — ChatView's .task is only a backup.
                        sendGreeting: { await appModel.maybeSendFirstRunGreeting() },
                        record: { appModel.recordOnboardingWizardCompletion($0) }
                    )
                }
            }
            .interactiveDismissDisabled(true)
        }
        // PATCH-2026-06-06: command-palette — Cmd+K modal.
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(isPresented: $showCommandPalette)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
            showCommandPalette = true
        }
        .sheet(isPresented: $showNewWorkshopTask) {
            NewWorkshopTaskSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkshopTaskRequest)) { _ in
            showNewWorkshopTask = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .iCloudInboxDidProcess)) { _ in
            let route = ICloudInboxDidProcessRoute.resolve(selectionRaw: selectionRaw)
            Task {
                _ = await appModel.refreshAfterICloudInboxDidProcess(route: route)
            }
        }
        // Build-in-Chat writes through AppModel first. This receiver owns only
        // routing and the first-session recovery; it never writes a second
        // draft over the one the action already prepared.
        .onReceive(NotificationCenter.default.publisher(for: .skillBuildRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            let starter = (note.object as? String) ?? "Create a skill from this conversation:"
            guard appModel.activeChatSessionId.isEmpty else { return }
            Task {
                await appModel.newChatSession()
                guard !appModel.activeChatSessionId.isEmpty else { return }
                _ = appModel.requestSkillBuild(starter: starter)
            }
        }
        // Inbox "Act" on a chat-shaped item — same shape as skillBuildRequest
        // above: switch to Chat, prefill only when the composer is empty so a
        // half-typed message is never clobbered.
        .onReceive(NotificationCenter.default.publisher(for: .openChatDraftRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            guard let draft = note.object as? String, !draft.isEmpty else { return }
            if appModel.activeChatSessionId.isEmpty { return }
            if appModel.chatDrafts[appModel.activeChatSessionId]?.isEmpty != false {
                appModel.injectChatDraft(draft, sessionId: appModel.activeChatSessionId)
            }
        }
        // L5 G6 — the inversion. Her message is already persisted (the act
        // handler posted it through the proactive-speech seam before posting
        // this). All that's left is to land User in the session and pull the new
        // row in. NOTHING is written to the composer: an empty composer with
        // her message above it is the whole point of the change.
        .onReceive(NotificationCenter.default.publisher(for: .openSpokenChatRequest)) { _ in
            selectionRaw = SidebarItem.chat.rawValue
            let sessionId = appModel.activeChatSessionId
            guard !sessionId.isEmpty else { return }
            Task { await appModel.refreshChatMessagesAfterTurn(sessionId: sessionId) }
        }
    }

    private func presentTourReplayIfNeeded(requestID: Int) {
        guard tourReplayCoordinator.claim(requestID) else { return }
        showFirstRunOnboarding = false
        showTour = true
    }

    @MainActor
    private func checkFirstRunOnboardingIfNeeded() async {
        guard !didCheckFirstRunOnboarding else { return }
        didCheckFirstRunOnboarding = true
        // WAVE 15 (2026-06-01): runtime must be plumbed — /v1/onboarding/start is retired,
        // and startOnboarding() now throws DaemonError.swiftOnlyRoute when the gate sees no runtime.
        // R22: AppModel's canonical `client` already carries the shared runtime.
        // ONBOARDING-2026-05-26: extended retry budget for cold first launch.
        // The previous budget (8 × 500ms = 4s) was below the bundled-Python
        // first-cold-launch daemon ready time (5–10s + indexing), so the
        // wizard never fired on a fresh DMG install — the user landed in the
        // main UI with an uninitialized persona. 60 × 500ms = 30s is enough
        // for first-cold-launch on slower Macs while still timing out fast
        // enough that a stuck daemon doesn't block the UI forever.
        for attempt in 0..<60 {
            if Task.isCancelled { return }
            do {
                let start = try await appModel.startOnboarding()
                // User, 2026-09-06: `profileRepairRequired` also opens the
                // wizard. It arrives WITH `hasExisting` true (the persona docs
                // and sentinel are real), so it has to be checked before the
                // `hasExisting` early return below or the repair lane is
                // unreachable and only Doctor ever names the condition.
                if start.pendingRecovery == true
                    || start.resetRequired == true
                    || start.profileRepairRequired == true {
                    selectionRaw = SidebarItem.chat.rawValue
                    showTour = false
                    showFirstRunOnboarding = true
                    return
                }
                guard !start.hasExisting else { return }
                selectionRaw = SidebarItem.chat.rawValue
                showTour = false
                showFirstRunOnboarding = true
                return
            } catch {
                if attempt == 0 {
                    await appModel.loadHealthCard(includeApprovals: false)
                }
                if attempt == 59 {
                    // A malformed or root-mismatched pending transaction is a
                    // fail-closed onboarding state, not permission to hide the
                    // wizard forever. The wizard exposes the exact error and an
                    // explicit backup-preserving reset; it never auto-deletes.
                    selectionRaw = SidebarItem.chat.rawValue
                    showTour = false
                    showFirstRunOnboarding = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // PATCH-2026-06-06: command-palette — sidebar badge counts for the
    // "needs your eyes" tabs. .activity stays the combined inbox/approvals
    // queue; .executions surfaces currently-running executions. Skills/MCP
    // have no pending count yet, so they return 0.
    private func sidebarBadgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .activity:
            return appModel.pendingActivityCount
        case .desk:
            return 0
        default:
            return 0
        }
    }

    private func applyNavigationDestination(_ destination: NativeAgentNavigationDestination) {
        switch destination {
        case .activity(let section):
            applyActivitySection(section)
        case .skillsTools(let section):
            applySkillsToolsSection(section)
        case .sidebar(.approvals):
            applyActivitySection(.approvals)
        case .sidebar(.autoImprovement):
            applyActivitySection(.selfImprovement)
        case .sidebar(let item):
            if item == .tools {
                applySkillsToolsSection(.tools)
                return
            }
            let target = item.normalized
            if target == .skills {
                applySkillsToolsSection(.skills)
                return
            }
            if target == .activity {
                applyActivityRoot()
                return
            }
            if target.isAdvanced {
                showAdvanced = true
            }
            // A route names the page, not the tab: land on the page's first
            // tab (the multimodal notice must open Trust, not Mac integration).
            if !classicShell, let first = SidebarItem.shellFirstTab(for: target) {
                UserDefaults.standard.set(first, forKey: ShellRailTab.storageKey(target))
            }
            selectSidebarItem(target)
        }
    }

    private func selectSidebarItem(_ target: SidebarItem) {
        // User, 2026-09-04: a former Advanced page that is a tab now opens its
        // rail page on that tab. The tab key is written before the selection
        // so the page mounts already on it.
        if !classicShell, let home = SidebarItem.shellHome(for: target) {
            UserDefaults.standard.set(home.tab, forKey: ShellRailTab.storageKey(home.parent))
            selectionRaw = home.parent.rawValue
            return
        }
        deskRootRouteVersion = DeskRootRoutePresentation.nextRootRouteVersion(
            current: deskRootRouteVersion,
            destination: target)
        if target.normalized == .settings {
            settingsRootRouteVersion &+= 1
        }
        selectionRaw = target.normalized.rawValue
    }

    private func applyActivitySection(_ section: ActivitySection) {
        // Behind the rail, Activity IS Today and it has no NavigationStack to
        // push onto. The memory/moment review lives on the Memories place's
        // Pending tab, so route there instead of stranding the request.
        if !classicShell, section == .memoryProposals {
            appModel.pendingActivitySectionRaw = nil
            memoryTabRaw = MemoryViewTab.pending.rawValue
            // The waiting card is on the Memories tab, not the graph.
            UserDefaults.standard.set("memories", forKey: ShellRailTab.storageKey(.memories))
            selectionRaw = SidebarItem.memories.rawValue
            return
        }
        appModel.pendingActivitySectionRaw = section.rawValue
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(
            name: .openActivitySectionRequest,
            object: section.rawValue
        )
    }

    private func applyActivityRoot() {
        appModel.pendingActivitySectionRaw = nil
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(name: .openActivityRootRequest, object: nil)
    }

    private func applySkillsToolsSection(_ section: SkillsToolsSection) {
        skillsToolsSectionRaw = section.rawValue
        // User, 2026-09-04: Skills and Tools are two tabs of Diagnostics in
        // the new shell.
        if !classicShell {
            UserDefaults.standard.set(
                section == .tools ? "tools" : "skills",
                forKey: ShellRailTab.storageKey(.diagnostics)
            )
            selectionRaw = SidebarItem.diagnostics.rawValue
            return
        }
        selectionRaw = SidebarItem.skills.rawValue
    }
}

private struct SidebarItemLabel: View {
    var item: SidebarItem
    var badgeCount: Int = 0
    var badgeIsStale: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Label(item.displayName, systemImage: item.systemImage)
            Spacer(minLength: 8)
            if badgeCount > 0 {
                Text(badgeIsStale ? "\(badgeCount)?" : "\(badgeCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .help(badgeIsStale ? "Partial or last-known count; one or more Activity sources were unavailable." : "")
            } else if badgeIsStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Activity count is unavailable because the last refresh failed.")
            }
        }
        // Liquid Feel (User 2026-08-17, "the tabs... no love?"): macOS sidebars
        // paint SELECTION natively but never hover — the roll-over feel is
        // ours to add. Rides the label so the native selection tint stays.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .naInteractive(radius: NativeAgentRadius.control)
        .accessibilityIdentifier("sidebar.item.\(item.rawValue)")
    }
}


struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(title)
                    .font(NativeAgentFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 48)
        .padding(NativeAgentSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}


struct ActivityRow: View {
    var event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(NativeAgentFont.section)
                    .lineLimit(1)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(NativeAgentFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(StatusActivityPresentation.timestamp(for: event))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .textSelection(.enabled)
    }

    private var icon: String {
        switch event.kind {
        case "mission": "target"
        case "trust": "lock.shield"
        case "backup": "externaldrive.badge.timemachine"
        case "eval": "checklist"
        case "connector": "point.3.connected.trianglepath.dotted"
        case "chat": "bubble.left.and.bubble.right"
        default: "circle"
        }
    }

    private var color: Color {
        switch event.status {
        case "ok": .green
        case "warn": .orange
        case "fail": .red
        default: .secondary
        }
    }
}

enum NativeScreenCapture {
    enum CaptureError: LocalizedError {
        case permissionRequired
        case noDisplay
        case encodingFailed
        case tooLarge
        // ScreenVision v1 (2026-06-06): preserves the underlying
        // ScreenCaptureKit reason when SwiftNativeScreenVision throws
        // .captureFailed(_). Previously these were collapsed to
        // .encodingFailed, which lost the real cause in the user-facing toast.
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Screen Recording permission is required for NativeAgent. Enable it in System Settings, then restart NativeAgent if macOS asks."
            case .noDisplay:
                return "NativeAgent could not find a display to capture."
            case .encodingFailed:
                return "NativeAgent captured the screen but could not encode it as an image."
            case .tooLarge:
                return "NativeAgent captured the screen, but the image was too large to send."
            case .captureFailed(let reason):
                return "Screen capture failed: \(reason)"
            }
        }
    }

    static let maxCaptureDimension = 1600
    static let maxCaptureBytes = 6 * 1024 * 1024

    static func captureImageBase64() async throws -> (base64: String, mime: String, name: String, byteSize: Int) {
        // v1 vision pipeline (2026-06-06): the capture itself is delegated to
        // the Swift-native ScreenVision module. The size-cap / re-encode path
        // below stays here because ScreenVision returns raw PNG bytes; the
        // chat surface still wants a JPEG-with-quality-ladder fallback for
        // anything that would exceed `maxCaptureBytes`.
        //
        // ScreenVision v1 captures the primary display only. There is no
        // display-selection argument here because accepting one we cannot
        // honor would silently send the wrong screen on a multi-display Mac.

        let png: Data
        do {
            png = try await SwiftNativeScreenVision().captureScreen()
        } catch let e as ScreenVisionError {
            // Map the ScreenVision error surface back onto the existing
            // CaptureError cases. Preserve the underlying ScreenCaptureKit
            // reason in .captureFailed so the user-facing toast shows the
            // real cause (e.g. "Screen capture failed: SCStream
            // configuration is invalid") instead of a generic encode error.
            switch e {
            case .permissionDenied:
                throw CaptureError.permissionRequired
            case .noDisplay:
                throw CaptureError.noDisplay
            case .captureFailed(let reason):
                throw CaptureError.captureFailed(reason)
            }
        }

        // Decode the PNG back into a CGImage so the existing encodeForChat
        // ladder (JPEG quality fallbacks, then PNG, then tooLarge) can run
        // unchanged.
        guard let provider = CGDataProvider(data: png as CFData),
              let cg = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CaptureError.encodingFailed
        }
        let encoded = try encodeForChat(cg)
        return (
            encoded.data.base64EncodedString(),
            encoded.mime,
            encoded.name,
            encoded.data.count
        )
    }

    static func encodeForChat(_ source: CGImage) throws -> (data: Data, mime: String, name: String) {
        let image = resizedForChat(source)
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try fittingEncodedPayload(
            maxBytes: maxCaptureBytes,
            jpegData: { quality in
                bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
            },
            pngData: { bitmap.representation(using: .png, properties: [:]) }
        )
    }

    static func fittingEncodedPayload(
        maxBytes: Int,
        jpegData: (Double) -> Data?,
        pngData: () -> Data?
    ) throws -> (data: Data, mime: String, name: String) {
        for quality in [0.78, 0.65, 0.52, 0.40] {
            if let jpeg = jpegData(quality), jpeg.count <= maxBytes {
                return (jpeg, "image/jpeg", "screen.jpg")
            }
        }
        if let png = pngData(), png.count <= maxBytes {
            return (png, "image/png", "screen.png")
        }
        throw CaptureError.tooLarge
    }

    static func resizedForChat(_ source: CGImage) -> CGImage {
        let width = source.width
        let height = source.height
        let largest = max(width, height)
        guard largest > maxCaptureDimension else { return source }
        let scale = CGFloat(maxCaptureDimension) / CGFloat(largest)
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? source
    }

}

// PATCH-2026-05-06: multimodal-ui Sprint 3 — ChatView extended with voice, image, file, screen capture
// B.2: recognised slash commands; anything else falls through to regular send
// PATCH-2026-05-08: review-fix-r2 Removed "skill" — handleSlashCommand has
// no case for it, so /skill ... was being intercepted as "Unknown command"
// instead of falling through to chat (where _chat_intent_skill_build can
// detect natural-language skill requests).
extension Notification.Name {
    /// Fired by AppModel.sendChat after a turn lands so any ContextFillBar
    /// instance can re-poll the session context.
    static let chatTurnCompleted = Notification.Name("chatTurnCompleted")
    /// Fired by /nextgen slash command to navigate to the NextGen panel in Capabilities.
    static let openNextGenRequest = Notification.Name("NativeAgent.openNextGenRequest")
    static let openApprovalsRequest = Notification.Name("NativeAgent.openApprovalsRequest")
    static let openTelegramRequest = Notification.Name("NativeAgent.openTelegramRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    /// B2.3 follow-up: posted by Desk's New Task toolbar button; ContentView
    /// owns the sheet (detail-attached sheets present only once on macOS).
    static let newWorkshopTaskRequest = Notification.Name("NativeAgent.newWorkshopTaskRequest")
    static let iCloudInboxDidProcess = Notification.Name("NativeAgent.iCloudInboxDidProcess")
    /// PATCH-2026-06-06: activity-flatten — posted by Cmd+Shift+A / Cmd+Shift+I
    /// (and any future direct-route into Activity's sub-queues). Object is an
    /// `ActivitySection.rawValue` string; ActivityView resets its
    /// NavigationPath and pushes the matching destination.
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    /// Inbox "Act" on a chat-shaped item (morning brief, idle check-in, …):
    /// switch to Chat and prefill the composer with the object string via
    /// AppModel.injectChatDraft — same idiom as skillBuildRequest.
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    /// L5 G6: Act on a card SHE authored — her message is ALREADY in the
    /// transcript by the time this posts. Switch to Chat and reload; the
    /// composer is deliberately left untouched, because User is answering her,
    /// not writing to himself.
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}


enum MemoryViewTab: String, CaseIterable, Identifiable {
    case active = "Active"
    case pending = "Pending"
    case tombstones = "Tombstones"
    var id: String { rawValue }
    // Consumer-facing label; rawValue stays stable for ids/deep links.
    var title: String {
        self == .tombstones ? "Deleted" : rawValue
    }
    var systemImage: String {
        switch self {
        case .active: return "brain"
        case .pending: return "tray"
        case .tombstones: return "xmark.bin"
        }
    }
}


extension String {
    var withoutStaleNextGenPhaseCopy: String {
        var value = self
        value = value.replacingOccurrences(
            of: #"(?i)next-gen runtime phases?\s+52\s*[-–]\s*92"#,
            with: "Next-Gen Runtime",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)phases?\s+52\s*[-–]\s*92"#,
            with: "next-gen phases",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-52[-–]92"#,
            with: "nextgen-phase",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"phase-73[-–]92"#,
            with: "nextgen-key-phase",
            options: .regularExpression
        )
        return value
    }
}


enum CapabilityWorkspaceMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case build = "Build"
    case operate = "Operate"
    case hardening = "Hardening"

    var id: String { rawValue }
}
