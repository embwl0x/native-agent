import Observation
import AppToolRuntime
// TodayView.swift
// HER DAY, IN HER WORDS. (ui-simplify 2026-09-02, lane C; rebuilt to Agent's
// own review of the page, 2026-09-02.)
//
// The first draft of this page was Activity with "Today" on the door. Her
// verdict: it should be HER telling him what happened while he was out. So:
//
//   · The header is the word "Today". Memories and Desk live on the rail; this
//     page does not carry a segmented control to them.
//   · First person, everywhere. "I dreamed", "I kept this", "I wrote up the
//     night", "Something I'm facing". Never "She…", never "Agent dreamed".
//   · Three things at most: what's waiting, what I did today, what's ahead.
//     The kept moments FOLD into one row that opens; the dream is one row;
//     the night write-up is one row. A quiet day is a short page.
//   · "Waiting for you" NAMES the thing and OFFERS the action — the moment
//     review opens from here, each approval carries its own approve/decline.
//   · Provider health is machinery, not her day. It is gone from the rows; at
//     most one grey line at the bottom says a provider is slow. Those cards
//     are still on the classic Activity page and in Diagnostics.
//
// Every row still comes from a real reader — an absent source renders as
// absence, never as invented copy:
//
//   moments she kept         SwiftNativeMemoryV2.listMemory(kind: "moment")
//   last night's dream       engine.today → engine.cognitionView.dreamDiary
//   something she's facing   NativeCognitionRuntime.towardRead() (horizon)
//   she wrote up the night   ChatSessionRecollections (compaction_summary rows)
//   approvals / notifications engine.approvals.records + engine.inbox.items
//
// Rule of the page: no counts as numerals, no valence, no weights, no ids, no
// internal vocabulary, no markdown. Clock times and weekday names are the only
// digits, because a day needs a spine.
//
// Alive glass (User approved the mockup, 2026-09-23): same three sections, now
// drawn from AlivePageKit — a serif "Today" with one first-person sentence
// built from the page's own counts, the waiting things in ONE group card, what
// I did as a timeline on a haze line, and what's ahead as pills.

import SwiftUI
import ApprovalTransactions
import NotificationInbox
import NativeAgentShared
import NativeAgentCore
import CognitiveSubstrate
import PersistenceCore
import Desk
import Transcripts
import MemoryV2
import ApprovalInbox
import Cognition
import DeviceSync
import DreamREMCycle
// Blueprint: | `TodayView.swift` | Visible Today lanes and activity from `engine.today`; waiting shares WorkOverview with quiet Today; engine layout renders current blocks; note actions use `engine.inbox`; local row/sheet interaction state |

// MARK: - Palette

/// The Life mockup's palette. Fills and hairlines are expressed against
/// `Color.primary` so the same 5%/6% recipe that produces the mockup's dark
/// render stays legible when the app is not in dark appearance; the teal is a
/// fixed identity color in both.
enum TodayPalette {
    /// The waiting card's priority mark: the small-caps heading and the action
    /// beside it, and nothing else on the page. 2026-09-12 (Agent, before User's
    /// eye): once the waiting card became the same near-white slate as every
    /// other card, the dark-only teal measured 1.73:1 on it — the one thing that
    /// must be seen, invisible in light. It gets a light variant the way
    /// `NativeAgentShell.needsYou` already does; dark keeps its exact hex.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, alpha: 1)
            : NSColor(srgbRed: 0x0E / 255, green: 0x74 / 255, blue: 0x90 / 255, alpha: 1)
    })
    /// Silver, not slate. The cool blue base was a workaround for a lamp that
    /// browned any neutral (User, 2026-09-10); with the lamp at 0.22 over 820pt
    /// a neutral holds — measured R-B -0.2 in the body of the page against -17
    /// on the old fill. User, 2026-09-12: "it's still off-putting, that color
    /// with our dark mode... more silverish"; Agent picked this rung of three.
    /// Lifted to L* 26.9 on a L* 13.8 ground, so a card reads by its own light.
    /// Light rooms keep their near-white. Opaque: the stroke and the lamp are
    /// the only things above it.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x35 / 255, green: 0x37 / 255, blue: 0x3A / 255, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.98, blue: 0.975, alpha: 1)
    })
    /// A hairline of silver on the lifted dark card; `.primary` at 6% disappeared
    /// on it. Light keeps the dark hairline it had — a white stroke on a
    /// near-white card is no stroke at all.
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.12)
            : NSColor(white: 0, alpha: 0.06)
    })
    static let hairline = Color.primary.opacity(0.08)
}

enum TodayMetrics {
    static let contentWidth: CGFloat = 920
    static let cardRadius: CGFloat = 12
    /// The timeline's time column, fixed. Wide enough for "11:50 AM – 1:10 PM"
    /// at 12pt and a gap before the ring: a folded row says its span, and the
    /// mockup's 64pt only held a single clock.
    static let timeColumnWidth: CGFloat = 122
    static let sectionSpacing: CGFloat = 20
    static let topPadding = NativeAgentSpacing.pageTop
    /// EVERY ROW THE SAME HEIGHT. User, 2026-09-02: the column read ragged
    /// because a row was one line, two lines, or a three-line morning brief.
    /// A row is now exactly a title and one clamped line, and this is the box
    /// they share. Fixed, never minimum: a minimum drifts.
    static let rowContentHeight: CGFloat = 38
    /// A row with no body line collapses to its title; it does not carry an
    /// empty second line just to hold height (Agent, 2026-09-02).
    static let rowContentHeightSingle: CGFloat = 18
    /// Characters that fit on that one line beside the gutter at 13pt. The
    /// text is cut at a WORD boundary (TodayWords.bounded) rather than left to
    /// the renderer's mid-word ellipsis.
    static let rowLineLimit = 96
}

// MARK: - A row

extension TodayRow {
    var time: String { gutter ?? (isHorizon ? TodayWords.weekday(at) : TodayWords.clock(at)) }
}

// MARK: - Waiting-for-you copy

enum TodayWaitingCopy {
    /// An approval's name in plain words. A skill proposal's own title is a
    /// tool sequence ("workspace → workspace"); that is not a name.
    static func approvalTitle(_ approval: ApprovalRecord) -> String {
        ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason)
    }
}

// MARK: - Waiting on you, defined once

/// "Waiting on you" — the Desk's Needs you count (`AppModel.ownerWaitingCount`,
/// OwnerAttentionPolicy through WorkOverviewRead), so Today and the Desk say
/// the same number (Agent, 2026-09-23: the two pages contradicted each other).
/// The card names the approvals itself; the rest wait on the Desk. Memories
/// she would like to keep are hers (User, 2026-10-01), on the Memories page.
@MainActor
enum WaitingOnYou {
    static func approvals(_ appModel: AppModel) -> [ApprovalRecord] {
        WorkOverviewRead.waitingApprovals(appModel.engine.approvals.records)
    }

    static func onDesk(_ appModel: AppModel) -> Int {
        WorkOverviewRead.waitingOnDesk(total: appModel.ownerWaitingCount, approvals: approvals(appModel).count)
    }

    /// `onDesk` split into Desk items and notes; nil when the overview could
    /// not say, or when something else (a run waiting on a decision) is
    /// among them.
    static func split(_ appModel: AppModel) -> (items: Int, notes: Int)? {
        WorkOverviewRead.waitingSplit(kinds: appModel.ownerWaitingKinds, onDesk: onDesk(appModel))
    }
}

// MARK: - The full queues

/// The queues a route can open (⌘⇧A, ⌘⇧I, a notification, a command). Behind
/// the rail each opens on Today in a sheet; `memoryProposals` lands on the
/// Memories page instead (ContentView.applyActivitySection).
enum ActivitySection: String, Sendable, Identifiable {
    case approvals
    case inbox
    case memoryProposals
    case selfImprovement
    /// Standing views from reflection, with the replay lineage beside them.
    case cognitionProposals

    var id: String { rawValue }

    var sheetTitle: String {
        switch self {
        case .approvals: "Approvals and past decisions"
        case .inbox: "Every note I've left you"
        case .memoryProposals: "Memories to look at"
        case .selfImprovement: "Self-improvement"
        case .cognitionProposals: "Standing views"
        }
    }
}

// MARK: - The page

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    private var today: TodayProjection { appModel.engine.today }
    private var snapshot: TodaySnapshot { today.snapshot }
    private var didRows: [TodayRow] { today.didRows }
    private var earlierNotes: [TodayEarlierNote] { today.earlierNotes }
    private var noteItems: [String: InboxItemRecord] { today.noteItems }
    private var dreamUnavailable: Bool { today.dreamUnavailable }
    @State private var openedNote: InboxItemRecord?
    @State private var noteFlight = InboxRowActionFlight()
    @State private var earlierOpen = false
    /// The full queue a route (⌘⇧A, ⌘⇧I, a notification) or the quiet line
    /// at the foot of the page opened.
    @State private var sheet: ActivitySection?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AlivePageHeader(title: "Today", line: headerLine)
                if let error = snapshot.projectionError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }

                PageReadStatus(
                    isReading: isReading,
                    text: isReading ? (snapshot.loaded ? "Refreshing today…" : "Reading today…") : nil
                )

                // The page's blocks in the layout's order (ui/layout.json, today).
                let blocks = appModel.engine.layout.layout.shown("today", profile: SimpleViewMode.advanced).map(\.name)
                let waiting = blocks.contains("waiting") && hasWaiting
                let earlier = blocks.contains("earlier") ? Self.earlierNotesLine(earlierNotes) : nil
                let did = blocks.contains("did") ? didRows : []
                let ahead = blocks.contains("ahead") ? snapshot.ahead : []
                let empty = !waiting && did.isEmpty && ahead.isEmpty && earlier == nil
                    && snapshot.loaded && !snapshot.memoryUnreadable && !dreamUnavailable && snapshot.projectionError == nil
                ForEach(blocks, id: \.self) { block in
                    switch block {
                    case "waiting" where waiting:
                        TodayWaitingCard(
                            approvals: WaitingOnYou.approvals(appModel),
                            deskCount: WaitingOnYou.onDesk(appModel),
                            split: WaitingOnYou.split(appModel),
                            onOpenApprovals: { sheet = .approvals }
                        )
                    // Failures and notices from earlier days are not waiting. One
                    // folded quiet line; it opens the grouped list in place.
                    case "earlier":
                        if let earlier {
                            VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                                Button(earlier + (earlierOpen ? " · Hide" : " · Show")) {
                                    withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)) {
                                        earlierOpen.toggle()
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(ShellType.labelMedium)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .accessibilityIdentifier("today.earlier-notes")
                                if earlierOpen {
                                    AliveGroupCard {
                                        ForEach(earlierNotes) { note in
                                            TodayEarlierNoteRow(note: note) { openedNote = note.newest }
                                        }
                                    }
                                    .transition(NativeAgentMotion.arrivalFade)
                                }
                            }
                        }
                    case "did" where !did.isEmpty:
                        TodaySection(
                            title: "What I did today",
                            rows: did,
                            onReadDream: readDream,
                            notes: noteItems,
                            onOpenNote: { openedNote = $0 }
                        )
                    case "ahead" where !ahead.isEmpty:
                        TodayAhead(rows: ahead)
                    case "queues":
                        if empty { emptyLine }
                        queuesLine
                    default:
                        EmptyView()
                    }
                }
                if empty, !blocks.contains("queues") { emptyLine }

                // A store that would not open is the one thing a quiet page
                // must still say out loud. One line, grey, no error text.
                if snapshot.memoryUnreadable {
                    Text("I couldn't read my memory just now.")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("today.memory-trouble")
                }

                if dreamUnavailable {
                    Text("I couldn't read the dream source just now.")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
            .padding(.top, TodayMetrics.topPadding)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The shared page column (`ShellPageFrame`): the scroll view is the
        // column, so its rows end where every other page's rows end.
        .pageScrollColumn()
        .padding(.horizontal, 20)
        .frame(maxWidth: TodayMetrics.contentWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The same detail surface the Activity page opens, with its own
        // read/action behaviour — an older note is opened here, not retold.
        .sheet(item: $openedNote) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: appModel.engine.inbox.items,
                onAction: { actionID in
                    let outcome = await noteFlight.perform {
                        try await InboxCardActions.perform(item.id, action: actionID,
                            dataRootOverride: appModel.dataRootOverride, effects: AppInboxCardActionEffects(inbox: appModel.engine.inbox))
                    }
                    if case .succeeded = outcome {
                        _ = await appModel.refreshForSidebarItem(.activity)
                        if let sync = appModel.engine.deviceSync { await sync.engine.writeSnapshots() }
                    }
                    return outcome
                },
                onClose: { openedNote = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $sheet) { section in
            PageSheetHost(title: section.sheetTitle, onDone: { sheet = nil }) {
                switch section {
                case .approvals: ApprovalsView()
                case .inbox: InboxView()
                case .selfImprovement: SelfImprovementView()
                case .cognitionProposals: CognitionProposalsView()
                // Routed to the Memories page before it gets here.
                case .memoryProposals: EmptyView()
                }
            }
        }
        // A route that arrived before this page mounted is stashed on
        // AppModel; one that arrives while it is up is posted.
        .liveOnAppear {
            if let raw = appModel.pendingActivitySectionRaw {
                appModel.pendingActivitySectionRaw = nil
                openSection(raw)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openActivitySectionRequest)) { note in
            guard !quietOffscreenRead else { return }
            appModel.pendingActivitySectionRaw = nil
            openSection(note.object as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openActivityRootRequest)) { _ in
            guard !quietOffscreenRead else { return }
            sheet = nil
        }
        .liveTask(id: [String(describing: scenePhase), appModel.activeChatSessionId] + WorkOverviewRead.todaySessionIDs(appModel.engine)) {
            if scenePhase == .active {
                today.start(engine: appModel.engine,
                    activeSessionID: { appModel.activeChatSessionId },
                    refreshQueues: { _ = await appModel.refreshForSidebarItem(.activity) },
                    publishWorkStatus: { await appModel.publishWorkStatus() })
            } else {
                today.stop()
            }
        }
        .onDisappear { if !quietOffscreenRead { today.stop() } }
        .quietReadTask(live: false) {
            _ = await appModel.refreshForSidebarItem(.activity)
            await appModel.publishWorkStatus()
            await today.refresh(appModel.engine, activeSessionID: appModel.activeChatSessionId)
        }
    }

    private func openSection(_ raw: String?) {
        guard let raw, let section = ActivitySection(rawValue: raw),
              section != .memoryProposals else { return }
        sheet = section
    }

    // MARK: the full queues

    /// One quiet line of the full queues this page folds to: every approval
    /// with the decisions already made, every note, the self-improvement
    /// pass, and the standing views waiting for a call. A count rides a word
    /// only when something in it is waiting.
    private var emptyLine: some View {
        Text("Nothing yet today. I'm around.")
            .font(ShellType.labelMedium)
            .foregroundStyle(NativeAgentShell.secondary)
            .padding(.top, 8)
    }

    private var queuesLine: some View {
        let standing = today.pending.count
        let inboxCount = appModel.ownerWaitingKinds?[.inbox] ?? 0
        // An unreadable queue says so; it never passes for an empty one.
        let standingUnavailable = today.cognitionUnavailable
        let entries: [(ActivitySection, String)] = [
            (.approvals, ActivitySection.approvals.sheetTitle),
            (.inbox, ActivitySection.inbox.sheetTitle
                + (inboxCount > 0 ? " (\(inboxCount) awaiting you)" : "")),
            (.selfImprovement, ActivitySection.selfImprovement.sheetTitle),
            (.cognitionProposals, ActivitySection.cognitionProposals.sheetTitle
                + (standingUnavailable != nil ? " (couldn't check)" : standing > 0 ? " (\(standing))" : "")),
        ]
        return AliveFlow(spacing: 18, lineSpacing: 6) {
            ForEach(entries, id: \.0) { section, label in
                Button(label) { sheet = section }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .help(section == .cognitionProposals ? (standingUnavailable ?? "") : "")
                    .accessibilityIdentifier("today.queue.\(section.rawValue)")
            }
        }
        .padding(.top, 4)
    }

    // MARK: the header's one sentence

    /// One first-person sentence from counts the page already holds. No model
    /// call, and nothing said before the lanes are read: a page that has not
    /// looked yet does not get to say "nothing is waiting".
    private var headerLine: String? {
        guard snapshot.loaded else { return nil }
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: Date())
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        let did = didRows.count
        let day: String
        switch did {
        case 0: day = "A quiet \(part) so far."
        case 1...2: day = "A quiet \(part)."
        default: day = "I've had a full \(part)."
        }
        // A store that would not open cannot vouch for "nothing".
        guard let waiting = appModel.ownerWaitingCount else { return day }
        if waiting == 0 {
            return snapshot.memoryUnreadable ? day : "\(day) Nothing is waiting on you."
        }
        let things = waiting == 1 ? "thing is" : "things are"
        return "\(day) \(DeskPageWords.spelled(waiting)) \(things) waiting on you."
    }

    // MARK: what's waiting


    /// "3 failures and 1 note since Monday".
    static func earlierNotesLine(_ notes: [TodayEarlierNote]) -> String? {
        guard let oldest = notes.map(\.oldest).min() else { return nil }
        let failures = notes.filter(\.isFailure).reduce(0) { $0 + $1.count }
        let others = notes.reduce(0) { $0 + $1.count } - failures
        var parts: [String] = []
        if failures > 0 { parts.append("\(failures) \(failures == 1 ? "failure" : "failures")") }
        if others > 0 { parts.append("\(others) \(others == 1 ? "note" : "notes")") }
        var since = TodayWords.dayLabel(oldest)
        if since == "Yesterday" { since = "yesterday" }
        return TodayWords.capitalizedFirst(parts.joined(separator: " and ")) + " since \(since)"
    }

    private var hasWaiting: Bool {
        (appModel.ownerWaitingCount ?? 0) > 0
    }

    // MARK: what I did today

    // MARK: loading

    private var isReading: Bool {
        !snapshot.loaded || today.isReading || appModel.panelRefreshCounts[.activity, default: 0] > 0
    }

    private func readDream(_ date: String) async -> Bool {
        guard let entry = await appModel.fetchDreamEntry(date: date),
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            today.dreamUnavailable = true
            return false
        }
        _ = NativeAgentAppCoordinator.shared.request(.sidebar(.dreams))
        return true
    }
}

// MARK: - Pieces

/// A titled run of rows, as a timeline: a haze line down the left, one ring
/// per row, the time in a fixed column. Not cards — a day is one thread.
struct TodaySection: View {
    let title: String
    let rows: [TodayRow]
    var onReadDream: ((String) async -> Bool)? = nil
    /// The note behind each row that is one; a click opens it.
    var notes: [String: InboxItemRecord] = [:]
    var onOpenNote: ((InboxItemRecord) -> Void)? = nil
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue

    var body: some View {
        let haze = HazeColor(stored: colorRaw).base
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TodayTimelineRow(
                        row: row,
                        // Each ring a little quieter than the one above it.
                        dotOpacity: rows.count <= 1 ? 1 : 1 - 0.55 * Double(index) / Double(rows.count - 1),
                        haze: haze,
                        onReadDream: onReadDream,
                        onOpen: notes[row.id].flatMap { note in onOpenNote.map { open in { open(note) } } })
                }
            }
            .background(alignment: .topLeading) {
                LinearGradient(colors: [haze.opacity(0.5), haze.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 1.5)
                    .padding(.leading, TodayMetrics.timeColumnWidth + 3.75)
                    .padding(.vertical, 14)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// What's ahead, as pills. Only what the page already reads — the horizon and
/// the next dream — never an invented plan.
struct TodayAhead: View {
    let rows: [TodayRow]

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Ahead")
            AliveFlow {
                ForEach(rows) { row in
                    // A horizon's line already carries its day; a bare title
                    // gets the time the old gutter gave it.
                    AlivePill(row.line.isEmpty ? row.title : row.line,
                              leading: row.line.isEmpty
                                ? "\(TodayWords.dayWord(row.at)), \(TodayWords.clock(row.at))"
                                : nil)
                }
            }
        }
        .accessibilityIdentifier("today.ahead")
    }
}

/// The one card that exists only when something is actually waiting on him.
/// It NAMES each thing and carries the action beside it.
struct TodayWaitingCard: View {
    @Environment(AppModel.self) private var appModel
    let approvals: [ApprovalRecord]
    /// Desk items waiting on him; one row that opens the Desk.
    var deskCount = 0
    /// `deskCount` as Desk items and notes; nil when it is not only those.
    var split: (items: Int, notes: Int)? = nil
    /// The full request behind an approval, and the decisions already made.
    var onOpenApprovals: (() -> Void)? = nil

    private var deskLine: String { appModel.engine.today.waitingLine(count:deskCount,split:split) }

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Waiting for you")
            AliveGroupCard(waiting: true) {
                ForEach(approvals) { approval in
                    TodayApprovalRow(approval: approval, onShowFull: onOpenApprovals)
                }

                if deskCount > 0 {
                    HStack(alignment: .center, spacing: 12) {
                        AliveWaitingDot()
                        Text(deskLine)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(NativeAgentShell.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: TodayMetrics.rowContentHeightSingle)
                        Spacer(minLength: 12)
                        Button("Open the Desk") {
                            _ = NativeAgentAppCoordinator.shared.request(.sidebar(.desk))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .hazeTinted(.button)
                        .accessibilityIdentifier("today.waiting.open-desk")
                    }
                }
            }
            .accessibilityIdentifier("today.waiting-for-you")
        }
        .quietReadTask(id:[deskCount,split?.items ?? -1,split?.notes ?? -1]) {
            if deskCount > 0 { await appModel.engine.today.prepareWaiting(appModel.engine,count:deskCount,split:split) }
        }
    }
}

/// One group in the folded earlier-notes list. The row opens the newest note.
struct TodayEarlierNoteRow: View {
    let note: TodayEarlierNote
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(TodayWords.bounded(note.title, limit: 80) + (note.count > 1 ? " ×\(note.count)" : ""))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(TodayWords.dayLabel(note.at))
                    .font(.system(size: 13))
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.earlier-note")
    }
}

/// One approval, by name, with the same approve/decline the Activity page
/// offers — `ApprovalDecisionAction` is literally the same call.
struct TodayApprovalRow: View {
    @Environment(AppModel.self) private var appModel
    let approval: ApprovalRecord
    /// Opens the full request — every preview line, the risk, the action.
    var onShowFull: (() -> Void)? = nil

    @State private var isDeciding = false
    @State private var errorText: String?
    /// The reason is one line; a click opens the whole of it. User,
    /// 2026-09-12: "I can't see the REM lesson, what it is, to approve it" —
    /// the lesson stays one click from the button that approves it.
    @State private var reasonOpen = false

    private var title: String {
        let named = TodayWords.line(TodayWaitingCopy.approvalTitle(approval), limit: 110)
        return named.isEmpty ? TodayWords.line(approval.action, limit: 110) : named
    }

    private var reason: String {
        let stated = TodayWords.firstSentence(approval.reason)
        if !stated.isEmpty { return stated }
        // A card with no reason line carries the thing itself in its preview
        // (a REM lesson is the lesson; User, 2026-09-12: "I can't see the REM
        // lesson, what it is, to approve it"). Show her words, not just a title.
        return TodayWords.bounded(TodayWords.plain(approval.payloadPreview), limit: 240)
    }

    private var shortReason: String { TodayWords.bounded(reason, limit: 90) }
    /// The row opens when its reason is cut, or when the full request is one
    /// click further; closed, it keeps the row's fixed height.
    private var reasonFolds: Bool { shortReason != reason || onShowFull != nil }
    private var canResolve: Bool { ApprovalChatCards.canResolve(approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                AliveWaitingDot()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title.isEmpty ? "I'm asking first" : TodayWords.bounded(title, limit: 70))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(NativeAgentShell.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if reasonFolds {
                            NativeDisclosureTriangle(isOpen: reasonOpen,
                                                     accessibilityLabel: reasonOpen ? "Show less" : "Read the whole reason") {
                                reasonOpen.toggle()
                            }
                            .fixedSize()
                        }
                    }
                    if !reason.isEmpty {
                        Text(reasonOpen ? reason : shortReason)
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(reasonOpen ? nil : 1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: reasonOpen)
                    }
                }
                // Fixed while closed; only an opened reason may grow the row.
                .frame(height: reasonOpen ? nil : (reason.isEmpty ? TodayMetrics.rowContentHeightSingle : TodayMetrics.rowContentHeight),
                       alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if reasonFolds { reasonOpen.toggle() } }
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: reasonOpen ? "Show less" : "Read the whole reason") {
                    if reasonFolds { reasonOpen.toggle() }
                }
                Spacer(minLength: 12)
                if isDeciding { ProgressView().controlSize(.small) }
                Button("Decline") { decide("denied") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDeciding || !canResolve)
                    .accessibilityIdentifier("today.waiting.decline.\(approval.id)")
                Button("Approve") { decide("approved") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hazeTinted(.button)
                    .disabled(isDeciding || !canResolve)
                    .accessibilityIdentifier("today.waiting.approve.\(approval.id)")
            }
            if reasonOpen, let onShowFull {
                Button("Show the full request", action: onShowFull)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .padding(.leading, 20)
                    .accessibilityIdentifier("today.waiting.full-request.\(approval.id)")
            }
            if !canResolve {
                troubleLine(ApprovalChatCards.unavailableText)
            }
            if let errorText {
                troubleLine(errorText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func troubleLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(NativeAgentShell.trouble)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }

    private func decide(_ decision: String) {
        isDeciding = true
        errorText = nil
        let id = approval.id
        Task {
            let failure = await ApprovalDecisionAction.resolve(
                id: id,
                decision: decision,
                appModel: appModel
            )
            await MainActor.run {
                errorText = failure
                isDeciding = false
            }
        }
    }
}

/// One timeline row: the time, a ring on the line, a title and one plain
/// line. A row that folds several things opens on click instead of spilling
/// them down the page.
struct TodayTimelineRow: View {
    let row: TodayRow
    var dotOpacity: Double = 1
    var haze: Color
    var onReadDream: ((String) async -> Bool)? = nil
    /// A row that is one note opens it; a row that folds opens in place.
    var onOpen: (() -> Void)? = nil
    @State private var isOpen = false
    @State private var readingDream = false
    @State private var dreamMissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var gutter: String { row.time }

    private var foldable: Bool { !row.details.isEmpty }

    /// The row's one line, cut at a word boundary. The renderer's own tail
    /// truncation stays as a backstop for a line that is short in characters
    /// and long on screen.
    private var line: String {
        TodayWords.bounded(row.line, limit: TodayMetrics.rowLineLimit)
    }

    private static let dotSize: CGFloat = 9
    private static let textLead: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Secondary, not tertiary: tertiary measured ≈2.6:1 on the
                // room where the haze discs overlap.
                Text(gutter)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // Never touching the ring.
                    .padding(.trailing, 8)
                    .frame(width: TodayMetrics.timeColumnWidth, alignment: .leading)
                    .padding(.top, 1)
                Circle()
                    .fill(NativeAgentShell.room)
                    .overlay(Circle().strokeBorder(haze.opacity(dotOpacity), lineWidth: 2))
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(NativeAgentShell.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if foldable {
                            NativeDisclosureTriangle(isOpen: isOpen, accessibilityLabel: isOpen ? "Fold" : "Open") { toggle() }
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // THE FIXED BOX. A one-line row and a two-line row each occupy
                // exactly this, so the column reads as a column.
                .frame(height: row.line.isEmpty ? TodayMetrics.rowContentHeightSingle : TodayMetrics.rowContentHeight, alignment: .topLeading)
                .padding(.leading, Self.textLead)
                Spacer(minLength: 0)
                if row.id == "dream" {
                    if let date = row.dreamDate, let onReadDream, !dreamMissing {
                        Button(readingDream ? "Reading…" : "Read dream") {
                            readingDream = true
                            Task { @MainActor in
                                dreamMissing = !(await onReadDream(date))
                                readingDream = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(readingDream)
                        .accessibilityIdentifier("today.read-dream")
                    } else {
                        Text("Dream source unavailable")
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
            }
            // The fold is the one thing allowed to grow a row, and only while
            // it is open. Closed, it is the same height as every other row.
            if foldable, isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, TodayMetrics.timeColumnWidth + Self.dotSize + Self.textLead)
                .transition(NativeAgentMotion.arrivalFade)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityAction(named: isOpen ? "Fold" : "Open") { toggle() }
        .help(onOpen != nil && !foldable ? "Open this note" : "")
        .accessibilityIdentifier("today.row")
    }

    private func toggle() {
        guard foldable else { onOpen?(); return }
        withAnimation(NativeAgentMotion.respecting(
            NativeAgentMotion.arrive, reduceMotion: reduceMotion
        )) { isOpen.toggle() }
    }
}
