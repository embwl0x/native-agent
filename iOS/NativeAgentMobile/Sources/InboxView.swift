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

// MARK: - Model

struct InboxItemRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let created_at: String
    let source: String
    let severity: String
    let title: String
    let summary: String
    let detail: String?
    let relatedWorkshopExecutionId: String?
    let related_approval_id: String?
    let related_paths: [String]?
    let related_groups: [InboxRelatedGroup]?
    let actions: [InboxActionRecord]
    let status: String
    let read_at: String?

    enum CodingKeys: String, CodingKey {
        case id, created_at, source, severity, title, summary, detail
        case relatedWorkshopExecutionId = "related_mission_id" // compatibility wire ID
        case related_approval_id, related_paths, related_groups, actions, status, read_at
    }

    var isUnread: Bool { status == "unread" }
    var hasLinkedApproval: Bool { !(related_approval_id ?? "").isEmpty }

    /// Presentation must expose only actions with a real end-to-end native
    /// contract. `reply` remains a compatibility wire action on old cards, but
    /// there is no typed proactive-card destination/result contract yet; hiding
    /// it is safer than accepting text and losing it after Mac rejects the call.
    var presentableActions: [InboxActionRecord] {
        actions.filter { $0.id != "reply" }
    }

    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important":  return .blue
        default:           return NativeAgentPalette.agentAccent
        }
    }

    var sourceIcon: String {
        if hasLinkedApproval { return "checkmark.shield.fill" }
        if source.hasPrefix("proactive_autonomy") { return "lightbulb.fill" }
        if source.hasPrefix("harness_learning") { return "wand.and.stars" }
        if source == "dream_cycle"               { return "moon.stars.fill" }
        if source == "rem_cycle"                 { return "sparkles" }
        if source.hasPrefix("trigger:file_watch") { return "doc.text.magnifyingglass" }
        // P2-4: `execution_complete:<id>` is the canonical source; historical
        // cards synced from the Mac still say `mission_complete:<id>`.
        if source.hasPrefix("execution_complete") || source.hasPrefix("mission_complete") {
            return "checkmark.circle.fill"
        }
        if source == "idle_checkin"               { return "clock.fill" }
        if source.hasPrefix("trigger:morning_brief") { return "sun.horizon.fill" }
        if source.hasPrefix("trigger:stuck_pattern") { return "arrow.trianglehead.2.clockwise" }
        if source == "self_test"                  { return "testtube.2" }
        return "bell.fill"
    }

    var sourceBadgeLabel: String {
        if hasLinkedApproval { return "APPROVAL" }
        if source.hasPrefix("proactive_autonomy") { return "IDEA" }
        if source.hasPrefix("harness_learning") { return "LEARNING" }
        if source == "dream_cycle" { return "DREAM" }
        if source == "rem_cycle" { return "REM" }
        if source.hasPrefix("trigger:file_watch")    { return "FILE-WATCH" }
        if source.hasPrefix("trigger:morning_brief") { return "MORNING-BRIEF" }
        if source.hasPrefix("trigger:stuck_pattern") { return "STUCK-PATTERNS" }
        if source == "idle_checkin"                  { return "IDLE-CHECKIN" }
        if source.hasPrefix("execution_complete") || source.hasPrefix("mission_complete") {
            return "WORKSHOP"
        }
        return source.uppercased().prefix(14).description
    }

    var createdDate: Date? {
        ISO8601DateFormatter().date(from: created_at)
    }

    var relativeCreatedAt: String {
        guard let date = createdDate else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60  { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    func replacingStatus(_ nextStatus: String, readAt: String? = nil) -> InboxItemRecord {
        InboxItemRecord(
            id: id,
            created_at: created_at,
            source: source,
            severity: severity,
            title: title,
            summary: summary,
            detail: detail,
            relatedWorkshopExecutionId: relatedWorkshopExecutionId,
            related_approval_id: related_approval_id,
            related_paths: related_paths,
            related_groups: related_groups,
            actions: actions,
            status: nextStatus,
            read_at: readAt ?? read_at
        )
    }
}

struct InboxRelatedGroup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
    let item_ids: [String]?
    let source: String?

    var itemIDs: Set<String> {
        Set(item_ids ?? [])
    }

    var displayCount: Int {
        max(count, item_ids?.count ?? 0)
    }

    func matches(_ item: InboxItemRecord) -> Bool {
        if item.id == id { return false }
        let ids = itemIDs
        if !ids.isEmpty && ids.contains(item.id) {
            return true
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty && item.title == cleanTitle
    }
}

struct InboxActionRecord: Codable, Hashable, Sendable {
    let id: String
    let label: String
    let description: String?
}

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

    private func applySuccessfulLocalAction(id: String, actionID: String) {
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

    private func applyFetchedItems(
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
        // Cap fires per refresh at FIRE_CAP and treat anything above
        // BURST_THRESHOLD as a batch (no notifications, just update
        // knownIDs so we don't re-fire next refresh).
        let fetchedIDs = Set(fetchedUnread.map { $0.id })
        let newIDs = fetchedIDs.subtracting(knownIDs)
        NSLog("[InboxStore] apply fetched=%d unread=%d known=%d new=%d visible=%@", fetched.count, fetchedUnread.count, knownIDs.count, newIDs.count, isVisible ? "true" : "false")
        if notifyNewArrivals && !knownIDs.isEmpty && !newIDs.isEmpty {
            let BURST_THRESHOLD = 8
            let FIRE_CAP = 3
            if newIDs.count >= BURST_THRESHOLD {
                // Batch arrival — silently update knownIDs to avoid spamming SpringBoard.
                NSLog("[InboxStore] suppressing notifications for batch arrival of %d cards", newIDs.count)
            } else {
                let newItems = fetchedUnread.filter { newIDs.contains($0.id) }.prefix(FIRE_CAP)
                for item in newItems {
                    fireLocalNotification(for: item)
                }
            }
        }
        knownIDs = fetchedIDs
        UserDefaults.standard.set(Array(Array(fetchedIDs).sorted().suffix(500)), forKey: "NativeAgentMobile.inboxKnownIDs")

        if animated {
            withAnimation(AppMotion.snappy) { items = fetched }
        } else {
            items = fetched
        }
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

    private func fireLocalNotification(for item: InboxItemRecord) {
        // Skip if user is on the Inbox tab right now
        guard !isVisible else { return }
        guard item.severity == "important" || item.severity == "actionable" else { return }

        let badgeCount = activeCount
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
}

// MARK: - Top-level view

struct InboxView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var store: InboxStore
    @StateObject private var sync = iCloudSyncEngine.shared
    @State private var groupFilter: InboxRelatedGroup?
    @State private var selectedDetailItem: InboxItemRecord?

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
        guard let groupFilter else { return store.items }
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
        ZStack(alignment: .top) {
            listContent

            if let err = store.bannerError {
                VStack(spacing: 0) {
                    InboxBannerView(message: err)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .animation(AppMotion.snappy, value: store.bannerError)
            }
        }
        .navigationTitle("Inbox")
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
            store.requestNotificationAuthorization()
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
                }
            }) {
                selectedDetailItem = nil
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("Loading inbox…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty {
            AppEmptyState(
                title: "Inbox empty",
                systemImage: "tray",
                description: "\(agentDisplayName) will surface things here when something is worth flagging.",
                tint: NativeAgentPalette.agentAccent
            )
        } else {
            List {
                if let groupFilter {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(NativeAgentPalette.agentAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(groupFilter.title)
                                    .font(AppFont.section)
                                Text("\(active.count) unread, \(read.count) earlier")
                                    .font(AppFont.tag)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear") {
                                withAnimation(AppMotion.snappy) {
                                    self.groupFilter = nil
                                }
                            }
                            .font(AppFont.label)
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

                if !read.isEmpty {
                    Section("Earlier") {
                        ForEach(read.prefix(10)) { item in
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
            }
            .listStyle(.plain)
        }
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
        GlassCard(tint: item.isUnread ? item.severityColor : nil) {
            VStack(alignment: .leading, spacing: 12) {

                // Header
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: item.sourceIcon)
                            .font(.body)
                            .foregroundStyle(item.severityColor)
                            .frame(width: 22)
                            .padding(.top, 2)
                        if item.isUnread {
                            PulsingDot(color: item.severityColor, size: 6)
                                .offset(x: 6, y: -2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(AppFont.section)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Source badge
                        Text(item.sourceBadgeLabel)
                            .font(AppFont.tag)
                            .foregroundStyle(item.severityColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(item.severityColor.opacity(0.14), in: Capsule())
                    }

                    Spacer()

                    // Created-at
                    if !item.relativeCreatedAt.isEmpty {
                        Text(item.relativeCreatedAt)
                            .font(AppFont.tag)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Body (no truncation)
                Text(item.summary)
                    .font(AppFont.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Action buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                    if actionIDs.contains("view") || item.detail?.isEmpty == false {
                        Button("View") {
                            onView()
                            if item.isUnread { onAction("read") }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(AppFont.label)
                    }

                    if hasApproveAction {
                        Button {
                            onAction("approve")
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                                .font(AppFont.section)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background { Capsule().fill(NativeAgentPalette.agentGradient) }
                        }
                        .buttonStyle(.plain)
                    }

                    if let rejectActionID {
                        Button {
                            onAction(rejectActionID)
                        } label: {
                            Label("Deny", systemImage: "xmark")
                                .font(AppFont.section)
                        }
                        .buttonStyle(.bordered)
                    }

                    if actionIDs.contains("act") {
                        Button(item.source.hasPrefix("trigger:file_watch") ? "Open File" : "Act") {
                            onAction("act")
                        }
                            .buttonStyle(.bordered)
                            .font(AppFont.label)
                    }

                    if showsArchive {
                        Button("Archive") { onAction("archive") }
                            .buttonStyle(.bordered)
                            .font(AppFont.label)
                    }

                    // Dismiss button
                    Button("Dismiss") { onAction("dismiss") }
                        .buttonStyle(.bordered)
                        .font(AppFont.label)

                    // Card-specific extra actions (filter out standard ones we already show)
                    ForEach(extraActions, id: \.id) { action in
                        Button(action.label) { onAction(action.id) }
                            .buttonStyle(.bordered)
                            .font(AppFont.label)
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
        if let groups = item.related_groups, !groups.isEmpty {
            return groups
        }
        return Self.groupsFromDigestDetail(item: item, allItems: allItems)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GlassCard(tint: item.severityColor) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title)
                                .font(AppFont.section)
                            Text(item.sourceBadgeLabel)
                                .font(AppFont.tag)
                                .foregroundStyle(item.severityColor)
                        }
                    }
                    Text(item.summary)
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(AppFont.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Review Groups")
                                .font(AppFont.section)
                            ForEach(relatedGroups) { group in
                                Button {
                                    onOpenGroup(group)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "tray.full")
                                            .foregroundStyle(item.severityColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(group.title)
                                                .font(AppFont.label)
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                            Text("\(group.displayCount) item\(group.displayCount == 1 ? "" : "s")")
                                                .font(AppFont.tag)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(AppFont.tag)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(item.severityColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
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

    private static func groupsFromDigestDetail(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        guard item.source == "autonomy_maintenance:inbox_digest",
              let detail = item.detail,
              detail.contains("Top groups:")
        else { return [] }
        let lines = detail.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Top groups:" }) else {
            return []
        }
        var groups: [InboxRelatedGroup] = []
        for rawLine in lines.dropFirst(start + 1) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("- ") else { break }
            let entry = String(line.dropFirst(2))
            let parsed = parseDigestGroupLine(entry)
            let matchingIDs = allItems
                .filter { $0.id != item.id && $0.title == parsed.title }
                .map(\.id)
            groups.append(InboxRelatedGroup(
                id: "digest-\(groups.count)-\(parsed.title)",
                title: parsed.title,
                count: parsed.count,
                item_ids: matchingIDs,
                source: nil
            ))
        }
        return groups
    }

    private static func parseDigestGroupLine(_ entry: String) -> (title: String, count: Int) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (trimmed, 0)
        }
        let title = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let countText = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return (title, Int(String(countText)) ?? 0)
    }
}

// MARK: - Banner

private struct InboxBannerView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.caption.weight(.semibold))
            Text(message).font(AppFont.label).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.85))
        .ignoresSafeArea(edges: .horizontal)
    }
}
