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
    @Published private(set) var hasLoadedSnapshot = false
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
        if iCloudSyncEngine.shared.inboxSnapshotLoaded { hasLoadedSnapshot = true }
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
        if let approvalID = item.related_approval_id, !approvalID.isEmpty {
            userInfo.removeValue(forKey: "itemId")
            userInfo["approvalId"] = approvalID
        }
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
            do {
                let request = UNNotificationRequest(
                    identifier: "nativeagent.inbox.batch.\(UUID().uuidString)",
                    content: try await CommunicationNotification.decorate(content),
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
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

    init(embedInNavigationStack: Bool = true, initialGroup: InboxRelatedGroup? = nil) {
        self.embedInNavigationStack = embedInNavigationStack
        _groupFilter = State(initialValue: initialGroup)
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

    private var earlierSection: InboxListPresentation.EarlierSection {
        InboxListPresentation.earlierSection(items: read, showsAll: showsAllEarlier)
    }

    private var headerLine: String {
        switch active.count {
        case 0: return "Nothing new from me."
        case 1: return "One new thing from me."
        default: return "\(AliveWords.spelled(active.count)) new things from me."
        }
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
        // E6: freshness of the Mac snapshot behind this list.
        AlivePage(title: "Inbox", line: headerLine, freshnessGroup: "inbox") {
            if store.isLoading { ProgressView().controlSize(.small) }
        } content: {
            // "Pair to view" is already said by the header and its Pair with Mac.
            if let err = store.bannerError, err != "Pair to view" {
                InboxBannerView(message: err)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            listContent
        }
        .animation(AppMotion.snappy, value: store.bannerError)
        .macSyncErrorBanner()
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

    private func card(_ item: InboxItemRecord) -> some View {
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
        .swipeActions(edge: .trailing) {
            Button("Dismiss") {
                Task {
                    await store.performAction(id: item.id, actionID: "dismiss",
                                              client: bridgeClient, pairingStore: pairingStore)
                }
            }
            .tint(.gray)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if store.isLoading && MobileDesignSamples.rows(store.items).isEmpty {
            ProgressView("Checking with your Mac…")
                .tint(AlivePalette.secondary)
                .foregroundStyle(AlivePalette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if MobileDesignSamples.rows(store.items).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing here yet.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                Text("When I notice something worth your attention, I'll leave it here.")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") {
                    Task { await store.refresh(client: bridgeClient, pairingStore: pairingStore) }
                }
                .aliveSecondaryButton()
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            }
            .padding(20)
            .aliveCard()
        } else {
            // One native row per card, in New and Earlier sections (User 09-27:
            // all native); swipe to dismiss.
            if let groupFilter {
                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(groupFilter.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(AlivePalette.text)
                            Text("\(active.count) new, \(read.count) earlier")
                                .font(.footnote)
                                .foregroundStyle(AlivePalette.secondary)
                        }
                        Spacer()
                        Button("Show all") {
                            withAnimation(AppMotion.snappy) {
                                self.groupFilter = nil
                                showsAllEarlier = false
                            }
                        }
                        .aliveSecondaryButton()
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if !active.isEmpty {
                Section("New") {
                    ForEach(active) { item in card(item) }
                }
            }

            let earlier = earlierSection
            if !earlier.visibleItems.isEmpty {
                Section("Earlier") {
                    ForEach(earlier.visibleItems) { item in card(item) }

                    if earlier.hiddenCount > 0 {
                        Button("Show \(earlier.hiddenCount) more") {
                            withAnimation(AppMotion.snappy) {
                                showsAllEarlier = true
                            }
                        }
                    } else if showsAllEarlier,
                              earlier.totalCount > InboxListPresentation.earlierPreviewLimit {
                        Button("Show fewer") {
                            withAnimation(AppMotion.snappy) {
                                showsAllEarlier = false
                            }
                        }
                    }
                }
            }
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

extension InboxItemRecord {
    /// Where a card came from, in plain words (the badge label is plumbing).
    var sourceWords: String {
        if hasLinkedApproval { return "Asking first" }
        if source.hasPrefix("proactive_autonomy") { return "An idea" }
        if source.hasPrefix("harness_learning") { return "Something I learned" }
        if source == "dream_cycle" { return "A dream" }
        if source == "rem_cycle" { return "From my rest" }
        if source.hasPrefix("trigger:file_watch") { return "A file changed" }
        if source.hasPrefix("trigger:morning_brief") { return "Your morning brief" }
        if source.hasPrefix("trigger:stuck_pattern") { return "A pattern I noticed" }
        if source == "idle_checkin" { return "Checking in" }
        if source.hasPrefix("execution_complete") || source.hasPrefix("mission_complete") { return "Work finished" }
        if source == "self_test" { return "A self-check" }
        if source == "desk" { return "From the Desk" }
        return "A note from me"
    }
}

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

    private var showsView: Bool {
        actionIDs.contains("view") || item.detail?.isEmpty == false
    }

    private var rejectActionID: String? {
        if actionIDs.contains("reject") { return "reject" }
        if actionIDs.contains("deny") { return "deny" }
        return nil
    }

    private var kindLine: String {
        item.relativeCreatedAt.isEmpty ? item.sourceWords : "\(item.sourceWords) · \(item.relativeCreatedAt)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if item.isUnread {
                    AliveWaitingDot()
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(kindLine)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
            }

            Text(item.title)
                .font(.body.weight(.medium))
                .foregroundStyle(AlivePalette.text)
                .fixedSize(horizontal: false, vertical: true)

            // Body (no truncation)
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Actions: one primary (Approve, else Read), the rest quiet.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if hasApproveAction {
                        Button("Approve") { onAction("approve") }
                            .alivePrimaryButton()
                    }

                    if let rejectActionID {
                        Button("Deny") { onAction(rejectActionID) }
                            .aliveSecondaryButton()
                    }

                    if showsView {
                        if hasApproveAction {
                            Button("Read") {
                                onView()
                                if item.isUnread { onAction("read") }
                            }
                            .aliveSecondaryButton()
                        } else {
                            Button("Read") {
                                onView()
                                if item.isUnread { onAction("read") }
                            }
                            .alivePrimaryButton()
                        }
                    }

                    if let action = item.presentableActions.first(where: { $0.id == "act" }) {
                        Button(item.source == "interaction" ? action.label
                               : item.source.hasPrefix("trigger:file_watch") ? "Open file" : "Go ahead") {
                            onAction("act")
                        }
                        .aliveSecondaryButton()
                    }

                    if showsArchive {
                        Button("Archive") { onAction("archive") }
                            .aliveSecondaryButton()
                    }

                    Button("Dismiss") { onAction("dismiss") }
                        .aliveSecondaryButton()

                    // Card-specific extra actions (filter out standard ones we already show)
                    ForEach(extraActions, id: \.id) { action in
                        Button(action.label) { onAction(action.id) }
                            .aliveSecondaryButton()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
            }
        }
        .aliveRow()
        .aliveCard()
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
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.relativeCreatedAt.isEmpty ? item.sourceWords : "\(item.sourceWords) · \(item.relativeCreatedAt)")
                            .font(.caption)
                            .foregroundStyle(AlivePalette.secondary)
                        Text(item.title)
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(AlivePalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.body)
                                .foregroundStyle(AlivePalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 4)

                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(AlivePalette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AliveMetrics.rowInsetH)
                            .aliveCard()
                    }

                    if !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            AliveEyebrow("Related")
                            AliveCard {
                                ForEach(Array(relatedGroups.enumerated()), id: \.element.id) { index, group in
                                    if index > 0 { AliveDivider() }
                                    Button {
                                        onOpenGroup(group)
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(group.title)
                                                    .font(.body)
                                                    .foregroundStyle(AlivePalette.text)
                                                    .multilineTextAlignment(.leading)
                                                Text(AliveWords.count(group.displayCount, "item"))
                                                    .font(.footnote)
                                                    .foregroundStyle(AlivePalette.secondary)
                                            }
                                            Spacer()
                                            AliveChevron()
                                        }
                                        .aliveRow()
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .alivePageChrome(title: "Inbox Item", root: false)
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
        AliveStatusNote(systemImage: "wifi.slash", text: message)
    }
}
