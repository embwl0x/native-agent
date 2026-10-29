import SwiftUI
import NativeAgentShared
import UIKit
import UserNotifications

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var phoneRequests = PhoneRequests.shared
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(HazeColor.key) private var hazeColorRaw = HazeColor.defaultValue.rawValue
    @EnvironmentObject private var pairingStore: PairingStore
    private let sync = iCloudSyncEngine.shared

    // Shared stores so the tab badges stay in sync with the views' stores
    @StateObject private var approvalsStore = ApprovalsStore()
    @StateObject private var inboxStore = InboxStore()

    @State private var selection: Tab = ContentView.initialTabFromLaunchArgs()
    @State private var isRefreshingActivityBadges = false
    @State private var skipNextActivityInitialRefresh = false
    @State private var openedFromNotificationLaunch = NativeAgentNotificationLaunchIntent.isPending
    @State private var notificationOpenRefreshTask: Task<Void, Never>? = nil
    @State private var lastNotificationOpenAt: Date = .distantPast
    @State private var suppressActivityRefreshUntil: Date = .distantPast
    @State private var activityNavigationTarget: ActivitySection?
    @State private var notifiedSessionID: String?
    @State private var notifiedDeskHandle: String?
    @State private var deskTaskNavigationTarget: NativeAgentNotificationLaunchIntent?

    enum Tab: Hashable {
        case chat, activity, memories, desk, more
    }

    private var activityBadgeCount: Int? {
        guard let overview = sync.workOverview, overview.unavailable.isEmpty else { return nil }
        return overview.needsYouCount
    }

    /// Parse `-initialTab <name>`, retaining legacy screen aliases.
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
                if try await !chatStore.readSharedInbox().items.isEmpty { selection = .chat }
            } catch { chatStore.errorBanner = "Sharing is unavailable: \(error.localizedDescription)" }
        }
    }

    var body: some View {
        tabContent
            .sheet(item: Binding(get: { phoneRequests.active }, set: { _ in })) { request in
                PhoneRequestSheet(request: request)
            }
            .task { await phoneRequests.resume() }
            .onChange(of: selection, initial: true) { before, after in
                sync.foregroundSnapshotGroup = switch after {
                case .chat: .chat
                case .activity, .memories: .activity
                case .desk: .desk
                case .more: .advanced
                }
                if before != after, after == .more {
                    Task {
                        _ = await sync.refreshCatalogSnapshot()
                        await sync.refreshSnapshotGroup(.advanced)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await phoneRequests.resume() } }
            }
            .alert("Phone request", isPresented: Binding(
                get: { phoneRequests.errorMessage != nil },
                set: { if !$0 { phoneRequests.errorMessage = nil } }
            )) { Button("OK") { phoneRequests.errorMessage = nil } }
            message: { Text(phoneRequests.errorMessage ?? "") }
    }

    private var tabContent: some View {
        TabView(selection: $selection) {
            ChatView(notifiedSessionID: $notifiedSessionID)
                .environmentObject(approvalsStore)
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.chat)

            ActivityView(
                skipInitialRefresh: $skipNextActivityInitialRefresh,
                navigationTarget: $activityNavigationTarget
            )
                .environmentObject(approvalsStore)
                .environmentObject(inboxStore)
                .tabItem {
                    Label("Activity", systemImage: "tray")
                    .environment(\.symbolVariants, .none)
                }
                .badge(activityBadgeCount.flatMap { $0 > 0 ? String($0) : nil })
                .tag(Tab.activity)

            MemoryView()
                .tabItem {
                    Label("Memories", systemImage: "brain")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.memories)

            NavigationStack {
                // More → Desk pushes WorkshopView inside More's navigation stack
                // for directed work; this tab opens the canonical Desk board.
                // The More route keeps More selected and does not switch to this tab.
                MobileDeskView(notifiedHandle: $notifiedDeskHandle)
            }
                .tabItem {
                    Label("Desk", systemImage: "rectangle.3.group")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.desk)

            // AdvancedView's own title names the page; no second label above it.
            AdvancedView(deskTaskNavigationTarget: $deskTaskNavigationTarget)
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                    .environment(\.symbolVariants, .none)
                }
                .tag(Tab.more)
        }
        .tint(HazeColor(stored: hazeColorRaw).control(dark: colorScheme == .dark, labelled: false))
        // Outlined tab glyphs keep one weight; tint and the selection pill indicate the active tab.
        .environment(\.symbolVariants, .none)
        .onAppear {
            openSharedChatIfNeeded()
            if MobileQuickAskRoute.isPending { selection = .chat }
        }
        .onReceive(NotificationCenter.default.publisher(for: MobileQuickAskRoute.notification)) { _ in
            selection = .chat
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                openSharedChatIfNeeded()
                if MobileQuickAskRoute.isPending { selection = .chat }
            }
        }
        .overlay(alignment: .top) {
            // Top toasts avoid the tab bar and composer; an empty overlay neither shifts layout nor intercepts taps.
            iOSSystemToastBar(center: SystemToastCenter.shared)
        }
        .onAppear {
            consumePendingNotificationOpenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeagentOpenActivity)) { _ in
            consumePendingNotificationOpenIfNeeded()
        }
        .onChange(of: sync.approvals) { _, _ in
            approvalsStore.applySyncedApprovalsFromSnapshot(
                notifyNewPending: true
            )
            Task {
                await pruneActivityNotifications()
            }
        }
        .onChange(of: activityBadgeCount, initial: true) { _, count in
            Task {
                // An unavailable count has no badge, just as on the tab.
                do { try await UNUserNotificationCenter.current().setBadgeCount(count ?? 0) }
                catch { NSLog("[Activity] badge update failed: %@", error.localizedDescription) }
            }
        }
        .onChange(of: sync.inboxItems) { _, _ in
            approvalsStore.applySyncedApprovalsFromSnapshot(
                notifyNewPending: true
            )
            inboxStore.applySyncedInboxFromSnapshot(
                notifyNewArrivals: true
            )
            Task {
                await pruneActivityNotifications()
            }
        }
        .task {
            if openedFromNotificationLaunch {
                // Let the launch/tap transition settle before touching iCloud
                // snapshots or UNUserNotificationCenter again.
                try? await Task.sleep(nanoseconds: 900_000_000)
            } else {
                await refreshActivityBadgesIfAllowed()
            }
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

    /// Known destinations share aliases; each ingress owns its unknown-input default.
    private static func tab(forScreen screen: String) -> Tab? {
        switch screen.lowercased() {
        case "chat": return .chat
        case "memories", "memory": return .memories
        case "desk": return .desk
        case "skills": return .more
        case "workshop", "missions": return .more
        case "more", "settings", "advanced": return .more
        case "mac_integration", "macintegration", "mac-integration": return .more
        case "activity", "approvals", "inbox": return .activity
        default: return nil
        }
    }

    @MainActor
    private func openActivityFromNotification(_ destination: NativeAgentNotificationLaunchIntent) {
        let screen = destination.screen
        let target = Self.tab(forScreen: screen) ?? .activity
        notifiedSessionID = destination.sessionID
        notifiedDeskHandle = screen == "desk" ? destination.taskID : nil
        if screen == "workshop" { deskTaskNavigationTarget = destination }
        activityNavigationTarget = target == .activity
            ? ActivityScreenPresentation.activityDestination(for: screen)
            : nil
        let now = Date()
        if now.timeIntervalSince(lastNotificationOpenAt) < 1.0 {
            selection = target
            return
        }
        lastNotificationOpenAt = now
        openedFromNotificationLaunch = true
        skipNextActivityInitialRefresh = (target == .activity)
        suppressActivityRefreshUntil = now.addingTimeInterval(2.0)
        selection = target

        notificationOpenRefreshTask?.cancel()
        notificationOpenRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_250_000_000)
            guard !Task.isCancelled else { return }
            await refreshActivityBadges(pruneNotifications: false, notifyNewActivity: false)
            openedFromNotificationLaunch = false
        }
    }

    @MainActor
    private func refreshActivityBadgesIfAllowed() async {
        guard Date() >= suppressActivityRefreshUntil else { return }
        await refreshActivityBadges()
    }

    @MainActor
    private func refreshActivityBadges(
        pruneNotifications: Bool = true,
        notifyNewActivity: Bool = true
    ) async {
        guard !isRefreshingActivityBadges else { return }
        isRefreshingActivityBadges = true
        defer { isRefreshingActivityBadges = false }
        await sync.refreshActivitySnapshot()
        if pairingStore.usesICloudTransport {
            approvalsStore.applySyncedApprovalsFromSnapshot(
                notifyNewPending: notifyNewActivity
            )
            inboxStore.applySyncedInboxFromSnapshot(
                notifyNewArrivals: notifyNewActivity
            )
        }
        if pruneNotifications {
            await pruneActivityNotifications()
        }
    }

    @MainActor
    private func pruneActivityNotifications() async {
        await NativeAgentActivityNotificationCleaner.pruneDeliveredNotifications(
            activeInboxItems: sync.inboxSnapshotLoaded ? inboxStore.items : nil,
            pendingApprovalIDs: sync.approvalsSnapshotLoaded
                ? Set(approvalsStore.approvals.filter { $0.outcome == .pending }.map(\.id))
                : nil
        )
    }
}

enum NativeAgentActivityNotificationCleaner {
    /// A missing queue is unavailable; only a successfully read empty queue
    /// proves that its delivered notifications have resolved.
    static func pruneDeliveredNotifications(activeInboxItems: [InboxItemRecord]?, pendingApprovalIDs: Set<String>?) async {
        guard activeInboxItems != nil || pendingApprovalIDs != nil else { return }
        let activeItemIDs = activeInboxItems.map { Set($0.filter { $0.isUnread }.map(\.id)) }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let idsToRemove = notificationIDsToRemove(
            activeItemIDs: activeItemIDs,
            pendingApprovalIDs: pendingApprovalIDs,
            deliveredNotifications: delivered
        )

        if !idsToRemove.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
        }
    }

    private static func notificationIDsToRemove(
        activeItemIDs: Set<String>?,
        pendingApprovalIDs: Set<String>?,
        deliveredNotifications: [UNNotification]
    ) -> [String] {
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
                if let activeItemIDs, !activeItemIDs.contains(itemID) {
                    removeIDs.append(notification.request.identifier)
                }
                continue
            }

            // A NativeAgent activity notification without an inbox identity
            // cannot be reconciled once the inbox snapshot is available.
            // Retaining it via a source-prefix allowlist leaks stale alerts
            // whenever a new Mac publisher is introduced.
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
