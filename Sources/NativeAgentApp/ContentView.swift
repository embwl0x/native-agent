import Cognition
import EngineRuntime
import AppToolRuntime
import ToolRegistry
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
import Onboarding
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
import DeviceSync
import CoreSpotlight
import CloudKit
import DeviceSync
#endif

// Blueprint: | `ContentView.swift` | `ContentView`: Simple/Advanced/Agent shell assembly, navigation destinations, first-run presentation and iCloud action refresh routing |

struct ContentView: View {
    // Page transitions respect Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selection") private var selectionRaw = SidebarItem.chat.rawValue
    @State private var hasMountedBots = false
    @SceneStorage("skillsToolsSection") private var skillsToolsSectionRaw = SkillsToolsSection.skills.rawValue
    @AppStorage("nativeagent.showTour") private var showTour = false
    /// The visible Simple, Advanced or Agent shell.
    @AppStorage(SimpleViewMode.key) private var viewModeRaw = ""
    /// ⌘0 hides the rail (and Chat's conversations column) so chat fills the window.
    @AppStorage(WorkPaneState.sidebarsHiddenKey) private var sidebarsHidden = false
    @AppStorage(WorkPaneState.openKey) private var workPaneOpen = false
    @AppStorage(ShellRailTab.storageKey(.capabilities)) private var capabilitiesTab = "capabilities"
    private var sensesVisible: Bool {
        !showsSimpleView && !showsAgentView && ((isShowingChat && workPaneOpen)
            || (activeContentItem == .capabilities && capabilitiesTab == "senses"))
    }
    private var showsSimpleView: Bool { SimpleViewMode.resolved(viewModeRaw) == SimpleViewMode.simple }
    private var showsAgentView: Bool { SimpleViewMode.resolved(viewModeRaw) == SimpleViewMode.agent }
    @State private var tourReplayCoordinator = OnboardingTourReplay.shared
    @State private var didCheckFirstRunOnboarding = false
    @State private var showFirstRunOnboarding = false
    @State private var firstRunReadError: String?
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
    // ContentView owns Desk's new-task sheet so repeated presentations remain available.
    @State private var showNewWorkshopTask = false
    @State private var navigationMountID: UUID?
    @State private var agentRoom = "home"

    private var selection: Binding<SidebarItem> {
        Binding {
            // Normalize saved selections and command routes on both read and write.
            let item = (SidebarItem(rawValue: selectionRaw) ?? .chat).normalized
            // Tab destinations select their parent rail page.
            if let home = SidebarItem.shellHome(for: item) { return home.parent }
            return item
        } set: {
            selectSidebarItem($0.normalized)
        }
    }

    private var activeContentItem: SidebarItem {
        selection.wrappedValue.normalized
    }

    /// Chat stays mounted; this controls only drawing and hit testing.
    private var isShowingChat: Bool {
        selection.wrappedValue.normalized == .chat
    }

    private var isShowingBots: Bool { selection.wrappedValue.normalized == .bots }

    var body: some View {
        // RenderAudit counts root evaluations only when its audit flag is enabled.
        RenderAudit.bump("contentview.body")
        return ZStack {
            Group {
            if showsSimpleView {
                SimpleShellView()
            } else if showsAgentView {
                AgentScreenView(room: $agentRoom)
            } else {
            ShellFrame {
                // The rail owns its width and marks pending approvals with one dot.
                if !sidebarsHidden {
                ShellSidebarRail(
                    selection: selection,
                    needsYou: Set(
                        SidebarItem.rail(appModel.engine.layout.layout).compactMap { $0 }
                            // Today's rail dot and header read the same Needs you count.
                            .filter { $0.normalized == .activity && (appModel.engine.desk.ownerWaitingCount ?? 0) > 0 }
                            .map(\.normalized)
                    )
                )
                .navigationTitle("NativeAgent")
                }
            } detail: {
                VStack(spacing: 0) {
                // Each panel shows retained-data failures here; Chat renders its own notice.
                if activeContentItem != .chat,
                   let notice = appModel.panelStaleNotice(for: activeContentItem) {
                    StalePanelNotice(text: notice)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ZStack {
                // Chat remains mounted for the window's lifetime.
                ChatView()
                    // Hidden chat disables keyboard commands, dictation and scroll monitoring.
                    .environment(\.chatPageIsVisible, isShowingChat)
                    // Keep Liquid Glass in the shared shell's composition.
                    // A separate native host changes its backdrop boundary.
                    // Fluid glass: it fades in when it comes to the front and
                    // goes at once when it leaves, so two pages never draw
                    // over each other. Only the opacity is animated.
                    .animation(isShowingChat ? NativeAgentMotion.crossfade : nil) {
                        $0.opacity(isShowingChat ? 1 : 0)
                    }
                    .allowsHitTesting(isShowingChat)
                    // Pointer hiding alone does not guard assistive actions.
                    // An AXPress carries no point, so VoiceOver/automation was
                    // still reaching the hidden transcript: a press on
                    // Personality > Dreams landed on a conversation-list row and
                    // one on Bots > New bot landed on the chat header's Trust
                    // button. `.disabled` is what an assistive press respects —
                    // a disabled control refuses the action and cannot take
                    // focus — and `children: .ignore` prunes the descendant
                    // elements that `.accessibilityHidden` alone leaves in the
                    // tree for AppKit-backed subviews. Both are driven by the
                    // same boolean, so Chat stays mounted either way.
                    .disabled(!isShowingChat)
                    .accessibilityHidden(!isShowingChat)
                    .accessibilityElement(children: isShowingChat ? .contain : .ignore)

                // Retain one visited shelf, not a cache of navigation destinations.
                // AppKit leaks AX observer arrays when these text controls are torn
                // down. Hidden work is cancelled inside the shelf.
                if hasMountedBots || isShowingBots {
                    BotsShelfView(onContinue: applyNavigationDestination, isVisible: isShowingBots)
                        .animation(isShowingBots ? NativeAgentMotion.crossfade : nil) {
                            $0.opacity(isShowingBots ? 1 : 0)
                        }
                        .allowsHitTesting(isShowingBots)
                        .disabled(!isShowingBots)
                        .accessibilityHidden(!isShowingBots)
                        .accessibilityElement(children: isShowingBots ? .contain : .ignore)
                        .onAppear { hasMountedBots = true }
                }

                ZStack {
                if !isShowingChat && !isShowingBots {
                Group {
                    // Routed child surfaces remain reachable without adding primary sidebar tabs.
                    switch selection.wrappedValue.normalized {
                    // ── Primary ───────────────────────────────────────────────
                    // .chat is mounted above, outside this switch.
                    case .chat: EmptyView()
                    case .bots: EmptyView()
                    case .activity: TodayView()
                    // Memories and the knowledge graph as tabs; a
                    // memory-review request lands on the Memories tab
                    // (applyActivitySection writes the tab first).
                    case .memories: MemoriesRailPage()
                    case .desk: DeskPageView(rootRouteVersion: deskRootRouteVersion)
                    case .personality: PersonalityRailPage()
                    case .connectors: ConnectorsRailPage()
                    case .trust: TrustRailPage()
                    case .providers:
                        ShellRailPage(title: "Providers", subtitlePage: .providers, alive: true) { ProviderSettingsView() }
                    case .settings:
                        // A route to Settings is a route to its ROOT, and
                        // the stack inside SetupView owns its own path —
                        // nothing can unwind it from out here. `.id` does
                        // it the only way an unbound stack allows: a fresh
                        // SetupView, standing on Settings.
                        SetupView().id(settingsRootRouteVersion)
                    // ── Advanced / routed child surfaces ──────────────────────
                    case .capabilities:
                        CapabilitiesRailPage()
                    case .diagnostics: DiagnosticsRailPage()
                    case .inboxPolicy:
                        ShellRailPage(title: "Notifications", alive: true) { InboxSettingsView() }
                    // Retired destinations resolve before rendering.
                    case .memory, .settingsHub, .approvals, .workshop, .legacyWorkshop, .work, .skillLifecycle, .skills, .tools,
                         .autoImprovement, .panels, .command, .macIntegration, .knowledge, .dreams, .cognition, .inspector, .telegram:
                        EmptyView()  // unreachable: normalized and shellHome resolve these above
                    }
                }
                // id() gives each page distinct identity so a switch mounts the
                // new page rather than reusing the old one's state; state
                // within a page is untouched while its selection is stable.
                .id(selection.wrappedValue.normalized)
                // Fluid glass: only the incoming page fades in; the outgoing
                // one is gone in the same frame.
                .transition(NativeAgentMotion.fadeIn)
                }
                }
                // Replace pages atomically. Crossfading two translucent pages
                // superimposes their text; retained chat/bots keep their state.
                // Local control animations remain owned by their own views.
                .animation(nil, value: selection.wrappedValue.normalized)
                }
                // The per-panel refresh belongs to the SELECTION, not to the
                // switch above — Chat now sits outside it and must still get
                // its refresh on arrival.
                .task(id: selectionRaw) {
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
                        //
                        // Today already runs that exact refresh as the
                        // initial read of its own file watcher, so doing it
                        // here too paid for the five queue fetches twice on
                        // every arrival.
                    } else if item.normalized == .capabilities || item.normalized == .settings || item == .tools
                                || (item.normalized == .memories
                                    && UserDefaults.standard.string(forKey: ShellRailTab.storageKey(.memories)) != "knowledge") {
                        // These pages own their arrival refresh, so the shell does not repeat it.
                    } else {
                        await appModel.refreshForSidebarItem(item)
                    }
                }
                }
            }
            // Keep the Activity badge honest without pulling the full
            // Activity surface while another tab is open. The full
            // Today owns detailed proposal/improvement refreshes. On the
            // frame, not the rail: ⌘0 hides the rail, and this refresh also
            // keeps the approvals the turn card and Work pane read current.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await appModel.engine.watchActivityChanges {
                    _ = await appModel.refreshSidebarActivityBadge()
                }
            }
            }
            }
            // S.5: hide NavigationSplitView from VoiceOver while onboarding overlay is active
            .accessibilityHidden(showTour || showFirstRunOnboarding)

            // The tour appears only when explicitly replayed from About.
            if showTour {
                OnboardingTourOverlay(
                    layout: appModel.engine.layout.layout,
                    onComplete: {
                        showTour = false
                    },
                    onSelectTab: { item in
                        selectionRaw = item.rawValue
                    }
                )
                .transition(NativeAgentMotion.fade)
            }
        }
        // The notice lane sits under pinned chat chrome or at the top of other pages.
        .overlayPreferenceValue(NoticeLaneRoomKey.self) { room in
            GeometryReader { proxy in
                NoticeLane(centers: [appModel.systemToasts] + [room?.notices].compactMap { $0 })
                    .padding(.top, room.map { proxy[$0.anchor].maxY + NativeAgentSpacing.sm } ?? NativeAgentSpacing.md)
            }
        }
        .onReceive(NativeAgentEngine.liveDeviceSync.bridge.$accountFailure) { failure in
            appModel.showICloudAccountFailure(failure)
        }
        .viewModeSwitch()
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: showTour
        )
        .onChange(of: tourReplayCoordinator.requestID) { _, requestID in
            presentTourReplayIfNeeded(requestID: requestID)
        }
        .onAppear {
            presentTourReplayIfNeeded(requestID: tourReplayCoordinator.requestID)
            // Translate saved destinations into their rail page and tab once.
            if let saved = SidebarItem(rawValue: selectionRaw),
               let home = SidebarItem.shellHome(for: saved) {
                let tab = (home.parent == .diagnostics && home.tab == "skills"
                    && (saved == .tools || skillsToolsSectionRaw == SkillsToolsSection.tools.rawValue)) ? "tools" : home.tab
                UserDefaults.standard.set(tab, forKey: ShellRailTab.storageKey(home.parent))
                selectionRaw = home.parent.rawValue
            }
            guard navigationMountID == nil else { return }
            navigationMountID = ApplicationLifetime.shared.mountMainScene(visiblePageInput: {
                switch SimpleViewMode.current {
                case SimpleViewMode.simple: return ["page": .string("chat")]
                case SimpleViewMode.agent: return ["page": .string("agent_view"), "item": .string(agentRoom)]
                default: return QuietPages.all.first { $0.item == activeContentItem }.map { ["page": .string($0.id)] }
                }
            }) { destination in
                applyNavigationDestination(destination)
            }
        }
        .onDisappear {
            guard let navigationMountID else { return }
            ApplicationLifetime.shared.unmountMainScene(id: navigationMountID)
            self.navigationMountID = nil
        }
        .task {
            await appModel.reloadPersonality()
            await checkFirstRunOnboardingIfNeeded()
        }
        .liveTask(id: sensesVisible) {
            if sensesVisible { await appModel.engine.senses.observe(dataRoot: appModel.engine.dataRoot) }
        }
        // All Mac projections of chat sessions share AppModel's one canonical
        // list: Chat, detached-window titles, Status, command search, and the
        // optional project/session lineage page. Keep it current from the
        // canonical index while the app scene is active. This watcher is
        // vnode-driven, burst-coalesced, and performs no idle polling; the
        // lightweight refresh also suppresses equal observed writes.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await appModel.engine.transcripts.watchIndexChanges {
                await appModel.refreshChatSessionIndex()
            }
        }
        .sheet(isPresented: $showFirstRunOnboarding) {
            OnboardingWizard {
                showFirstRunOnboarding = false
                Task {
                    selectionRaw = SidebarItem.chat.rawValue
                    await appModel.reloadPersonality()
                    _ = await appModel.refreshForSidebarItem(.chat)
                    // Fire after Chat loads; ChatView's task is a backup.
                    let greeting = await appModel.maybeSendFirstRunGreeting()
                    if let message = greeting.routeFailureMessage {
                        appModel.statusText = "Onboarding finished, but \(message)."
                    }
                }
            }
            .interactiveDismissDisabled(true)
        }
        .alert("Couldn't read setup", isPresented: Binding(
            get: { firstRunReadError != nil },
            set: { if !$0 { firstRunReadError = nil } }
        )) {
            Button("Retry") {
                firstRunReadError = nil
                didCheckFirstRunOnboarding = false
                Task { await checkFirstRunOnboardingIfNeeded() }
            }
            Button("Dismiss", role: .cancel) { firstRunReadError = nil }
        } message: {
            Text(firstRunReadError ?? "")
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(isPresented: $showCommandPalette)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
            guard !appModel.deskHoldsCommandPalette else { return }
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
                switch route {
                case .refreshActivity:
                    await appModel.refreshForSidebarItem(.activity)
                case .refreshActivityBadge:
                    await appModel.refreshSidebarActivityBadge()
                }
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
            if appModel.chatDraft(for: appModel.activeChatSessionId).isEmpty {
                appModel.injectChatDraft(draft, sessionId: appModel.activeChatSessionId)
            }
        }
        // The message is already persisted; reload its session without touching the composer.
        .onReceive(NotificationCenter.default.publisher(for: .openSpokenChatRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            guard let sessionId = note.object as? String, !sessionId.isEmpty else { return }
            Task {
                if sessionId != appModel.activeChatSessionId {
                    await appModel.refreshChatSessionIndex()
                    guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionId }) else { return }
                    await appModel.selectChatSession(session)
                }
                await appModel.refreshChatMessagesAfterTurn(sessionId: sessionId)
            }
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
        guard !Task.isCancelled else { return }
        do {
            let result = try await appModel.engine.onboarding.startOnboarding()
            guard !Task.isCancelled, result.requiresPresentation else { return }
        } catch {
            guard !Task.isCancelled else { return }
            firstRunReadError = UserFacingError.cause(error, action: "check first-run setup")
            return
        }
        selectionRaw = SidebarItem.chat.rawValue
        showTour = false
        showFirstRunOnboarding = true
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
            // A page route lands on its first visible tab; SettingsLink
            // chooses a requested tab after routing.
            if let first = ShellRailTab.all(appModel.engine.layout.layout).first(where: { $0.page == target })?.tabs.first?.key {
                UserDefaults.standard.set(first, forKey: ShellRailTab.storageKey(target))
            }
            selectSidebarItem(target)
        }
    }

    private func selectSidebarItem(_ target: SidebarItem) {
        // Write the tab key before selecting its parent so the page mounts on that tab.
        if let home = SidebarItem.shellHome(for: target) {
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
        // push onto. The memory review lives on the Memories place's
        // Pending tab, so route there instead of stranding the request.
        if section == .memoryProposals {
            appModel.pendingActivitySectionRaw = nil
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
        UserDefaults.standard.set(
            section == .tools ? "tools" : "skills",
            forKey: ShellRailTab.storageKey(.diagnostics)
        )
        selectionRaw = SidebarItem.diagnostics.rawValue
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
        .aliveCard(radius: NativeAgentRadius.panel)
    }
}



extension Notification.Name {
    static let openApprovalsRequest = Notification.Name("NativeAgent.openApprovalsRequest")
    static let openTelegramRequest = Notification.Name("NativeAgent.openTelegramRequest")
    /// Opens Trust where screen capture and the other multimodal grants live.
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    /// Posted by the Desk page's New task button; ContentView owns the sheet
    /// (a sheet attached inside the page presents only once on macOS).
    static let newWorkshopTaskRequest = Notification.Name("NativeAgent.newWorkshopTaskRequest")
    /// Posted by the New Task sheet once the task exists, so an open Desk
    /// re-reads its board instead of waiting for its next poll.
    static let deskTaskCreated = Notification.Name("NativeAgent.deskTaskCreated")
    /// The object is an `ActivitySection.rawValue` string naming the queue Today opens.
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    /// Inbox "Act" on a chat-shaped item (morning brief, idle check-in, …):
    /// switch to Chat and prefill the composer with the object string via
    /// AppModel.injectChatDraft — same idiom as skillBuildRequest.
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    /// Opens the session containing the agent's persisted message without changing the composer.
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}




// Capabilities' two tabs (CapabilitiesRailPage). Hardening is not a third: it
// moved, whole, behind the "For developers" fold at the bottom of the page.
// "What needs a look" held only a third approval inbox and is gone: approvals
// are the chat's inline cards and Today's Approvals (⌘⇧A).
enum CapabilityWorkspaceMode: String, CaseIterable, Identifiable {
    case canDo = "What I can do"
    case installed = "What's installed"

    var id: String { rawValue }
}

/// Routes an iCloud inbox mutation to the smallest current Activity read. The
/// route is selected when the notification arrives, before an async refresh can
/// observe a later sidebar change.
enum ICloudInboxDidProcessRoute: Equatable, Sendable {
    case refreshActivity
    case refreshActivityBadge

    static func resolve(selectionRaw: String) -> Self {
        guard let item = SidebarItem(rawValue: selectionRaw), item.normalized == .activity else {
            return .refreshActivityBadge
        }
        return .refreshActivity
    }
}
