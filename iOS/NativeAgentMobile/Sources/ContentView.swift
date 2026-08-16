// PATCH-2026-05-07: ios-parity ContentView — focused bottom TabView.
// Primary tabs stay below iOS overflow; advanced/workspace surfaces live behind More.
// Design-system pass: accent tint applied to TabView selection color.
// PATCH-2026-05-09: skill-lifecycle-ios — Skills tab added (SkillLifecycleView)
// PATCH-2026-05-09: proactive-inbox-ios — Inbox tab added (InboxView + InboxStore)
// PATCH-2026-05-10: sidebar-flatten — collapse the former 6-tab layout
// Approvals / Inbox / Settings / More) into 5 (Chat / Activity / Memories /
// Skills / More).  Activity links to separate Approvals / Inbox / Memory
// Proposals / Self-Improvement queues.  More becomes a flat NavigationLink list of
// single-purpose destinations (no nested hubs).
// PATCH-2026-06-07: mac-integration-tab-ios — route "mac_integration" and
// "macintegration" launch-arg / notification-screen aliases land on the More
// tab (where the new MacIntegrationView lives under Manage). The view itself
// is reached one tap deeper; collapsing it into a primary tab would break the
// 5-tab geometry and the Tab-enum-driven badge/notification routing.
import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var sync = iCloudSyncEngine.shared

    // Shared stores so the tab badges stay in sync with the views' stores
    @StateObject private var approvalsStore = ApprovalsStore()
    @StateObject private var inboxStore = InboxStore()

    @State private var selection: Tab = ContentView.initialTabFromLaunchArgs()
    @State private var isRefreshingActivityBadges = false
    @State private var skipNextActivityInitialRefresh = false
    @State private var openedFromNotificationLaunch = NativeAgentNotificationLaunchIntent.hasPendingOpenActivity
    @State private var notificationOpenRefreshTask: Task<Void, Never>? = nil
    @State private var lastNotificationOpenAt: Date = .distantPast
    @State private var suppressActivityRefreshUntil: Date = .distantPast

    enum Tab: Hashable {
        case chat, activity, memories, skills, more
    }

    private var activityBadgeCount: Int {
        let approvalCount = max(
            approvalsStore.pendingCount,
            sync.approvals.filter { $0.status.lowercased() == "pending" }.count
        )
        let inboxCount = max(
            inboxStore.activeCount,
            sync.inboxItems.filter {
                let status = $0.status.lowercased()
                return status == "active" || status == "unread"
            }.count
        )
        return approvalCount
            + inboxCount
            + sync.memoryProposals.filter(\.isPending).count
            + sync.trainingProposals.filter(\.isHumanActionable).count
            + sync.promotionCandidates.filter(\.isHumanActionable).count
    }

    /// Parse `-initialTab <name>` from process arguments.  Legacy names route
    /// to their new homes so existing UI tests keep landing in the right place.
    private static func initialTabFromLaunchArgs() -> Tab {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-initialTab"), idx + 1 < args.count else {
            return .chat
        }
        switch args[idx + 1].lowercased() {
        case "chat": return .chat
        case "activity", "approvals", "inbox": return .activity
        case "memory", "memories": return .memories
        case "skills": return .skills
        case "missions", "workshop", "more", "advanced", "settings": return .more
        case "mac_integration", "macintegration", "mac-integration": return .more
        default: return .chat
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(Tab.chat)

            ActivityView(skipInitialRefresh: $skipNextActivityInitialRefresh)
                .environmentObject(approvalsStore)
                .environmentObject(inboxStore)
                .tabItem {
                    Label("Activity", systemImage: "tray.full")
                }
                .badge(activityBadgeCount)
                .tag(Tab.activity)

            MemoryView()
                .tabItem {
                    Label("Memories", systemImage: "brain")
                }
                .tag(Tab.memories)

            SkillsToolsView()
                .tabItem {
                    Label("Skills", systemImage: "puzzlepiece.extension")
                }
                .tag(Tab.skills)

            AdvancedView()
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .tag(Tab.more)
        }
        .tint(NativeAgentPalette.agentAccent)
        .safeAreaInset(edge: .bottom) {
            // PATCH-2026-06-06: iOS SystemToast parity. safeAreaInset(.bottom)
            // pushes the toast bar above the TabView/home indicator without
            // hand-rolled offsets (the system handles iPhone home-indicator
            // vs iPad geometry differences). iOSSystemToastCenter.shared is
            // pushed from any view surfacing a transient banner (inline
            // approval decisions, remote model-picker changes, and action results).
            // gpt-5.5 review finding #4: replaced fixed 56pt overlay padding
            // with a safe-area-aware inset, and dropped the redundant
            // .allowsHitTesting wrapper (the bar's own gate already skips
            // hit-testing when the queue is empty).
            iOSSystemToastBar(center: iOSSystemToastCenter.shared)
        }
        .onAppear {
            consumePendingNotificationOpenIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeagentOpenActivity)) { note in
            let screen = (note.userInfo?["screen"] as? String) ?? "activity"
            openActivityFromNotification(screen: screen)
        }
        .onChange(of: sync.approvals) { _, _ in
            approvalsStore.applySyncedApprovalsFromSnapshot(
                animated: true,
                notifyNewPending: true
            )
        }
        .onChange(of: sync.inboxItems) { _, _ in
            inboxStore.applySyncedInboxFromSnapshot(
                animated: true,
                notifyNewArrivals: true
            )
            Task {
                await NativeAgentActivityNotificationCleaner.pruneDeliveredNotifications(
                    activeInboxItems: inboxStore.items
                )
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
            // CloudKit/KVS snapshot groups are owner-driven. Retain the sampled
            // fallback only for the legacy direct bridge, which has no complete
            // snapshot publication owner.
            while !Task.isCancelled, !pairingStore.usesICloudTransport {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
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
        if let screen = NativeAgentNotificationLaunchIntent.consumePendingScreen() {
            openActivityFromNotification(screen: screen)
        }
    }

    /// F7: maps a notification payload `screen` to a top-level tab.
    private func tab(forNotificationScreen screen: String) -> Tab {
        switch screen.lowercased() {
        case "chat": return .chat
        case "memories", "memory": return .memories
        case "skills": return .skills
        case "more", "settings", "advanced": return .more
        case "mac_integration", "macintegration", "mac-integration": return .more
        case "activity", "approvals", "inbox": return .activity
        default: return .activity
        }
    }

    @MainActor
    private func openActivityFromNotification(screen: String = "activity") {
        _ = NativeAgentNotificationLaunchIntent.consumeOpenActivityPending()
        let target = tab(forNotificationScreen: screen)
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
            await refreshActivityBadges(pruneNotifications: false, animated: false, notifyNewActivity: false)
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
        animated: Bool = true,
        notifyNewActivity: Bool = true
    ) async {
        guard !isRefreshingActivityBadges else { return }
        isRefreshingActivityBadges = true
        defer { isRefreshingActivityBadges = false }
        await sync.refreshActivitySnapshot()
        if pairingStore.usesICloudTransport {
            approvalsStore.applySyncedApprovalsFromSnapshot(
                animated: animated,
                notifyNewPending: notifyNewActivity
            )
            inboxStore.applySyncedInboxFromSnapshot(
                animated: animated,
                notifyNewArrivals: notifyNewActivity
            )
        } else {
            await approvalsStore.refresh(client: bridgeClient, pairingStore: pairingStore)
            await inboxStore.refresh(client: bridgeClient, pairingStore: pairingStore)
        }
        if pruneNotifications {
            await NativeAgentActivityNotificationCleaner.pruneDeliveredNotifications(activeInboxItems: inboxStore.items)
        }
    }
}

enum NativeAgentActivityNotificationCleaner {
    static func pruneDeliveredNotifications(activeInboxItems: [InboxItemRecord]) async {
        let activeItemIDs = Set(activeInboxItems.filter { $0.isUnread }.map(\.id))
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        var removeIDs: [String] = []

        for notification in delivered {
            let content = notification.request.content
            let info = normalizedNativeAgentInfo(content.userInfo)
            guard isNativeAgentActivityNotification(info) else { continue }

            if let itemID = infoString("itemId", in: info), !itemID.isEmpty {
                if !activeItemIDs.contains(itemID) {
                    removeIDs.append(notification.request.identifier)
                }
                continue
            }

            let source = infoString("source", in: info) ?? ""
            if source == "scheduler_job_ran"
                || source == "proactive_autonomy"
                || source.hasPrefix("proactive_autonomy:")
                || source.hasPrefix("autonomy_maintenance:") {
                removeIDs.append(notification.request.identifier)
            }
        }

        if !removeIDs.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: removeIDs)
        }

        let badgeCount = activeItemIDs.count
        if #available(iOS 16.0, *) {
            try? await center.setBadgeCount(badgeCount)
        } else {
            await MainActor.run {
                UIApplication.shared.applicationIconBadgeNumber = badgeCount
            }
        }
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
        return infoString("itemId", in: info) != nil || infoString("source", in: info) != nil
    }

    private static func infoString(_ key: String, in info: [AnyHashable: Any]) -> String? {
        if let value = info[AnyHashable(key)] {
            return String(describing: value)
        }
        return nil
    }
}
