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
import StandingBots
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
import DeviceSync
import CoreSpotlight
import CloudKit
import DeviceSync
import Foundation
#endif

// Blueprint: | `ContentView.swift` | `ContentView`: shell, scene navigation, first-run and iCloud refresh routing |

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selection") private var selectionRaw = SidebarItem.chat.rawValue
    @AppStorage("nativeagent.showTour") private var showTour = false
    @AppStorage(SimpleViewMode.key) private var viewModeRaw = ""
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
    /// Remount Settings' unbound NavigationStack by identity so every route reaches its root.
    // Own the task sheet outside Desk so macOS permits repeated presentations.
    @State private var showNewDeskTask = false
    @State private var navigationMountID: UUID?
    @State private var chatShortcut: ChatSlashPage?
    @State private var agentRoom = "home"

    private var selection: Binding<SidebarItem> {
        Binding {
            let item = (SidebarItem(rawValue: selectionRaw) ?? .chat).normalized
            if let home = SidebarItem.shellHome(for: item) { return home.parent }
            return item
        } set: {
            selectSidebarItem($0.normalized)
        }
    }

    private var activeContentItem: SidebarItem {
        selection.wrappedValue.normalized
    }

    /// Keep Chat mounted; visibility affects drawing and hit testing only.
    private var isShowingChat: Bool {
        selection.wrappedValue.normalized == .chat
    }

    var body: some View {
        RenderAudit.bump("contentview.body")
        return ZStack {
            Group {
            if let failure = SimpleViewMode.readFailure {
                VStack(spacing: 16) {
                    Text("View unavailable").font(.title2)
                    Text(failure).textSelection(.enabled)
                    HStack {
                        Button("Choose Simple") { viewModeRaw = SimpleViewMode.simple }
                        Button("Choose Advanced") { viewModeRaw = SimpleViewMode.advanced }
                        Button("Choose Agent") { viewModeRaw = SimpleViewMode.agent }
                    }
                }.padding(24)
            } else if showsSimpleView {
                SimpleShellView()
            } else if showsAgentView {
                AgentScreenView(room: $agentRoom)
            } else {
            ShellFrame {
                if !sidebarsHidden {
                ShellSidebarRail(
                    selection: selection,
                    needsYou: appModel.engine.desk.ownerWaitingCount.map { $0 > 0 ? [.activity] : [] },
                    attentionItem: .activity
                )
                .navigationTitle("NativeAgent")
                }
            } detail: {
                VStack(spacing: 0) {
                if activeContentItem != .chat,
                   let notice = appModel.panelStaleNotice(for: activeContentItem) {
                    StalePanelNotice(text: notice)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ZStack {
                ChatView()
                    .environment(\.chatPageIsVisible, isShowingChat)
                    // Keep glass in the shared composition; a separate native host changes its backdrop boundary.
                    .animation(isShowingChat ? NativeAgentMotion.crossfade : nil) {
                        $0.opacity(isShowingChat ? 1 : 0)
                    }
                    .allowsHitTesting(isShowingChat)
                    // AXPress has no pointer location: disable hidden controls and prune AppKit descendants so they cannot act or take focus.
                    .disabled(!isShowingChat)
                    .accessibilityHidden(!isShowingChat)
                    .accessibilityElement(children: isShowingChat ? .contain : .ignore)

                ZStack {
                if !isShowingChat {
                Group {
                    switch selection.wrappedValue.normalized {
                    case .chat: EmptyView()
                    case .bots: FacePageView(page: "bots", isReading: appModel.panelRefreshCounts[.bots, default: 0] > 0)
                    case .activity: TodayView()
                    case .memories: FacePageView(page: "memories").modifier(MemoriesFaceNavigation())
                    case .desk: FacePageView(page: "desk").modifier(DeskFaceEditors())
                    case .personality: FacePageView(page: "personality").personalityDestinations()
                    case .connectors: ConnectorsRailPage()
                    case .trust: FacePageView(page: "trust")
                    case .providers:
                        FacePageView(page: "providers", isReading: appModel.panelRefreshCounts[.providers, default: 0] > 0)
                    case .settings:
                        FacePageView(page: "settings")
                    case .capabilities:
                        CapabilitiesRailPage()
                    case .diagnostics: DiagnosticsRailPage()
                    case .inboxPolicy:
                        ShellRailPage(title: "Notifications", alive: true) { InboxSettingsView() }
                    case .skills, .tools,
                         .macIntegration, .knowledge, .dreams, .cognition, .inspector, .telegram:
                        EmptyView()  // unreachable: normalized and shellHome resolve these above
                    }
                }
                // Give each page distinct identity so navigation cannot reuse another page's state.
                .id(selection.wrappedValue.normalized)
                .transition(NativeAgentMotion.fadeIn)
                }
                }
                // Replace pages atomically to avoid superimposed translucent text; local controls own their animations.
                .animation(nil, value: selection.wrappedValue.normalized)
                }
                // Refresh by selection so mounted Chat also receives its arrival refresh.
                .task(id: selectionRaw) {
                    let item = activeContentItem
                    if item.normalized == .activity {
                        // Today owns the complete queue-read receipt and watcher; another arrival refresh would duplicate its five fetches.
                    } else if item.normalized == .settings || item == .tools
                                || (item.normalized == .memories
                                    && UserDefaults.standard.string(forKey: ShellRailTab.storageKey(.memories)) != "knowledge") {
                        // These pages own their arrival refresh, so the shell does not repeat it.
                    } else {
                        await appModel.refreshForSidebarItem(item)
                    }
                }
                }
            }
            // Watch badges on the frame so hidden rails still keep approvals current without loading the full Activity surface.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await appModel.engine.watchActivityChanges {
                    _ = await appModel.refreshSidebarActivityBadge()
                }
            }
            }
            }
            .accessibilityHidden((showTour && appModel.engine.layout.layout != nil) || showFirstRunOnboarding)

            if showTour, let layout = appModel.engine.layout.layout {
                OnboardingTourOverlay(
                    layout: layout,
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .unavailable = appModel.engine.layout.availability {
                SurfaceLayoutContent(appModel.engine.layout.availability) { _ in EmptyView() }
            }
        }
        .disabled(chatShortcut != nil)
        .overlay {
            if let page = chatShortcut {
                SimpleSetupPanel { chatShortcut = nil } content: {
                    page.content { chatShortcut = nil }
                }
            }
        }
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
        // Watch the canonical session index so every Mac projection shares current titles without idle polling.
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
            guard appModel.engine.desk.faceRequest == nil else { return }
            showCommandPalette = true
        }
        .sheet(isPresented: $showNewDeskTask) {
            NewDeskTaskSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDeskTaskRequest)) { _ in
            showNewDeskTask = true
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
        // AppModel already prepared the draft; this receiver only routes and recovers a missing first session.
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
        // Prefill only an empty composer so routing cannot clobber a half-written message.
        .onReceive(NotificationCenter.default.publisher(for: .openChatDraftRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            guard let draft = note.object as? String, !draft.isEmpty else { return }
            if appModel.activeChatSessionId.isEmpty { return }
            if appModel.chatDraft(for: appModel.activeChatSessionId).isEmpty {
                appModel.injectChatDraft(draft, sessionId: appModel.activeChatSessionId)
            }
        }
        // The message is durable; reload its session without touching the composer.
        .onReceive(NotificationCenter.default.publisher(for: .openSpokenChatRequest)) { note in
            selectionRaw = SidebarItem.chat.rawValue
            guard let sessionId = note.object as? String, !sessionId.isEmpty else { return }
            Task {
                if sessionId != appModel.activeChatSessionId {
                    await appModel.refreshChatSessionIndex()
                    guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionId }) else { return }
                    await appModel.selectChatSession(session)
                }
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
        if case .chatShortcut(let page) = destination {
            chatShortcut = page
            return
        }
        if chatShortcut != nil {
            chatShortcut = nil
            if destination != .sidebar(.chat) {
                viewModeRaw = SimpleViewMode.advanced
            }
        }
        switch destination {
        case .chatShortcut: break
        case .savedThing(let saved):
            viewModeRaw = SimpleViewMode.advanced
            switch saved {
            case .botReply(let botID, let entryID):
                Task { await openHelperReply(botID: botID, entryID: entryID) }
            case .dream:
                appModel.pendingPaletteDestination = saved
                selectSidebarItem(.dreams)
            case .memory:
                appModel.pendingPaletteDestination = saved
                UserDefaults.standard.set("memories", forKey: ShellRailTab.storageKey(.memories))
                selectSidebarItem(.memories)
            }
        case .activity(let section):
            applyActivitySection(section)
        case .skillsTools(let section):
            applySkillsToolsSection(section)
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
            let layout = appModel.engine.layout.availability
            if let first = ShellRailTab.all(layout).first(where: { $0.page == target })?.tabs.first?.key {
                UserDefaults.standard.set(first, forKey: ShellRailTab.storageKey(target))
            }
            selectSidebarItem(target)
        }
    }

    private func openHelperReply(botID: UUID, entryID: UUID) async {
        let root = appModel.engine.dataRoot
        do {
            let entry = try await Task.detached { try ShelfStore(dataRoot: root).entry(entryID) }.value
            guard entry.botId == botID, let sessionID = entry.sessionID else {
                appModel.statusText = "This reply has no matching helper conversation. Its saved result is kept."
                return
            }
            await appModel.refreshChatSessionIndex()
            guard let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionID }) else {
                appModel.statusText = "This helper conversation could not be read from the conversation index. Its saved reply is kept."
                return
            }
            await appModel.selectChatSession(session)
            if appModel.activeChatSessionId == sessionID { selectSidebarItem(.chat) }
        } catch { appModel.statusText = UserFacingError.message(error, action: "open that helper's reply") }
    }

    private func selectSidebarItem(_ target: SidebarItem) {
        // Write the tab before selecting its parent so the page mounts on that tab.
        if let home = SidebarItem.shellHome(for: target) {
            UserDefaults.standard.set(home.tab, forKey: ShellRailTab.storageKey(home.parent))
            selectionRaw = home.parent.rawValue
            return
        }
        if target.normalized == .desk { appModel.pendingDeskHandle = nil }
        selectionRaw = target.normalized.rawValue
    }

    private func applyActivitySection(_ section: ActivitySection) {
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
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    /// Own the sheet in ContentView: a sheet attached inside Desk presents only once on macOS.
    static let newDeskTaskRequest = Notification.Name("NativeAgent.newDeskTaskRequest")
    static let deskTaskCreated = Notification.Name("NativeAgent.deskTaskCreated")
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}




/// Resolve the route on notification receipt before an async refresh can observe a later sidebar selection.
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

// MARK: - Render audit

// Enable render counters only on request to keep ordinary rendering quiet.
final class RenderAudit: @unchecked Sendable {
    static let shared = RenderAudit()
    let enabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_RENDER_AUDIT"] == "1"
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var lastDump = Date()

    static func bump(_ key: String) { shared._bump(key) }

    private func _bump(_ key: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
        if Date().timeIntervalSince(lastDump) >= 5 {
            let line = counts.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            FileHandle.standardError.write(Data("RenderAudit[5s]: \(line)\n".utf8))
            counts = [:]
            lastDump = Date()
        }
    }
}
