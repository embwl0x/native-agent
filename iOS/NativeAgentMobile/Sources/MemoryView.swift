// PATCH-2026-05-19: ui-pull-together MemoryView — Memories / Proposals only.
// Skills have their own primary tab, so this view stays focused on memory.
import SwiftUI
import CloudKit
import NativeAgentShared

// MARK: - MemoryView

struct MemoryView: View {
    @StateObject private var store = MemoryStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @State private var showsConnection = false
    @State private var hasNoCloudAccount = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var segment: MemorySegment
    /// Sweep 2026-09-01 item 36 — local filter over the memory snapshot the
    /// phone has ALREADY synced. The Mac's semantic recall runs in-process
    /// against SwiftNativeMemoryV2 and is not exposed on the action channel,
    /// so there is no Mac search API to prefer here; inventing one would be a
    /// new remote surface, not a search box.
    @State private var searchQuery = ""
    /// `false` when pushed as a navigationDestination from another
    /// NavigationStack (e.g. ActivityView → Memory Proposals). Nesting
    /// NavigationStacks causes the destination to render and immediately
    /// pop back. Default `true` keeps the Memory tab root working.
    private let embedInNavigationStack: Bool

    enum MemorySegment: String, CaseIterable {
        case memories = "Memories"
        case proposals = "Proposals"
    }

    /// The Mac snapshot group behind each tab. They fail INDEPENDENTLY —
    /// `memories` and `memory_proposals` are separate fetches on the Mac — so a
    /// badge pinned to one group leaves the other tab looking fresh while the
    /// Mac already knows its rows are old.
    static func snapshotGroup(for segment: MemorySegment) -> String {
        switch segment {
        case .memories: return "memories"
        case .proposals: return "memory_proposals"
        }
    }

    init(initialSegment: MemorySegment = .memories, embedInNavigationStack: Bool = true) {
        _segment = State(initialValue: initialSegment)
        self.embedInNavigationStack = embedInNavigationStack
    }

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack { memoryContent }
            } else {
                memoryContent
            }
        }
    }

    @ViewBuilder
    private var memoryContent: some View {
        Group {
            switch segment {
            case .memories:
                MemoryListView(store: store, searchQuery: searchQuery, header: AnyView(memoryHeader))
            case .proposals:
                ProposalsListView(store: store, header: AnyView(memoryHeader))
            }
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(NativeAgentMobileTheme.Colors.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background { MobileRoomBackground() }
        .tint(NativeAgentMobileTheme.Colors.accentText)
        .sheet(isPresented: $showsConnection) {
            PairingView(onSkip: { showsConnection = false }, onPaired: { showsConnection = false })
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.refresh() } }
        .onChange(of: sync.memories) { _, _ in store.applySyncedState(from: sync) }
        .onChange(of: sync.memoryProposals) { _, _ in store.applySyncedState(from: sync) }
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  DeviceCloudKitPreflight.entitlementGrantsContainer(NativeAgentICloudBridgeConstants.containerID) else { return }
            hasNoCloudAccount = (try? await CKContainer(identifier: NativeAgentICloudBridgeConstants.containerID).accountStatus()) == .noAccount
        }
    }

    private var memoryHeader: some View {
        VStack(spacing: 8) {
            if segment == .memories {
                HStack {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("Search memories", text: $searchQuery)
                        .font(.body)
                        .submitLabel(.search)
                }
                .padding(12)
                .background(NativeAgentMobileTheme.Colors.softFill, in: RoundedRectangle(cornerRadius: 12))
            }
            memorySyncStatus
            HStack(spacing: 4) {
                ForEach(MemorySegment.allCases, id: \.self) { seg in
                    Button { segment = seg } label: {
                        Text(seg.rawValue)
                            .font(.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.vertical, 4)
                            .background(segment == seg ? NativeAgentMobileTheme.Colors.softFill : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(segment == seg ? .isSelected : [])
                }
            }

            if let error = MemoryErrorLinePresentation.visibleMessage(store.error) {
                MemoryErrorLine(message: error) {
                    store.dismissError()
                }
            }

        }
    }

    private var sampleSyncState: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-memorySample"), let i = args.firstIndex(of: "-memorySampleStatus"), args.indices.contains(i + 1) {
            return args[i + 1]
        }
        #endif
        return nil
    }

    private var memorySyncStatus: some View {
        // Reuse the freshness cadence and rules; connection and snapshot age
        // are independent facts, presented together with one recovery.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let sample = sampleSyncState
            let state = StatusConnectionPresentation.syncState(
                // This segment's own delivery clock, not the cache-read clock.
                lastSyncedAt: sample == "stale"
                    ? context.date.addingTimeInterval(-7200)
                    : sample != nil
                        ? nil
                        : sync.transportDeliveryAt(screenGroup: Self.snapshotGroup(for: segment)),
                now: context.date)
            let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup(for: segment))
            let noAccount = sample == "noAccount" || (sample == nil && hasNoCloudAccount)
            let unavailable = noAccount || (sample == nil && bridgeClient.bridgeStatus != .online)
            let sharedError = MemoryErrorLinePresentation.visibleMessage(sync.syncError)
            VStack(alignment: .leading, spacing: 4) {
                Text(sharedError != nil ? "Memories could not update" : reason == nil ? StatusConnectionPresentation.cardValue(for: state) : "Memories out of date")
                    .font(.caption.weight(.semibold))
                if sharedError == nil && (unavailable || reason != nil || StatusConnectionPresentation.needsAttention(state)) {
                    Text(noAccount ? "No iCloud account; memories cannot update."
                         : reason.map { "Saved memories may be out of date. \($0)" }
                         ?? (unavailable ? "Connection unavailable; memories cannot update."
                             : StatusConnectionPresentation.detail(for: state) ?? ""))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sharedError != nil || unavailable || reason != nil || StatusConnectionPresentation.needsAttention(state) {
                    Button(noAccount ? "Open Settings" : unavailable ? "Review connection" : "Refresh memories") {
                        if noAccount {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        } else if unavailable { showsConnection = true }
                        else { Task { await store.refresh() } }
                    }
                    .accessibilityHint(noAccount ? "Sign in to Apple Account in Settings, then return to refresh memories." : "")
                    .foregroundStyle(NativeAgentMobileTheme.Colors.accentText)
                    .frame(minHeight: 44)
                }
            }
            .foregroundStyle(NativeAgentMobileTheme.Colors.metadataText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
        .macSyncErrorBanner()
    }
}

// MARK: - Store

enum MemoryErrorLinePresentation {
    static func visibleMessage(_ error: String?) -> String? {
        guard let error else { return nil }
        let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}

private struct MemoryErrorLine: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(AppFont.label)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .frame(width: 44, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss memory warning")
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

// NOTE (2026-06-06): `MemoryStackStatus` + the `memory_stack.json` read were
// removed — no writer for that file exists anywhere on disk, so the iOS view
// was reading a phantom. The Memory Stack summary card came out with it.

@MainActor
final class MemoryStore: ObservableObject {
    @Published var memories: [MemoryRecord] = []
    @Published var memoryProposals: [MemoryProposalRecord] = []
    @Published var decidingMemoryProposalIDs: Set<String> = []
    @Published var deletingMemoryIDs: Set<String> = []
    @Published var isLoading = false
    @Published var error: String?

    private let refreshMemorySnapshot: () async -> Void
    private let syncErrorProvider: () -> String?

    private var hiddenResolvedMemoryProposalIDs: Set<String> = []
    private var hiddenDeletedMemoryIDs: Set<String> = []

    init(
        refreshMemorySnapshot: @escaping () async -> Void = {
            await iCloudSyncEngine.shared.refreshMemorySnapshot()
        },
        syncErrorProvider: @escaping () -> String? = {
            iCloudSyncEngine.shared.syncError
        }
    ) {
        self.refreshMemorySnapshot = refreshMemorySnapshot
        self.syncErrorProvider = syncErrorProvider
    }

    func refresh() async {
        isLoading = true
        error = nil
        await refreshMemorySnapshot()
        let sync = iCloudSyncEngine.shared
        applySyncedState(from: sync)
        error = MemoryErrorLinePresentation.visibleMessage(syncErrorProvider())
        isLoading = false
    }

    func dismissError() {
        error = nil
    }

    func applySyncedState(from sync: iCloudSyncEngine) {
        applySyncedState(memories: sync.memories, memoryProposals: sync.memoryProposals)
    }

    func applySyncedState(
        memories syncedMemories: [MemoryRecord],
        memoryProposals syncedMemoryProposals: [MemoryProposalRecord]
    ) {
        let memoryIDs = Set(syncedMemories.map(\.id))
        let proposalIDs = Set(syncedMemoryProposals.map(\.id))
        // This intersection bounds the local hide set to ids still present in
        // the current snapshot or an active delete, including repeated swipes.
        hiddenDeletedMemoryIDs.formIntersection(memoryIDs.union(deletingMemoryIDs))
        hiddenResolvedMemoryProposalIDs.formIntersection(
            proposalIDs.union(decidingMemoryProposalIDs)
        )
        memories = syncedMemories.filter { !hiddenDeletedMemoryIDs.contains($0.id) }
        memoryProposals = syncedMemoryProposals.filter {
            !hiddenResolvedMemoryProposalIDs.contains($0.id)
        }
    }

    func approveMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: true)
    }

    func rejectMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: false)
    }

    private func decideMemoryProposal(_ proposal: MemoryProposalRecord, approve: Bool) {
        Task { @MainActor in
            await performMemoryProposalDecision(
                proposal,
                approve: approve,
                submit: { approve, proposalID in
                    if approve {
                        try await iCloudSyncEngine.shared.approveMemoryProposal(proposalId: proposalID)
                    } else {
                        try await iCloudSyncEngine.shared.rejectMemoryProposal(proposalId: proposalID)
                    }
                },
                refresh: { await self.refresh() }
            )
        }
    }

    /// Runs one proposal decision and then reconciles the current Mac snapshot.
    /// It remains visible after every unconfirmed failure; only a successful
    /// action may retain the optimistic hide while snapshot publication catches
    /// up.
    func performMemoryProposalDecision(
        _ proposal: MemoryProposalRecord,
        approve: Bool,
        submit: (Bool, String) async throws -> Void,
        refresh: () async -> Void
    ) async {
        guard !decidingMemoryProposalIDs.contains(proposal.id) else { return }
        error = nil
        decidingMemoryProposalIDs.insert(proposal.id)
        hiddenResolvedMemoryProposalIDs.insert(proposal.id)
        memoryProposals.removeAll { $0.id == proposal.id }

        do {
            try await submit(approve, proposal.id)
        } catch {
            // A timeout only means the phone did not observe the Mac's answer.
            // It cannot prove the action was applied, so do not leave the
            // proposal optimistically hidden from the next snapshot.
            hiddenResolvedMemoryProposalIDs.remove(proposal.id)
            if iCloudSyncEngine.isMacResponseTimeout(error) {
                self.error = "Decision sent; waiting for Mac/iCloud to publish the result."
            } else {
                self.error = error.localizedDescription
            }
        }
        decidingMemoryProposalIDs.remove(proposal.id)
        await refresh()
    }

    func deleteMemory(_ memory: MemoryRecord) {
        guard !deletingMemoryIDs.contains(memory.id) else { return }
        error = nil
        deletingMemoryIDs.insert(memory.id)
        hiddenDeletedMemoryIDs.insert(memory.id)
        memories.removeAll { $0.id == memory.id }

        Task {
            var deleteConfirmed = false
            do {
                try await iCloudSyncEngine.shared.deleteMemory(id: memory.id)
                deleteConfirmed = true
            } catch {
                self.hiddenDeletedMemoryIDs.remove(memory.id)
                self.error = error.localizedDescription
            }
            self.deletingMemoryIDs.remove(memory.id)
            if deleteConfirmed {
                // The action receipt proves only that the Mac accepted the
                // tombstone. Until its next snapshot omits this id, do not
                // keep the row invisibly suppressed forever.
                self.hiddenDeletedMemoryIDs.remove(memory.id)
            }
            await refresh()
            if deleteConfirmed,
               iCloudSyncEngine.shared.memories.contains(where: { $0.id == memory.id }) {
                self.error = "Delete recorded; waiting for Mac/iCloud to remove this memory."
            }
        }
    }
}

// MARK: - Memories list

/// Sweep 2026-09-01 item 36. Memory was delete-only with no way to find the
/// row you meant to delete. This is a pure local filter over rows the phone
/// has already synced — it never claims to have searched anything the Mac
/// holds and the phone has not received.
enum MemorySearchPresentation {
    /// Empty means "no filter", never "no rows". Whitespace is not a query.
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ memory: MemoryRecord, query: String) -> Bool {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return true }
        if memory.text.lowercased().contains(needle) { return true }
        if memory.layer.lowercased().contains(needle) { return true }
        return memory.tags?.contains { $0.lowercased().contains(needle) } ?? false
    }

    static func filter(_ memories: [MemoryRecord], query: String) -> [MemoryRecord] {
        let needle = normalizedQuery(query)
        guard !needle.isEmpty else { return memories }
        return memories.filter { matches($0, query: needle) }
    }

    /// Why the list is empty. A filtered-to-nothing list must never borrow the
    /// "waiting for iCloud" copy — that would blame the sync for the query.
    enum EmptyState: Equatable {
        case noSyncedMemories
        case noMatches(String)
    }

    static func emptyState(visibleCount: Int, syncedCount: Int, query: String) -> EmptyState? {
        guard visibleCount == 0 else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, syncedCount > 0 { return .noMatches(trimmed) }
        return .noSyncedMemories
    }
}

struct MemoryListView: View {
    @ObservedObject var store: MemoryStore
    var searchQuery: String = ""
    var header: AnyView = AnyView(EmptyView())
    @State private var pendingDeleteMemory: MemoryRecord?

    private var isSample: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-memorySample")
        #else
        false
        #endif
    }

    private var sourceMemories: [MemoryRecord] {
        guard isSample else { return store.memories }
        // View-only fixtures; never inserted into the store or sent to the Mac.
        let json = """
        [
          {"id":"sample-1","layer":"semantic","text":"Keep mornings open for focused work and save errands for the afternoon.","importance":0.8,"confidence":1,"tags":["routine","focus"],"createdAt":"2026-09-07"},
          {"id":"sample-2","layer":"episodic","text":"A walk by the water was a good way to end a busy week.","importance":0.6,"confidence":1,"tags":["weekend","outdoors"],"createdAt":"2026-09-07"},
          {"id":"sample-3","layer":"semantic","text":"When planning a project, start with a short outline and one useful next step.","importance":0.7,"confidence":1,"tags":["planning"],"createdAt":"2026-09-07"}
        ]
        """
        return (try? JSONDecoder().decode([MemoryRecord].self, from: Data(json.utf8))) ?? []
    }

    private var visibleMemories: [MemoryRecord] {
        MemorySearchPresentation.filter(sourceMemories, query: searchQuery)
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteMemory != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteMemory = nil }
            }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            header.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if isSample { Text("Sample memories").font(.caption).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary).listRowBackground(Color.clear) }
            if let emptyState = MemorySearchPresentation.emptyState(
                visibleCount: visibleMemories.count,
                syncedCount: sourceMemories.count,
                query: searchQuery
            ) {
                switch emptyState {
                case .noSyncedMemories:
                    AppEmptyState(
                        title: "No memories",
                        systemImage: "brain.head.profile",
                        kind: .unavailable,
                        description: "Memories will appear here after iCloud sync."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                case .noMatches(let query):
                    AppEmptyState(
                        title: "No matches",
                        systemImage: "magnifyingglass",
                        kind: .empty,
                        description: "No synced memory matches \u{201c}\(query)\u{201d}."
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else {
                // PATCH-2026-05-07: polish-MemoryView importance-tinted layer badge, richer tag pills
                ForEach(visibleMemories) { memory in
                    let importance = memory.importance
                    let importanceTint = NativeAgentMobileTheme.Colors.metadataText
                    let isDeleting = store.deletingMemoryIDs.contains(memory.id)
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(memory.layer.capitalized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(importanceTint)
                            Spacer()
                            if memory.pinned == true {
                                Image(systemName: "pin").font(.caption).foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                            }
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(String(format: "Importance %.0f%%", importance * 100))
                                .font(AppFont.mono)
                                .foregroundStyle(importanceTint)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memory.layer.capitalized)
                            Text(String(format: "Importance %.0f%%", importance * 100))
                            if memory.pinned == true { Label("Pinned", systemImage: "pin") }
                            if isDeleting { ProgressView().controlSize(.small) }
                        }
                        .font(.caption)
                        .foregroundStyle(importanceTint)
                        }
                        Text(memory.text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tags = memory.tags, !tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(tags, id: \.self) { tag in
                                        MemoryTagPill(tag: tag)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .id(memory.id)
                    .listRowBackground(NativeAgentMobileTheme.Colors.contentSurface)
                    .swipeActions(edge: .trailing) {
                        Button(
                            role: ButtonRole.destructive,
                            action: { pendingDeleteMemory = memory },
                            label: { Label("Delete", systemImage: "trash") }
                        )
                        .disabled(isDeleting || isSample)
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            #if DEBUG
            if isSample, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-memorySampleRow"),
               ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
                proxy.scrollTo(ProcessInfo.processInfo.arguments[i + 1], anchor: .top)
            }
            // Account status can arrive after the first layout. Reposition the
            // fixture after the status changes the actual list viewport.
            if isSample && ProcessInfo.processInfo.arguments.contains("-memorySampleEnd"), let last = visibleMemories.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            #endif
        }
        .onAppear {
            #if DEBUG
            if isSample, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-memorySampleRow"),
               ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
                proxy.scrollTo(ProcessInfo.processInfo.arguments[i + 1], anchor: .top)
            }
            if isSample && ProcessInfo.processInfo.arguments.contains("-memorySampleEnd"), let last = visibleMemories.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            #endif
        }
        .confirmationDialog(
            "Delete memory?",
            isPresented: isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let memory = pendingDeleteMemory {
                Button("Delete Memory", role: .destructive) {
                    store.deleteMemory(memory)
                }
            }
        } message: {
            if let memory = pendingDeleteMemory {
                Text(MemoryDeleteConfirmationPresentation.message(for: memory))
            }
        }
        }
    }
}

private struct MemoryTagPill: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NativeAgentMobileTheme.Colors.quietFill)
            .foregroundStyle(NativeAgentMobileTheme.Colors.metadataText)
            .clipShape(Capsule())
    }
}

enum MemoryDeleteConfirmationPresentation {
    static func message(for memory: MemoryRecord) -> String {
        "Delete \u{201c}\(memory.text)\u{201d} from durable memory? This writes a tombstone so it does not come back."
    }
}

// MARK: - Memory proposal list

struct ProposalsListView: View {
    @ObservedObject var store: MemoryStore
    var header: AnyView = AnyView(EmptyView())

    var body: some View {
        List {
            header.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if !store.memoryProposals.isEmpty {
                Section("Memory Proposals (\(store.memoryProposals.count))") {
                    ForEach(store.memoryProposals) { proposal in
                        MemoryProposalRow(
                            proposal: proposal,
                            isDeciding: store.decidingMemoryProposalIDs.contains(proposal.id),
                            onApprove: { store.approveMemoryProposal(proposal) },
                            onDeny: { store.rejectMemoryProposal(proposal) }
                        )
                    }
                }
            }

            if store.memoryProposals.isEmpty {
                AppEmptyState(
                    title: "No memory proposals",
                    systemImage: "lightbulb",
                    kind: .empty,
                    description: "Pending memory proposals will appear here."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct MemoryProposalRow: View {
    let proposal: MemoryProposalRecord
    let isDeciding: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.displayText ?? proposal.text)
                .font(AppFont.body)
                .lineLimit(3)

            Text(proposal.evidenceSummary)
                .font(AppFont.label)
                .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)

            HStack(spacing: 8) {
                if let layer = proposal.layer {
                    Text(layer)
                        .font(AppFont.label)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
                Spacer(minLength: 8)
                if let imp = proposal.importance {
                    Text(String(format: "importance %.0f%%", imp * 100))
                        .font(AppFont.tag)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                }
            }

            HStack(spacing: 10) {
                if isDeciding {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 8)
                Button(role: .destructive, action: onDeny) {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .disabled(isDeciding)

                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isDeciding)
            }
            .font(AppFont.label)
        }
        .padding(.vertical, 4)
    }
}

// NOTE (2026-06-06): The "Apple-native memory stack" summary card
// (`MemoryStackPanelCard`) was removed along with `MemoryStackStatus` and the
// `memory_stack.json` read — no writer for that snapshot exists on disk, so
// the card was always showing placeholder defaults.
