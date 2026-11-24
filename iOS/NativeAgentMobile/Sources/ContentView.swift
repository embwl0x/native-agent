import SwiftUI
import NativeAgentShared
import UIKit
import UserNotifications

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let phoneRequests = PhoneRequests.shared
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(HazeColor.key) private var hazeColorRaw = HazeColor.defaultValue.rawValue
    @Environment(PairingStore.self) private var pairingStore
    @Environment(MacBridgeClient.self) private var bridgeClient
    @Environment(VoiceInputController.self) private var voiceInput
    @Environment(VoiceOutputController.self) private var voiceOutput
    private let talk = TalkModeController.shared
    private let sync = iCloudSyncEngine.shared

    @State private var inboxStore = InboxStore()

    @State private var selection: Tab = ContentView.initialTabFromLaunchArgs()
    @State private var notificationOpenRefreshTask: Task<Void, Never>? = nil
    @State private var activityNavigationTarget: ActivitySection?
    /// A card a face's link asked Today to open.
    @State private var activityCardID: String?
    @Environment(\.openURL) private var openURL
    @State private var notifiedSessionID: String?
    @State private var opensMemories = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-initialTab"), args.indices.contains(index + 1) else { return false }
        return ["memory", "memories"].contains(args[index + 1].lowercased())
    }()

    enum Tab: Hashable {
        case chat, activity, desk, settings, more
    }

    private var activityBadgeCount: Int? {
        guard let overview = sync.workOverview, overview.unavailable.isEmpty else { return nil }
        return overview.needsYouCount
    }

    private var isOpeningNotification: Bool {
        notificationOpenRefreshTask != nil || NativeAgentNotificationLaunchIntent.isPending
    }

    private static func initialTabFromLaunchArgs() -> Tab {
        initialTab(fromLaunchArguments: ProcessInfo.processInfo.arguments)
    }

    static func initialTab(fromLaunchArguments arguments: [String]) -> Tab {
        guard let idx = arguments.firstIndex(of: "-initialTab"), idx + 1 < arguments.count else {
            return .chat
        }
        return tab(forScreen: arguments[idx + 1]) ?? .chat
    }

    private func openSharedChatIfNeeded() {
        Task {
            do {
                // Choosing the tab needs only whether a share waits, never every attachment decoded.
                if try await Task.detached(priority: .utility) { try !SharedChatInbox.pendingFiles().isEmpty }.value { selection = .chat }
            } catch { chatStore.errorBanner = "Sharing is unavailable: \(error.localizedDescription)" }
        }
    }

    var body: some View {
        tabContent
            .fullScreenCover(isPresented: Binding(get: { talk.isPresented }, set: { if !$0 { talk.end() } })) {
                TalkModeView(talk: talk)
            }
            .onAppear { consumePendingTalk() }
            .onMessage(MobileTalkRoute.Requested.self) { _ in consumePendingTalk() }
            .onChange(of: chatStore.isSwitchingSession) { _, switching in if !switching { consumePendingTalk() } }
            .onChange(of: pairingStore.iCloudPairingSecret) { _, _ in
                talk.end(reason: "Talk ended because the Mac pairing changed.")
            }
            .onChange(of: sync.voicePreference) { _, preference in
                if preference?.quiet == true { voiceOutput.stop(); talk.quietPreferenceChanged() }
            }
            .sheet(item: Binding(get: { phoneRequests.presented }, set: { _ in })) { request in
                PhoneRequestSheet(request: request)
                    .id(request.id)
            }
            .task { await phoneRequests.resume() }
            .onChange(of: selection, initial: true) { before, after in
                sync.foregroundSnapshotGroup = switch after {
                case .chat: .chat
                case .activity: .activity
                case .desk: .desk
                case .settings, .more: .advanced
                }
                if before != after, after == .more {
                    Task { await sync.refreshSnapshotGroup(.advanced) }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    consumePendingTalk()
                    Task { await phoneRequests.resume() }
                }
            }
            .alert("Phone request", isPresented: Binding(
                get: { phoneRequests.errorMessage != nil },
                set: { if !$0 { phoneRequests.errorMessage = nil } }
            )) { Button("OK") { phoneRequests.errorMessage = nil } }
            message: { Text(phoneRequests.errorMessage ?? "") }
    }

    private func consumePendingTalk() {
        guard scenePhase == .active, !chatStore.isSwitchingSession, MobileTalkRoute.consume() else { return }
        selection = .chat
        voiceInput.cancel(); voiceOutput.stop()
        let model = sync.surfaceModels["ios"]
        let controls = ChatRuntimeControls(model: model?.model ?? "", reasoningEffort: model?.reasoningEffort ?? "high",
            serviceTier: model?.serviceTier ?? "default",
            fileAccess: ChatRuntimeControlPresentation.normalizedFileAccessID(UserDefaults.standard.string(forKey: "chatFileAccess") ?? "auto"),
            providerId: model?.providerID ?? "")
        talk.begin(client: bridgeClient, controls: controls)
    }

    /// A face's link to a place of the shell: a conversation in Chat, Today's queues and cards, the Desk, the browser. Answers the words for a
    /// place this phone does not have.
    private func followFaceLink(_ link: String) -> String? {
        guard let target = FaceLink(link) else { return "This row has no destination on iPhone." }
        switch target {
        case .chat(let session):
            notifiedSessionID = session
            selection = .chat
        case .approval:
            activityNavigationTarget = .inbox
            selection = .activity
        case .card(let id):
            activityCardID = id
            selection = .activity
        case .url(let url):
            openURL(url)
        case .page("today", let item?):
            // Approvals and notes are one Inbox, as on the Mac.
            guard let section = item == "approvals" ? .inbox : ActivitySection(rawValue: item) else {
                return "This queue opens on your Mac."
            }
            activityNavigationTarget = section
            selection = .activity
        case .page("today", nil):
            selection = .activity
        case .page("desk", _):
            selection = .desk
        case .page("memory_proposals", _):
            // The Memories face carries what waits to be kept, with Keep and Don't keep on each.
            opensMemories = true
            selection = .more
        case .page(let page, _):
            // A page is named by its own face; a page the phone has never read keeps its catalog name.
            return (sync.faces[page]?.face?.title ?? QuietToolPage.page(named: page)?.title ?? page) + " opens on your Mac."
        case .dream:
            return "This opens on your Mac."
        }
        return nil
    }

    private var tabContent: some View {
        TabView(selection: $selection) {
            ChatView(notifiedSessionID: $notifiedSessionID)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.chat)

            ActivityView(
                navigationTarget: $activityNavigationTarget,
                cardTarget: $activityCardID
            )
                .environment(inboxStore)
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                    .environment(\.symbolVariants, .none)
                }
                .badge(activityBadgeCount.flatMap { $0 > 0 ? String($0) : nil })
                .tag(Tab.activity)

            NavigationStack {
                // Directed work stays inside More's navigation stack; the Desk tab owns the canonical board.
                MobileFacePage(page: "desk", style: .root)
            }
                .macSyncErrorBanner()
                .tabItem {
                    Label("Desk", systemImage: "rectangle.3.group")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.desk)

            NavigationStack { SettingsViewFull(presentation: .root) }
                .macSyncErrorBanner()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.settings)

            AdvancedView(opensMemories: $opensMemories)
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.more)
        }
        .tint(HazeColor(stored: hazeColorRaw).control(dark: colorScheme == .dark, labelled: false))
        .environment(\.symbolVariants, .none)
        .environment(\.faceRouter, FaceRouter(follow: followFaceLink))
        .onAppear {
            openSharedChatIfNeeded()
            if MobileQuickAskRoute.isPending { selection = .chat }
        }
        .onMessage(MobileQuickAskRoute.Requested.self) { _ in
            selection = .chat
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                openSharedChatIfNeeded()
                if MobileQuickAskRoute.isPending { selection = .chat }
            }
        }
        .overlay(alignment: .top) {
            // Top toasts avoid composer/tab controls; an empty overlay must neither move content nor intercept taps.
            iOSSystemToastBar(center: SystemToastCenter.shared)
        }
        .onAppear {
            consumePendingNotificationOpenIfNeeded()
        }
        .onMessage(NativeAgentNotificationLaunchIntent.Staged.self) { _ in
            consumePendingNotificationOpenIfNeeded()
        }
        .onChange(of: sync.approvals) { _, _ in
            Task {
                await pruneActivityNotifications()
            }
        }
        .onChange(of: activityBadgeCount, initial: true) { _, count in
            Task {
                do { try await UNUserNotificationCenter.current().setBadgeCount(count ?? 0) }
                catch { NSLog("[Activity] badge update failed: %@", error.localizedDescription) }
            }
        }
        .onChange(of: sync.inboxItems) { _, _ in
            inboxStore.applySyncedInboxFromSnapshot()
            Task {
                await pruneActivityNotifications()
            }
        }
        .task {
            guard !isOpeningNotification else { return }
            await sync.refreshActivitySnapshot()
            await pruneActivityNotifications()
        }
        .onDisappear {
            notificationOpenRefreshTask?.cancel()
            notificationOpenRefreshTask = nil
        }
    }

    @MainActor
    private func consumePendingNotificationOpenIfNeeded() {
        if let destination = NativeAgentNotificationLaunchIntent.consume() {
            openActivityFromNotification(destination)
        }
    }

    private static func tab(forScreen screen: String) -> Tab? {
        switch screen.lowercased() {
        case "chat": return .chat
        case "memories", "memory": return .more
        case "desk": return .desk
        case "skills": return .more
        case "settings": return .settings
        case "more": return .more
        case "mac_integration", "macintegration", "mac-integration": return .more
        case "activity", "approvals", "inbox": return .activity
        default: return nil
        }
    }

    @MainActor
    private func openActivityFromNotification(_ destination: NativeAgentNotificationLaunchIntent) {
        let screen = destination.screen
        let target = Self.tab(forScreen: screen) ?? .activity
        if ["memory", "memories"].contains(screen.lowercased()) { opensMemories = true }
        notifiedSessionID = destination.sessionID
        activityNavigationTarget = target == .activity
            ? ActivityScreenPresentation.activityDestination(for: screen)
            : nil
        selection = target

        notificationOpenRefreshTask?.cancel()
        notificationOpenRefreshTask = Task { @MainActor in
            await iCloudBridge.shared.drainDeviceTransport()
            if !Task.isCancelled { notificationOpenRefreshTask = nil }
        }
    }

    @MainActor
    private func pruneActivityNotifications() async {
        guard !Task.isCancelled, !isOpeningNotification,
              sync.inboxSnapshotLoaded || sync.approvalsSnapshotLoaded else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        guard !Task.isCancelled, !isOpeningNotification else { return }
        let idsToRemove = NativeAgentActivityNotificationCleaner.notificationIDsToRemove(
            activeInboxItems: sync.inboxSnapshotLoaded ? inboxStore.items : nil,
            pendingApprovalIDs: sync.approvalsSnapshotLoaded
                ? Set(sync.approvals.filter { $0.outcome == .pending }.map(\.id))
                : nil,
            deliveredNotifications: delivered
        )
        if !idsToRemove.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
        }
    }
}

enum NativeAgentActivityNotificationCleaner {
    /// Only a successfully read empty queue proves resolution; a missing queue remains unavailable.
    static func notificationIDsToRemove(
        activeInboxItems: [InboxItemRecord]?,
        pendingApprovalIDs: Set<String>?,
        deliveredNotifications: [UNNotification]
    ) -> [String] {
        let activeItemIDs = activeInboxItems.map { Set($0.filter { $0.isUnread }.map(\.id)) }
        var removeIDs: [String] = []

        for notification in deliveredNotifications {
            let info = normalizedNativeAgentInfo(notification.request.content.userInfo)
            guard isNativeAgentActivityNotification(info) else { continue }

            if let approvalID = infoString("approvalId", in: info), !approvalID.isEmpty {
                if let pendingApprovalIDs, !pendingApprovalIDs.contains(approvalID) {
                    removeIDs.append(notification.request.identifier)
                }
                continue
            }

            if let itemID = infoString("itemId", in: info), !itemID.isEmpty {
                // A result that lives in a chat is never an Inbox row, so the Inbox cannot say it was read.
                if let session = infoString("sessionId", in: info), !session.isEmpty { continue }
                if let activeItemIDs, !activeItemIDs.contains(itemID) {
                    removeIDs.append(notification.request.identifier)
                }
                continue
            }

            // Without inbox identity an activity alert cannot reconcile; source allowlists would retain stale alerts from newly added publishers.
            if activeItemIDs != nil {
                removeIDs.append(notification.request.identifier)
            }
        }

        return removeIDs
    }

    private static func normalizedNativeAgentInfo(_ userInfo: [AnyHashable: Any]) -> [AnyHashable: Any] {
        if let nested = userInfo["nativeagent"] as? [AnyHashable: Any] {
            return nested
        }
        if let nested = userInfo["nativeagent"] as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: nested.map { (AnyHashable($0.key), $0.value) })
        }
        return userInfo
    }

    private static func isNativeAgentActivityNotification(_ info: [AnyHashable: Any]) -> Bool {
        if infoString("screen", in: info) == "activity" { return true }
        return infoString("itemId", in: info) != nil || infoString("approvalId", in: info) != nil
    }

    private static func infoString(_ key: String, in info: [AnyHashable: Any]) -> String? {
        if let value = info[AnyHashable(key)] {
            return String(describing: value)
        }
        return nil
    }
}
