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
//   moments awaiting review  SwiftNativeMemoryV2.listProposals(status:"pending")
//                            filtered by MemoryMoments.isMoment(metadata)
//   moments she kept         SwiftNativeMemoryV2.listMemory(kind: "moment")
//   last night's dream       AppModel.fetchDreamDiary → dream_diary/<date>.md
//   something she's facing   NativeCognitionRuntime.towardRead() (horizon)
//   she wrote up the night   ChatSessionRecollections (compaction_summary rows)
//   approvals / notifications AppModel.approvals + AppModel.inboxItems
//
// Rule of the page: no counts as numerals, no valence, no weights, no ids, no
// internal vocabulary, no markdown. Clock times and weekday names are the only
// digits, because a day needs a spine.

import SwiftUI
import NativeAgentShared
import NativeAgentCore
import CognitiveSubstrate
import PersistenceCore
import MemoryV2

// MARK: - Palette

/// The Life mockup's palette. Fills and hairlines are expressed against
/// `Color.primary` so the same 5%/6% recipe that produces the mockup's dark
/// render stays legible when the app is not in dark appearance; the teal is a
/// fixed identity color in both.
enum TodayPalette {
    static let accent = Color(.sRGB, red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255, opacity: 1)
    static let cardFill = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.06)
    static let waitingFill = accent.opacity(0.08)
    static let waitingStroke = accent.opacity(0.18)
    static let hairline = Color.primary.opacity(0.08)
}

enum TodayMetrics {
    static let contentWidth: CGFloat = 920
    static let cardRadius: CGFloat = 12
    /// Wide enough for "6:51–9:55 am" on one line.
    static let timeColumnWidth: CGFloat = 100
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 20
    static let topPadding: CGFloat = 36
    /// How many recent sessions are scanned for today's recollection. Bounded
    /// because each scan reads one transcript off disk.
    static let sessionsScanned = 8
    /// At most this many kept moments inside the folded row.
    static let keptMomentsShown = 6
    /// At most this many of her notes in one day.
    static let noteRowsShown = 4
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

/// One line of her day. Payload-free by construction: a title, one plain
/// sentence, and when it happened (or is due). `details` is non-empty only on
/// a row that FOLDS several things — the card then opens on click.
struct TodayRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let line: String
    /// When it happened, or when a horizon falls due.
    let at: Date
    /// A horizon sorts after everything that already happened and shows a
    /// weekday instead of a clock.
    let isHorizon: Bool
    /// The things this row folds. Empty on a plain row.
    let details: [String]
    /// A folded row spans a stretch of the day; the gutter shows the span.
    let gutter: String?

    init(
        id: String,
        title: String,
        line: String,
        at: Date,
        isHorizon: Bool = false,
        details: [String] = [],
        gutter: String? = nil
    ) {
        self.id = id
        self.title = title
        self.line = line
        self.at = at
        self.isHorizon = isHorizon
        self.details = details
        self.gutter = gutter
    }
}

// MARK: - Plain-words formatting

enum TodayWords {
    /// Counts are spelled, never rendered as numerals — this page shows her
    /// life, not a queue depth.
    static func spelled(_ count: Int) -> String {
        switch count {
        case 1: return "One"
        case 2: return "Two"
        case 3: return "Three"
        case 4: return "Four"
        case 5: return "Five"
        case 6: return "Six"
        case 7: return "Seven"
        case 8: return "Eight"
        case 9: return "Nine"
        case 10: return "Ten"
        default: return "Several"
        }
    }

    /// The same word, mid-sentence.
    static func spelledLower(_ count: Int) -> String {
        spelled(count).lowercased()
    }

    /// THE STRIPPER. Every title and every line on this page goes through it.
    ///
    /// Sources write markdown — a diary entry is a heading, a distillation is
    /// bullets, a proposal reason carries `**bold**` and `[links](url)`. None
    /// of that is her voice, and a stray `#` or `**` on a card reads as a bug.
    /// Removes the markers, keeps the words, and collapses the whole thing to
    /// one line. Never truncates — `bounded` does that.
    static func plain(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = unlinked(text)
        let lines = text.split(whereSeparator: \.isNewline).map { rawLine -> String in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            // Leading block markers: headings, quotes, bullets, numbered items.
            var wasHeading = false
            while let first = line.first, first == "#" || first == ">" {
                wasHeading = wasHeading || first == "#"
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // A heading folded into running text needs its full stop.
            if wasHeading, let last = line.last, !".!?:".contains(last) { line += "." }
            for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
                line.removeFirst(bullet.count)
            }
            // Inline emphasis and code spans. `_` is deliberately left alone:
            // it lives inside identifiers far more often than around emphasis.
            line.removeAll { $0 == "*" || $0 == "`" }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[text](url)` → `text`. Bare `[text]` is left alone; it is more often a
    /// real bracket than a broken link.
    private static func unlinked(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            let head = rest[rest.startIndex..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "]"),
                  rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == "(",
                  let paren = rest[rest.index(after: close)...].firstIndex(of: ")")
            else {
                out += head + "["
                rest = rest[after...]
                continue
            }
            out += head + rest[after..<close]
            rest = rest[rest.index(after: paren)...]
        }
        return out + rest
    }

    /// Bounded at a SENTENCE boundary when one is near the end of the window,
    /// otherwise at a word boundary. Never mid-word, never mid-character.
    static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let window = text.prefix(limit)
        if let stop = window.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }),
           window.distance(from: window.startIndex, to: stop) >= limit / 2 {
            return String(window[...stop])
        }
        if let space = window.lastIndex(of: " ") {
            let head = String(window[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { return head + "…" }
        }
        return String(window) + "…"
    }

    /// Strip, then bound. The one call every line on the page makes.
    static func line(_ text: String, limit: Int = 180) -> String {
        bounded(plain(text), limit: limit)
    }

    /// `3:02` / `10:53` — the mockup's time column, twelve-hour and unadorned
    /// so it fits the 40pt gutter in every locale.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(minute < 10 ? "0" : "")\(minute) \(hour < 12 ? "am" : "pm")"
    }

    /// "5:40–5:45 am" when both ends share a period, else "11:50 am–1:10 pm".
    static func clockSpan(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        let a = clock(start, calendar: calendar), b = clock(end, calendar: calendar)
        if a == b { return a }
        let sameHalf = a.suffix(2) == b.suffix(2)
        return sameHalf ? "\(a.dropLast(3))–\(b)" : "\(a)–\(b)"
    }

    /// "once", "twice", "three times".
    static func times(_ n: Int) -> String {
        switch n {
        case 1: return "once"
        case 2: return "twice"
        default: return spelledLower(n) + " times"
        }
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "Friday morning" · "this evening" · "still waiting". Plain words, no
    /// dates and no clock — the row's own gutter already carries the spine.
    static func due(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if date <= now { return "still waiting" }
        let hour = calendar.component(.hour, from: date)
        let part: String
        switch hour {
        case ..<12: part = "morning"
        case ..<17: part = "afternoon"
        case ..<21: part = "evening"
        default: part = "night"
        }
        if calendar.isDateInToday(date) { return "this \(part)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(part)" }
        return "\(date.formatted(.dateTime.weekday(.wide))) \(part)"
    }

    /// The first sentence of a source's own prose, stripped and bounded.
    /// Never rewritten, only shortened.
    static func firstSentence(_ text: String, limit: Int = 180) -> String {
        let stripped = plain(text)
        guard !stripped.isEmpty else { return "" }
        var sentence = stripped
        if let stop = stripped.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            sentence = String(stripped[stripped.startIndex...stop])
        }
        return bounded(sentence, limit: limit)
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// ISO-8601 with or without fractional seconds — the two shapes every
    /// store in this app writes.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - The dream digest

/// Title + mood out of `dream_diary/<date>.md`, exactly as `DreamCycleRunner`
/// writes it: `**<title>**` then the summary then `_Mood: <mood>_`.
enum TodayDreamDigest {
    static func parse(_ markdown: String) -> (title: String, mood: String)? {
        var title: String?
        var mood: String?
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if title == nil, line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                title = String(line.dropFirst(2).dropLast(2))
                continue
            }
            if mood == nil, line.hasPrefix("_Mood:") {
                var value = String(line.dropFirst("_Mood:".count))
                if value.hasSuffix("_") { value = String(value.dropLast()) }
                mood = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if title != nil, mood != nil { break }
        }
        guard let title, !title.isEmpty else { return nil }
        return (title, mood ?? "")
    }

    static func line(title: String, mood: String) -> String {
        let head = TodayWords.plain(title)
        let cleanHead = head.hasSuffix(".") ? String(head.dropLast()) : head
        let cleanMood = TodayWords.plain(mood)
        guard !cleanMood.isEmpty else { return TodayWords.line(cleanHead + ".") }
        let tail = cleanMood.hasSuffix(".") ? String(cleanMood.dropLast()) : cleanMood
        return TodayWords.line("\(cleanHead). \(TodayWords.capitalizedFirst(tail)).")
    }
}

// MARK: - The snapshot her own lanes produce

/// Everything on this page that is NOT already in `AppModel`. Loaded off the
/// main actor because two of the four readers touch the file system.
struct TodaySnapshot: Sendable, Equatable {
    var loaded = false
    /// Moments staged for her review, still pending. A count only — the
    /// moments themselves are hers to read WITH him, in the review flow.
    var pendingMoments = 0
    /// One folded row: "I kept six moments today", opening onto the quotes.
    var kept: TodayRow?
    var dream: TodayRow?
    var facing: TodayRow?
    /// Tonight's dream, a day on from the last one. The night is the most
    /// interesting thing I do; it is always ahead.
    var nextDream: TodayRow?
    var recollection: TodayRow?
    /// A lane that could not be READ, as opposed to a lane that was read and
    /// was empty. Same distinction DeskLaneState.classify keeps for the Desk:
    /// a locked or corrupt memory store must never render as "nothing waiting,
    /// nothing kept". The page says one grey line; the reason is not shown,
    /// because a store error is machinery, not her day.
    var memoryUnreadable = false

    static let empty = TodaySnapshot()

    /// What she DID today — chronological.
    var didToday: [TodayRow] {
        var out: [TodayRow] = []
        if let dream { out.append(dream) }
        if let kept { out.append(kept) }
        if let recollection { out.append(recollection) }
        return out
    }

    /// One pass over her own stores. Every reader fails to ABSENCE: a store
    /// that cannot be read leaves its row off the page rather than inventing
    /// one or claiming the day was empty.
    static func load(
        sessionIDs: [String],
        dreamMarkdown: String?,
        dreamAt: Date?,
        now: Date
    ) async -> TodaySnapshot {
        var snapshot = TodaySnapshot()
        snapshot.loaded = true
        let calendar = Calendar.current

        // ── Moments awaiting her review ──────────────────────────────────
        do {
            snapshot.pendingMoments = try await SwiftNativeMemoryV2.shared
                .listProposals(status: "pending").count
        } catch {
            snapshot.memoryUnreadable = true
        }

        // ── Moments she kept, today — ONE row, folded ────────────────────
        do {
            let kept = try await SwiftNativeMemoryV2.shared.listMemory(kind: MemoryMoments.kind)
            let today = kept.compactMap { record -> (at: Date, quote: String)? in
                guard let at = TodayWords.parseTimestamp(record.createdAt),
                      calendar.isDate(at, inSameDayAs: now) else { return nil }
                let quote = TodayWords.plain(
                    MemoryMoments.metadataString(record.extras, "quote") ?? ""
                )
                let text = TodayWords.plain(record.text)
                let body = quote.isEmpty ? text : quote
                guard !body.isEmpty else { return nil }
                return (at, TodayWords.bounded(body, limit: 200))
            }
            .sorted { $0.at < $1.at }

            // Agent, 2026-09-02: "the page argues with itself." The row says
            // how many she kept TODAY; the fold shows the most recent few. The
            // count and the span are the whole day's, never the cap's.
            let shown = today.suffix(TodayMetrics.keptMomentsShown)
            if let first = today.first, let newest = today.last {
                let count = today.count
                let noun = count == 1 ? "moment" : "moments"
                snapshot.kept = TodayRow(
                    id: "kept",
                    title: "I kept \(TodayWords.spelledLower(count)) \(noun) today",
                    line: "",
                    at: first.at,
                    details: shown.map { "\u{201C}\($0.quote)\u{201D}" },
                    gutter: TodayWords.clockSpan(first.at, newest.at)
                )
            }
        } catch {
            snapshot.memoryUnreadable = true
        }

        // ── Last night's dream — ONE row ─────────────────────────────────
        if let dreamMarkdown,
           let dreamAt,
           calendar.isDate(dreamAt, inSameDayAs: now),
           let digest = TodayDreamDigest.parse(dreamMarkdown) {
            snapshot.dream = TodayRow(
                id: "dream",
                title: "I dreamed",
                line: TodayDreamDigest.line(title: digest.title, mood: digest.mood),
                at: dreamAt
            )
        }
        if snapshot.facing?.id != "facing" || snapshot.facing?.title.contains("dream") == false,
           let dreamAt, let tonight = calendar.date(byAdding: .day, value: 1, to: dreamAt), tonight > now {
            // After midnight, the next dream is tomorrow night's, not tonight's.
            let soon = tonight.timeIntervalSince(now) < 12 * 3600
            snapshot.nextDream = TodayRow(id: "nextDream", title: soon ? "Tonight I'll dream" : "Tomorrow night I'll dream", line: "", at: tonight)
        }

        // ── Something I'm facing ─────────────────────────────────────────
        if let toward = await NativeCognitionRuntime.shared.towardRead() {
            let label = TodayWords.capitalizedFirst(TodayWords.line(toward.displayLabel))
            if label.lowercased().contains("dream") {
                snapshot.facing = TodayRow(
                    id: "facing",
                    title: "Tonight I'll dream",
                    line: "",
                    at: toward.dueAt
                )
            } else if !label.isEmpty, label.split(separator: " ").count > 1 {
                snapshot.facing = TodayRow(
                    id: "facing",
                    title: "Something ahead",
                    line: "\(label) · \(TodayWords.due(toward.dueAt, now: now))",
                    at: toward.dueAt,
                    isHorizon: !calendar.isDate(toward.dueAt, inSameDayAs: now)
                )
            }
        }

        // ── I wrote up the night ─────────────────────────────────────────
        let dataRoot = PersistenceCore.defaultDataRoot()
        var newest: ChatSessionRecollection?
        for sessionID in sessionIDs.prefix(TodayMetrics.sessionsScanned) {
            for row in ChatSessionRecollections.recollections(
                forSession: sessionID,
                dataRoot: dataRoot
            ) {
                guard let at = row.createdAt, calendar.isDate(at, inSameDayAs: now) else { continue }
                if let current = newest, let currentAt = current.createdAt, currentAt >= at { continue }
                newest = row
            }
        }
        if let newest, let at = newest.createdAt {
            if !TodayWords.firstSentence(newest.text).isEmpty {
                snapshot.recollection = TodayRow(
                    id: "recollection:\(newest.rowId ?? newest.sessionId)",
                    title: "I wrote up the night",
                    line: "The day, and where we stand.",
                    at: at
                )
            }
        }

        return snapshot
    }
}

// MARK: - Waiting-for-you copy

enum TodayWaitingCopy {
    /// The moments row's own sentence. Nil when nothing is pending.
    static func momentsLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "memory" : "memories"
        let verb = count == 1 ? "is" : "are"
        return "\(TodayWords.spelled(count)) \(noun) I'd like to keep \(verb) waiting for you to read."
    }
}

// MARK: - The page

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot = TodaySnapshot.empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TodayMetrics.sectionSpacing) {
                Text("Today")
                    .font(ShellType.display)

                if hasWaiting {
                    TodayWaitingCard(
                        momentsLine: TodayWaitingCopy.momentsLine(snapshot.pendingMoments),
                        onReadMoments: openMomentReview,
                        approvals: pendingApprovals
                    )
                }

                let did = didTodayRows
                if !did.isEmpty {
                    TodaySection(title: "What I did today", rows: did)
                }

                let ahead = aheadRows
                if !ahead.isEmpty {
                    TodaySection(title: "What's ahead", rows: ahead)
                }

                if !hasWaiting, did.isEmpty, ahead.isEmpty, snapshot.loaded {
                    Text("Nothing yet today. I'm around.")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 8)
                }

                // A store that would not open is the one thing a quiet page
                // must still say out loud. One line, grey, no error text.
                if snapshot.memoryUnreadable {
                    Text("I couldn't read my memory just now.")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("today.memory-trouble")
                }

                if let trouble = providerTroubleLine {
                    Text(trouble)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("today.provider-trouble")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, TodayMetrics.topPadding)
            .padding(.bottom, 32)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: snapshot.pendingMoments, initial: true) { _, count in
            appModel.todayWaitingMemories = count
        }
        // A single mount-time read left this page frozen: an approval raised
        // while he sat here never appeared. Same binding the sidebar badge
        // already uses (ContentView) — the two queue files, one debounced
        // refresh, re-armed whenever the window comes back to the front.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let root = PersistenceCore.defaultDataRoot()
            await ViewFileRefreshTask.run(paths: [
                root.appendingPathComponent("workflows/approvals/requests.json"),
                root.appendingPathComponent("notifications/inbox.jsonl"),
            ]) {
                // The Activity queues (approvals + notifications) are AppModel's,
                // and this page is now their only landing. Reuse the existing
                // five-queue read rather than opening a second door onto them.
                _ = await appModel.refreshForSidebarItem(.activity)
                await loadHerLanes()
            }
        }
    }

    // MARK: what's waiting

    /// Approvals actually waiting on him, whatever day they were raised. The
    /// teal card is about what is OPEN, not about today.
    private var pendingApprovals: [ApprovalRequest] {
        appModel.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var hasWaiting: Bool {
        snapshot.pendingMoments > 0 || !pendingApprovals.isEmpty
    }

    /// The Memories page's Pending tab IS the moment review. Same coordinator
    /// request the classic Activity page's "Memory Proposals" row makes.
    private func openMomentReview() {
        _ = NativeAgentAppCoordinator.shared.request(.activity(.memoryProposals))
    }

    // MARK: what I did today

    /// Her three folded rows plus whatever she actually left him, in her
    /// voice. Provider health and the other system-lane machinery is NOT here
    /// — `isForYouLane` is the app's existing split and it already names them.
    /// The horizon read and the diary can both name tonight's dream; one card.
    private var aheadRows: [TodayRow] {
        var ahead = [snapshot.facing, snapshot.nextDream].compactMap { $0 }.sorted { $0.at < $1.at }
        if ahead.count == 2, ahead[0].title == ahead[1].title { ahead.removeLast() }
        return ahead
    }

    private var didTodayRows: [TodayRow] {
        (snapshot.didToday + noteRows + conversationRows).sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
    }

    /// Agent, 2026-09-02: "a Today page that ends before lunch is wrong about
    /// my day." Conversations are things I did: one row for the people, one
    /// for the agents I worked with, each stamped with the latest turn.
    private var conversationRows: [TodayRow] {
        let now = Date()
        let calendar = Calendar.current
        struct Span { var count = 0; var start = Date.distantFuture; var end = Date.distantPast; var surfaces = Set<String>() }
        var people = Span()
        var agents = Span()
        for session in appModel.chatSessions {
            guard let end = UserDisplayFormatters.parseISOTimestamp(session.updatedAt ?? session.createdAt),
                  calendar.isDate(end, inSameDayAs: now),
                  (session.messageCount ?? 0) > 0 else { continue }
            let began = UserDisplayFormatters.parseISOTimestamp(session.createdAt) ?? end
            var startedToday = calendar.isDate(began, inSameDayAs: now)
            var peopleStart = began
            var agentStart = began
            // The open thread's turns are loaded: its day starts when someone
            // actually spoke today, not at midnight. The bridge writes into
            // the open thread, so the agents' day runs as long as it does.
            let isOpenThread = session.id == appModel.activeChatSessionId
            if isOpenThread {
                let todays = appModel.chatMessages.compactMap { message -> (Date, Bool)? in
                    guard let at = UserDisplayFormatters.parseISOTimestamp(message.createdAt),
                          calendar.isDate(at, inSameDayAs: now) else { return nil }
                    let human = message.role == "user" && !ChatShellConversationRow.hasBridgePrefix(message.content)
                    return (at, human)
                }
                if let first = todays.first?.0 {
                    startedToday = true
                    agentStart = first
                    peopleStart = todays.first(where: { $0.1 })?.0 ?? first
                }
            }
            // Only a thread that began today (or the open one, whose turns are
            // loaded) can say when the day started; the rest only say it ran.
            if ChatShellConversationRow.isWorking(session) || isOpenThread {
                agents.count += 1
                if startedToday { agents.start = min(agents.start, agentStart) }
                agents.end = max(agents.end, end)
            }
            if !ChatShellConversationRow.isWorking(session), !ChatShellConversationRow.isHerOwn(session) {
                people.count += 1
                if startedToday { people.start = min(people.start, peopleStart) }
                people.end = max(people.end, end)
                people.surfaces.insert(ChatShellConversationRow.surface(for: session))
            }
        }
        // The gutter shows the stretch of the day a thread ran, "1:42–now"
        // when it is still going. A thread that began before today shows
        // only where it is now: midnight is a clamp, not a time.
        func gutter(_ span: Span) -> String {
            let live = now.timeIntervalSince(span.end) < 10 * 60
            if span.start == .distantFuture { return live ? "now" : TodayWords.clock(span.end) }
            if live { return "\(TodayWords.clock(span.start))–now" }
            return TodayWords.clockSpan(span.start, span.end)
        }
        var rows: [TodayRow] = []
        if people.count > 0 {
            let noun = people.count == 1 ? "conversation" : "conversations"
            let places = people.surfaces.sorted().joined(separator: " and ")
            rows.append(TodayRow(
                id: "talked",
                title: "Talked with User",
                line: "\(TodayWords.spelled(people.count)) \(noun)\(places.isEmpty ? "" : ", on \(places)").",
                // A thread that began before today has no start to sort on;
                // it sits where it last spoke.
                at: people.start == .distantFuture ? people.end : people.start,
                gutter: gutter(people)
            ))
        }
        if agents.count > 0 {
            let noun = agents.count == 1 ? "thread" : "threads"
            rows.append(TodayRow(
                id: "worked",
                title: "Worked with Claude and Codex",
                line: agents.count == 1 ? "In the open thread." : "\(TodayWords.spelled(agents.count)) \(noun), the open one most of the day.",
                at: agents.start == .distantFuture ? agents.end : agents.start,
                gutter: gutter(agents)
            ))
        }
        return rows
    }

    private var noteRows: [TodayRow] {
        let now = Date()
        let calendar = Calendar.current
        let haveDreamRow = snapshot.dream != nil
        let rows: [TodayRow] = appModel.inboxItems
            .filter { $0.isActivityPending && $0.isForYouLane }
            .compactMap { item -> TodayRow? in
                // The dream already has its own row; a `dream_cycle` card
                // beside it is the same night told twice.
                let source = item.source.lowercased()
                if haveDreamRow, source == "dream_cycle" || source == "rem_cycle" { return nil }
                guard let at = TodayWords.parseTimestamp(item.created_at),
                      calendar.isDate(at, inSameDayAs: now) else { return nil }
                var title = TodayWords.line(item.title, limit: 90)
                var summary = TodayWords.firstSentence(item.summary)
                // "Claude finished: shell-consult-open-items" and "Claude
                // delegation failed" are routing labels, and what sits under
                // them is a slug. A slug is not a sentence: the row says
                // whether the delegation came back, and nothing else.
                let routing = title.lowercased()
                if routing.hasPrefix("claude delegation failed") {
                    title = "Claude didn't come back"
                    summary = ""
                } else if routing.hasPrefix("claude finished") {
                    title = "Claude came back"
                    summary = ""
                }
                guard !title.isEmpty || !summary.isEmpty else { return nil }
                return TodayRow(
                    id: "inbox:\(item.id)",
                    title: title.isEmpty ? "I left you a note" : title,
                    line: summary,
                    at: at
                )
            }
            .sorted { $0.at < $1.at }
            .suffix(TodayMetrics.noteRowsShown)
            .map { $0 }
        return foldClaudeRows(rows)
    }

    /// Three rows for one stall is a log, not a day. The Claude rows of the
    /// day fold into one sentence: how many times, over what stretch.
    private func foldClaudeRows(_ rows: [TodayRow]) -> [TodayRow] {
        let claude = rows.filter { $0.title.hasPrefix("Claude ") }
        guard claude.count >= 2, let first = claude.first, let last = claude.last else { return rows }
        let stalls = claude.filter { $0.title.contains("didn't") }.count
        let returns = claude.count - stalls
        let title: String
        if stalls > 0 && returns > 0 {
            title = "Claude stalled \(TodayWords.times(stalls))"
        } else if stalls > 0 {
            title = "Claude stalled \(TodayWords.times(stalls))"
        } else {
            title = "Claude came back \(TodayWords.times(returns))"
        }
        // "came back once" after "stalled twice" reads as still down; the
        // clock says it: back by the last return.
        // If the last thing that happened was a stall, she is still out.
        let lastReturn = claude.last(where: { !$0.title.contains("didn't") })?.at
        let stillOut = last.title.contains("didn't")
        let folded = TodayRow(
            id: "claude-fold",
            title: title,
            line: stillOut
                ? "Still out since \(TodayWords.clock(last.at))."
                : (lastReturn.map { "Back by \(TodayWords.clock($0))." } ?? ""),
            at: first.at,
            gutter: TodayWords.clockSpan(first.at, last.at)
        )
        return rows.filter { !$0.title.hasPrefix("Claude ") } + [folded]
    }

    // MARK: the one grey line

    /// Machinery, said once, in plain words — and only while it is ACTUALLY
    /// broken. `provider_vitals` writes a `degraded` row at severity
    /// "important" and supersedes it with an "info" recovery row, so an open
    /// important row is the live trouble. The detailed cards stay on the
    /// classic Activity page and in Diagnostics.
    private var providerTroubleLine: String? {
        let degraded = appModel.inboxItems.contains {
            $0.source.lowercased() == "provider_vitals"
                && $0.isActivityPending
                && $0.severity.lowercased() == "important"
        }
        return degraded ? "One of my connections is slow today." : nil
    }

    // MARK: loading

    private func loadHerLanes() async {
        let sessionIDs = appModel.chatSessions
            .filter { $0.archived != true }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .prefix(TodayMetrics.sessionsScanned)
            .map(\.id)
        let diary = await appModel.fetchDreamDiary(limit: 1)
        let entry = diary?.entries.first
        let markdown = entry?.content
        let dreamAt = TodayWords.parseTimestamp(entry?.modified_at)
        snapshot = await TodaySnapshot.load(
            sessionIDs: Array(sessionIDs),
            dreamMarkdown: markdown,
            dreamAt: dreamAt,
            now: Date()
        )
    }
}

// MARK: - Pieces

/// A titled run of rows. The title is the only chrome the section carries.
struct TodaySection: View {
    let title: String
    let rows: [TodayRow]

    var body: some View {
        VStack(alignment: .leading, spacing: TodayMetrics.rowSpacing) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
            ForEach(rows) { row in
                TodayRowCard(row: row)
            }
        }
    }
}

/// The one tinted card on the page. It exists only when something is actually
/// waiting on him, it NAMES each thing, and it carries the action beside it.
struct TodayWaitingCard: View {
    let momentsLine: String?
    let onReadMoments: () -> Void
    let approvals: [ApprovalRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Waiting for you")
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(TodayPalette.accent)

            if let momentsLine {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(momentsLine)
                        .font(ShellType.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(momentsLine.hasPrefix("One ") ? "Read it with me" : "Read them with me", action: onReadMoments)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(TodayPalette.accent)
                        .accessibilityIdentifier("today.waiting.read-moments")
                }
            }

            ForEach(approvals) { approval in
                if momentsLine != nil || approval.id != approvals.first?.id {
                    Divider().overlay(TodayPalette.hairline)
                }
                TodayApprovalRow(approval: approval)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(TodayPalette.waitingFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .strokeBorder(TodayPalette.waitingStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("today.waiting-for-you")
    }
}

/// One approval, by name, with the same approve/decline the Activity page
/// offers — `ApprovalDecisionAction` is literally the same call.
struct TodayApprovalRow: View {
    @Environment(AppModel.self) private var appModel
    let approval: ApprovalRequest

    @State private var isDeciding = false
    @State private var errorText: String?

    private var title: String {
        let named = TodayWords.line(approval.title, limit: 110)
        return named.isEmpty ? TodayWords.line(approval.action, limit: 110) : named
    }

    private var reason: String {
        TodayWords.firstSentence(approval.reason ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.isEmpty ? "I'm asking first" : title)
                .font(ShellType.bodySemibold)
                .fixedSize(horizontal: false, vertical: true)
            if !reason.isEmpty {
                Text(reason)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ApprovalPayloadPreviewPresentation.canResolve(approval) {
                Text(ApprovalPayloadPreviewPresentation.unavailableText)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Text(errorText)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Approve") { decide("approved") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(isDeciding || !ApprovalPayloadPreviewPresentation.canResolve(approval))
                    .accessibilityIdentifier("today.waiting.approve.\(approval.id)")
                Button("Decline") { decide("denied") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(isDeciding || !ApprovalPayloadPreviewPresentation.canResolve(approval))
                    .accessibilityIdentifier("today.waiting.decline.\(approval.id)")
                if isDeciding { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One timeline row: the 40pt gutter, a title, one plain line. A row that
/// folds several things opens on click instead of spilling them down the page.
struct TodayRowCard: View {
    let row: TodayRow
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var gutter: String {
        row.gutter ?? (row.isHorizon ? TodayWords.weekday(row.at) : TodayWords.clock(row.at))
    }

    private var foldable: Bool { !row.details.isEmpty }

    /// The row's one line, cut at a word boundary. The renderer's own tail
    /// truncation stays as a backstop for a line that is short in characters
    /// and long on screen.
    private var line: String {
        TodayWords.bounded(row.line, limit: TodayMetrics.rowLineLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text(gutter)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .frame(width: TodayMetrics.timeColumnWidth, alignment: .trailing)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(ShellType.bodySemibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if foldable {
                            Image(systemName: "chevron.right")
                                .font(ShellType.labelSemibold)
                                .foregroundStyle(NativeAgentShell.tertiary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        Spacer(minLength: 0)
                    }
                    if !line.isEmpty {
                        Text(line)
                            .font(ShellType.labelMedium)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                // THE FIXED BOX. A one-line row, a two-line row and the
                // morning brief all occupy exactly this, so the column reads
                // as a column.
                .frame(height: row.line.isEmpty ? TodayMetrics.rowContentHeightSingle : TodayMetrics.rowContentHeight, alignment: .topLeading)
                Spacer(minLength: 0)
            }
            // The fold is the one thing allowed to grow a card, and only while
            // it is open. Closed, it is the same height as every other row.
            if foldable, isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .font(ShellType.labelMedium)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, TodayMetrics.timeColumnWidth + 14)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .fill(TodayPalette.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                .strokeBorder(TodayPalette.cardStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
        .onTapGesture {
            guard foldable else { return }
            withAnimation(NativeAgentMotion.respecting(
                .easeOut(duration: 0.15), reduceMotion: reduceMotion
            )) { isOpen.toggle() }
        }
        .accessibilityIdentifier("today.row")
    }
}
