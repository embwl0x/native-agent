// InboxView.swift — iOS proactive agent inbox surface.
//
// Reads the iCloud inbox snapshot while visible; pull-to-refresh also works.
// Dismiss and supported action operations are signed iCloud bridge messages
// that the Mac app applies through the in-process Swift runtime.
// UNUserNotificationCenter fires a local notification when a new card arrives
// in the foreground while the user is NOT on this tab.
//
// Inbox snapshot shape:
//   id, created_at, source, severity (info|important|actionable),
//   title, summary, detail?, related_mission_id?, related_approval_id?,
//   related_paths?, related_groups?, actions[], status, read_at?
//
// Severity → tint:
//   info        → NativeAgentPalette.agentAccent
//   important   → .blue (matches Mac InboxView)
//   actionable  → .orange

import SwiftUI
import UserNotifications
import NativeAgentShared


// MARK: - Store

@MainActor
final class InboxStore: ObservableObject {
    @Published var items: [InboxItemRecord] = []
    @Published var isLoading = false
    @Published var bannerError: String? = nil

    // Known IDs from previous fetch — used for new-card detection
    private var knownIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "NativeAgentMobile.inboxKnownIDs") ?? [])
    // Whether we are currently on the Inbox tab (caller sets this)
    var isVisible: Bool = false
    private let notificationScheduler: ((InboxLocalNotificationPlan, Int) -> Void)?

    init(notificationScheduler: ((InboxLocalNotificationPlan, Int) -> Void)? = nil) {
        self.notificationScheduler = notificationScheduler
    }

    var activeCount: Int {
        items.filter { $0.isUnread }.count
    }

    var tabBadge: String? {
        activeCount > 0 ? "\(activeCount)" : nil
    }

    // MARK: - Fetch

    func refresh(client: MacBridgeClient, pairingStore: PairingStore) async {
        isLoading = true
        defer { isLoading = false }
        guard pairingStore.usesICloudTransport else {
            bannerError = "Pair to view"
            applyFetchedItems([])
            return
        }
        await iCloudSyncEngine.shared.refreshInboxSnapshot()
        applySyncedInboxFromSnapshot()
    }

    func applySyncedInboxFromSnapshot(animated: Bool = true, notifyNewArrivals: Bool = true) {
        let fetched = iCloudSyncEngine.shared.inboxItems
        NSLog("[InboxStore] refresh via iCloud fetched=%d", fetched.count)
        if shouldIgnoreTransientEmptySnapshot(
            fetched: fetched,
            snapshotLoaded: iCloudSyncEngine.shared.inboxSnapshotLoaded
        ) {
            NSLog("[InboxStore] ignoring transient empty iCloud inbox before first snapshot load known=%d current=%d", knownIDs.count, items.count)
            bannerError = iCloudSyncEngine.shared.syncError
            return
        }
        applyFetchedItems(fetched, animated: animated, notifyNewArrivals: notifyNewArrivals)
        bannerError = iCloudSyncEngine.shared.syncError
    }

    // MARK: - Actions

    func dismiss(id: String, client: MacBridgeClient, pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else { bannerError = "Pair to view"; return }
        do {
            _ = try await iCloudSyncEngine.shared.inboxAction(itemId: id, actionId: "dismiss")
            await refresh(client: client, pairingStore: pairingStore)
        } catch {
            bannerError = "Failed to dismiss: \(error.localizedDescription)"
        }
    }

    func act(id: String, client: MacBridgeClient, pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else { bannerError = "Pair to view"; return }
        do {
            _ = try await iCloudSyncEngine.shared.inboxAction(itemId: id, actionId: "act")
            await refresh(client: client, pairingStore: pairingStore)
        } catch {
            bannerError = "Failed to act: \(error.localizedDescription)"
        }
    }

    func performAction(id: String, actionID: String, client: MacBridgeClient, pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else { bannerError = "Pair to view"; return }
        do {
            _ = try await iCloudSyncEngine.shared.inboxAction(itemId: id, actionId: actionID)
            applySuccessfulLocalAction(id: id, actionID: actionID)
            await refresh(client: client, pairingStore: pairingStore)
        } catch {
            bannerError = "Failed: \(error.localizedDescription)"
        }
    }

    /// Project an already accepted Mac action while the next signed snapshot
    /// catches up. This does not treat a transport acknowledgement as success.
    func applySuccessfulLocalAction(id: String, actionID: String) {
        let nextStatus: String?
        switch actionID {
        case "archive", "repair":
            nextStatus = "archived"
        case "dismiss":
            nextStatus = "dismissed"
        case "act", "approve", "reject", "deny", "read":
            nextStatus = "read"
        default:
            nextStatus = nil
        }
        guard let nextStatus else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        items = items.map { item in
            guard item.id == id else { return item }
            return item.replacingStatus(nextStatus, readAt: item.read_at ?? now)
        }
    }

    func applyFetchedItems(
        _ fetched: [InboxItemRecord],
        animated: Bool = true,
        notifyNewArrivals: Bool = true
    ) {
        let fetchedUnread = fetched.filter { $0.isUnread }

        // Detect new arrivals for local notifications.
        //
        // 2026-05-09 fix: defense-in-depth against SpringBoard storms.
        // The first-poll guard (!knownIDs.isEmpty) prevents the obvious
        // case where every existing card looks "new" on cold launch.
        // But a Mac-side burst (e.g. Auto-Doctor batch-publishing 50
        // cards in one tick) would still fire 50 simultaneous local
        // notifications, which can wedge SpringBoard's notification UI.
        // Cap individual fires per refresh. A larger batch becomes one
        // summary notification, preserving the safety limit without making a
        // batch-only Mac publisher invisible to the person using the phone.
        let fetchedIDs = Set(fetchedUnread.map { $0.id })
        let newIDs = fetchedIDs.subtracting(knownIDs)
        NSLog("[InboxStore] apply fetched=%d unread=%d known=%d new=%d visible=%@", fetched.count, fetchedUnread.count, knownIDs.count, newIDs.count, isVisible ? "true" : "false")
        let notificationPlan: InboxLocalNotificationPlan
        if notifyNewArrivals && !knownIDs.isEmpty && !newIDs.isEmpty {
            notificationPlan = InboxNotificationBurstPresentation.plan(
                newUnreadItems: fetchedUnread.filter { newIDs.contains($0.id) },
                isInboxVisible: isVisible
            )
        } else {
            notificationPlan = .none
        }
        knownIDs = fetchedIDs
        UserDefaults.standard.set(Array(Array(fetchedIDs).sorted().suffix(500)), forKey: "NativeAgentMobile.inboxKnownIDs")

        if animated {
            withAnimation(AppMotion.snappy) { items = fetched }
        } else {
            items = fetched
        }
        scheduleLocalNotifications(notificationPlan, badgeCount: activeCount)
    }

    func shouldIgnoreTransientEmptySnapshot(fetched: [InboxItemRecord], snapshotLoaded: Bool) -> Bool {
        fetched.isEmpty && !snapshotLoaded && (!knownIDs.isEmpty || !items.isEmpty)
    }

    #if DEBUG
    func debugKnownIDs() -> Set<String> {
        knownIDs
    }
    #endif

    // MARK: - Local notifications

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                NSLog("[InboxStore] notification authorization error: %@", error.localizedDescription)
            }
            NSLog("[InboxStore] notification authorization granted=%@", granted ? "true" : "false")
        }
    }

    private func scheduleLocalNotifications(_ plan: InboxLocalNotificationPlan, badgeCount: Int) {
        if let notificationScheduler {
            guard plan != .none else { return }
            notificationScheduler(plan, badgeCount)
            return
        }
        switch plan {
        case .none:
            return
        case .items(let items):
            for item in items {
                Self.fireLocalNotification(for: item, badgeCount: badgeCount)
            }
        case .summary(let newUnreadCount):
            Self.fireBatchNotification(newUnreadCount: newUnreadCount, badgeCount: badgeCount)
        }
    }

    private static func fireLocalNotification(for item: InboxItemRecord, badgeCount: Int) {
        var userInfo = [
            "itemId": item.id,
            "source": item.source,
            "screen": "activity"
        ]
        let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
        userInfo["eventId"] = eventID

        Task.detached {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.summary
            content.sound = .default
            content.badge = NSNumber(value: badgeCount)
            content.userInfo = userInfo
            do {
                let added = try await NativeAgentNotificationEventGate.add(
                    content: content,
                    eventID: eventID,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                NSLog("[InboxStore] notification %@ for %@ event=%@",
                      added ? "scheduled" : "deduplicated", item.id, eventID)
            } catch {
                NSLog("[InboxStore] notification add failed for %@: %@", item.id, error.localizedDescription)
            }
        }
    }

    private static func fireBatchNotification(newUnreadCount: Int, badgeCount: Int) {
        Task.detached {
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent Inbox"
            content.body = "\(newUnreadCount) new Inbox items are ready to review."
            content.sound = .default
            content.badge = NSNumber(value: badgeCount)
            content.userInfo = ["screen": "activity", "source": "inbox_batch"]
            let request = UNNotificationRequest(
                identifier: "nativeagent.inbox.batch.\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
                NSLog("[InboxStore] scheduled batch notification for %d cards", newUnreadCount)
            } catch {
                NSLog("[InboxStore] batch notification add failed: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - Top-level view

struct InboxView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var store: InboxStore
    @StateObject private var sync = iCloudSyncEngine.shared
    @State private var groupFilter: InboxRelatedGroup?
    @State private var selectedDetailItem: InboxItemRecord?
    @State private var showsAllEarlier = false

    /// When `true` (the default — used by tab roots), wraps the content in a
    /// NavigationStack. When `false`, returns just the inner content so the
    /// caller's NavigationStack provides the navigation context. Required
    /// when this view is pushed as a `navigationDestination` from another
    /// NavigationStack — nesting them causes the destination to render and
    /// immediately pop back, leaving the user staring at a blank slide-out.
    let embedInNavigationStack: Bool

    init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
    }

    private var visibleItems: [InboxItemRecord] {
        guard let groupFilter else { return MobileDesignSamples.rows(store.items) }
        return store.items.filter { groupFilter.matches($0) }
    }

    private var active: [InboxItemRecord] {
        visibleItems.filter { $0.isUnread }
    }

    private var read: [InboxItemRecord] {
        visibleItems.filter { !$0.isUnread && $0.status != "dismissed" && $0.status != "archived" }
    }

    private var agentDisplayName: String {
        sync.agentDisplayName
    }

    private var earlierSection: InboxListPresentation.EarlierSection {
        InboxListPresentation.earlierSection(items: read, showsAll: showsAllEarlier)
    }

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack { inboxContent }
            } else {
                inboxContent
            }
        }
    }

    @ViewBuilder
    private var inboxContent: some View {
        VStack(spacing: 0) {
            if let err = store.bannerError {
                VStack(spacing: 0) {
                    InboxBannerView(message: err)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .animation(AppMotion.snappy, value: store.bannerError)
            }
            listContent
        }
        .mobileReadingScreen()
        .navigationTitle("Inbox")
        .macSyncErrorBanner()
        .safeAreaInset(edge: .top, spacing: 0) { MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
        // E6: freshness of the Mac snapshot behind this list.
        .macSnapshotFreshnessBadge(group: "inbox")
        .toolbar {

            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoading {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .refreshable {
            await store.refresh(client: bridgeClient, pairingStore: pairingStore)
        }
        .task {
            if MobileDesignSamples.screen == nil {
                store.requestNotificationAuthorization()
            }
            store.isVisible = true
            await store.refresh(client: bridgeClient, pairingStore: pairingStore)
        }
        .onReceive(sync.$inboxItems) { _ in
            guard pairingStore.usesICloudTransport, store.isVisible else { return }
            store.applySyncedInboxFromSnapshot(animated: false, notifyNewArrivals: false)
        }
        .onDisappear { store.isVisible = false }
        .onAppear    { store.isVisible = true  }
        .sheet(item: $selectedDetailItem) { item in
            InboxDetailSheet(item: item, allItems: store.items, onOpenGroup: { group in
                selectedDetailItem = nil
                withAnimation(AppMotion.snappy) {
                    groupFilter = group
                    showsAllEarlier = false
                }
            }) {
                selectedDetailItem = nil
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if store.isLoading && MobileDesignSamples.rows(store.items).isEmpty {
            ProgressView("Loading inbox…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if MobileDesignSamples.rows(store.items).isEmpty {
            MobileReadingEmptyState(
                title: "Inbox empty",
                systemImage: "tray",
                kind: .empty,
                description: "\(agentDisplayName) will surface things here when something is worth flagging.",
                tint: NativeAgentPalette.agentAccent
            )
        } else {
            List {
                if let groupFilter {
                    Section {
                        MobileAdaptiveRow(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(groupFilter.title)
                                    .font(.headline)
                                Text("\(active.count) unread, \(read.count) earlier")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear") {
                                withAnimation(AppMotion.snappy) {
                                    self.groupFilter = nil
                                    showsAllEarlier = false
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                if !active.isEmpty {
                    Section("Unread (\(active.count))") {
                        ForEach(active) { item in
                            InboxCardRow(item: item, onAction: { action in
                                Task {
                                    await store.performAction(
                                        id: item.id,
                                        actionID: action,
                                        client: bridgeClient,
                                        pairingStore: pairingStore
                                    )
                                }
                            }, onView: {
                                selectedDetailItem = item
                            })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                }

                let earlier = earlierSection
                if !earlier.visibleItems.isEmpty {
                    Section("Earlier (\(earlier.totalCount))") {
                        ForEach(earlier.visibleItems) { item in
                            InboxCardRow(item: item, onAction: { action in
                                Task {
                                    await store.performAction(
                                        id: item.id,
                                        actionID: action,
                                        client: bridgeClient,
                                        pairingStore: pairingStore
                                    )
                                }
                            }, onView: {
                                selectedDetailItem = item
                            })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }

                        if earlier.hiddenCount > 0 {
                            Button("Show \(earlier.hiddenCount) more earlier") {
                                withAnimation(AppMotion.snappy) {
                                    showsAllEarlier = true
                                }
                            }
                            .font(.callout)
                        } else if showsAllEarlier,
                                  earlier.totalCount > InboxListPresentation.earlierPreviewLimit {
                            Button("Show fewer earlier") {
                                withAnimation(AppMotion.snappy) {
                                    showsAllEarlier = false
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// Presentation projection for the read-history section. The section title
/// always carries the complete count, while a capped preview exposes an
/// explicit path to every remaining card.
enum InboxListPresentation {
    static let earlierPreviewLimit = 10

    struct EarlierSection {
        let visibleItems: [InboxItemRecord]
        let totalCount: Int
        let hiddenCount: Int
    }

    static func earlierSection(
        items: [InboxItemRecord],
        showsAll: Bool
    ) -> EarlierSection {
        let visibleItems = showsAll ? items : Array(items.prefix(earlierPreviewLimit))
        return EarlierSection(
            visibleItems: visibleItems,
            totalCount: items.count,
            hiddenCount: max(0, items.count - visibleItems.count)
        )
    }
}

// MARK: - Card row

struct InboxCardRow: View {
    let item: InboxItemRecord
    let onAction: (String) -> Void
    let onView: () -> Void

    private var actionIDs: Set<String> {
        Set(item.presentableActions.map(\.id))
    }

    private var showsArchive: Bool {
        actionIDs.contains("archive")
    }

    private var extraActions: [InboxActionRecord] {
        item.presentableActions.filter {
            !["view", "reply", "act", "archive", "dismiss", "read", "approve", "reject", "deny"].contains($0.id)
        }
    }

    private var hasApproveAction: Bool {
        actionIDs.contains("approve")
    }

    private var rejectActionID: String? {
        if actionIDs.contains("reject") { return "reject" }
        if actionIDs.contains("deny") { return "deny" }
        return nil
    }

    var body: some View {
        MobileReadingSurface {
            VStack(alignment: .leading, spacing: 12) {

                // Header
                MobileAdaptiveRow(alignment: .top, spacing: 12) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: item.sourceIcon)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .padding(.top, 2)
                        if item.isUnread {
                            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.secondary)
                                .offset(x: 6, y: -2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Source badge
                        Text(item.sourceBadgeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
                    }

                    Spacer()

                    // Created-at
                    if !item.relativeCreatedAt.isEmpty {
                        Text(item.relativeCreatedAt)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Body (no truncation)
                Text(item.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Action buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    MobileAdaptiveRow(spacing: 12) {
                    if actionIDs.contains("view") || item.detail?.isEmpty == false {
                        Button("View") {
                            onView()
                            if item.isUnread { onAction("read") }
                        }
                        .buttonStyle(.borderedProminent)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                        .font(.callout)
                    }

                    if hasApproveAction {
                        Button {
                            onAction("approve")
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                                .font(.headline)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                                .frame(minHeight: 44)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background { Capsule().fill(NativeAgentMobileTheme.Colors.accentText) }
                        }
                        .buttonStyle(.plain)
                    }

                    if let rejectActionID {
                        Button {
                            onAction(rejectActionID)
                        } label: {
                            Label("Deny", systemImage: "xmark")
                                .font(.headline)
                        }
                        .buttonStyle(.bordered)
                .tint(.secondary)
                    }

                    if actionIDs.contains("act") {
                        Button(item.source.hasPrefix("trigger:file_watch") ? "Open File" : "Act") {
                            onAction("act")
                        }
                            .buttonStyle(.bordered)
                .tint(.secondary)
                            .font(.callout)
                    }

                    if showsArchive {
                        Button("Archive") { onAction("archive") }
                            .buttonStyle(.bordered)
                .tint(.secondary)
                            .font(.callout)
                    }

                    // Dismiss button
                    Button("Dismiss") { onAction("dismiss") }
                        .buttonStyle(.bordered)
                .tint(.secondary)
                        .font(.callout)

                    // Card-specific extra actions (filter out standard ones we already show)
                    ForEach(extraActions, id: \.id) { action in
                        Button(action.label) { onAction(action.id) }
                            .buttonStyle(.bordered)
                .tint(.secondary)
                            .font(.callout)
                    }

                }
                }
            }
        }
    }
}

struct InboxDetailSheet: View {
    let item: InboxItemRecord
    let allItems: [InboxItemRecord]
    let onOpenGroup: (InboxRelatedGroup) -> Void
    let onDone: () -> Void

    private var relatedGroups: [InboxRelatedGroup] {
        InboxDetailGroupProjection.groups(item: item, allItems: allItems)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MobileReadingSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .font(.headline)
                            Text(item.sourceBadgeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Review Groups")
                                .font(.headline)
                            ForEach(relatedGroups) { group in
                                Button {
                                    onOpenGroup(group)
                                } label: {
                                    MobileAdaptiveRow(spacing: 12) {
                                        Image(systemName: "tray.full")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.title)
                                                .font(.callout)
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                            Text("\(group.displayCount) item\(group.displayCount == 1 ? "" : "s")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(NativeAgentMobileTheme.Colors.quietFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .mobileReadingScreen()
            .navigationTitle("Inbox Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

/// The only route from a persisted digest card to the detail sheet's Review
/// Groups controls. Current Mac cards carry structured groups; the bounded
/// prose parser keeps existing JSONL digest cards useful after the migration.
extension InboxItemRecord: InboxDigestItem {}
extension InboxRelatedGroup: @retroactive InboxDigestGroup {}

enum InboxDetailGroupProjection {
    static func groups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        InboxDigestGroupProjection.groups(item: item, allItems: allItems)
    }

    static func legacyGroups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        InboxDigestGroupProjection.legacyGroups(item: item, allItems: allItems)
    }
}

// MARK: - Banner

private struct InboxBannerView: View {
    let message: String

    var body: some View {
        MobileAdaptiveRow(spacing: 8) {
            Image(systemName: "wifi.slash").font(.caption.weight(.semibold))
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NativeAgentMobileTheme.Colors.contentSurface)
        .ignoresSafeArea(edges: .horizontal)
    }
}
