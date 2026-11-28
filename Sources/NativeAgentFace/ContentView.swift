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
    @State private var didCheckFirstRunOnboarding = false
    @State private var showFirstRunOnboarding = false
    @State private var firstRunReadError: String?
    @State private var showCommandPalette = false
    /// Remount Settings' unbound NavigationStack by identity so every route reaches its root.
    @State private var navigationMountID: UUID?
    @State private var shownBodyToasts: Set<UUID> = []
    @State private var chatShortcut: ChatSlashPage?
    @State private var simplePane: SimpleShellView.Pane = .agent
    @State private var agentRoom = "home"
    @State private var tourID = UUID()
    /// The page last shown in each surface during this run of the window, which choosing the surface shows again.
    @State private var surfacePages: [ShellSurface: ShellRailRow] = [:]

    /// The page of the agent's own the window shows: the selection holds it as `page:<id>`, the same name the rail's layout block has.
    private var ownPageID: String? {
        selectionRaw.hasPrefix(SurfaceLayout.pagePrefix) ? String(selectionRaw.dropFirst(SurfaceLayout.pagePrefix.count)) : nil
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

    /// The page the window shows, as the layout's rail block names it.
    private var shownRow: ShellRailRow {
        ownPageID.map(ShellRailRow.page) ?? .item(activeContentItem)
    }

    /// The place of the page shown, so every writer of the selection also lands on its place and tab, in Simple and Advanced alike.
    private var shownSurface: ShellSurface { ShellSurface(activeContentItem) }

    /// Keep Chat mounted; visibility affects drawing and hit testing only.
    private var isShowingChat: Bool {
        selection.wrappedValue == .chat
    }

    var body: some View {
        let windowAction = appModel.windowActions.first
        FacePreferences(keys: ["nativeagent.showTour", ShellViewMode.key, WorkPaneState.sidebarsHiddenKey]) { preferenceContent }
            // Choosing Simple starts on the conversation: it is the view a person meets first, whatever page Advanced was on.
            .onChange(of: viewModeRaw) { old, new in
                if new == ShellViewMode.simple, !old.isEmpty, old != new { selectSidebarItem(.chat) }
            }
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
        let tourPresented = showTour && appModel.shellLayout?.value != nil
        let connectorPresented = showsSimpleView && isShowingChat && CardControls.shared.connectorSheet != nil
        return ZStack {
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
                SimpleShellView(pane: $simplePane, shown: shownRow, choose: { chooseSurface($0, pages: $1) }, select: { selectRow($0) })
                    .task(id: selectionRaw) { await refreshShownPage() }
            } else if showsAgentView {
                AgentScreenView(room: $agentRoom)
            } else {
            ShellFrame {
                if !sidebarsHidden {
                ShellSidebarRail(surface: shownSurface) { chooseSurface($0, pages: $1) }
                .navigationTitle("NativeAgent")
                }
            } detail: {
                ZStack {
                ChatView()
                    .environment(\.chatPageIsVisible, isShowingChat && !showFirstRunOnboarding)
                    // Keep glass in the shared composition; a separate native host changes its backdrop boundary.
                    .animation(isShowingChat ? NativeAgentMotion.crossfade : nil) {
                        $0.opacity(isShowingChat ? 1 : 0)
                    }
                    .allowsHitTesting(isShowingChat)
                    // AXPress has no pointer location: disable hidden controls and prune AppKit descendants so they cannot act or take focus.
                    .disabled(!isShowingChat)
                    .accessibilityHidden(!isShowingChat)
                    .accessibilityElement(children: isShowingChat ? .contain : .ignore)

                // Chat stays mounted above; every other page draws in its place's page area.
                ShellPlacePage(shown: shownRow) { selectRow($0) }
                }
                // Refresh by selection so mounted Chat also receives its arrival refresh.
                .task(id: selectionRaw) { await refreshShownPage() }
            }
            }
            }
            .viewModeSwitch(visible: !connectorPresented)
            .disabled(tourPresented)
            .accessibilityHidden(tourPresented || showFirstRunOnboarding)
            .onChange(of: shownRow, initial: true) {
                surfacePages[shownSurface] = shownRow
                ApplicationLifetime.shared.sceneShown()
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
        .accessibilityHidden(chatShortcut != nil)
        .overlay {
            if let page = chatShortcut {
                SimpleSetupPanel { chatShortcut = nil } content: {
                    page.content { chatShortcut = nil }
                }
            }
        }
        .overlay(alignment: .top) {
            NoticeLane(centers: [appModel.systemToasts])
                .padding(.top, NativeAgentSpacing.md)
        }
        .onChange(of: appModel.face.slot(.counts).select("toastQueues", as: CountsFace.self) {
            $0?.statuses.toastQueues.values.flatMap { $0 }
        }, initial: true) { _, toasts in
            guard let toasts else { return }
            for id in shownBodyToasts.subtracting(toasts.map(\.id)) { appModel.systemToasts.dismiss(id) }
            for toast in toasts where !shownBodyToasts.contains(toast.id) {
                appModel.systemToasts.push(SystemToast(kind: toast.kind, text: toast.text, autoDismissAfter: nil, id: toast.id, createdAt: toast.createdAt))
            }
            shownBodyToasts = Set(toasts.map(\.id))
        }
        .animation(
            Animation.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: showTour
        )
        .onAppear {
            guard navigationMountID == nil else { return }
            navigationMountID = ApplicationLifetime.shared.mountMainScene(visiblePageInput: {
                switch displayedViewMode {
                case ShellViewMode.agent: return ["page": .string("agent_view"), "item": .string(agentRoom)]
                default:
                    if let page = ownPageID { return ["page": .string(page)] }
                    return QuietPages.shown(activeContentItem).map { ["page": .string($0.id)] }
                }
            }, chatIsVisible: {
                isShowingChat && !showsAgentView && (!showsSimpleView || simplePane == .agent)
                    && !showFirstRunOnboarding && !(showTour && appModel.shellLayout?.value != nil)
                    && appModel.settingsViewModeIssue == nil && chatShortcut == nil
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
        .onMessage(OpenCommandPaletteRequest.self) { _ in
            guard DeskWindowPresentation.shared.receiver == nil else { return }
            showCommandPalette = true
        }
        // AppModel already prepared the draft; this receiver only routes and recovers a missing first session.
        .onMessage(SkillBuildRequest.self) { message in
            selectionRaw = SidebarItem.chat.rawValue
            guard appModel.activeChatSessionId.isEmpty else { return }
            Task {
                await appModel.newChatSession()
                guard !appModel.activeChatSessionId.isEmpty else { return }
                _ = appModel.requestSkillBuild(starter: message.starter)
            }
        }
        // Prefill only an empty composer so routing cannot clobber a half-written message.
        .onMessage(OpenChatDraftRequest.self) { message in
            selectionRaw = SidebarItem.chat.rawValue
            let draft = message.draft
            guard !draft.isEmpty else { return }
            if appModel.activeChatSessionId.isEmpty { return }
            if appModel.chatDraft(for: appModel.activeChatSessionId).isEmpty {
                appModel.injectChatDraft(draft, sessionId: appModel.activeChatSessionId)
            }
        }
    }

    /// The shown page's arrival refresh, the same in Simple and Advanced.
    private func refreshShownPage() async {
        appModel.faceRefreshIssue = nil
        let item = activeContentItem
        if item == .activity {
            // Today's source owner posts its face; opening it only draws that face.
        } else if item == .settings || item == .ownPage
                    || (item == .memories
                        && ShellRailTabStore.shared.value(for: .memories, default: "memories") != "knowledge") {
            // These pages own their arrival refresh, so the shell does not repeat it.
        } else {
            await appModel.refreshForSidebarItem(item)
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
                throw PartCallError(code: "onboarding_reply_invalid", message: "NativeAgent didn't answer. Try again.")
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
        // Simple and Advanced show every page in place; any other view has none, so a non-chat destination opens Advanced.
        if destination != .sidebar(.chat), viewModeRaw != ShellViewMode.simple {
            viewModeRaw = ShellViewMode.advanced
        }
        // Agent view has no chat pane: a conversation it opens shows in Simple, and Choose Agent returns.
        if destination == .sidebar(.chat), viewModeRaw == ShellViewMode.agent { viewModeRaw = ShellViewMode.simple }
        switch destination {
        case .chatShortcut: break
        case .ownPage(let page):
            selectionRaw = SurfaceLayout.pagePrefix + page
        case .savedThing(let saved):
            switch saved {
            case .botReply(let botID, let entryID):
                Task { await openHelperReply(botID: botID, entryID: entryID) }
            case .dream:
                appModel.pendingPaletteDestination = saved
                selectSidebarItem(.dreams)
            case .memory:
                appModel.pendingPaletteDestination = saved
                ShellRailTabStore.shared.set("memories", for: .memories)
                selectSidebarItem(.memories)
            }
        case .activity(let section):
            applyActivitySection(section)
        case .sidebar(let target):
            if target == .chat { simplePane = .agent }
            if target == .activity {
                applyActivityRoot()
                return
            }
            if let layout = appModel.shellLayout, let first = ShellRailTab.all(layout).first(where: { $0.page == target })?.tabs.first?.key {
                ShellRailTabStore.shared.set(first, for: target)
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
        } catch { appModel.statusText = error.localizedDescription; appModel.systemToasts.push(error: appModel.statusText) }
    }

    /// Choosing a surface shows the page last shown in it, or the page it opens on. The choice is the person's.
    private func chooseSurface(_ surface: ShellSurface, pages: [ShellRailRow]) {
        ApplicationLifetime.shared.personChose()
        if let page = surface.opening(pages, last: surfacePages[surface]) { selectRow(page) }
    }

    /// A tab or surface selects its page the way every other writer does: an app page by its item, a page of the agent's own by its id.
    /// The rail, the tabs and Simple's sidebar are the person's own choices, a tab included where the page shown stays the same.
    private func selectRow(_ row: ShellRailRow) {
        ApplicationLifetime.shared.personChose()
        switch row {
        case .item(let item): selectSidebarItem(item)
        case .page(let page): selectionRaw = SurfaceLayout.pagePrefix + page
        case .divider: break
        }
    }

    private func selectSidebarItem(_ target: SidebarItem) {
        // A page of the agent's own is selected by its id (`.ownPage(id)`, its tab on the agent's surface), never by the bare case.
        guard target != .ownPage else { return }
        // Write the tab before selecting its parent so the page mounts on that tab.
        if let home = SidebarItem.shellHome(for: target) {
            ShellRailTabStore.shared.set(home.tab, for: home.parent)
            selectionRaw = home.parent.rawValue
            return
        }
        selectionRaw = target.rawValue
    }

    private func applyActivitySection(_ section: ActivitySection) {
        if section == .memoryProposals {
            appModel.pendingActivitySectionRaw = nil
            // The waiting card is on the Memories tab, not the graph.
            ShellRailTabStore.shared.set("memories", for: .memories)
            selectionRaw = SidebarItem.memories.rawValue
            return
        }
        appModel.pendingActivitySectionRaw = section.rawValue
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(OpenActivitySectionRequest(section: section))
    }

    private func applyActivityRoot() {
        appModel.pendingActivitySectionRaw = nil
        selectionRaw = SidebarItem.activity.rawValue
        NotificationCenter.default.post(OpenActivityRootRequest())
    }

}




struct OpenCommandPaletteRequest: NotificationCenter.MainActorMessage {
    typealias Subject = NSObject
}

struct OpenActivitySectionRequest: NotificationCenter.MainActorMessage {
    typealias Subject = NSObject
    let section: ActivitySection
}

struct OpenActivityRootRequest: NotificationCenter.MainActorMessage {
    typealias Subject = NSObject
}

struct OpenChatDraftRequest: NotificationCenter.MainActorMessage {
    typealias Subject = NSObject
    let draft: String
}
