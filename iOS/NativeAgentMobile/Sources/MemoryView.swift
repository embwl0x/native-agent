// PATCH-2026-05-19: ui-pull-together MemoryView — Memories / Proposals only.
// Skills have their own primary tab, so this view stays focused on memory.
import SwiftUI
import NativeAgentShared

// MARK: - MemoryView

struct MemoryView: View {
    @StateObject private var store = MemoryStore()
    @ObservedObject private var sync = iCloudSyncEngine.shared
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
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                ForEach(MemorySegment.allCases, id: \.self) { seg in
                    Text(seg.rawValue).tag(seg)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let error = MemoryErrorLinePresentation.visibleMessage(store.error) {
                MemoryErrorLine(message: error) {
                    store.dismissError()
                }
            }

            Group {
                switch segment {
                case .memories:
                    MemoryListView(store: store, searchQuery: searchQuery)
                        .searchable(
                            text: $searchQuery,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search memories"
                        )
                case .proposals:
                    ProposalsListView(store: store)
                }
            }
        }
        .navigationTitle("Memory")
        // Sweep 2026-09-01 item 2: Memory renders Mac-owned rows and had no
        // freshness badge at all, so a group the Mac failed to rebuild read as
        // current memory. The badge follows the visible tab, because Memories
        // and Proposals come from two independently-failing Mac groups.
        .macSnapshotFreshnessBadge(group: Self.snapshotGroup(for: segment))
        .macSyncErrorBanner()
        .toolbar {
            // Sweep R4 C11.4. SyncBadge only appears once the snapshot is
            // >30s old and says nothing about the Mac itself, so the chip
            // sits beside it rather than replacing it.
            ToolbarItem(placement: .navigationBarLeading) {
                MacStatusChip()
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                    SyncBadge(date: syncAt)
                }
            }
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.refresh() } }
        .onChange(of: sync.memories) { _, _ in store.applySyncedState(from: sync) }
        .onChange(of: sync.memoryProposals) { _, _ in store.applySyncedState(from: sync) }
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
                    .foregroundStyle(.secondary)
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
    @State private var pendingDeleteMemory: MemoryRecord?

    private var visibleMemories: [MemoryRecord] {
        MemorySearchPresentation.filter(store.memories, query: searchQuery)
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
        List {
            if let emptyState = MemorySearchPresentation.emptyState(
                visibleCount: visibleMemories.count,
                syncedCount: store.memories.count,
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
                    let importanceTint: Color = importance > 0.7 ? .orange : importance > 0.4 ? .blue : .secondary
                    let isDeleting = store.deletingMemoryIDs.contains(memory.id)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(memory.layer.capitalized)
                                .font(AppFont.label)
                                .foregroundStyle(importanceTint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(importanceTint.opacity(0.1), in: Capsule())
                            Spacer()
                            if memory.pinned == true {
                                Image(systemName: "pin.fill").font(AppFont.tag).foregroundStyle(.orange)
                            }
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(String(format: "%.0f%%", importance * 100))
                                .font(AppFont.mono)
                                .foregroundStyle(importanceTint)
                        }
                        Text(memory.text)
                            .font(AppFont.body)
                            .lineLimit(3)
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
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(
                            role: ButtonRole.destructive,
                            action: { pendingDeleteMemory = memory },
                            label: { Label("Delete", systemImage: "trash") }
                        )
                        .disabled(isDeleting)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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

private struct MemoryTagPill: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(AppFont.tag)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(NativeAgentPalette.agentAccent.opacity(0.12))
            .foregroundStyle(NativeAgentPalette.agentAccent)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    NativeAgentPalette.agentAccent.opacity(0.25),
                    lineWidth: 0.5
                )
            )
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

    var body: some View {
        List {
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
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if let layer = proposal.layer {
                    Text(layer)
                        .font(AppFont.label)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let imp = proposal.importance {
                    Text(String(format: "importance %.0f%%", imp * 100))
                        .font(AppFont.tag)
                        .foregroundStyle(.secondary)
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
