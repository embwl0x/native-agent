import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MemoryV2
import Transcripts
import NotificationInbox
import ChatSessionWork
import ApprovalInbox
import Desk

/// One line of her day. Payload-free by construction: a title, one plain
/// sentence, and when it happened (or is due). `details` is non-empty only on
/// a row that FOLDS several things — the card then opens on click.
public struct TodayRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let line: String
    /// When it happened, or when a horizon falls due.
    public let at: Date
    /// A horizon sorts after everything that already happened and shows a
    /// weekday instead of a clock.
    public let isHorizon: Bool
    /// The things this row folds. Empty on a plain row.
    public let details: [String]
    /// A folded row spans a stretch of the day; the gutter shows the span.
    public let gutter: String?
    /// Only the diary key travels with the summary; the reader owns the body.
    public let dreamDate: String?

    public init(
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

public enum TodayWords {
    /// Counts are spelled, never rendered as numerals — this page shows her
    /// life, not a queue depth.
    public static func spelled(_ count: Int) -> String {
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
    public static func spelledLower(_ count: Int) -> String {
        spelled(count).lowercased()
    }

    /// THE STRIPPER. Every title and every line on this page goes through it.
    ///
    /// Sources write markdown — a diary entry is a heading, a distillation is
    /// bullets, a proposal reason carries `**bold**` and `[links](url)`. None
    /// of that is her voice, and a stray `#` or `**` on a card reads as a bug.
    /// Removes the markers, keeps the words, and collapses the whole thing to
    /// one line. Never truncates — `bounded` does that.
    public static func plain(_ raw: String) -> String {
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
    public static func bounded(_ text: String, limit: Int) -> String {
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
    public static func line(_ text: String, limit: Int = 180) -> String {
        bounded(plain(text), limit: limit)
    }

    /// The Mac's own short time ("4:30 AM" in a US locale), in the display
    /// zone: the one clock every User-facing time wears.
    public static func clock(_ date: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The system's own interval: "5:40 – 5:45 AM" when both ends share a
    /// period, else "11:50 AM – 1:10 PM".
    public static func clockSpan(_ start: Date, _ end: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
        guard clock(start, calendar: calendar) != clock(end, calendar: calendar), start < end else {
            return clock(start, calendar: calendar)
        }
        let style = Date.IntervalFormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        return (start..<end).formatted(style)
    }

    /// "once", "twice", "three times".
    public static func times(_ n: Int) -> String {
        switch n {
        case 1: return "once"
        case 2: return "twice"
        default: return spelledLower(n) + " times"
        }
    }

    public static func weekday(_ date: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
    }

    /// "Today", "Tonight", "Tomorrow" or the weekday — from the real date and
    /// hour, so a 4:30 am dream is never called tonight's.
    public static func dayWord(_ date: Date, now: Date = Date(), calendar: Calendar = DisplayTimeZone.calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 18 ? "Tonight" : "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
    }

    /// Raw ids out of a line: `conversation-cbd5dce3af1b903c`, UUIDs, long
    /// hex. What is left is tidied so no empty "()" or trailing colon remains.
    public static func withoutIDs(_ text: String) -> String {
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
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = DisplayTimeZone.calendar) -> String {
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)) }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
    }

    /// "Friday morning" · "this evening" · "still waiting". Plain words, no
    /// dates and no clock — the row's own gutter already carries the spine.
    public static func due(_ date: Date, now: Date, calendar: Calendar = DisplayTimeZone.calendar) -> String {
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
        return "\(date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))) \(part)"
    }

    /// The first sentence of a source's own prose, stripped and bounded.
    /// Never rewritten, only shortened.
    public static func firstSentence(_ text: String, limit: Int = 180) -> String {
        let stripped = plain(text)
        guard !stripped.isEmpty else { return "" }
        var sentence = stripped
        if let stop = stripped.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            sentence = String(stripped[stripped.startIndex...stop])
        }
        return bounded(sentence, limit: limit)
    }

    public static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// ISO-8601 with or without fractional seconds — the two shapes every
    /// store in this app writes.
    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }

}

// MARK: - The dream digest

/// Title + mood out of `dream_diary/<date>.md`, exactly as `DreamCycleRunner`
/// writes it: `**<title>**` then the summary then `_Mood: <mood>_`.
public enum TodayDreamDigest {
    public static func parse(_ markdown: String) -> (title: String, mood: String)? {
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

    public static func line(title: String, mood: String) -> String {
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
public struct TodaySnapshot: Sendable, Equatable {
    public var loaded = false
    /// One folded row: "I kept six moments today", opening onto the quotes.
    public var kept: TodayRow?
    public var dream: TodayRow?
    public var facing: TodayRow?
    /// The enabled dream scheduler's next due time.
    public var nextDream: TodayRow?
    public var recollection: TodayRow?
    /// A lane that could not be READ, as opposed to a lane that was read and
    /// was empty. Same distinction DeskLaneState.classify keeps for the Desk:
    /// a locked or corrupt memory store must never render as "nothing waiting,
    /// nothing kept". The page says one grey line; the reason is not shown,
    /// because a store error is machinery, not her day.
    public var memoryUnreadable = false

    public static let empty = TodaySnapshot()

    /// What she DID today — chronological.
    public var didToday: [TodayRow] {
        var out: [TodayRow] = []
        if let dream { out.append(dream) }
        if let kept { out.append(kept) }
        if let recollection { out.append(recollection) }
        return out
    }

    /// One pass over her own stores. Every reader fails to ABSENCE: a store
    /// that cannot be read leaves its row off the page rather than inventing
    /// one or claiming the day was empty.
    public static func load(
        cognitionView: CognitionViewFacade,
        recollections: [ChatSessionRecollection],
        dreamMarkdown: String?,
        dreamAt: Date?,
        dreamDate: String? = nil,
        dreamEnabled: Bool,
        nextDreamAt: Date?,
        now: Date
    ) async -> TodaySnapshot {
        var snapshot = TodaySnapshot()
        snapshot.loaded = true
        let calendar = DisplayTimeZone.calendar

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

            // Count and span cover the whole day; the fold shows only the
            // most recent moments.
            let shown = today.suffix(WorkOverviewRead.keptMomentsShown)
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
        if dreamEnabled, let next = nextDreamAt {
            snapshot.nextDream = TodayRow(id: "nextDream", title: "I'll dream", line: "", at: next)
        }

        // ── Something I'm facing ─────────────────────────────────────────
        if let toward = await cognitionView.towardRead() {
            let label = TodayWords.capitalizedFirst(TodayWords.line(toward.displayLabel))
            if label.lowercased().contains("dream") {
                if dreamEnabled, let nextDreamAt {
                    snapshot.facing = TodayRow(id: "facingDream", title: "I'll dream", line: "", at: nextDreamAt)
                }
            } else if !label.isEmpty {
                snapshot.facing = TodayRow(
                    id: "facing",
                    title: label,
                    line: TodayWords.due(toward.dueAt, now: now),
                    at: toward.dueAt,
                    isHorizon: !calendar.isDate(toward.dueAt, inSameDayAs: now)
                )
            }
        }

        // ── Conversation recollection ────────────────────────────────────
        var newest: ChatSessionRecollection?
        for row in recollections {
            guard let at = row.createdAt, calendar.isDate(at, inSameDayAs: now) else { continue }
            if let current = newest, let currentAt = current.createdAt, currentAt >= at { continue }
            newest = row
        }
        if let newest, let at = newest.createdAt {
            if !TodayWords.firstSentence(newest.text).isEmpty {
                snapshot.recollection = TodayRow(
                    id: "recollection:\(newest.rowId ?? newest.sessionId)",
                    title: "I wrote down what we talked about",
                    line: "A note to myself, so I remember it later.",
                    at: at
                )
            }
        }

        return snapshot
    }
}

/// Session titles and an open tab are not participation receipts. Only dated,
/// persisted ingress with matching builder provenance contributes to this row.
public enum TodayCollaboration {
    public static func row(messagesBySession: [String: [ChatMessage]], now: Date, parseTimestamp: (String) -> Date?) -> TodayRow? {
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
                      let at = parseTimestamp(message.createdAt),
                      at <= now, DisplayTimeZone.calendar.isDate(at, inSameDayAs: now) else { continue }
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

/// Notes from earlier days that are not waiting on him: one group per source
/// and title, so the same failure twice is one row.
public struct TodayEarlierNote: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let isFailure: Bool
    public var count: Int
    /// The newest in the group — its date, and the note a click opens.
    public var at: Date
    public var oldest: Date
    public var newest: InboxItemRecord
}

extension WorkOverviewRead {
    static let sessionsScanned = 8
    static let keptMomentsShown = 6
    static let noteRowsShown = 4
    private static let claudeJobRowPrefix = "claude:"

    public static func waitingApprovals(_ approvals: [ApprovalRecord]) -> [ApprovalRecord] {
        approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
    }

    public static func waitingOnDesk(total: Int?, approvals: Int) -> Int {
        max(0, (total ?? 0) - approvals)
    }

    public static func waitingSplit(kinds: [WorkOverviewReference.Kind: Int]?, onDesk: Int) -> (items: Int, notes: Int)? {
        guard let kinds else { return nil }
        let items = kinds[.desk] ?? 0, notes = kinds[.inbox] ?? 0
        return items + notes == onDesk ? (items, notes) : nil
    }

    public static func earlierNotes(_ inbox: [InboxItemRecord]) -> [TodayEarlierNote] {
        let now = Date()
        var groups: [String: TodayEarlierNote] = [:]
        for item in inbox where item.isActivityPending && !item.isSystemLane {
            guard let at = TodayWords.parseTimestamp(item.created_at),
                  !DisplayTimeZone.calendar.isDate(at, inSameDayAs: now) else { continue }
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

    public static func aheadRows(_ snapshot: TodaySnapshot) -> [TodayRow] {
        // One dream chip: the horizon's own due time when it names the dream.
        let dreamFacing = snapshot.facing?.id == "facingDream"
        return [snapshot.facing, dreamFacing ? nil : snapshot.nextDream]
            .compactMap { $0 }
            .sorted { $0.at < $1.at }
    }

    @MainActor
    public static func conversationSurfaces(_ sessions: [NativeAgentShared.ChatSession]) -> [String: String] {
        let now = Date()
        let calendar = DisplayTimeZone.calendar
        return Dictionary(sessions.filter {
            guard ($0.messageCount ?? 0) > 0,
                  let at = TodayWords.parseTimestamp($0.updatedAt ?? $0.createdAt),
                  calendar.isDate(at, inSameDayAs: now) else { return false }
            return !ChatShellConversationRow.isWorking($0) && !ChatShellConversationRow.isHerOwn($0)
        }
            .map { ($0.id, ChatShellConversationRow.surface(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    public static func didTodayRows(_ snapshot: TodaySnapshot, _ collaborationMessages: [String: [ChatMessage]], inbox: [InboxItemRecord], sessions: [NativeAgentShared.ChatSession], surfaces: [String: String], activeSessionID: String, messages: [ChatMessage], parseTimestamp: (String) -> Date?) -> [TodayRow] {
        (snapshot.didToday + noteRows(inbox, snapshot) + conversationRows(sessions, collaborationMessages, surfaces: surfaces, activeSessionID: activeSessionID, messages: messages, parseTimestamp: parseTimestamp)).sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.id < rhs.id
        }
    }

    private static func conversationRows(_ sessions: [NativeAgentShared.ChatSession], _ collaborationMessages: [String: [ChatMessage]], surfaces: [String: String], activeSessionID: String, messages: [ChatMessage], parseTimestamp: (String) -> Date?) -> [TodayRow] {
        let now = Date()
        let calendar = DisplayTimeZone.calendar
        struct Span { var count = 0; var start = Date.distantFuture; var end = Date.distantPast; var surfaces = Set<String>() }
        var people = Span()
        for session in sessions {
            guard let end = parseTimestamp(session.updatedAt ?? session.createdAt),
                  calendar.isDate(end, inSameDayAs: now),
                  (session.messageCount ?? 0) > 0 else { continue }
            let began = parseTimestamp(session.createdAt) ?? end
            var startedToday = calendar.isDate(began, inSameDayAs: now)
            var peopleStart = began
            // The open thread's turns are loaded: its day starts when someone
            // actually spoke today, not at midnight.
            let isOpenThread = session.id == activeSessionID
            if isOpenThread {
                let todays = messages.compactMap { message -> (Date, Bool)? in
                    guard let at = parseTimestamp(message.createdAt),
                          calendar.isDate(at, inSameDayAs: now) else { return nil }
                    let human = message.role == "user" && SessionMessageProvenance.make(
                        role: message.role, source: message.source, hasOrigin: message.metadata?.origin != nil,
                        surface: message.metadata?.origin?.surface, agent: message.metadata?.origin?.agent
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
            if let surface = surfaces[session.id] {
                people.count += 1
                if startedToday { people.start = min(people.start, peopleStart) }
                people.end = max(people.end, end)
                people.surfaces.insert(surface)
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
        let activeID = activeSessionID
        if !activeID.isEmpty {
            loaded[activeID] = messages
        }
        if let collaboration = TodayCollaboration.row(messagesBySession: loaded, now: now, parseTimestamp: parseTimestamp) {
            rows.append(collaboration)
        }
        return rows
    }

    private static func noteRows(_ inbox: [InboxItemRecord], _ snapshot: TodaySnapshot) -> [TodayRow] {
        foldClaudeRows(todayNotes(inbox, snapshot).map(\.row))
    }

    public static func todayNotes(_ inbox: [InboxItemRecord], _ snapshot: TodaySnapshot) -> [(row: TodayRow, item: InboxItemRecord)] {
        let now = Date()
        let calendar = DisplayTimeZone.calendar
        let haveDreamRow = snapshot.dream != nil
        return inbox
            .filter { $0.isActivityPending && !$0.isSystemLane }
            .compactMap { item -> (row: TodayRow, item: InboxItemRecord)? in
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
                return (TodayRow(
                    id: rowID,
                    title: title.isEmpty ? "I left you a note" : title,
                    line: summary,
                    at: at
                ), item)
            }
            .sorted { $0.row.at < $1.row.at }
            .suffix(WorkOverviewRead.noteRowsShown)
            .map { $0 }
    }

    private static func claudeJobIdentity(_ item: InboxItemRecord) -> String? {
        if let id = item.relatedWorkshopExecutionId, !id.isEmpty { return id }
        guard let colon = item.title.firstIndex(of: ":") else { return nil }
        let slug = item.title[item.title.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    private static func claudeJobKey(rowID: String) -> String {
        let parts = rowID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : rowID
    }

    private static func foldClaudeRows(_ rows: [TodayRow]) -> [TodayRow] {
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

    @MainActor
    public static func readLanes(_ engine: NativeAgentEngine, fetchDiary: @MainActor () async -> DreamDiary?, publishWorkStatus: @MainActor () async -> Void) async -> (TodaySnapshot, [String: [ChatMessage]], Bool) {
        let sessionIDs = engine.transcripts.sessions
            .filter { $0.archived != true }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .prefix(WorkOverviewRead.sessionsScanned)
            .map(\.id)
        let diary = await fetchDiary()
        let entry = diary?.entries.first
        let markdown = entry?.text
        let dreamAt = TodayWords.parseTimestamp(entry?.modifiedAt)
        let dreamEnabled = await engine.cognitionView.dreamEnabled()
        var nextDreamAt: Date?
        if dreamEnabled {
            switch await engine.desk.jobsFeed() {
            case .current(let jobs), .partial(let jobs, _):
                nextDreamAt = jobs.filter { $0.kind == "dream" && $0.enabled }
                    .compactMap { TodayWords.parseTimestamp($0.nextRunAt) }.min()
            case .sourceAbsent, .unavailable: break
            }
        }
        let dreamUnavailable = diary == nil || (diary?.unreadableEntries ?? 0) > 0
            || (entry != nil && (markdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        var loaded: [String: [ChatMessage]] = [:]
        // One read per transcript. The recollections the snapshot needs come
        // out of the same decoded rows rather than a second parse of the same
        // eight JSONL files.
        var recollections: [ChatSessionRecollection] = []
        for id in sessionIDs {
            if let transcript = try? await engine.transcripts.loadTranscript(sessionId: id, cached: true) {
                loaded[id] = transcript.messages
                recollections += transcript.recollections
            }
        }
        // The Desk's own overview, for the shared count.
        await publishWorkStatus()
        let snapshot = await TodaySnapshot.load(
            cognitionView: engine.cognitionView,
            recollections: recollections,
            dreamMarkdown: markdown,
            dreamAt: dreamAt,
            dreamDate: entry?.date,
            dreamEnabled: dreamEnabled,
            nextDreamAt: nextDreamAt,
            now: Date()
        )
        return (snapshot, loaded, dreamUnavailable)
    }
}
