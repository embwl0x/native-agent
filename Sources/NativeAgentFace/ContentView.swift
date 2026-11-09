import Foundation
import SwiftUI
import AppKit
import NativeAgentShared

// Blueprint: | `ContentView.swift` | `ContentView`: shell, scene navigation, first-run and window navigation |

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var appModel
    @SceneStorage("selection") private var selectionRaw = SidebarItem.chat.rawValue
    @FacePreference("nativeagent.showTour") private var showTour = false
    @FacePreference(ShellViewMode.key) private var viewModeRaw = ""
    @FacePreference(WorkPaneState.sidebarsHiddenKey) private var sidebarsHidden = false
    private var displayedViewMode: String {
        showTour && appModel.shellLayout?.value != nil ? ShellViewMode.advanced : viewModeRaw
    }
    private var showsSimpleView: Bool { displayedViewMode == ShellViewMode.simple }
    private var showsAgentView: Bool { displayedViewMode == ShellViewMode.agent }
    private var displayedPage: String? {
        showsAgentView ? "home" : showsSimpleView ? "chat" : ownPageID ?? ShellPageContent.doorPage(activeContentItem)
    }
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
    @State private var tourID = UUID()

    /// The page of the agent's own the window shows: the selection holds it as `page:<id>`, the same name the rail's layout block has.
    private var ownPageID: String? {
        selectionRaw.hasPrefix(SurfaceLayout.pagePrefix) ? String(selectionRaw.dropFirst(SurfaceLayout.pagePrefix.count)) : nil
    }

    /// One identity per page shown, so two pages of the agent's own never share a page's state.
    private var paneIdentity: String {
        ownPageID.map { SurfaceLayout.pagePrefix + $0 } ?? selection.wrappedValue.rawValue
    }

    private var selection: Binding<SidebarItem> {
        Binding {
            if ownPageID != nil { return .ownPage }
            // A stored selection that names no page any more opens Chat, the rail's first page.
            let item = SidebarItem(rawValue: selectionRaw) ?? .chat
            if let home = SidebarItem.shellHome(for: item) { return home.parent }
            return item
        } set: {
            selectSidebarItem($0)
        }
    }

    private var activeContentItem: SidebarItem {
        selection.wrappedValue
    }

    /// Keep Chat mounted; visibility affects drawing and hit testing only.
    private var isShowingChat: Bool {
        selection.wrappedValue == .chat
    }

    var body: some View {
        let windowAction = appModel.windowActions.first
        FacePreferences(keys: ["nativeagent.showTour", ShellViewMode.key, WorkPaneState.sidebarsHiddenKey]) { preferenceContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appModel.windowActionIssues) { issue in
                        windowIssue(issue.message) { appModel.windowActionIssues.removeAll { $0.id == issue.id } }
                    }
                }
            }
            .task(id: windowAction?.id) {
                guard !Task.isCancelled, let request = windowAction else { return }
                defer { appModel.windowActions.removeAll { $0.id == request.id } }
                do { try await request.perform(appModel) }
                catch {
                    guard !Task.isCancelled, appModel.windowActions.contains(where: { $0.id == request.id }) else { return }
                    appModel.windowActionIssues.append(.init(id: request.id,
                        message: FaceActionFeedback.message(error, action: request.operation.words)))
                }
            }
            .onDisappear {
                appModel.windowActions.removeAll()
                appModel.windowActionIssues.removeAll()
            }
    }

    private var preferenceContent: some View {
        ZStack {
            Group {
            if let failure = appModel.settingsViewModeIssue {
                VStack(spacing: 16) {
                    Text("View unavailable").font(.title2)
                    Text(failure).textSelection(.enabled)
                    HStack {
                        Button("Choose Simple") { viewModeRaw = ShellViewMode.simple }
                        Button("Choose Advanced") { viewModeRaw = ShellViewMode.advanced }
                        Button("Choose Agent") { viewModeRaw = ShellViewMode.agent }
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
                    selectedPage: ownPageID,
                    selectPage: { selectionRaw = SurfaceLayout.pagePrefix + $0 }
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
                // Chat stays mounted above; every other page draws through the one page map.
                ShellPageContent(item: selection.wrappedValue, ownPage: ownPageID)
                // Give each page distinct identity so navigation cannot reuse another page's state.
                .id(paneIdentity)
                .transition(NativeAgentMotion.fadeIn)
                }
                }
                // Replace pages atomically to avoid superimposed translucent text; local controls own their animations.
                .animation(nil, value: paneIdentity)
                }
                // Refresh by selection so mounted Chat also receives its arrival refresh.
                .task(id: selectionRaw) {
                    appModel.faceRefreshIssue = nil
                    let item = activeContentItem
                    if item == .activity {
                        // Today's source owner posts its face; opening it only draws that face.
                    } else if item == .settings || item == .ownPage
                                || (item == .memories
                                    && UserDefaults.standard.string(forKey: ShellRailTab.storageKey(.memories)) != "knowledge") {
                        // These pages own their arrival refresh, so the shell does not repeat it.
                    } else {
                        await appModel.refreshForSidebarItem(item)
                    }
                }
                }
            }
            }
            }
            .accessibilityHidden((showTour && appModel.shellLayout?.value != nil) || showFirstRunOnboarding)
            .overlay {
                FacePagePaintHost(page: displayedPage)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: [selectionRaw, displayedViewMode], initial: true) {
                // Links that await the body before navigating slightly undercount the person's wait.
                FacePageDiagnostics.selected(page: displayedPage)
            }

            if showTour, let layout = appModel.shellLayout?.value {
                OnboardingTourOverlay(
                    layout: layout,
                    onComplete: {
                        showTour = false
                    },
                    onSelectTab: { item in
                        selectionRaw = item.rawValue
                    }
                )
                .id(tourID)
                .transition(NativeAgentMotion.fade)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .unavailable = appModel.shellLayout {
                SurfaceLayoutContent(appModel.shellLayout) { _ in EmptyView() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let issue = appModel.faceLinkIssue {
                    windowIssue(issue) { appModel.faceLinkIssue = nil }
                }
                if let issue = appModel.faceRefreshIssue {
                    windowIssue(issue) { appModel.faceRefreshIssue = nil }
                }
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
        .viewModeSwitch()
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: showTour
        )
        .onAppear {
            guard navigationMountID == nil else { return }
            navigationMountID = ApplicationLifetime.shared.mountMainScene(visiblePageInput: {
                switch displayedViewMode {
                case ShellViewMode.simple: return ["page": .string("chat")]
                case ShellViewMode.agent: return ["page": .string("agent_view"), "item": .string(agentRoom)]
                default:
                    if let page = ownPageID { return ["page": .string(page)] }
                    return QuietPages.shown(activeContentItem).map { ["page": .string($0.id)] }
                }
            }, replayTour: {
                chatShortcut = nil
                showFirstRunOnboarding = false
                tourID = UUID()
            }) { destination in
                applyNavigationDestination(destination)
            }
        }
        .onDisappear {
            guard let navigationMountID else { return }
            ApplicationLifetime.shared.unmountMainScene(id: navigationMountID)
            self.navigationMountID = nil
        }
        .onChange(of: visibleScene, initial: true) { previous, report in
            if previous?.destination != report?.destination { appModel.faceRefreshIssue = nil }
            if let report { FaceReports.shared.submit(.reportScene(report)) }
        }
        .task {
            await appModel.reloadPersonality()
            await checkFirstRunOnboardingIfNeeded()
        }
        .task(id: appModel.manualRefreshRequest) {
            guard let requested = appModel.manualRefreshRequest else { return }
            _ = await appModel.requestFaceRefresh(.all, userInitiated: true)
            if appModel.manualRefreshRequest == requested { appModel.manualRefreshRequest = nil }
        }
        .modifier(FaceObservation(demand: .key(.sessionNavigation)))
        .sheet(isPresented: $showFirstRunOnboarding) {
            OnboardingWizard {
                showFirstRunOnboarding = false
                Task {
                    selectionRaw = SidebarItem.chat.rawValue
                    await appModel.reloadPersonality()
                    _ = await appModel.refreshForSidebarItem(.chat)
                    if let message = await appModel.maybeSendFirstRunGreeting() {
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
            guard DeskWindowPresentation.shared.receiver == nil else { return }
            showCommandPalette = true
        }
        .sheet(isPresented: $showNewDeskTask) {
            NewDeskTaskSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newDeskTaskRequest)) { _ in
            showNewDeskTask = true
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
                    do { try FaceWindowReply.check(await appModel.client.act(.selectConversation(session: sessionId, userInitiated: true))) }
                    catch { appModel.statusText = error.localizedDescription }
                }
            }
        }
    }

    private func windowIssue(_ text: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }.padding(12)
    }

    @MainActor
    private func checkFirstRunOnboardingIfNeeded() async {
        guard !didCheckFirstRunOnboarding else { return }
        didCheckFirstRunOnboarding = true
        guard !Task.isCancelled else { return }
        do {
            let reply = try FaceWindowReply.value(await appModel.client.act(.onboarding(.start)))
            guard case .object(let value) = reply, case .bool(let requiresPresentation)? = value["requiresPresentation"] else {
                throw PartCallError(code: "onboarding_reply_invalid", message: "The body did not return the setup disposition.")
            }
            guard !Task.isCancelled, requiresPresentation else { return }
        } catch {
            guard !Task.isCancelled else { return }
            firstRunReadError = error.localizedDescription
            return
        }
        selectionRaw = SidebarItem.chat.rawValue
        showTour = false
        showFirstRunOnboarding = true
    }

    private var visibleScene: SceneReport? {
        guard navigationMountID != nil else { return nil }
        return ApplicationLifetime.shared.scene
    }

    private func applyNavigationDestination(_ destination: NativeAgentNavigationDestination) {
        if case .chatShortcut(let page) = destination {
            chatShortcut = page
            return
        }
        chatShortcut = nil
        // Every non-chat destination needs the full shell, whether or not an overlay was open.
        if destination != .sidebar(.chat) {
            viewModeRaw = ShellViewMode.advanced
        }
        switch destination {
        case .chatShortcut: break
        case .ownPage(let page):
            selectionRaw = SurfaceLayout.pagePrefix + page
        case .savedThing(let saved):
            viewModeRaw = ShellViewMode.advanced
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
        case .sidebar(let target):
            if target == .activity {
                applyActivityRoot()
                return
            }
            if let layout = appModel.shellLayout, let first = ShellRailTab.all(layout).first(where: { $0.page == target })?.tabs.first?.key {
                UserDefaults.standard.set(first, forKey: ShellRailTab.storageKey(target))
            }
            selectSidebarItem(target)
        }
    }

    private func openHelperReply(botID: UUID, entryID: UUID) async {
        do {
            let request = DocumentRequest(id: UUID(), subject: .helperEntry(entryID.uuidString))
            let reply = try FaceWindowReply.value(await appModel.client.act(.requestDocument(request)))
            guard case .object(let fields) = reply,
                  case .string(let returnedBot)? = fields["bot_id"], returnedBot == botID.uuidString,
                  case .string(let session)? = fields["session_id"] else {
                throw PartCallError(code: "helper_reply_unavailable", message: "This saved reply has no matching helper conversation.")
            }
            guard await appModel.selectChatSession(id: session, userInitiated: true) else { return }
            selectSidebarItem(.chat)
        } catch { appModel.statusText = error.localizedDescription }
    }

    private func selectSidebarItem(_ target: SidebarItem) {
        // A page of the agent's own is selected by its id (`.ownPage(id)`, the rail's page row), never by the bare case.
        guard target != .ownPage else { return }
        // Write the tab before selecting its parent so the page mounts on that tab.
        if let home = SidebarItem.shellHome(for: target) {
            UserDefaults.standard.set(home.tab, forKey: ShellRailTab.storageKey(home.parent))
            selectionRaw = home.parent.rawValue
            return
        }
        if target == .desk { appModel.pendingDeskHandle = nil }
        selectionRaw = target.rawValue
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
    static let openTrustMultimodalRequest = Notification.Name("openTrustMultimodalRequest")
    static let openCommandRouteRequest = Notification.Name("NativeAgent.openCommandRouteRequest")
    static let openCommandPaletteRequest = Notification.Name("NativeAgent.openCommandPaletteRequest")
    /// Own the sheet in ContentView: a sheet attached inside Desk presents only once on macOS.
    static let newDeskTaskRequest = Notification.Name("NativeAgent.newDeskTaskRequest")
    static let openActivitySectionRequest = Notification.Name("NativeAgent.openActivitySectionRequest")
    static let openActivityRootRequest = Notification.Name("NativeAgent.openActivityRootRequest")
    static let openChatDraftRequest = Notification.Name("NativeAgent.openChatDraftRequest")
    static let openSpokenChatRequest = Notification.Name("NativeAgent.openSpokenChatRequest")
}




// MARK: - Render audit

// Enable render counters only on request to keep ordinary rendering quiet.
@MainActor final class RenderAudit {
    static let shared = RenderAudit()
    let enabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_RENDER_AUDIT"] == "1"
    private var counts: [String: Int] = [:]
    private var lastDump = Date()

    static func bump(_ key: String) { shared._bump(key) }

    private func _bump(_ key: String) {
        guard enabled else { return }
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
