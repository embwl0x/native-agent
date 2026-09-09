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
//   the memories        AppModel.memories (refreshForSidebarItem(.memories))
//   search              AppModel.runMemorySemanticSearch + the same
//                       MemorySearchPresentation.displayedRecords projection,
//                       so meaning-based results win over word matches exactly
//                       as they do on the classic page
//   pending proposals   AppModel.memoryProposals, status "pending"
//   keep / don't keep   AppModel.approveMemoryProposal / rejectMemoryProposal
//   pin / unpin         AppModel.pinMemory
//   delete              AppModel.deleteMemory (behind the same confirmation)
//   read                MemoryFullTextView, the classic page's own sheet
//   deleted             AppModel.memoryProposals, status "rejected"
//   a moment's quote    SwiftNativeMemoryV2.listProposals(status:"pending"),
//                       metadata `quote` — the same read Today's kept-moments
//                       fold makes, joined to the proposal by id
//
// MemoryView is untouched: the classic shell still renders it, and the
// consolidate / hygiene / Spotlight-reindex menu lives there.

import SwiftUI
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore

// MARK: - Metrics

enum MemoriesPageMetrics {
    // The same ramp the rest of the shell runs (ShellType).
    static let titleSize: CGFloat = ShellType.bodySize
    static let lineSize: CGFloat = ShellType.labelSize
    static let metaSize: CGFloat = ShellType.labelSize
    static let rowRadius: CGFloat = 10
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
/// (`adaptive-promoter:1f3c…`, `workshop:ex-9`, `skill-index`) and a run handle
/// on a page about what she remembers is machinery leaking through. Every case
/// below is grounded in a source string something in this app actually writes:
///
///   `moment-promoter:<session>`     MemoryMoments.sourcePrefix
///   `adaptive-promoter:<session>`   MemoryV2+AdaptivePromoter
///   `semantic-adaptive-extractor`   MemoryV2+FoundationModels
///   `workshop:<execution>`          WorkshopExecutionMemory.sourcePrefix
///   `skill-index`                   MemoryV2+SkillIndex
///
/// An unrecognised handle says so rather than being dressed up as one of these:
/// inventing a provenance is worse than admitting to none.
enum MemoriesProvenance: Equatable {
    case fromHim
    case fromTalking
    case fromAMoment
    case fromWork
    case fromSkills
    case wroteItDown
    case tidiedUp
    case unknown

    var words: String {
        switch self {
        case .fromHim: "Shared by you"
        case .fromTalking: "I picked it up while we talked"
        case .fromAMoment: "I kept it from something that happened"
        case .fromWork: "I checked it myself"
        case .fromSkills: "I learned it from what I can do"
        case .wroteItDown: "I wrote it down myself"
        case .tidiedUp: "I tidied it up from older notes"
        case .unknown: "I don't remember where this came from"
        }
    }

    static func classify(_ sourceRunId: String?) -> MemoriesProvenance {
        let raw = (sourceRunId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // No handle at all, or the app's own word for "a person typed this".
        if raw.isEmpty || raw == "manual" || raw == "user" { return .fromHim }
        // Her own commit_memory tool: she wrote it down herself.
        if raw.hasPrefix("chat.commit_memory") || raw.hasPrefix("commit_memory") { return .wroteItDown }
        if raw.hasPrefix(MemoryMoments.sourcePrefix) { return .fromAMoment }
        if raw.hasPrefix("adaptive-promoter") || raw.hasPrefix("semantic-adaptive-extractor") {
            return .fromTalking
        }
        if raw.hasPrefix("workshop") { return .fromWork }
        if raw.hasPrefix("skill-index") || raw.hasPrefix("skill") { return .fromSkills }
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
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: at, relativeTo: now)
        }
        if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            return "in \(at.formatted(.dateTime.month(.wide)))"
        }
        return "in \(at.formatted(.dateTime.month(.wide).year()))"
    }

    /// The row sorts on the newest of the two stamps the store keeps.
    static func sortDate(_ memory: NativeAgentShared.MemoryRecord) -> Date {
        let updated = memory.updatedAt.flatMap { UserDisplayFormatters.parseISOTimestamp($0) }
        let created = UserDisplayFormatters.parseISOTimestamp(memory.createdAt)
        return updated ?? created ?? .distantPast
    }

    /// The stamp the meta line shows: the update if there is one, else the save.
    static func stamp(_ memory: NativeAgentShared.MemoryRecord) -> String? {
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

    /// Pinned first, then newest. The same order the conversations list keeps.
    static func ordered(_ memories: [NativeAgentShared.MemoryRecord]) -> [NativeAgentShared.MemoryRecord] {
        memories.sorted { lhs, rhs in
            let lp = lhs.pinned == true, rp = rhs.pinned == true
            if lp != rp { return lp }
            let la = MemoriesWhen.sortDate(lhs), ra = MemoriesWhen.sortDate(rhs)
            if la != ra { return la > ra }
            return lhs.id < rhs.id
        }
    }

    /// "Pinned · in July · I checked it myself".
    static func meta(_ memory: NativeAgentShared.MemoryRecord, now: Date) -> String {
        var parts: [String] = []
        if memory.pinned == true { parts.append("Pinned") }
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
    static func proposalLine(_ proposal: MemoryProposalRecord, quote: String?) -> String {
        if let quote, !quote.isEmpty {
            return "\u{201C}\(TodayWords.bounded(TodayWords.plain(quote), limit: 200))\u{201D}"
        }
        return TodayWords.line(proposal.display_text ?? proposal.fact_text, limit: 200)
    }
}

// MARK: - The one read this page makes of its own

/// Everything the page needs that is NOT already on `AppModel`. Two things: the
/// quotes that make a pending moment a moment, and whether the store could be
/// opened at all. Taken off the main actor because it touches SQLite.
struct MemoriesPageSnapshot: Sendable, Equatable {
    var loaded = false
    /// Proposal id → the exact words that made the moment.
    var momentQuotes: [String: String] = [:]
    /// A store that would not open. Same distinction TodayView keeps: read and
    /// empty is calm, could-not-be-read is a sentence.
    var memoryUnreadable = false

    static let empty = MemoriesPageSnapshot()

    static func load() async -> MemoriesPageSnapshot {
        var snapshot = MemoriesPageSnapshot()
        snapshot.loaded = true
        do {
            let pending = try await SwiftNativeMemoryV2.shared.listProposals(status: "pending")
            for proposal in pending where MemoryMoments.isMoment(proposal.metadata) {
                if let quote = MemoryMoments.metadataString(proposal.metadata, "quote"),
                   !quote.isEmpty {
                    snapshot.momentQuotes[proposal.id] = quote
                }
            }
        } catch {
            snapshot.memoryUnreadable = true
        }
        return snapshot
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
    @State private var snapshot = MemoriesPageSnapshot.empty
    @State private var rejectedProposals: [MemoryProposalRecord] = []
    @State private var rejectedShown = MemoriesPageMetrics.foldRowCap
    @State private var now = Date()
    @State private var searchTask: Task<Void, Never>?
    @State private var openFolds: Set<String> = []
    @State private var notice: String?
    @State private var fullText: MemoriesFullText?

    private enum Fold {
        static let showAll = "show-all"
        static let deleted = "deleted"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TodayMetrics.sectionSpacing) {
                header

                MemoriesSearchField(text: $query)

                if isSearching {
                    searchSection
                } else {
                    if !pendingProposals.isEmpty { waitingCard }
                    keptSection
                    deletedFold
                }

                if let notice {
                    Text(notice)
                        .font(.system(size: MemoriesPageMetrics.metaSize))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityIdentifier("memories.notice")
                }

                // The one line a quiet page must still say out loud. Same
                // sentence as Today's, because it is the same store.
                if snapshot.memoryUnreadable {
                    Text("I couldn't read my memory just now.")
                        .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                        .foregroundStyle(NativeAgentShell.tertiary)
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
            MemoryFullTextView(text: item.text)
        }
        // Same live binding TodayView takes: the memory database and its WAL,
        // debounced, re-armed whenever the window comes back to the front. A
        // proposal staged while he sits here appears without a manual refresh.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let database = root
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("memory.sqlite")
            await ViewFileRefreshTask.run(paths: [
                database,
                URL(fileURLWithPath: database.path + "-wal"),
            ]) {
                await reload()
            }
        }
        // The owner starts its generation gate before its debounce, so a new
        // keystroke invalidates old results instead of leaving a previous
        // query's rows under the current search text. Same call the classic
        // page makes, so "meaning, not words" behaves identically here.
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task { await appModel.runMemorySemanticSearch(query: newValue) }
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: header

    private var memories: [NativeAgentShared.MemoryRecord] { appModel.memories }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !embedded {
                Text("Memories")
                    .font(ShellType.display)
            }
            Text(MemoriesPageContent.keptLine(memories.count))
                .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                .foregroundStyle(NativeAgentShell.secondary)
                .accessibilityIdentifier("memories.kept-line")
        }
    }

    // MARK: search

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The SAME projection the classic page uses: semantic results when they
    /// name the query in the field, the cheap lexical pass otherwise.
    private var found: [NativeAgentShared.MemoryRecord] {
        MemorySearchPresentation.displayedRecords(
            memories,
            query: query,
            semanticResults: appModel.memorySearchResults,
            resultQuery: appModel.memorySearchResultQuery
        ) { memory, lower in
            memory.text.lowercased().contains(lower) || memory.layer.lowercased().contains(lower)
        }
    }

    private var searchState: MemorySearchPresentation {
        MemorySearchPresentation.resolve(
            query: query,
            resultCount: found.count,
            isLoading: appModel.memorySearchIsLoading
                && MemorySearchPresentation.matchesCurrentQuery(
                    query, resultQuery: appModel.memorySearchResultQuery),
            error: MemorySearchPresentation.matchesCurrentQuery(
                query, resultQuery: appModel.memorySearchResultQuery)
                ? appModel.memorySearchError
                : nil
        )
    }

    @ViewBuilder
    private var searchSection: some View {
        DeskPageSectionLabel("What I found")
        switch searchState {
        case .searching:
            Text("Looking\u{2026}")
                .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                .foregroundStyle(NativeAgentShell.secondary)
        case .unavailable:
            // The reason is a backend sentence; the page says what it means.
            Text("I couldn't search by meaning just now, and nothing matched the words either.")
                .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                .foregroundStyle(NativeAgentShell.tertiary)
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
                ForEach(found, id: \.id) { memory in
                    keptRow(memory)
                }
            }
        }
    }

    // MARK: waiting for you

    private var pendingProposals: [MemoryProposalRecord] {
        appModel.memoryProposals.filter { $0.status == "pending" }
    }

    /// Today's teal card, and only when something is actually pending.
    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Waiting for you")
                .font(.system(size: MemoriesPageMetrics.metaSize, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(TodayPalette.accent)

            ForEach(pendingProposals) { proposal in
                if proposal.id != pendingProposals.first?.id {
                    Divider().overlay(TodayPalette.hairline)
                }
                MemoriesProposalRow(
                    line: MemoriesPageContent.proposalLine(
                        proposal, quote: snapshot.momentQuotes[proposal.proposal_id]),
                    meta: "staged \(MemoriesWhen.words(proposal.staged_at, now: now))",
                    onKeep: { decide(proposal, keep: true) },
                    onNotNow: { decide(proposal, keep: false) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(TodayPalette.waitingFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .strokeBorder(TodayPalette.waitingStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("memories.waiting-for-you")
    }

    // MARK: what I've kept

    private var ordered: [NativeAgentShared.MemoryRecord] {
        MemoriesPageContent.ordered(memories)
    }

    @ViewBuilder
    private var keptSection: some View {
        if ordered.isEmpty {
            if snapshot.loaded, !snapshot.memoryUnreadable {
                Text("Nothing kept yet. It fills up as we talk.")
                    .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .padding(.top, 8)
            }
        } else {
            DeskPageSectionLabel("What I've kept")
            let shown = Array(ordered.prefix(MemoriesPageMetrics.keptShown))
            ForEach(shown, id: \.id) { memory in
                keptRow(memory)
            }
            let rest = Array(ordered.dropFirst(MemoriesPageMetrics.keptShown))
            if !rest.isEmpty {
                DeskPageFoldRow(
                    title: "\(DeskPageWords.spelled(rest.count)) more",
                    meta: nil,
                    isOpen: binding(Fold.showAll)
                ) {
                    ForEach(rest, id: \.id) { memory in
                        keptRow(memory)
                    }
                }
                .accessibilityIdentifier("memories.show-all")
            }
        }
    }

    private func keptRow(_ memory: NativeAgentShared.MemoryRecord) -> some View {
        MemoriesRowCard(
            line: MemoriesPageContent.line(memory.text),
            meta: MemoriesPageContent.meta(memory, now: now),
            isPinned: memory.pinned == true,
            onRead: { fullText = MemoriesFullText(id: memory.id, text: memory.text) },
            onTogglePin: { Task { await togglePin(memory) } },
            onDelete: { Task { await delete(memory) } }
        )
    }

    // MARK: deleted

    @ViewBuilder
    private var deletedFold: some View {
        if !rejectedProposals.isEmpty {
            let count = rejectedProposals.count
            DeskPageFoldRow(
                title: "\(DeskPageWords.spelled(count)) \(DeskPageWords.plural(count, "thing I let go", "things I let go"))",
                meta: nil,
                isOpen: binding(Fold.deleted)
            ) {
                // Read-only on purpose: the classic page's Deleted tab has no
                // restore, and MemoryV2 has no un-reject. A "Bring it back"
                // button here would be a button that cannot do anything.
                MemoriesRejectedHistory(proposals: rejectedProposals, shown: $rejectedShown) { proposal in
                    fullText = MemoriesFullText(
                        id: proposal.id, text: proposal.display_text ?? proposal.fact_text)
                }
            }
            .padding(.top, 4)
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
    private func decide(_ proposal: MemoryProposalRecord, keep: Bool) {
        Task {
            do {
                let result = keep
                    ? try await appModel.approveMemoryProposal(id: proposal.proposal_id)
                    : try await appModel.rejectMemoryProposal(id: proposal.proposal_id)
                if (result["status"] as? String) == "pending_approval" {
                    notice = "I've asked first; it's waiting on an approval."
                } else {
                    notice = keep ? "Kept it." : "Left it."
                }
                await reload()
            } catch {
                notice = "I couldn't save that decision just now."
            }
        }
    }

    @MainActor
    private func togglePin(_ memory: NativeAgentShared.MemoryRecord) async {
        let outcome = await appModel.pinMemory(memory, pinned: !(memory.pinned ?? false))
        notice = outcome.message
    }

    @MainActor
    private func delete(_ memory: NativeAgentShared.MemoryRecord) async {
        await appModel.deleteMemory(memory)
        if appModel.statusText.hasPrefix("Memory delete failed:") {
            appModel.systemToasts.push(error: appModel.statusText)
            notice = "I couldn't forget that one."
        } else {
            notice = "Forgotten."
        }
    }

    @MainActor
    private func reload() async {
        // The same five-queue read the classic page's Refresh performs, so the
        // memories, the proposals and the status all move together.
        await appModel.refreshForSidebarItem(.memories)
        do {
            let rejected = try await appModel.client.getRejectedMemoryProposals()
            guard !Task.isCancelled else { return }
            rejectedProposals = rejected
        } catch {
            notice = "Could not reload rejected memory history."
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            await MemoriesPageSnapshot.load()
        }.value
        guard !Task.isCancelled else { return }
        now = Date()
        snapshot = loaded
    }
}

// MARK: - Pieces

/// The sheet's identity. `MemoryFullTextView` is the classic page's own
/// read-only full-text sheet — opening it does not pin, delete or mutate.
struct MemoriesFullText: Identifiable, Equatable {
    let id: String
    let text: String
}

/// The page's search box, in the shell's quiet fill rather than a system
/// rounded-border field that belongs to a different app.
struct MemoriesSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(ShellType.labelMedium)
                .foregroundStyle(NativeAgentShell.tertiary)
            TextField("Search what I remember", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: MemoriesPageMetrics.lineSize))
                .accessibilityIdentifier("memories.search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: MemoriesPageMetrics.rowRadius, style: .continuous)
                .fill(NativeAgentShell.quietFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MemoriesPageMetrics.rowRadius, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
        )
    }
}

/// One kept memory. A line and a meta line, uniform height; Read, Pin and
/// Delete appear on hover, the way the conversations list reveals its pin.
struct MemoriesRowCard: View {
    let line: String
    let meta: String
    let isPinned: Bool
    let onRead: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.isEmpty ? "An empty note" : line)
                    .font(.system(size: MemoriesPageMetrics.titleSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meta)
                    .font(.system(size: MemoriesPageMetrics.metaSize))
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                iconButton("doc.text.magnifyingglass", help: "Read the whole thing", action: onRead)
                iconButton(
                    isPinned ? "pin.fill" : "pin",
                    help: isPinned ? "Unpin" : "Pin to the top",
                    tint: isPinned ? NativeAgentShell.text : nil,
                    action: onTogglePin
                )
                iconButton("trash", help: "Forget this") { confirmingDelete = true }
            }
            // Pinned rows keep the pin visible; everything else appears under
            // the cursor, so sixty rows read as sixty lines, not sixty toolbars.
            .opacity(hovering || isPinned ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: MemoriesPageMetrics.rowRadius, style: .continuous)
                .fill(NativeAgentShell.quietFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MemoriesPageMetrics.rowRadius, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
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
                .foregroundStyle(tint ?? NativeAgentShell.tertiary)
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
    let onKeep: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line)
                .font(.system(size: MemoriesPageMetrics.lineSize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(meta)
                .font(.system(size: MemoriesPageMetrics.metaSize))
                .foregroundStyle(NativeAgentShell.tertiary)
            HStack(spacing: 8) {
                Button("Keep", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(TodayPalette.accent)
                    .accessibilityIdentifier("memories.waiting.keep")
                Button("Don't keep", action: onNotNow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("memories.waiting.not-now")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Loaded history retains the store's order and proposal identity. Reading is
/// available independently of the terminal review decision.
struct MemoriesRejectedHistory: View {
    let proposals: [MemoryProposalRecord]
    @Binding var shown: Int
    let onRead: (MemoryProposalRecord) -> Void

    var body: some View {
        ForEach(Array(proposals.prefix(shown))) { proposal in
            Button { onRead(proposal) } label: {
                HStack {
                    DeskPageDetailRow(
                        title: MemoriesPageContent.line(proposal.display_text ?? proposal.fact_text),
                        line: "", meta: "I didn't keep this")
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(NativeAgentShell.tertiary)
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
