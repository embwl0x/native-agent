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
//
// Alive glass (User approved the mockup, 2026-09-23): same three sections, now
// drawn from AlivePageKit — a serif "Today" with one first-person sentence
// built from the page's own counts, the waiting things in ONE group card, what
// I did as a timeline on a haze line, and what's ahead as pills.

import SwiftUI
import NativeAgentShared
import NativeAgentCore
import CognitiveSubstrate
import PersistenceCore
import MemoryV2
import ApprovalInbox

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
    /// 2026-09-12 (User's eye, Agent's read): the waiting card was a third
    /// surface — a translucent green-grey that let the ground through while
    /// every other card was opaque slate. One family of surfaces: it wears the
    /// card's own fill and stroke, and its priority is carried by the teal
    /// heading (`accent`) and the action beside the line, not by the ground
    /// under it.
    static let waitingFill = cardFill
    static let waitingStroke = cardStroke
    static let hairline = Color.primary.opacity(0.08)
}

enum TodayMetrics {
    static let contentWidth: CGFloat = 920
    static let cardRadius: CGFloat = 12
    /// The timeline's time column, fixed. Wide enough for "10:53–11:55 am"
    /// at 12pt: a folded row says its span, and the mockup's 64pt only held
    /// a single clock.
    static let timeColumnWidth: CGFloat = 98
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
    /// Only the diary key travels with the summary; the reader owns the body.
    let dreamDate: String?

    init(
        id: String,
        title: String,
        line: String,
        at: Date,
        isHorizon: Bool = false,
        details: [String] = [],
        gutter: String? = nil,
        dreamDate: String? = nil
    ) {
        self.id = id
        self.title = title
        self.line = line
        self.at = at
        self.isHorizon = isHorizon
        self.details = details
        self.gutter = gutter
        self.dreamDate = dreamDate
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
            // A backslash is never something to read: a stray one in a quote
            // rendered "exax\ctly" on Memories (2026-09-23).
            line.removeAll { $0 == "*" || $0 == "`" || $0 == "\\" }
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
    static func clock(_ date: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(minute < 10 ? "0" : "")\(minute) \(hour < 12 ? "am" : "pm")"
    }

    /// "5:40–5:45 am" when both ends share a period, else "11:50 am–1:10 pm".
    static func clockSpan(_ start: Date, _ end: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
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

    /// "Today", "Tonight", "Tomorrow" or the weekday — from the real date and
    /// hour, so a 4:30 am dream is never called tonight's.
    static func dayWord(_ date: Date, now: Date = Date(), calendar: Calendar = DisplayTimeZone.calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 18 ? "Tonight" : "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    /// Raw ids out of a line: `conversation-cbd5dce3af1b903c`, UUIDs, long
    /// hex. What is left is tidied so no empty "()" or trailing colon remains.
    static func withoutIDs(_ text: String) -> String {
        var out = text
            .replacing(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/, with: "")
            .replacing(/\b[A-Za-z]+[-_][0-9A-Fa-f]{8,}\b/, with: "")
            .replacing(/\b(?=[0-9A-Fa-f]*[0-9])[0-9A-Fa-f]{12,}\b/, with: "")
        out = out.replacing(/\(\s*\)/, with: "").replacing(/\s{2,}/, with: " ")
        out = out.trimmingCharacters(in: .whitespaces)
        while let last = out.last, ":·-".contains(last) {
            out = String(out.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// The honest date of something still open from an earlier day:
    /// "Yesterday", then the weekday inside the last week, then "9 Sep".
    /// Never "today" — a note that waited says how long it waited.
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = DisplayTimeZone.calendar) -> String {
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "Friday morning" · "this evening" · "still waiting". Plain words, no
    /// dates and no clock — the row's own gutter already carries the spine.
    static func due(_ date: Date, now: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
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
        /// The recollections carried by the SAME transcript read the page
        /// already did, across `sessionIDs`. Nil means "not read for me" and
        /// this pass reads them itself, as it always did.
        recollections: [ChatSessionRecollection]? = nil,
        dreamMarkdown: String?,
        dreamAt: Date?,
        dreamDate: String? = nil,
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
                    details: shown.map { "\u{201C}\(TodayWords.plain($0.quote))\u{201D}" },
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
                at: dreamAt,
                dreamDate: dreamDate
            )
        }
        // The chip's day word comes from this date (TodayAhead), never from
        // how soon it is.
        if let dreamAt, let next = calendar.date(byAdding: .day, value: 1, to: dreamAt), next > now {
            snapshot.nextDream = TodayRow(id: "nextDream", title: "I'll dream", line: "", at: next)
        }

        // ── Something I'm facing ─────────────────────────────────────────
        if let toward = await NativeCognitionRuntime.shared.towardRead() {
            let label = TodayWords.capitalizedFirst(TodayWords.line(toward.displayLabel))
            if label.lowercased().contains("dream") {
                snapshot.facing = TodayRow(
                    id: "facingDream",
                    title: "I'll dream",
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
        let scanned: [ChatSessionRecollection] = recollections ?? sessionIDs
            .prefix(TodayMetrics.sessionsScanned)
            .flatMap { ChatSessionRecollections.recollections(forSession: $0, dataRoot: dataRoot) }
        var newest: ChatSessionRecollection?
        for row in scanned {
            guard let at = row.createdAt, calendar.isDate(at, inSameDayAs: now) else { continue }
            if let current = newest, let currentAt = current.createdAt, currentAt >= at { continue }
            newest = row
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

    /// An approval's name in plain words. A skill proposal's own title is a
    /// tool sequence ("workspace → workspace"); that is not a name.
    static func approvalTitle(_ approval: ApprovalRequest) -> String {
        ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason ?? "")
    }
}

// MARK: - Waiting on you, defined once

/// "Waiting on you" — ONE definition, read by the Today and Desk headers alike
/// (Agent, 2026-09-23: the two pages contradicted each other). Something that
/// needs his decision or action: a pending approval, a memory to review, or a
/// Desk item waiting on him. Failures and notices are never in it.
@MainActor
enum WaitingOnYou {
    static func approvals(_ appModel: AppModel) -> [ApprovalRequest] {
        appModel.approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status) }
    }

    static func memories(_ appModel: AppModel) -> Int { appModel.memoryProposals.count }

    static func deskItems(_ items: [DeskItem]) -> [DeskItem] { DeskPageContent.waitingOnOwner(items) }

    static func count(_ appModel: AppModel, deskItems items: [DeskItem]) -> Int {
        approvals(appModel).count + memories(appModel) + deskItems(items).count
    }
}

// MARK: - The page

/// Session titles and an open tab are not participation receipts. Only dated,
/// persisted ingress with matching builder provenance contributes to this row.
enum TodayCollaboration {
    static func row(messagesBySession: [String: [ChatMessage]], now: Date) -> TodayRow? {
        var participants = Set<String>()
        var sessions = Set<String>()
        var dates: [Date] = []
        for (sessionID, messages) in messagesBySession {
            for message in messages {
                guard message.sessionId == nil || message.sessionId == sessionID,
                      message.role == "user",
                      !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let origin = message.metadata?.origin,
                      let agent = origin.agent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      ["claude", "codex"].contains(agent),
                      origin.surface?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "\(agent)-bridge",
                      let at = UserDisplayFormatters.parseISOTimestamp(message.createdAt),
                      at <= now, Calendar.current.isDate(at, inSameDayAs: now) else { continue }
                participants.insert(agent)
                sessions.insert(sessionID)
                dates.append(at)
            }
        }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let noun = sessions.count == 1 ? "conversation" : "conversations"
        let names = participants.sorted().map(TodayWords.capitalizedFirst).joined(separator: " and ")
        return TodayRow(
            id: "worked",
            title: "I worked with \(names)",
            line: "\(TodayWords.spelled(sessions.count)) \(noun).",
            at: first,
            gutter: TodayWords.clockSpan(first, last)
        )
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @State private var snapshot = TodaySnapshot.empty
    @State private var collaborationMessages: [String: [ChatMessage]] = [:]
    @State private var dreamUnavailable = false
    @State private var openedNote: InboxItemRecord?
    @State private var noteFlight = InboxRowActionFlight()
    @State private var earlierOpen = false
    /// The Desk board, for the one shared "waiting on you" count.
    @State private var deskItems: [DeskItem] = []
    @State private var deskUnreadable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                AlivePageHeader(title: "Today", line: headerLine)

                if hasWaiting {
                    TodayWaitingCard(
                        momentsLine: TodayWaitingCopy.momentsLine(WaitingOnYou.memories(appModel)),
                        onReadMoments: openMomentReview,
                        approvals: WaitingOnYou.approvals(appModel),
                        deskCount: WaitingOnYou.deskItems(deskItems).count
                    )
                }

                // Failures and notices from earlier days are not waiting. One
                // folded quiet line; it opens the grouped list in place.
                if let earlierNotesLine {
                    VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                        Button(earlierNotesLine + (earlierOpen ? " · Hide" : " · Show")) {
                            earlierOpen.toggle()
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
                        }
                    }
                }

                let did = didTodayRows
                if !did.isEmpty {
                    TodaySection(title: "What I did today", rows: did, onReadDream: readDream)
                }

                let ahead = aheadRows
                if !ahead.isEmpty {
                    TodayAhead(rows: ahead)
                }

                if !hasWaiting, did.isEmpty, ahead.isEmpty, earlierNotesLine == nil,
                   snapshot.loaded, !snapshot.memoryUnreadable, !dreamUnavailable {
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
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("today.memory-trouble")
                }

                if dreamUnavailable {
                    Text("I couldn't read the dream source just now.")
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                }

                if let trouble = providerTroubleLine {
                    Text(trouble)
                        .font(ShellType.labelMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("today.provider-trouble")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, TodayMetrics.topPadding)
            .motionArrival(when: snapshot.loaded)
            .padding(.bottom, 32)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The same detail surface the Activity page opens, with its own
        // read/action behaviour — an older note is opened here, not retold.
        .sheet(item: $openedNote) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: appModel.inboxItems,
                onAction: { actionID in
                    let outcome = await noteFlight.perform {
                        try await appModel.client.inboxAction(item.id, action: actionID)
                    }
                    if case .succeeded = outcome {
                        _ = await appModel.refreshForSidebarItem(.activity)
                    }
                    return outcome
                },
                onClose: { openedNote = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .onChange(of: snapshot.pendingMoments, initial: true) { _, count in
            // Nobody is looking at this copy, so it has cleared nothing.
            guard !quietOffscreenRead else { return }
            appModel.todayWaitingMemories = count
        }
        // Queue and memory changes share one coalesced refresh, re-armed
        // whenever the window comes back to the front.
        .liveTask(id: scenePhase) {
            guard scenePhase == .active else { return }
            let root = PersistenceCore.defaultDataRoot()
            await ViewFileRefreshTask.run(paths: [
                root.appendingPathComponent("workflows/approvals/requests.json"),
                root.appendingPathComponent("notifications/inbox.jsonl"),
                root.appendingPathComponent("memory/memory.sqlite"),
                root.appendingPathComponent("memory/memory.sqlite-wal"),
            ]) {
                // The Activity queues (approvals + notifications) are AppModel's,
                // and this page is now their only landing. Reuse the existing
                // five-queue read rather than opening a second door onto them.
                _ = await appModel.refreshForSidebarItem(.activity)
                await loadHerLanes()
            }
        }
        // The visible page is loaded by the watcher above; the offscreen copy
        // a quiet read mounts has no watcher, so it reads the same lanes once.
        .quietReadTask(live: false) {
            _ = await appModel.refreshForSidebarItem(.activity)
            await loadHerLanes()
        }
    }

    // MARK: the header's one sentence

    /// One first-person sentence from counts the page already holds. No model
    /// call, and nothing said before the lanes are read: a page that has not
    /// looked yet does not get to say "nothing is waiting".
    private var headerLine: String? {
        guard snapshot.loaded else { return nil }
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"
        let did = didTodayRows.count
        let day: String
        switch did {
        case 0: day = "A quiet \(part) so far."
        case 1...2: day = "A quiet \(part)."
        default: day = "I've had a full \(part)."
        }
        // A store that would not open cannot vouch for "nothing".
        let waiting = WaitingOnYou.count(appModel, deskItems: deskItems)
        if waiting == 0 {
            return snapshot.memoryUnreadable || deskUnreadable ? day : "\(day) Nothing is waiting on you."
        }
        let things = waiting == 1 ? "thing is" : "things are"
        return "\(day) \(DeskPageWords.spelled(waiting)) \(things) waiting on you."
    }

    // MARK: what's waiting

    /// Notes from an earlier day he has not cleared — failures and things she
    /// told him. Not waiting: today's own notes are in the timeline, and a
    /// morning brief from yesterday is just a note. Grouped so the same agent
    /// failing the same way twice is one row, "×2"; newest group first.
    private var earlierNotes: [TodayEarlierNote] {
        let now = Date()
        var groups: [String: TodayEarlierNote] = [:]
        for item in appModel.inboxItems where item.isActivityPending && item.isForYouLane {
            guard let at = TodayWords.parseTimestamp(item.created_at),
                  !Calendar.current.isDate(at, inSameDayAs: now) else { continue }
            let title = TodayWords.withoutIDs(TodayWords.line(item.title, limit: 90))
            let lower = title.lowercased()
            let failure = lower.contains("fail") || lower.contains("lost") || lower.contains("didn't finish")
            let key = "\(item.source.lowercased())|\(lower)"
            if var group = groups[key] {
                group.count += 1
                if at > group.at { group.at = at; group.newest = item }
                if at < group.oldest { group.oldest = at }
                groups[key] = group
            } else {
                groups[key] = TodayEarlierNote(
                    id: key, title: title.isEmpty ? "A note I left you" : title,
                    isFailure: failure, count: 1, at: at, oldest: at, newest: item)
            }
        }
        return groups.values.sorted {
            $0.isFailure != $1.isFailure ? $0.isFailure : $0.at > $1.at
        }
    }

    /// "3 failures and 1 note since Monday".
    private var earlierNotesLine: String? {
        let notes = earlierNotes
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
        WaitingOnYou.count(appModel, deskItems: deskItems) > 0
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
        // One dream chip: the horizon's own due time when it names the dream.
        let dreamFacing = snapshot.facing?.id == "facingDream"
        return [snapshot.facing, dreamFacing ? nil : snapshot.nextDream]
            .compactMap { $0 }
            .sorted { $0.at < $1.at }
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
        for session in appModel.chatSessions {
            guard let end = UserDisplayFormatters.parseISOTimestamp(session.updatedAt ?? session.createdAt),
                  calendar.isDate(end, inSameDayAs: now),
                  (session.messageCount ?? 0) > 0 else { continue }
            let began = UserDisplayFormatters.parseISOTimestamp(session.createdAt) ?? end
            var startedToday = calendar.isDate(began, inSameDayAs: now)
            var peopleStart = began
            // The open thread's turns are loaded: its day starts when someone
            // actually spoke today, not at midnight.
            let isOpenThread = session.id == appModel.activeChatSessionId
            if isOpenThread {
                let todays = appModel.chatMessages.compactMap { message -> (Date, Bool)? in
                    guard let at = UserDisplayFormatters.parseISOTimestamp(message.createdAt),
                          calendar.isDate(at, inSameDayAs: now) else { return nil }
                    let human = message.role == "user" && MacChatMessageProvenance.make(
                        role: message.role, source: message.source, origin: message.metadata?.origin
                    )?.isAutomated != true
                    return (at, human)
                }
                if let first = todays.first?.0 {
                    startedToday = true
                    peopleStart = todays.first(where: { $0.1 })?.0 ?? first
                }
            }
            // Only a thread that began today (or the open one, whose turns are
            // loaded) can say when the day started; the rest only say it ran.
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
                title: "Talked with you",
                line: "\(TodayWords.spelled(people.count)) \(noun)\(places.isEmpty ? "" : ", on \(places)").",
                // A thread that began before today has no start to sort on;
                // it sits where it last spoke.
                at: people.start == .distantFuture ? people.end : people.start,
                gutter: gutter(people)
            ))
        }
        var loaded = collaborationMessages
        let activeID = appModel.activeChatSessionId
        if !activeID.isEmpty {
            loaded[activeID] = appModel.chatMessages
        }
        if let collaboration = TodayCollaboration.row(messagesBySession: loaded, now: now) {
            rows.append(collaboration)
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
                var title = TodayWords.withoutIDs(TodayWords.line(item.title, limit: 90))
                var summary = TodayWords.withoutIDs(TodayWords.firstSentence(item.summary))
                // "Claude finished: shell-consult-open-items" and "Claude
                // delegation failed" are routing labels, and what sits under
                // them is a slug. A slug is not a sentence: the row says
                // whether the delegation came back, and nothing else.
                let routing = title.lowercased()
                var rowID = "inbox:\(item.id)"
                if routing.hasPrefix("claude delegation failed") {
                    title = "The connected agent didn't finish"
                    summary = ""
                    if let job = Self.claudeJobIdentity(item) { rowID = "claude:\(job):\(item.id)" }
                } else if routing.hasPrefix("claude finished") {
                    title = "The connected agent finished"
                    summary = ""
                    if let job = Self.claudeJobIdentity(item) { rowID = "claude:\(job):\(item.id)" }
                }
                guard !title.isEmpty || !summary.isEmpty else { return nil }
                return TodayRow(
                    id: rowID,
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

    /// The job a Claude routing note refers to: the referenced execution when
    /// the note carries one, else the slug its routing label names. A note with
    /// neither names no job we can identify, so it is never folded with
    /// another note and stays an attributed historical row of its own.
    private static func claudeJobIdentity(_ item: InboxItemRecord) -> String? {
        if let id = item.relatedWorkshopExecutionId, !id.isEmpty { return id }
        guard let colon = item.title.firstIndex(of: ":") else { return nil }
        let slug = item.title[item.title.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    private static let claudeJobRowPrefix = "claude:"

    private static func claudeJobKey(rowID: String) -> String {
        let parts = rowID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : rowID
    }

    /// Three rows for one stall is a log, not a day — so the notes of ONE job
    /// fold into one line. Only of one job: separate delegations folded
    /// together made an outage and a recovery out of two unrelated runs.
    ///
    /// These are filtered historical notifications. They record what a
    /// delegation reported and when the note was written; they are not a job
    /// record, so this says nothing in the present tense — no "still out",
    /// no "back by". Whether anyone is working right now is not in this data.
    private func foldClaudeRows(_ rows: [TodayRow]) -> [TodayRow] {
        let claude = rows.filter { $0.id.hasPrefix(Self.claudeJobRowPrefix) }
        guard !claude.isEmpty else { return rows }
        var order: [String] = []
        var byJob: [String: [TodayRow]] = [:]
        for row in claude {
            let job = Self.claudeJobKey(rowID: row.id)
            if byJob[job] == nil { order.append(job) }
            byJob[job, default: []].append(row)
        }
        var folded: [TodayRow] = []
        for job in order {
            let group = byJob[job] ?? []
            guard group.count >= 2, let first = group.first, let last = group.last else {
                folded += group
                continue
            }
            let stalls = group.filter { $0.title.contains("didn't") }.count
            let returns = group.count - stalls
            let title: String
            if stalls > 0 && returns > 0 {
                title = "The connected agent finished \(TodayWords.times(returns)), "
                    + "didn't finish \(TodayWords.times(stalls))"
            } else if stalls > 0 {
                title = "The connected agent didn't finish \(TodayWords.times(stalls))"
            } else {
                title = "The connected agent finished \(TodayWords.times(returns))"
            }
            folded.append(TodayRow(
                id: "claude-fold:\(job)",
                title: title,
                line: "",
                at: first.at,
                gutter: TodayWords.clockSpan(first.at, last.at)
            ))
        }
        return rows.filter { !$0.id.hasPrefix(Self.claudeJobRowPrefix) } + folded
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
        dreamUnavailable = diary == nil || (diary?.unreadableEntries ?? 0) > 0
            || (entry != nil && (markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        var loaded: [String: [ChatMessage]] = [:]
        // One read per transcript. The recollections the snapshot needs come
        // out of the same decoded rows rather than a second parse of the same
        // eight JSONL files.
        var recollections: [ChatSessionRecollection] = []
        for id in sessionIDs {
            if let transcript = try? await appModel.client.getChatTranscript(sessionId: id) {
                loaded[id] = transcript.messages
                recollections += transcript.recollections
            }
        }
        collaborationMessages = loaded
        // The same board read the Desk page takes, for the shared count.
        do {
            deskItems = try await SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot()).liveState().items
            deskUnreadable = false
        } catch {
            deskUnreadable = true
        }
        snapshot = await TodaySnapshot.load(
            sessionIDs: Array(sessionIDs),
            recollections: recollections,
            dreamMarkdown: markdown,
            dreamAt: dreamAt,
            dreamDate: entry?.date,
            now: Date()
        )
    }

    private func readDream(_ date: String) async -> Bool {
        guard let entry = await appModel.fetchDreamEntry(date: date),
              !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dreamUnavailable = true
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
                        onReadDream: onReadDream)
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
    let momentsLine: String?
    let onReadMoments: () -> Void
    let approvals: [ApprovalRequest]
    /// Desk items waiting on him; one row that opens the Desk.
    var deskCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow("Waiting for you")
            AliveGroupCard(waiting: true) {
                if let momentsLine {
                    HStack(alignment: .center, spacing: 12) {
                        AliveWaitingDot()
                        Text(TodayWords.bounded(momentsLine, limit: 80))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(NativeAgentShell.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: TodayMetrics.rowContentHeightSingle)
                        Spacer(minLength: 12)
                        Button(momentsLine.hasPrefix("One ") ? "Read it with me" : "Read them with me", action: onReadMoments)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .hazeTinted(.button)
                            .accessibilityIdentifier("today.waiting.read-moments")
                    }
                }

                ForEach(approvals) { approval in
                    TodayApprovalRow(approval: approval)
                }

                if deskCount > 0 {
                    HStack(alignment: .center, spacing: 12) {
                        AliveWaitingDot()
                        Text(deskCount == 1
                             ? "One thing on the Desk needs your answer."
                             : "\(DeskPageWords.spelled(deskCount)) things on the Desk need your answer.")
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
    }
}

/// Notes from earlier days that are not waiting on him: one group per source
/// and title, so the same failure twice is one row.
struct TodayEarlierNote: Identifiable {
    let id: String
    let title: String
    let isFailure: Bool
    var count: Int
    /// The newest in the group — its date, and the note a click opens.
    var at: Date
    var oldest: Date
    var newest: InboxItemRecord
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
    let approval: ApprovalRequest

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
        let stated = TodayWords.firstSentence(approval.reason ?? "")
        if !stated.isEmpty { return stated }
        // A card with no reason line carries the thing itself in its preview
        // (a REM lesson is the lesson; User, 2026-09-12: "I can't see the REM
        // lesson, what it is, to approve it"). Show her words, not just a title.
        return TodayWords.bounded(TodayWords.plain(approval.payloadPreview ?? ""), limit: 240)
    }

    private var shortReason: String { TodayWords.bounded(reason, limit: 90) }
    private var reasonFolds: Bool { shortReason != reason }
    private var canResolve: Bool { ApprovalPayloadPreviewPresentation.canResolve(approval) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                AliveWaitingDot()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.isEmpty ? "I'm asking first" : TodayWords.bounded(title, limit: 70))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            if !canResolve {
                troubleLine(ApprovalPayloadPreviewPresentation.unavailableText)
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
    @State private var isOpen = false
    @State private var readingDream = false
    @State private var dreamMissing = false
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
                            Image(systemName: "chevron.right")
                                .font(ShellType.captionSemibold)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .accessibilityHidden(true)
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
                .transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityAction(named: isOpen ? "Fold" : "Open") { toggle() }
        .accessibilityIdentifier("today.row")
    }

    private func toggle() {
        guard foldable else { return }
        withAnimation(NativeAgentMotion.respecting(
            NativeAgentMotion.quick, reduceMotion: reduceMotion
        )) { isOpen.toggle() }
    }
}
