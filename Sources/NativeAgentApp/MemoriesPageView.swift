import Cognition
import Foundation
// MemoriesPageView.swift
// WHAT I'VE KEPT, IN HER WORDS. (ui-simplify 2026-09-03, lane M.)
//
// The classic Memory page opens on a Memory Status card — backend name, vector
// count, CloudKit account state, Spotlight index health — then three tabs, then
// rows stamped `adaptive-promoter:abc123 · conf 87% · saved 3w ago`. That is a
// database inspector wearing the word "Memory". None of it is what she
// remembers.
//
// Same data, Today's shape:
//
//   · One centred column. The word "Memories", and under it one line in her
//     voice that says how many things she has kept.
//   · The status card is gone. The ONE thing a person needs to hear about the
//     store is whether it could be read at all, and that is one grey line at
//     the bottom — the same sentence, and the same honesty, as TodayView's
//     `memoryUnreadable`.
//   · "Waiting for you" first, teal, and ONLY when something is pending. Each
//     proposal is named and carries Keep / Don't keep beside it, so the moment
//     review IS this page rather than a tab behind a segmented control.
//   · "What I've kept": uniform rows. One line of the memory, cut at a word
//     boundary, and a meta line of plain words — "in July · I checked it
//     myself". Never `sourceRunId`, never a confidence percentage, never a
//     lifecycle value.
//   · "Deleted" is one fold with a count at the bottom.
//   · No coloured badges anywhere. Pinned is the WORD Pinned in the meta line,
//     exactly the way the conversations list says it.
//
// Nothing is lost. Every action the classic page offers is still here and calls
// the SAME function:
//
//   the memories        engine.memory.memories (refreshForSidebarItem(.memories))
//   search              engine.memory.search + the same
//                       MemorySearchPresentation.displayedRecords projection,
//                       so meaning-based results win over word matches exactly
//                       as they do on the classic page
//   pending proposals   engine.memory.proposals, status "pending"
//   keep / don't keep   AppModel.approveMemoryProposal / rejectMemoryProposal
//   pin / unpin         AppModel.pinMemory
//   delete              AppModel.deleteMemory (behind the same confirmation)
//   read                MemoryFullTextView, the classic page's own sheet
//   deleted             engine.memory.proposals(status: "rejected")
//   a moment's quote    engine.memory.proposals metadata `quote`,
//                       from the pending-proposal read already loaded above
//
// The classic page's consolidate / hygiene / Spotlight-reindex menu and its
// status block (with Advanced diagnostics) are the "Upkeep and details" fold
// at the foot of the page (MemoryUpkeepPanel, MemoryView.swift).
//
// Alive glass (2026-09-23), from AlivePageKit like Today and the Desk: the
// rail page's frame draws the serif "Memories" and one counts sentence for
// both tabs; the proposals sit in one waiting group card; the kept rows, the
// search results and each fold's rows are group cards with hairlines between
// rows. Same data, same actions, same ids.

import SwiftUI
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MemoriesPageView.swift` | `MemoriesPageView` struct |

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

// MARK: - Where a memory came from

/// The row's provenance, as a WORD. The stored value is a run handle
/// (`adaptive-promoter:1f3c…`, `moment-promoter:…`) and a run handle
/// on a page about what she remembers is machinery leaking through. Every case
/// below is grounded in a source string something in this app actually writes:
///
///   `moment-promoter:<session>`     MemoryMoments.sourcePrefix
///   `adaptive-promoter:<session>`   MemoryV2+AdaptivePromoter
///   `semantic-adaptive-extractor`   MemoryV2+FoundationModels
///
/// An unrecognised handle says so rather than being dressed up as one of these:
/// inventing a provenance is worse than admitting to none.
enum MemoriesProvenance: Equatable {
    case fromHim
    case fromTalking
    case fromAMoment
    case wroteItDown
    case tidiedUp
    case unknown

    var words: String {
        switch self {
        case .fromHim: "Shared by you"
        case .fromTalking: "I picked it up while we talked"
        case .fromAMoment: "I kept it from something that happened"
        case .wroteItDown: "I wrote it down myself"
        case .tidiedUp: "I tidied it up from older notes"
        case .unknown: "I don't remember where this came from"
        }
    }

    static func classify(_ sourceRunId: String?) -> MemoriesProvenance {
        let raw = (sourceRunId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The app's own word for "a person typed this". ONLY that.
        if raw == "manual" || raw == "user" { return .fromHim }
        // NO HANDLE AT ALL IS NOT AUTHORSHIP (Astra comb 4, lane4 finding 3).
        // Sixteen browsable memories carry `source=NULL` because they were
        // migrated from the legacy candidate files — `7b5e580e-…` ("User
        // appreciates when Agent catches jokes…") retains `legacy_file_id` and a
        // staged, approved `legacy_proposal` with its supporting session. That is
        // an inferred memory she was allowed to keep, not one he handed her, and
        // the page was signing his name to it. This enum's own rule applies:
        // inventing a provenance is worse than admitting to none.
        if raw.isEmpty { return .unknown }
        // Her own commit_memory tool: she wrote it down herself.
        if raw.hasPrefix("chat.commit_memory") || raw.hasPrefix("commit_memory") { return .wroteItDown }
        if raw.hasPrefix(MemoryMoments.sourcePrefix) { return .fromAMoment }
        if raw.hasPrefix("adaptive-promoter") || raw.hasPrefix("semantic-adaptive-extractor") {
            return .fromTalking
        }
        if raw.hasPrefix("consolidat") || raw.hasPrefix("hygiene") { return .tidiedUp }
        return .unknown
    }
}

// MARK: - When, in plain words

/// "today" · "yesterday" · "2 weeks ago" · "in July" · "in July 2025". A
/// timestamp that will not parse says so; it never becomes "just now".
enum MemoriesWhen {
    static func words(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let iso,
              let at = UserDisplayFormatters.parseISOTimestamp(iso)
        else { return "when, I'm not sure" }
        if calendar.isDateInToday(at) { return "today" }
        if calendar.isDateInYesterday(at) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: at, to: now).day ?? 0
        if days >= 0, days < 30 {
            return relativeLock.withLock { relative.localizedString(for: at, relativeTo: now) }
        }
        if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            return "in \(at.formatted(.dateTime.month(.wide)))"
        }
        return "in \(at.formatted(.dateTime.month(.wide).year()))"
    }

    /// One formatter for every row, not one built per row per redraw. Used
    /// only under `relativeLock`, since the caller is not tied to one thread.
    private static let relativeLock = NSLock()
    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// The row sorts on the newest of the two stamps the store keeps.
    static func sortDate(_ memory: MemoryV2.MemoryRecord) -> Date {
        let updated = memory.updatedAt.flatMap { UserDisplayFormatters.parseISOTimestamp($0) }
        let created = UserDisplayFormatters.parseISOTimestamp(memory.createdAt)
        return updated ?? created ?? .distantPast
    }

    /// The stamp the meta line shows: the update if there is one, else the save.
    static func stamp(_ memory: MemoryV2.MemoryRecord) -> String? {
        if let updated = memory.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !updated.isEmpty {
            return updated
        }
        return memory.createdAt
    }
}

// MARK: - What the page says

/// Pure projections, so the copy can be reasoned about without a store.
enum MemoriesPageContent {
    /// The one line under the title. Counts are spelled, the way Today and the
    /// Desk spell them; `DeskPageWords` is the same rule carried past ten.
    static func keptLine(_ count: Int) -> String {
        switch count {
        case 0: return "Nothing kept yet."
        case 1: return "One thing I've kept."
        default: return "\(DeskPageWords.spelled(count)) things I've kept."
        }
    }

    /// The serif header's one sentence (alive glass, 2026-09-23): numerals,
    /// and the proposals named for what they are, memories to look at, never
    /// "waiting on you" (Today and the Desk own that count). Nil until the
    /// memories have been read: a page that has not looked says nothing.
    static func headerLine(loaded: Bool, failed: Bool, kept: Int?, toLookAt: Int) -> String? {
        guard loaded else { return nil }
        guard !failed, let kept else { return "I couldn't refresh all my memories just now." }
        let keep: String
        switch kept {
        case 0: keep = "No memories loaded."
        case 1: keep = "1 memory loaded."
        default: keep = "\(kept) memories loaded."
        }
        guard toLookAt > 0 else { return keep }
        return "\(keep) \(toLookAt) \(toLookAt == 1 ? "memory" : "memories") to look at."
    }

    @MainActor
    static func headerLine(_ appModel: AppModel) -> String? {
        let status = appModel.panelRefreshStatus[.memories]
        return headerLine(
            loaded: status != nil,
            failed: status?.failedEndpoints.contains("memories") == true,
            kept: appModel.engine.memory.totalCount,
            toLookAt: appModel.engine.memory.proposals.filter { $0.status == "pending" }.count)
    }

    /// Pinned first, then newest. The same order the conversations list keeps.
    static func ordered(_ memories: [MemoryV2.MemoryRecord]) -> [MemoryV2.MemoryRecord] {
        // Each stamp parsed once, not twice per comparison.
        memories.map { ($0, MemoriesWhen.sortDate($0)) }.sorted { l, r in
            let (lhs, la) = l, (rhs, ra) = r
            let lp = lhs.pinned == true, rp = rhs.pinned == true
            if lp != rp { return lp }
            if la != ra { return la > ra }
            return lhs.id < rhs.id
        }.map(\.0)
    }

    /// "Pinned · in July · I checked it myself".
    static func meta(_ memory: MemoryV2.MemoryRecord, now: Date) -> String {
        var parts: [String] = []
        if let warning = MemorySenseProvenance.warning(in: memory.extras) { parts.append(warning) }
        if memory.pinned == true { parts.append("Pinned") }
        if MemoryLifecycle.normalized(memory.lifecycle) == MemoryLifecycle.graduated { parts.append("graduated → GROWTH") }
        parts.append(MemoriesWhen.words(MemoriesWhen.stamp(memory), now: now))
        parts.append(MemoriesProvenance.classify(memory.sourceRunId).words)
        return parts.joined(separator: " · ")
    }

    /// One line of the memory, cut at a word boundary and stripped of markdown.
    static func line(_ text: String) -> String {
        TodayWords.line(text, limit: MemoriesPageMetrics.rowLineLimit)
    }

    /// A staged proposal's own words. A moment carries its quote in the stored
    /// content already (`MemoryMoments.composedContent`), so when the metadata
    /// hands one back the row shows it as a quote in her voice, the same way
    /// Today's kept-moments fold does.
    /// The memory itself leads: for a moment that is the agent's own sentence,
    /// for a fact the fact. The quote that made a moment is evidence, shown
    /// beneath, never in place of the memory (User, 2026-09-10).
    /// The quote shows once, beneath (User, 2026-10-10: it read twice).
    static func proposalLine(_ proposal: ProposalRecord) -> String {
        MemoryMoments.narration(ofStored: proposal.content, metadata: proposal.metadata)
    }
    /// The lane first — Moment, Correction or Fact — so a card says what Keep writes.
    static func proposalMeta(_ proposal: ProposalRecord, quote: String?, staged: String) -> String {
        let kind = MemoryMoments.metadataString(proposal.metadata, "kind")
        let lane = (quote?.isEmpty == false || kind == "moment") ? "Moment" : kind == "correction" ? "Correction" : "Fact"
        guard let quote, !quote.isEmpty else { return "\(lane) · \(staged)" }
        return "\(lane) · \u{201C}\(TodayWords.bounded(TodayWords.plain(quote), limit: 120))\u{201D} · \(staged)"
    }
}

// MARK: - The page

struct MemoriesPageView: View {
    /// True under the Memories rail page, which draws the title and the tab
    /// row and insets the column; the page then keeps only its kept line.
    var embedded: Bool = false
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
        let query: String
        let now: Date
    }

    private var rowInput: RowInput {
        RowInput(memories: memories, results: memory.searchResults,
                 resultQuery: memory.searchResultQuery, query: query, now: now)
    }

    private enum Fold {
        static let showAll = "show-all"
        static let deleted = "deleted"
        static let upkeep = "upkeep"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                // Under the rail page the frame draws the serif header (both
                // tabs share its sentence); a bare page draws its own.
                if !embedded { header }

                MemoriesSearchField(text: $query)

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
            .padding(.horizontal, embedded ? 0 : 20)
            .padding(.top, embedded ? 0 : TodayMetrics.topPadding)
            .padding(.bottom, 32)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ShellRoomBackdrop() }
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
            let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let database = root
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
                    resultQuery: input.resultQuery
                ) { $0.text.lowercased().contains($1) }.map(row)
                return (ordered, found)
            }.value
            guard !Task.isCancelled, input == rowInput else { return }
            (ordered, found) = rows
        }
        // The owner starts its generation gate before its debounce, so a new
        // keystroke invalidates old results instead of leaving a previous
        // query's rows under the current search text. Same call the classic
        // page makes, so "meaning, not words" behaves identically here.
        .onChange(of: query) { _, newValue in
            found = []
            searchTask?.cancel()
            searchTask = Task { await memory.search(query: newValue) }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: header

    private var memory: MemoryFacade { appModel.engine.memory }
    private var memories: [MemoryV2.MemoryRecord] { memory.memories }

    private var header: some View {
        AlivePageHeader(
            title: "Memories",
            line: MemoriesPageContent.headerLine(
                loaded: loaded,
                failed: memory.proposalsReadFailed
                    || appModel.panelRefreshStatus[.memories]?.failedEndpoints.contains("memories") == true,
                kept: memory.totalCount,
                toLookAt: pendingProposals.count),
            lineID: "memories.kept-line")
    }

    // MARK: search

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchState: MemorySearchPresentation {
        MemorySearchPresentation.resolve(
            query: query,
            resultCount: found.count,
            isLoading: memory.searchIsLoading
                && MemorySearchPresentation.matchesCurrentQuery(
                    query, resultQuery: memory.searchResultQuery),
            error: MemorySearchPresentation.matchesCurrentQuery(
                query, resultQuery: memory.searchResultQuery)
                ? memory.searchError
                : nil
        )
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("What I found")
            switch searchState {
            case .searching:
                Text("Looking\u{2026}")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
            case .unavailable:
                // The reason is a backend sentence; the page says what it means.
                Text("I couldn't search by meaning just now, and nothing matched the words either.")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityIdentifier("memories.search-trouble")
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
                    AliveGroupCard(lazy: true) {
                        ForEach(found, id: \.id) { memory in
                            keptRow(memory)
                        }
                    }
                }
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
                        line: MemoriesPageContent.proposalLine(proposal),
                        meta: MemoriesPageContent.proposalMeta(
                            proposal,
                            quote: MemoryMoments.isMoment(proposal.metadata) ? MemoryMoments.metadataString(proposal.metadata, "quote") : nil,
                            staged: "staged \(MemoriesWhen.words(proposal.createdAt, now: now))"),
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
                // Read-only on purpose: the classic page's Deleted tab has no
                // restore, and MemoryV2 has no un-reject. A "Bring it back"
                // button here would be a button that cannot do anything.
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

    /// The SAME accept/reject the classic Pending tab calls, one for one.
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
        // The same five-queue read the classic page's Refresh performs, so the
        // memories, the proposals and the status all move together.
        await appModel.refreshForSidebarItem(.memories)
        await memory.refreshRejectedHistory()
        if let error = memory.rejectedHistoryError { notice = error }
        guard !Task.isCancelled else { return }
        now = Date()
        loaded = true
    }
}

// MARK: - Pieces

/// The sheet's identity. `MemoryFullTextView` is the classic page's own
/// read-only full-text sheet — opening it does not pin, delete or mutate.
struct MemoriesFullText: Identifiable, Equatable {
    let id: String
    let text: String
    /// Set only for a kept memory row: the store id a correction is written
    /// against. A rejected proposal has no memory to correct.
    var memoryID: String? = nil
}

/// The page's search box: a rounded quiet field on the card's fill and rim,
/// not a system rounded-border field that belongs to a different app. Its
/// glyphs are secondary: tertiary grey fails 4.5:1 where the haze peaks.
struct MemoriesSearchField: View {
    @Binding var text: String

    var body: some View {
        NativeSearchField(text: $text, prompt: "Search what I remember",
                          identifier: "memories.search", accessibilityLabel: "Search memories")
    }
}

/// A fold on the page: one quiet line (a count and a chevron) that opens its
/// card beneath it. One gesture: one fade, one height change.
struct MemoriesFold<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The Mac's own disclosure (User 09-27: all controls native).
        DisclosureGroup(isExpanded: $isOpen) {
            content()
                .padding(.top, AliveMetrics.eyebrowGap)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One kept memory. Up to two prose lines and a meta line; Read, Pin and
/// Delete appear on hover, the way the conversations list reveals its pin.
/// A row inside the group card: the card carries the chrome.
struct MemoriesRowCard: View {
    let line: String
    let meta: String
    let isPinned: Bool
    let onRead: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case read, pin }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                Text(line.isEmpty ? "An empty note" : line)
                    .font(ShellType.rowTitle)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minHeight: TodayMetrics.rowContentHeight, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                iconButton("doc.text.magnifyingglass", help: "Read the whole thing", action: onRead)
                    .focused($focusedAction, equals: .read)
                iconButton(
                    isPinned ? "pin.fill" : "pin",
                    help: isPinned ? "Unpin" : "Pin to the top",
                    tint: isPinned ? NativeAgentShell.text : nil,
                    action: onTogglePin
                )
                .focused($focusedAction, equals: .pin)
            }
            // Pinned rows keep the pin visible; everything else appears under
            // the cursor, so sixty rows read as sixty lines, not sixty toolbars.
            .opacity(hovering || isPinned || focusedAction != nil ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The Mac's own right-click menu (User 09-27: all controls native).
        .contextMenu {
            Button("Read the whole thing", systemImage: "doc.text.magnifyingglass", action: onRead)
            Button(isPinned ? "Unpin" : "Pin to the top", systemImage: isPinned ? "pin.slash" : "pin",
                   action: onTogglePin)
            Divider()
            Button("Forget this…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        // The classic row's confirmation, kept: a delete cannot be undone.
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\u{201C}\(line)\u{201D}\n\nThis cannot be undone.")
        }
        .accessibilityIdentifier("memories.row")
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ShellType.labelMedium)
                .foregroundStyle(tint ?? NativeAgentShell.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One staged proposal in the teal card: what she'd like to keep, when it was
/// staged, and the two words she needs back.
struct MemoriesProposalRow: View {
    let line: String
    let meta: String
    let isSaving: Bool
    let onKeep: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AliveWaitingDot()
            VStack(alignment: .leading, spacing: 3) {
                // The memory is read whole before it is kept: it wraps.
                Text(line)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Don't keep", action: onNotNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("memories.waiting.not-now")
                Button("Keep", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hazeTinted(.button)
                    .accessibilityIdentifier("memories.waiting.keep")
            }
            .fixedSize()
            .disabled(isSaving)
            .opacity(isSaving ? 0 : 1)
            .overlay {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Loaded history retains the store's order and proposal identity. Reading is
/// available independently of the terminal review decision.
struct MemoriesRejectedHistory: View {
    let proposals: [ProposalRecord]
    @Binding var shown: Int
    let onRead: (ProposalRecord) -> Void

    var body: some View {
        ForEach(Array(proposals.prefix(shown))) { proposal in
            Button { onRead(proposal) } label: {
                HStack {
                    DeskPageDetailRow(
                        title: MemoriesPageContent.line(proposal.content),
                        line: "", meta: "I didn't keep this")
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read the whole thing")
            .accessibilityIdentifier("memories.deleted.read.\(proposal.id)")
        }
        if proposals.count > shown {
            HStack {
                Button("Show \(min(proposals.count - shown, MemoriesPageMetrics.foldRowCap)) more") {
                    shown = min(proposals.count, shown + MemoriesPageMetrics.foldRowCap)
                }
                .accessibilityIdentifier("memories.deleted.show-more")
            }
        }
    }
}

/// The mounted Memory search field distinguishes a still-running canonical
/// search from an honest empty result and from a failed semantic reader whose
/// keyword fallback also found nothing.
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

    /// Semantic results are usable only when they name the query currently in
    /// the field. Even then, an empty semantic array is not enough evidence to
    /// suppress the cheap lexical fallback: the embedder can be unavailable,
    /// weak, or return an incomplete projection while the rendered memory list
    /// still has an exact text match.
    static func displayedRecords<Record>(
        _ records: [Record],
        query: String,
        semanticResults: [Record]?,
        resultQuery: String?,
        lexicalMatch: (Record, String) -> Bool
    ) -> [Record] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        let lexical = records.filter { lexicalMatch($0, trimmed.lowercased()) }
        guard matchesCurrentQuery(query, resultQuery: resultQuery),
              let semanticResults,
              !semanticResults.isEmpty else {
            return lexical
        }
        return semanticResults
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
        if resultCount > 0 { return .results }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        return .empty
    }
}
