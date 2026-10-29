import Cognition
import Foundation
import SwiftUI
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore

// Blueprint: | `MemoriesPageView.swift` | `MemoriesPageView`: canonical recall rows without inventory substitution; request-scoped loading/failure, retained rows labeled by their original query |

// MARK: - Metrics

enum MemoriesPageMetrics {
    // The same ramp the rest of the shell runs (ShellType).
    static let titleSize: CGFloat = ShellType.bodySize
    static let lineSize: CGFloat = ShellType.labelSize
    static let metaSize: CGFloat = ShellType.labelSize
    /// The first paint shows the newest sixty; the rest sit behind one fold.
    /// A page that lays four hundred rows out at once is a table, not a page.
    static let keptShown = 60
    /// Additional loaded history rows revealed by each Show more action.
    static let foldRowCap = 60
    /// Characters that fit on one line beside the row's padding at 13pt.
    static let rowLineLimit = TodayMetrics.rowLineLimit
}

// MARK: - The page

struct MemoriesPageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var query = ""
    @State private var loaded = false
    @State private var readCount = 0
    @State private var rejectedShown = MemoriesPageMetrics.foldRowCap
    @State private var now = Date()
    @State private var searchTask: Task<Void, Never>?
    @State private var openFolds: Set<String> = []
    @State private var notice: String?
    @State private var fullText: MemoriesFullText?
    @State private var savingProposalIDs: Set<String> = []
    @State private var ordered: [MemoryRow] = []
    @State private var found: [MemoryRow] = []

    private struct MemoryRow: Identifiable, Sendable {
        let memory: MemoryV2.MemoryRecord
        let line: String
        let meta: String
        var id: String { memory.id }
    }

    private struct RowInput: Equatable, Sendable {
        let memories: [MemoryV2.MemoryRecord]
        let results: [MemoryV2.MemoryRecord]?
        let resultQuery: String?
        let requestQuery: String?
        let error: String?
        let query: String
        let now: Date
    }

    private var rowInput: RowInput {
        RowInput(memories: memories, results: memory.searchResults,
                 resultQuery: memory.searchResultQuery, requestQuery: memory.searchQuery,
                 error: memory.searchError, query: query, now: now)
    }

    private enum Fold {
        static let showAll = "show-all"
        static let deleted = "deleted"
        static let upkeep = "upkeep"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                NativeSearchField(text: $query, prompt: "Search what I remember",
                                  identifier: "memories.search", accessibilityLabel: "Search memories")

                PageReadStatus(
                    isReading: !loaded || readCount > 0,
                    text: !loaded ? "Reading my memories…" : readCount > 0 ? "Refreshing my memories…" : nil
                )

                if isSearching {
                    searchSection
                } else {
                    if !pendingProposals.isEmpty {
                        waitingCard.transition(NativeAgentMotion.arrivalFade)
                    }
                    keptSection
                    deletedFold
                    // The store's upkeep and status, folded: nobody needs it
                    // to read what was kept, and nothing of it is lost.
                    MemoriesFold(title: "Upkeep and details", isOpen: binding(Fold.upkeep)) {
                        MemoryUpkeepPanel()
                    }
                    .accessibilityIdentifier("memories.upkeep")
                }

                if let notice {
                    Text(notice)
                        .font(.system(size: MemoriesPageMetrics.metaSize))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityIdentifier("memories.notice")
                }

                // The one line a quiet page must still say out loud. Same
                // sentence as Today's, because it is the same store.
                if memory.proposalsReadFailed {
                    Text("I couldn't read my memory just now.")
                        .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("memories.memory-trouble")
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $fullText) { item in
            MemoryFullTextView(
                text: item.text,
                onCorrect: item.memoryID.map { id in
                    { correct(memoryID: id, text: item.text) }
                }
            )
        }
        // Same live binding TodayView takes: the memory database and its WAL,
        // debounced, re-armed whenever the window comes back to the front. A
        // proposal staged while he sits here appears without a manual refresh.
        .liveTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            let database = appModel.engine.dataRoot
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("memory.sqlite")
            await EventDeadlinePhysiology.refreshOnChanges(paths: [
                database,
                URL(fileURLWithPath: database.path + "-wal"),
            ]) {
                await reload()
            }
        }
        // The visible page is loaded by the watcher above; the offscreen copy
        // a quiet read mounts has no watcher, so it reads once.
        .quietReadTask(live: false) { await reload() }
        .task(id: rowInput) {
            let input = rowInput
            let rows = await Task.detached {
                func row(_ record: MemoryV2.MemoryRecord) -> MemoryRow {
                    MemoryRow(memory: record, line: MemoriesPageContent.line(record.text),
                              meta: MemoriesPageContent.meta(record, now: input.now))
                }
                let ordered = MemoriesPageContent.ordered(input.memories).map(row)
                let found = MemorySearchPresentation.displayedRecords(
                    input.memories, query: input.query, semanticResults: input.results,
                    resultQuery: input.resultQuery, requestQuery: input.requestQuery,
                    error: input.error
                ).map(row)
                return (ordered, found)
            }.value
            guard !Task.isCancelled, input == rowInput else { return }
            (ordered, found) = rows
        }
        // The owner starts its generation gate before its debounce, so a new
        // keystroke invalidates old results instead of leaving a previous
        // query's rows under the current search text.
        .onChange(of: query) { _, newValue in
            found = []
            searchTask?.cancel()
            searchTask = Task { await memory.search(query: newValue) }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var memory: MemoryFacade { appModel.engine.memory }
    private var memories: [MemoryV2.MemoryRecord] { memory.memories }

    // MARK: search

    private var isSearching: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    private var searchState: MemorySearchPresentation {
        MemorySearchPresentation.resolve(
            query: query,
            resultCount: found.count,
            isLoading: memory.searchIsLoading
                && MemorySearchPresentation.matchesCurrentQuery(
                    query, resultQuery: memory.searchQuery),
            error: MemorySearchPresentation.matchesCurrentQuery(
                query, resultQuery: memory.searchQuery)
                ? memory.searchError
                : nil
        )
    }


    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            if case .unavailable = searchState {
                AliveEyebrow("Search unavailable")
            } else {
                AliveEyebrow("What I found")
            }
            switch searchState {
            case .searching:
                Text("Looking\u{2026}")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityIdentifier("memories.search-trouble")
                if !found.isEmpty { searchRows }
            case .empty:
                Text("Nothing I've kept matches that.")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
            case .results, .allMemories:
                if found.isEmpty {
                    Text("Nothing I've kept matches that.")
                        .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                        .foregroundStyle(NativeAgentShell.secondary)
                } else {
                    searchRows
                }
            }
        }
    }

    private var searchRows: some View {
        AliveGroupCard(lazy: true) {
            ForEach(found, id: \.id) { memory in
                keptRow(memory)
            }
        }
    }

    // MARK: waiting for you

    private var pendingProposals: [ProposalRecord] {
        memory.proposals.filter { $0.status == "pending" }
    }

    /// Today's waiting card, and only when something is actually pending.
    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Waiting for you")
            AliveGroupCard(waiting: true) {
                ForEach(pendingProposals) { proposal in
                    MemoriesProposalRow(
                        line: proposal.content,
                        meta: MemoriesPageContent.proposalMeta(
                            proposal, staged: "staged \(MemoriesWhen.words(proposal.createdAt, now: now))"),
                        isSaving: savingProposalIDs.contains(proposal.id),
                        onKeep: { decide(proposal, keep: true) },
                        onNotNow: { decide(proposal, keep: false) }
                    )
                    .transition(NativeAgentMotion.arrivalFade)
                }
            }
            .accessibilityIdentifier("memories.waiting-for-you")
        }
    }

    // MARK: what I've kept

    @ViewBuilder
    private var keptSection: some View {
        let ordered = self.ordered
        if ordered.isEmpty {
            if memories.isEmpty, loaded, !memory.proposalsReadFailed,
               appModel.panelRefreshStatus[.memories]?.failedEndpoints.contains("memories") == false {
                Text("It fills up as we talk.")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                AliveEyebrow("What I've kept")
                AliveGroupCard(lazy: true) {
                    ForEach(Array(ordered.prefix(MemoriesPageMetrics.keptShown)), id: \.id) { memory in
                        keptRow(memory)
                    }
                }
            }
            let rest = Array(ordered.dropFirst(MemoriesPageMetrics.keptShown))
            if !rest.isEmpty {
                MemoriesFold(title: "\(rest.count) more", isOpen: binding(Fold.showAll)) {
                    AliveGroupCard(lazy: true) {
                        ForEach(rest, id: \.id) { memory in
                            keptRow(memory)
                        }
                    }
                }
                .accessibilityIdentifier("memories.show-all")
            }
        }
    }

    private func keptRow(_ row: MemoryRow) -> some View {
        let memory = row.memory
        return MemoriesRowCard(
            line: row.line,
            meta: row.meta,
            isPinned: memory.pinned == true,
            onRead: { fullText = MemoriesFullText(id: memory.id, text: memory.text, memoryID: memory.id) },
            onTogglePin: { Task { await togglePin(memory) } },
            onDelete: { Task { await delete(memory) } }
        )
    }

    // MARK: deleted

    @ViewBuilder
    private var deletedFold: some View {
        if !memory.rejectedProposals.isEmpty {
            let count = memory.rejectedProposals.count
            MemoriesFold(
                title: "\(count) \(DeskPageWords.plural(count, "thing I let go", "things I let go"))",
                isOpen: binding(Fold.deleted)
            ) {
                // Rejected history is read-only; MemoryV2 has no un-reject action.
                AliveGroupCard {
                    MemoriesRejectedHistory(proposals: memory.rejectedProposals, shown: $rejectedShown) { proposal in
                        fullText = MemoriesFullText(
                            id: proposal.id, text: proposal.content)
                    }
                }
            }
            .accessibilityIdentifier("memories.deleted")
        }
    }

    // MARK: actions

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { openFolds.contains(key) },
            set: { isOpen in
                if isOpen { openFolds.insert(key) } else { openFolds.remove(key) }
            })
    }

    /// Keep and reject use the canonical proposal actions.
    private func decide(_ proposal: ProposalRecord, keep: Bool) {
        guard savingProposalIDs.insert(proposal.id).inserted else { return }
        Task {
            defer { savingProposalIDs.remove(proposal.id) }
            do {
                if keep {
                    try await appModel.approveMemoryProposal(id: proposal.id)
                } else {
                    try await appModel.rejectMemoryProposal(id: proposal.id)
                }
                notice = keep ? "Kept it." : "Left it."
                await reload()
            } catch {
                notice = "I couldn't save that decision just now."
            }
        }
    }

    /// "Correct this" hands the exact row to Chat and stops. The replacement
    /// is his to write; she saves it with the `corrects` lineage so the old
    /// row is retired rather than left competing with the new one.
    @MainActor
    private func correct(memoryID: String, text: String) {
        fullText = nil
        let draft = """
            Correct what you remember. The memory (id \(memoryID)) says:

            "\(text)"

            What's actually true:
            """
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }

    @MainActor
    private func togglePin(_ memory: MemoryV2.MemoryRecord) async {
        let outcome = await appModel.pinMemory(memory, pinned: !(memory.pinned ?? false))
        notice = outcome.message
    }

    @MainActor
    private func delete(_ memory: MemoryV2.MemoryRecord) async {
        if await !appModel.deleteMemory(memory) {
            appModel.systemToasts.push(error: appModel.statusText)
            notice = "I couldn't forget that one."
        } else {
            notice = "Forgotten."
        }
    }

    @MainActor
    private func reload() async {
        readCount += 1
        defer { readCount -= 1 }
        // Refresh memories, proposals and status through their shared owner.
        await appModel.refreshForSidebarItem(.memories)
        await memory.refreshRejectedHistory()
        if let error = memory.rejectedHistoryError { notice = error }
        guard !Task.isCancelled else { return }
        now = Date()
        loaded = true
    }
}

/// The mounted Memory search field distinguishes a still-running canonical
/// search from an honest empty result and from a failed canonical reader.
enum MemorySearchPresentation: Equatable {
    case allMemories
    case searching
    case results
    case empty
    case unavailable(String)

    static func matchesCurrentQuery(_ query: String, resultQuery: String?) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count >= 3
            && resultQuery?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
    }

    /// Only canonical rows belong to a search. Prior rows may accompany a
    /// failed current request, whose error names their original query.
    static func displayedRecords<Record>(
        _ records: [Record],
        query: String,
        semanticResults: [Record]?,
        resultQuery: String?,
        requestQuery: String?,
        error: String?
    ) -> [Record] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return records }
        guard matchesCurrentQuery(query, resultQuery: requestQuery),
              error != nil || matchesCurrentQuery(query, resultQuery: resultQuery)
        else { return [] }
        return semanticResults ?? []
    }

    static func resolve(
        query: String,
        resultCount: Int,
        isLoading: Bool,
        error: String?
    ) -> Self {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return .allMemories
        }
        if isLoading { return .searching }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        if resultCount > 0 { return .results }
        return .empty
    }
}
