import SwiftUI
import NativeAgentShared
import UserNotifications
// Blueprint: | `InboxView.swift` | Inbox list, card rows and reading navigation use the shared sync projection |

// MARK: - Top-level view

struct InboxView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var store: InboxStore
    private let sync = iCloudSyncEngine.shared
    @State private var groupFilter: InboxRelatedGroup?
    @State private var selectedDetailItemID: String?
    @State private var showsAllEarlier = false

    /// Tab roots own navigation; pushed destinations use the caller’s stack.
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

    private var headerLine: String {
        switch active.count {
        case 0: return "No unread notes from me."
        case 1: return "One unread note from me."
        default: return "\(AliveWords.spelled(active.count)) unread notes from me."
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
            await store.refresh(pairingStore: pairingStore)
        }
        .task {
            if MobileDesignSamples.screen == nil {
                store.requestNotificationAuthorization()
            }
            store.isVisible = true
            await store.refresh(pairingStore: pairingStore)
        }
        .onChange(of: sync.inboxItems, initial: true) { _, _ in
            guard pairingStore.usesICloudTransport, store.isVisible else { return }
            store.applySyncedInboxFromSnapshot(notifyNewArrivals: false)
        }
        .onDisappear { store.isVisible = false }
        .onAppear    { store.isVisible = true  }
        .sheet(isPresented: Binding(get: { selectedDetailItemID != nil }, set: { if !$0 { selectedDetailItemID = nil } })) {
            if let id = selectedDetailItemID {
                InboxDetailSheet(itemID: id, onOpenGroup: { group in
                    selectedDetailItemID = nil
                    withAnimation(AppMotion.snappy) {
                        groupFilter = group
                        showsAllEarlier = false
                    }
                }) {
                    selectedDetailItemID = nil
                }
            }
        }
    }

    private func card(_ item: InboxItemRecord) -> some View {
        InboxCardRow(item: item, onAction: { action in
            Task {
                await store.performAction(
                    id: item.id,
                    actionID: action,
                    pairingStore: pairingStore
                )
            }
        }, onView: {
            selectedDetailItemID = item.id
        })
        .swipeActions(edge: .trailing) {
            Button("Dismiss") {
                Task {
                    await store.performAction(id: item.id, actionID: "dismiss",
                                              pairingStore: pairingStore)
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
                    Task { await store.refresh(pairingStore: pairingStore) }
                }
                .aliveSecondaryButton()
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            }
            .padding(20)
            .aliveCard()
        } else {
            // One native row per card in New and Earlier; swipe to dismiss.
            let earlierRows = read
            if let groupFilter {
                Section {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(groupFilter.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(AlivePalette.text)
                            Text("\(active.count) unread, \(earlierRows.count) earlier")
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

            let earlierPreviewLimit = 10
            let earlier = showsAllEarlier ? earlierRows : Array(earlierRows.prefix(earlierPreviewLimit))
            let hiddenCount = max(0, earlierRows.count - earlier.count)
            if !earlier.isEmpty {
                Section("Earlier") {
                    ForEach(earlier) { item in card(item) }

                    if hiddenCount > 0 {
                        Button("Show \(hiddenCount) more") {
                            withAnimation(AppMotion.snappy) {
                                showsAllEarlier = true
                            }
                        }
                    } else if showsAllEarlier,
                              earlierRows.count > earlierPreviewLimit {
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
                        Button(item.presentation?.actLabel ?? action.label) {
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

// MARK: - Banner

private struct InboxBannerView: View {
    let message: String

    var body: some View {
        AliveStatusNote(systemImage: "wifi.slash", text: message)
    }
}
