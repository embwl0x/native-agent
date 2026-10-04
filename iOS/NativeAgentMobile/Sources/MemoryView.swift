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
    @EnvironmentObject private var pairingStore: PairingStore
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
        var segment = initialSegment
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-memorySampleProposals") { segment = .proposals }
        #endif
        _segment = State(initialValue: segment)
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
        // At the tab root the bar has nothing to hold; pushed, it keeps Back.
        .alivePageChrome(title: "Memories", root: embedInNavigationStack)
        // The search floats over the list, above the tab bar, like the
        // composer. Outside the chrome, so the list's bottom fade runs under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing to search until something has arrived.
            if segment == .memories && (!store.memories.isEmpty || MemorySamples.isOn || !searchQuery.isEmpty) {
                AliveSearchField(prompt: "Search memories", text: $searchQuery)
                    .padding(.horizontal, AliveMetrics.pageInset)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
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

    private var headerLine: String {
        let sample = MemorySamples.isOn
        switch segment {
        case .memories:
            return MemoryWords.memoriesLine(sample ? MemorySamples.memories.count : store.memories.count)
        case .proposals:
            let count = sample && store.memoryProposals.isEmpty ? MemorySamples.proposals.count : store.memoryProposals.count
            return MemoryWords.proposalsLine(count)
        }
    }

    private var memoryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            AlivePageHeader(title: "Memories", line: headerLine,
                            style: embedInNavigationStack ? .root : .pushed)
                .padding(.horizontal, 4)
            memorySyncStatus
            AliveSegmentedPicker(selection: $segment, options: MemorySegment.allCases) { $0.rawValue }
                .padding(.top, 6)
            if let error = MemoryErrorLinePresentation.visibleMessage(store.error) {
                MemoryErrorLine(message: error) {
                    store.dismissError()
                }
            }
        }
        .padding(.top, embedInNavigationStack ? AliveMetrics.rootTop : 4)
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
            let state = MacSnapshotPageFreshness.state(
                // This segment's own delivery clock, not the cache-read clock.
                lastSyncedAt: sample == "stale"
                    ? context.date.addingTimeInterval(-7200)
                    : sample != nil
                        ? nil
                        : sync.transportDeliveryAt(screenGroup: Self.snapshotGroup(for: segment)),
                now: context.date)
            let reason = MacSnapshotGroupStaleness.reason(in: sync.staleSnapshotGroups, group: Self.snapshotGroup(for: segment))
            let sharedError = MemoryErrorLinePresentation.visibleMessage(sync.syncError)
            // The Mac's status is said once, in the chat header and More ›
            // Connection. Here: unpaired, only the one way on; paired, only
            // this page's own age when it is stale or never arrived.
            let unpaired = sample == nil && !pairingStore.usesICloudTransport
            // A paired phone that lost its Apple Account: no snapshot can
            // arrive, so the age alone would not say why or how to fix it.
            let noAccount = sample == "noAccount" || (sample == nil && hasNoCloudAccount)
            let attention = sharedError != nil || reason != nil || StatusConnectionPresentation.needsAttention(state)
            if unpaired {
                AliveNoteAction(title: "Pair with Mac", hint: "Connects this iPhone to your Mac") {
                    showsConnection = true
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if noAccount {
                AliveStatusNote(
                    systemImage: "icloud.slash",
                    text: AliveConnection.noICloud + ". Sign in to iCloud in Settings and my memories will arrive here.",
                    actionTitle: "Open Settings",
                    actionHint: "Sign in to Apple Account in Settings, then return to refresh memories."
                ) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            } else if attention {
                // The page note every page wears: what is true, and one way on.
                let title = sharedError != nil ? "My memories couldn\u{2019}t update"
                    : reason != nil ? "My memories may be out of date"
                    : MacSnapshotPageFreshness.line(for: state)
                let detail: String? = sharedError != nil ? nil
                    : reason.map { "Saved memories may be out of date. \($0)" }
                AliveStatusNote(
                    systemImage: "arrow.clockwise.icloud",
                    text: [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "),
                    actionTitle: "Refresh memories"
                ) {
                    Task { await store.refresh() }
                }
            } else {
                AliveFootnote(MacSnapshotPageFreshness.line(for: state))
            }
        }
        .macSyncErrorBanner()
    }
}

/// Plain words for the page: counts spelled out, kinds named for people.
private enum MemoryWords {
    static func memoriesLine(_ n: Int) -> String {
        switch n {
        case 0: return "What I keep from our conversations."
        case 1: return "I remember one thing."
        default: return "I remember \(AliveWords.spelled(n, capitalized: false)) things."
        }
    }

    static func proposalsLine(_ n: Int) -> String {
        switch n {
        case 0: return "What I\u{2019}d like to remember, for you to decide."
        case 1: return "One thing I\u{2019}d like to remember."
        default:
            return AliveWords.spelled(n) + " things I\u{2019}d like to remember."
        }
    }

    static func kind(_ layer: String?) -> String? {
        guard let raw = layer?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "semantic": return "Fact"
        case "episodic": return "Moment"
        case "procedural": return "Habit"
        case "working": return "For now"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func meta(kind: String?, pinned: Bool, importance: Double?, extra: [String]) -> String {
        var parts: [String] = []
        if let kind { parts.append(kind) }
        if pinned { parts.append("pinned") }
        if let importance, importance >= 0.8 { parts.append("important") }
        return (parts + extra).joined(separator: " \u{00B7} ")
    }

    static func evidence(_ proposal: MemoryProposalRecord) -> String {
        let times = proposal.recurrenceCount <= 1 ? "once" : proposal.recurrenceCount == 2 ? "twice" : "\(AliveWords.spelled(proposal.recurrenceCount, capitalized: false)) times"
        let sessions = proposal.supportingSessionIds.count
        guard sessions > 1 else { return "noticed \(times)" }
        return "noticed \(times) across \(AliveWords.spelled(sessions, capitalized: false)) conversations"
    }
}

/// View-only fixtures for `-memorySample`; never inserted into the store or
/// sent to the Mac.
private enum MemorySamples {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-memorySample")
        #else
        false
        #endif
    }

    static let memories: [MemoryRecord] = decode("""
    [
      {"id":"sample-1","layer":"semantic","text":"Keep mornings open for focused work and save errands for the afternoon.","importance":0.8,"confidence":1,"tags":["routine","focus"],"createdAt":"2026-09-07"},
      {"id":"sample-2","layer":"episodic","text":"A walk by the water was a good way to end a busy week.","importance":0.6,"confidence":1,"tags":["weekend","outdoors"],"createdAt":"2026-09-07"},
      {"id":"sample-3","layer":"semantic","text":"When planning a project, start with a short outline and one useful next step.","importance":0.7,"confidence":1,"tags":["planning"],"createdAt":"2026-09-07"}
    ]
    """)

    static let proposals: [MemoryProposalRecord] = decode("""
    [
      {"id":"sample-p1","text":"Prefers a short summary first, with the details after.","layer":"semantic","importance":0.85,"supporting_session_ids":["a","b"],"recurrence_count":3},
      {"id":"sample-p2","text":"Likes to finish the week with a walk outside.","layer":"episodic","importance":0.5,"supporting_session_ids":[],"recurrence_count":1}
    ]
    """)

    private static func decode<T: Decodable>(_ json: String) -> [T] {
        (try? JSONDecoder().decode([T].self, from: Data(json.utf8))) ?? []
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

    func refresh(preservingActionError: Bool = false) async {
        isLoading = true
        if !preservingActionError { error = nil }
        await refreshMemorySnapshot()
        let sync = iCloudSyncEngine.shared
        applySyncedState(from: sync)
        if !preservingActionError || error == nil {
            error = MemoryErrorLinePresentation.visibleMessage(syncErrorProvider())
        }
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
                refresh: { await self.refresh(preservingActionError: true) }
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
            await refresh(preservingActionError: true)
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

    private var isSample: Bool { MemorySamples.isOn }

    private var sourceMemories: [MemoryRecord] {
        isSample ? MemorySamples.memories : store.memories
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
            header.aliveListRow(top: 0, bottom: 10)
            if let emptyState = MemorySearchPresentation.emptyState(
                visibleCount: visibleMemories.count,
                syncedCount: sourceMemories.count,
                query: searchQuery
            ) {
                switch emptyState {
                case .noSyncedMemories:
                    AliveCalmState(
                        title: "Nothing here yet.",
                        line: "What I learn with you on the Mac arrives here once iCloud syncs."
                    )
                    .aliveListRow()
                case .noMatches(let query):
                    AliveCalmState(
                        title: "Nothing matches \u{201c}\(query)\u{201d}.",
                        line: "I only search the memories already on this iPhone."
                    )
                    .aliveListRow()
                }
            } else {
                ForEach(visibleMemories) { memory in
                    let isDeleting = store.deletingMemoryIDs.contains(memory.id)
                    MemoryCard(memory: memory, isDeleting: isDeleting)
                        .id(memory.id)
                        .aliveListRow(top: 5, bottom: 5)
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
        .scrollDismissesKeyboard(.immediately)
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

/// One memory, as I would say it: the words first and large, what kind of
/// thing it is and its tags as quiet small words under it.
private struct MemoryCard: View {
    let memory: MemoryRecord
    let isDeleting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(memory.text)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(AlivePalette.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MemoryWords.meta(kind: MemoryWords.kind(memory.layer),
                                      pinned: memory.pinned == true,
                                      importance: memory.importance,
                                      extra: memory.tags ?? []))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isDeleting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard()
        .accessibilityElement(children: .combine)
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

    private var isSample: Bool { MemorySamples.isOn && store.memoryProposals.isEmpty }

    private var proposals: [MemoryProposalRecord] {
        isSample ? MemorySamples.proposals : store.memoryProposals
    }

    var body: some View {
        List {
            header.aliveListRow(top: 0, bottom: 10)
            if proposals.isEmpty {
                AliveCalmState(
                    title: "Nothing to decide.",
                    line: "When something seems worth keeping, I\u{2019}ll ask you here first."
                )
                .aliveListRow()
            } else {
                ForEach(proposals) { proposal in
                    MemoryProposalRow(
                        proposal: proposal,
                        isDeciding: store.decidingMemoryProposalIDs.contains(proposal.id),
                        // Sample rows are pictures only; they never reach the Mac.
                        onApprove: { if !isSample { store.approveMemoryProposal(proposal) } },
                        onDeny: { if !isSample { store.rejectMemoryProposal(proposal) } }
                    )
                    .aliveListRow(top: 5, bottom: 5)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }
}

/// Something I would like to remember, and your two answers.
struct MemoryProposalRow: View {
    let proposal: MemoryProposalRecord
    let isDeciding: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(proposal.displayText ?? proposal.text)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MemoryWords.meta(kind: MemoryWords.kind(proposal.layer),
                                      pinned: false,
                                      importance: proposal.importance,
                                      extra: [MemoryWords.evidence(proposal)]))
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            MobileAdaptiveRow(spacing: 10) {
                Button(action: onDeny) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .aliveSecondaryButton()
                .accessibilityLabel("Discard this memory")

                Button(action: onApprove) {
                    Group {
                        if isDeciding {
                            ProgressView().tint(.white)
                        } else {
                            Text("Keep")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .alivePrimaryButton()
                .accessibilityLabel("Keep this memory")
            }
            .font(.body.weight(.semibold))
            .controlSize(.large)
            .disabled(isDeciding)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aliveCard()
    }
}

// NOTE (2026-06-06): The "Apple-native memory stack" summary card
// (`MemoryStackPanelCard`) was removed along with `MemoryStackStatus` and the
// `memory_stack.json` read — no writer for that snapshot exists on disk, so
// the card was always showing placeholder defaults.
