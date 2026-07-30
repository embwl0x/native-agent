// PATCH-2026-05-19: ui-pull-together MemoryView — Memories / Proposals only.
// Skills have their own primary tab, so this view stays focused on memory.
import SwiftUI
import NativeAgentShared

// MARK: - MemoryView

struct MemoryView: View {
    @StateObject private var store = MemoryStore()
    @State private var segment: MemorySegment
    /// `false` when pushed as a navigationDestination from another
    /// NavigationStack (e.g. ActivityView → Memory Proposals). Nesting
    /// NavigationStacks causes the destination to render and immediately
    /// pop back. Default `true` keeps the Memory tab root working.
    private let embedInNavigationStack: Bool

    enum MemorySegment: String, CaseIterable {
        case memories = "Memories"
        case proposals = "Proposals"
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

            if let error = store.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(AppFont.label)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            Group {
                switch segment {
                case .memories:
                    MemoryListView(store: store)
                case .proposals:
                    ProposalsListView(store: store)
                }
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if let syncAt = iCloudSyncEngine.shared.lastSyncAt {
                    SyncBadge(date: syncAt)
                }
            }
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.refresh() } }
    }
}

// MARK: - Store

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

    private var hiddenResolvedMemoryProposalIDs: Set<String> = []
    private var hiddenDeletedMemoryIDs: Set<String> = []

    func refresh() async {
        isLoading = true
        await iCloudSyncEngine.shared.refreshMemorySnapshot()
        let sync = iCloudSyncEngine.shared
        memories = sync.memories.filter { !hiddenDeletedMemoryIDs.contains($0.id) }
        memoryProposals = sync.memoryProposals.filter { !hiddenResolvedMemoryProposalIDs.contains($0.id) }
        isLoading = false
    }

    func approveMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: true)
    }

    func rejectMemoryProposal(_ proposal: MemoryProposalRecord) {
        decideMemoryProposal(proposal, approve: false)
    }

    private func decideMemoryProposal(_ proposal: MemoryProposalRecord, approve: Bool) {
        guard !decidingMemoryProposalIDs.contains(proposal.id) else { return }
        error = nil
        decidingMemoryProposalIDs.insert(proposal.id)
        hiddenResolvedMemoryProposalIDs.insert(proposal.id)
        memoryProposals.removeAll { $0.id == proposal.id }

        Task {
            do {
                if approve {
                    try await iCloudSyncEngine.shared.approveMemoryProposal(proposalId: proposal.id)
                } else {
                    try await iCloudSyncEngine.shared.rejectMemoryProposal(proposalId: proposal.id)
                }
            } catch {
                if iCloudSyncEngine.isMacResponseTimeout(error) {
                    self.error = "Decision sent; waiting for Mac/iCloud to publish the result."
                } else {
                    self.hiddenResolvedMemoryProposalIDs.remove(proposal.id)
                    self.error = error.localizedDescription
                }
            }
            self.decidingMemoryProposalIDs.remove(proposal.id)
            await refresh()
        }
    }

    func deleteMemory(_ memory: MemoryRecord) {
        guard !deletingMemoryIDs.contains(memory.id) else { return }
        error = nil
        deletingMemoryIDs.insert(memory.id)
        hiddenDeletedMemoryIDs.insert(memory.id)
        memories.removeAll { $0.id == memory.id }

        Task {
            do {
                try await iCloudSyncEngine.shared.deleteMemory(id: memory.id)
            } catch {
                self.hiddenDeletedMemoryIDs.remove(memory.id)
                self.error = error.localizedDescription
            }
            self.deletingMemoryIDs.remove(memory.id)
            await refresh()
        }
    }
}

// MARK: - Memories list

struct MemoryListView: View {
    @ObservedObject var store: MemoryStore
    @State private var selectedMemory: MemoryRecord?
    @State private var pendingDeleteMemory: MemoryRecord?

    var body: some View {
        List {
            if store.memories.isEmpty {
                AppEmptyState(
                    title: "No memories",
                    systemImage: "brain.head.profile",
                    description: "Memories will appear here after iCloud sync."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                // PATCH-2026-05-07: polish-MemoryView importance-tinted layer badge, richer tag pills
                ForEach(store.memories) { memory in
                    let importance = memory.importance
                    let importanceTint: Color = importance > 0.7 ? .orange : importance > 0.4 ? .blue : .secondary
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
                            if store.deletingMemoryIDs.contains(memory.id) {
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
                                        Text(tag)
                                            .font(AppFont.tag)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(NativeAgentPalette.agentAccent.opacity(0.12))
                                            .foregroundStyle(NativeAgentPalette.agentAccent)
                                            .clipShape(Capsule())
                                            .overlay(Capsule().strokeBorder(NativeAgentPalette.agentAccent.opacity(0.25), lineWidth: 0.5))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDeleteMemory = memory
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(store.deletingMemoryIDs.contains(memory.id))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "Delete memory?",
            isPresented: Binding(
                get: { pendingDeleteMemory != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteMemory = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive) {
                if let pendingDeleteMemory {
                    store.deleteMemory(pendingDeleteMemory)
                }
                pendingDeleteMemory = nil
            }
        } message: {
            Text("This removes it from durable memory and writes a tombstone so it does not come back.")
        }
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
