import Foundation
import Observation
import Cognition
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MemoryV2
import Transcripts
import NotificationInbox
import ChatSessionWork
import DreamREMCycle
import ApprovalInbox
import Desk
import AuthoredCapabilities
import AppToolRuntime
import ToolExecution
import Senses
// Blueprint: | `WorkOverviewRead+Today.swift` | `TodayProjection` freezes checked sources and provenance, feeds the pure `today-readout.js` faces through L0's version/epoch cache, binds source IDs to native dates and note links, and publishes through `LatestRead`; waiting counts share a pure face too. `TodayDreamDigest` reads the latest dream through `DreamNight`; native input supplies its title, mood and timestamp, never diary Markdown for JS to parse. Narration, grouping, due words and ordering live in the part. Unbound rows are omitted individually with native reasons; other activity, Ahead, earlier notes and note links remain. Native unavailable evidence, localization and live clock gutters remain. Mac and quiet reads consume the same prepared rows |

/// One line of her day. Payload-free by construction: a title, one plain
/// sentence, and when it happened (or is due). `details` is non-empty only on
/// a row that FOLDS several things — the card then opens on click.
public struct TodayRow: Identifiable, Equatable, Sendable {
    public struct Span: Equatable, Sendable {
        public let start: Date?
        public let end: Date
        public init(start: Date?, end: Date) { self.start=start; self.end=end }
    }
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
    private let fixedGutter: String?
    private let liveSpan: Span?
    public var gutter: String? {
        if let span=liveSpan {
            let live=Date().timeIntervalSince(span.end)<10*60
            if let start=span.start { return live ? TodayWords.clock(start)+"–now" : TodayWords.clockSpan(start,span.end) }
            return live ? "now" : TodayWords.clock(span.end)
        }
        return fixedGutter
    }
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
        dreamDate: String? = nil,
        liveSpan: Span? = nil
    ) {
        self.id = id
        self.title = title
        self.line = line
        self.at = at
        self.isHorizon = isHorizon
        self.details = details
        self.fixedGutter = gutter
        self.liveSpan = liveSpan
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
    public static func clock(_ date: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The system's own interval: "5:40 – 5:45 AM" when both ends share a
    /// period, else "11:50 AM – 1:10 PM".
    public static func clockSpan(_ start: Date, _ end: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        guard clock(start, calendar: calendar) != clock(end, calendar: calendar), start < end else {
            return clock(start, calendar: calendar)
        }
        let style = Date.IntervalFormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        return (start..<end).formatted(style)
    }

    public static func weekday(_ date: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
    }

    /// "Today", "Tonight", "Tomorrow" or the weekday — from the real date and
    /// hour, so a 4:30 am dream is never called tonight's.
    public static func dayWord(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
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
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)) }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
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

/// Title + mood of the night's dream: the latest one, read through `DreamNight`
/// like every other reader of the diary.
public enum TodayDreamDigest {
    public static func parse(_ markdown: String) -> (title: String, mood: String)? {
        guard let dream = DreamNight(markdown).latest, let title = dream.title else { return nil }
        return (title, dream.mood ?? "")
    }
}

// MARK: - The snapshot her own lanes produce

/// The lanes assembled by the engine's Today projection. File-backed reads
/// run outside the main actor; views retain no second assembled day.
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
    public var projectionError: String?
    public var ahead: [TodayRow] = []

    public static let empty = TodaySnapshot()

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

    public static func waitingApprovals(_ approvals: [ApprovalRecord]) -> [ApprovalRecord] {
        approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
    }

    public static func waitingOnDesk(total: Int?, approvals: Int) -> Int {
        max(0, (total ?? 0) - approvals)
    }

    /// The same Desk/notes sentence in visible and quiet Today.
    public static func waitingDeskInput(count: Int, split: (items: Int, notes: Int)?) -> JSONValue {
        .object(["mode":.string("waiting"),"count":.int(Int64(count)),"countWord":.string(DeskPageWords.spelledLower(count)),
            "split":split.map { .object(["items":.int(Int64($0.items)),"notes":.int(Int64($0.notes)),
                "itemsWord":.string(DeskPageWords.spelledLower($0.items)),"notesWord":.string(DeskPageWords.spelledLower($0.notes))]) } ?? .null])
    }

    public static func waitingSplit(kinds: [WorkOverviewReference.Kind: Int]?, onDesk: Int) -> (items: Int, notes: Int)? {
        guard let kinds else { return nil }
        let items = kinds[.desk] ?? 0, notes = kinds[.inbox] ?? 0
        return items + notes == onDesk ? (items, notes) : nil
    }

    @MainActor
    public static func conversationSurfaces(_ sessions: [NativeAgentShared.ChatSession]) -> [String: String] {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        return Dictionary(sessions.filter {
            guard ($0.messageCount ?? 0) > 0,
                  let at = TodayWords.parseTimestamp($0.updatedAt ?? $0.createdAt),
                  calendar.isDate(at, inSameDayAs: now) else { return false }
            return !ChatShellConversationRow.isWorking($0) && !ChatShellConversationRow.isHerOwn($0)
        }
            .map { ($0.id, ChatShellConversationRow.surface(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    @MainActor
    public static func todaySessionIDs(_ engine: NativeAgentEngine) -> [String] {
        todaySessionIDs(engine.transcripts.sessions)
    }

    static func todaySessionIDs(_ sessions: [NativeAgentShared.ChatSession]) -> [String] {
        sessions
            .filter { $0.archived != true }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .prefix(WorkOverviewRead.sessionsScanned)
            .map(\.id)
    }

}

/// The assembled day for one engine. The window and semantic read render this
/// same publication; source invalidation and cognition belong to this owner.
private struct TodayDecision: Sendable {
    struct Row: Sendable {
        let id: String
        let title: String
        let line: String
        let sources: [String]
        let details: [String]
    }
    struct Earlier: Sendable {
        let title: String
        let sources: [String]
        let failure: Bool
        let count: Int
    }
    let did: [Row]
    let ahead: [Row]
    let earlier: [Earlier]
    let omissions: [String]

    init(face: PartFace) {
        var omissions = face.sections.filter { $0.id.hasPrefix("omitted:") }.map { section in
            let reason = section.rows.isEmpty ? "no source." : "missing facts: " + section.rows.map(\.id).joined(separator: ", ") + "."
            return "Today row \(section.id.dropFirst("omitted:".count)) omitted: " + reason
        }
        func rows(_ prefix: String) -> [Row] {
            face.sections.filter { $0.id.hasPrefix(prefix) }.map { section in
                let id=String(section.id.dropFirst(prefix.count))
                let details=face.sections.first { $0.id == "details:"+id }?.rows.map(\.title) ?? []
                return Row(id:id,title:section.title ?? "",line:section.rows.first?.title ?? "",
                    sources:section.rows.map(\.id),details:details)
            }
        }
        did=rows("did:"); ahead=rows("ahead:")
        var earlier: [Earlier] = []
        for section in face.sections where section.id.hasPrefix("earlier:") {
            for row in section.rows {
                let failure=row.id.hasPrefix("failure:")
                let newest=failure ? String(row.id.dropFirst("failure:".count)) : row.id
                if let oldest=row.detail, let value=row.value, let count=Int(value), count>0 {
                    earlier.append(Earlier(title:row.title,sources:newest == oldest ? [newest] : [newest,oldest],failure:failure,count:count))
                } else { omissions.append("Earlier note \(newest) omitted: no count or bound date range.") }
            }
        }
        self.earlier=earlier
        self.omissions=omissions
    }
}

private struct TodaySource: Sendable {
    struct Fact: Sendable {
        let at: Date
        var start: Date?
        var end: Date?
        var horizon = false
        var dreamDate: String?
        var note: InboxItemRecord?
    }
    var input: [String: JSONValue] = [:]
    var facts: [String: Fact] = [:]
    var memoryUnreadable = false
    var dreamUnavailable = false
    var unavailable: [String] = []

    @MainActor
    static func read(_ engine: NativeAgentEngine, activeSessionID: String) async -> TodaySource {
        var source = TodaySource()
        var characterSet = Set<String>()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        let sessions: [NativeAgentShared.ChatSession]
        var sessionState = "available"
        do {
            let path = engine.dataRoot.appendingPathComponent("chat/sessions.json")
            sessions = try await SwiftNativePersistenceCore().withFileLock(path) {
                try ChatSessionIndexFile.loadObjectRowsForMutation(at: path).map(NativeAgentShared.ChatSession.init(row:))
            }
            sessionState = sessions.isEmpty ? "empty" : "available"
        } catch {
            sessions = []
            sessionState = "unavailable"
            source.unavailable.append("Conversation source unavailable: " + error.localizedDescription)
        }
        let notesState: String
        if let error = engine.inbox.loadError {
            notesState = engine.inbox.items.isEmpty ? "unavailable" : "partial"
            source.unavailable.append("Notes source unavailable: " + error)
        } else if !engine.inbox.hasLoadedSnapshot {
            notesState = "unavailable"
            source.unavailable.append("Notes source has not been read.")
        } else { notesState = engine.inbox.items.isEmpty ? "empty" : "available" }
        source.input["sourceStates"] = .object(["conversations": .string(sessionState), "notes": .string(notesState)])
        var moments: [JSONValue] = []
        do {
            let kept = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: engine.dataRoot).listMemory(kind: MemoryMoments.kind)
            for record in kept {
                if let at = TodayWords.parseTimestamp(record.createdAt), today(at) {
                    let quote = TodayWords.plain(MemoryMoments.metadataString(record.extras, "quote") ?? "")
                    let body = quote.isEmpty ? TodayWords.plain(record.text) : quote
                    if !body.isEmpty {
                        let key = "moment:" + record.id
                        source.facts[key] = .init(at: at)
                        moments.append(.object(["key": .string(key), "at": .double(at.timeIntervalSince1970),
                            "quote": .string(TodayWords.bounded(body, limit: 200))]))
                    }
                } else if TodayWords.parseTimestamp(record.createdAt) == nil {
                    source.memoryUnreadable = true
                }
            }
            source.input["moments"] = .object(["state": .string(source.memoryUnreadable ? "partial" : "available"), "rows": .array(moments)])
        } catch {
            source.memoryUnreadable = true
            source.input["moments"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        do {
            let diary = try await engine.cognitionView.dreamDiary(limit: 1)
            if (diary.unreadableEntries ?? 0) > 0 { source.dreamUnavailable = true }
            if let entry = diary.entries.first {
                let markdown = entry.text
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source.dreamUnavailable = true }
                if let at = TodayWords.parseTimestamp(entry.modifiedAt), today(at) {
                    if let digest = TodayDreamDigest.parse(markdown) {
                        source.facts["dream"] = .init(at: at, dreamDate: entry.date)
                        source.input["dream"] = .object(["state": .string(source.dreamUnavailable ? "partial" : "available"),
                            "title": .string(digest.title), "mood": .string(digest.mood), "at": .double(at.timeIntervalSince1970)])
                    } else {
                        source.dreamUnavailable = true
                        source.unavailable.append("Dream title unavailable.")
                        source.input["dream"] = .object(["state": .string("unavailable"), "reason": .string("Dream title unavailable.")])
                    }
                } else if TodayWords.parseTimestamp(entry.modifiedAt) == nil {
                    source.dreamUnavailable = true
                    source.input["dream"] = .object(["state":.string("unavailable"),"reason":.string("Dream time unavailable.")])
                } else { source.input["dream"] = .object(["state": .string("empty")]) }
            } else { source.input["dream"] = .object(["state": .string("empty")]) }
        } catch {
            source.dreamUnavailable = true
            source.input["dream"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        let dreamEnabled = await engine.cognitionView.dreamEnabled()
        var next: Date?
        var scheduleUnavailable = false
        if dreamEnabled {
            switch await engine.desk.jobsFeed() {
            case .current(let jobs): next = jobs.filter { $0.kind == "dream" && $0.enabled }.compactMap { TodayWords.parseTimestamp($0.nextRunAt) }.min()
            case .partial(let jobs, let detail):
                next = jobs.filter { $0.kind == "dream" && $0.enabled }.compactMap { TodayWords.parseTimestamp($0.nextRunAt) }.min()
                source.unavailable.append(String(describing: detail))
                scheduleUnavailable = true
            case .unavailable(let detail):
                source.unavailable.append(String(describing: detail)); scheduleUnavailable = true
            case .sourceAbsent:
                source.unavailable.append("Dream schedule source absent."); scheduleUnavailable = true
            }
        }
        if let next { source.facts["nextDream"] = .init(at: next) }
        source.input["nextDream"] = .object(["state":.string(next != nil ? "available" : scheduleUnavailable ? "unavailable" : "empty"),"enabled":.bool(dreamEnabled),"at":next.map { .double($0.timeIntervalSince1970) } ?? .null])
        if let toward = await engine.cognitionView.towardRead() {
            source.facts["facing"] = .init(at: toward.dueAt, horizon: !today(toward.dueAt))
            let weekday=toward.dueAt.formatted(Date.FormatStyle(calendar:calendar,timeZone:calendar.timeZone).weekday(.wide))
            source.input["toward"] = .object(["state":.string("available"),"label": .string(TodayWords.line(toward.displayLabel)),
                "past":.bool(toward.dueAt <= now),"hour":.int(Int64(calendar.component(.hour,from:toward.dueAt))),
                "today":.bool(today(toward.dueAt)),"tomorrow":.bool(calendar.isDateInTomorrow(toward.dueAt)),
                "weekday":.string(weekday),"at":.double(toward.dueAt.timeIntervalSince1970)])
        } else { source.input["toward"] = .object(["state":.string(engine.cognition == nil ? "unavailable" : "empty")]) }
        var recollections: [JSONValue] = [], builders: [JSONValue] = []
        var loaded: [String: [ChatMessage]] = [:]
        for id in WorkOverviewRead.todaySessionIDs(sessions) {
            do {
                let transcript = try await engine.transcripts.loadTranscript(sessionId: id, cached: true)
                loaded[id] = transcript.messages
                for row in transcript.recollections {
                    if let at = row.createdAt, today(at) {
                        let key = "recollection:" + (row.rowId ?? row.sessionId)
                        source.facts[key] = .init(at: at)
                        recollections.append(.object(["key": .string(key), "at": .double(at.timeIntervalSince1970),
                            "text": .string(TodayWords.firstSentence(row.text))]))
                    }
                }
            } catch { source.unavailable.append("Transcript \(id): \(error.localizedDescription)") }
        }
        // The open thread's live persisted rows belong to the same canonical owner.
        if !activeSessionID.isEmpty { loaded[activeSessionID] = engine.transcripts.messages(for: activeSessionID) }
        let surfaces = WorkOverviewRead.conversationSurfaces(sessions)
        var conversations: [JSONValue] = []
        for session in sessions {
            if let end = TodayWords.parseTimestamp(session.updatedAt ?? session.createdAt), today(end),
               (session.messageCount ?? 0) > 0, let surface = surfaces[session.id] {
                let began = TodayWords.parseTimestamp(session.createdAt) ?? end
                var start: Date? = today(began) ? began : nil
                if session.id == activeSessionID {
                    let turns = (loaded[session.id] ?? []).compactMap { message -> (Date, Bool)? in
                        if let at = TodayWords.parseTimestamp(message.createdAt), today(at) {
                            let human = message.role == "user" && SessionMessageProvenance.make(role: message.role,
                                source: message.source, hasOrigin: message.metadata?.origin != nil,
                                surface: message.metadata?.origin?.surface, agent: message.metadata?.origin?.agent)?.isAutomated != true
                            return (at,human)
                        }
                        return nil
                    }
                    if let first = turns.first { start = turns.first(where: { $0.1 })?.0 ?? first.0 }
                }
                let key = "conversation:" + session.id
                source.facts[key] = .init(at: start ?? end, start: start, end: end)
                conversations.append(.object(["key": .string(key), "surface": .string(surface),"at":.double((start ?? end).timeIntervalSince1970),
                    "start":start.map { .double($0.timeIntervalSince1970) } ?? .null,"end":.double(end.timeIntervalSince1970)]))
            }
        }
        // Provenance is admission evidence, never inferred from titles or prose.
        for (sessionID, messages) in loaded {
            for message in messages {
                if (message.sessionId == nil || message.sessionId == sessionID), message.role == "user",
                   !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let origin = message.metadata?.origin,
                   let agent = origin.agent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   ["claude","codex"].contains(agent),
                   origin.surface?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == agent + "-bridge",
                   let at = TodayWords.parseTimestamp(message.createdAt), at <= now, today(at) {
                    let key = "builder:" + sessionID + ":" + message.id
                    source.facts[key] = .init(at: at)
                    builders.append(.object(["key": .string(key), "session": .string(sessionID), "agent": .string(agent),"at":.double(at.timeIntervalSince1970)]))
                }
            }
        }
        let notes = engine.inbox.items.filter { $0.isActivityPending && !$0.isSystemLane }.compactMap { item -> JSONValue? in
            if let at = TodayWords.parseTimestamp(item.created_at) {
                let key = "inbox:" + item.id
                source.facts[key] = .init(at: at, note: item)
                // Only the native owner's job identity is allowed to bind a fold.
                let slug = item.title.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                let job = item.relatedWorkshopExecutionId?.isEmpty == false ? item.relatedWorkshopExecutionId : slug
                return .object(["key": .string(key), "at": .double(at.timeIntervalSince1970), "today": .bool(today(at)),
                    "source": .string(item.source), "title": .string(TodayWords.withoutIDs(TodayWords.line(item.title,limit:90))),
                    "summary": .string(TodayWords.withoutIDs(TodayWords.firstSentence(item.summary))), "job": job.map(JSONValue.string) ?? .null])
            }
            source.unavailable.append("Note time unavailable: " + item.id)
            return nil
        }
        source.input["recollections"] = .array(recollections)
        source.input["conversations"] = .array(conversations.sorted { ($0.objectValue?["key"]?.stringValue ?? "") < ($1.objectValue?["key"]?.stringValue ?? "") })
        source.input["builders"] = .array(builders.sorted { ($0.objectValue?["key"]?.stringValue ?? "") < ($1.objectValue?["key"]?.stringValue ?? "") })
        source.input["notes"] = .array(notes)
        source.input["availability"] = .object(["state": .string(source.unavailable.isEmpty ? "available" : "partial"),
            "unavailable": .array(source.unavailable.map(JSONValue.string))])
        func collectCharacters(_ value: JSONValue) {
            switch value {
            case .string(let text):
                for version in [text,TodayWords.plain(text),text.uppercased()] {
                    for character in version {
                        let glyph=String(character)
                        if glyph.utf16.count > 1 { characterSet.insert(glyph) }
                    }
                }
            case .array(let rows): for row in rows { collectCharacters(row) }
            case .object(let fields): for field in fields.values { collectCharacters(field) }
            default: break
            }
        }
        for field in source.input.values { collectCharacters(field) }
        let clusters=characterSet.sorted { lhs,rhs in
            lhs.utf16.count != rhs.utf16.count ? lhs.utf16.count > rhs.utf16.count : lhs < rhs
        }
        source.input["clusters"] = .array(clusters.map(JSONValue.string))
        return source
    }

    func row(_ decision: TodayDecision.Row) throws -> TodayRow {
        let sources = try decision.sources.map { key -> Fact in
            if let fact = facts[key] { return fact }
            throw PartCallError(code: "unbound_source", message: "Today row names an unknown source: " + key)
        }
        if sources.isEmpty { throw PartCallError(code: "unbound_source", message: "Today row has no source.") }
        let first = sources.map(\.at).min()!, end = sources.map { $0.end ?? $0.at }.max()!
        var at = first, gutter: String?, span: TodayRow.Span?
        if decision.id == "talked" {
            let start = sources.compactMap(\.start).min()
            at = start ?? end
            span = .init(start:start,end:end)
        } else if decision.id == "kept" || decision.id == "worked" || decision.id.hasPrefix("claude-fold:") {
            gutter = TodayWords.clockSpan(first,end)
        }
        return TodayRow(id: decision.id, title: decision.title, line: decision.line, at: at,
            isHorizon: sources[0].horizon, details: decision.details, gutter: gutter, dreamDate: sources[0].dreamDate,liveSpan:span)
    }
}

@MainActor
@Observable
public final class TodayProjection {
    public private(set) var snapshot = TodaySnapshot.empty
    public private(set) var didRows: [TodayRow] = []
    public private(set) var earlierNotes: [TodayEarlierNote] = []
    public private(set) var noteItems: [String: InboxItemRecord] = [:]
    private var dayFaces: PartFaces?
    @ObservationIgnored private var dayInput: JSONValue?
    @ObservationIgnored private var dayEpoch: UInt64 = 0
    private var waitingFaces: PartFaces?
    @ObservationIgnored private var waitingInput: JSONValue?
    @ObservationIgnored private var waitingEpoch: UInt64 = 0

    public func waitingLine(count: Int, split: (items: Int, notes: Int)?) -> String {
        if waitingInput != WorkOverviewRead.waitingDeskInput(count:count,split:split) { return "Reading Today…" }
        if let snapshot=waitingFaces?.snapshots["today-readout"], snapshot.sourceEpoch == waitingEpoch { return waitingWords(snapshot) }
        return "Today readout unavailable."
    }

    private func waitingWords(_ snapshot: PartFaceSnapshot) -> String {
        if snapshot.status == .ready, let text=snapshot.face?.sections.first?.rows.first?.title { return text }
        return "Today "+snapshot.status.rawValue+": "+(snapshot.error?.message ?? snapshot.status.rawValue)
    }

    public func prepareWaiting(_ engine: NativeAgentEngine, count: Int, split: (items: Int, notes: Int)?) async -> String {
        let input=WorkOverviewRead.waitingDeskInput(count:count,split:split)
        if waitingInput != input { waitingInput=input; waitingEpoch += 1 }
        if waitingFaces == nil {
            let root=engine.dataRoot
            waitingFaces=PartFaces(dataRoot:root) { id,input,version in
                let host=AppToolExecutor.authoredProgramHost(dataRoot:root) { _,_ in nil }
                return await OwnedProgramInvocation.$host.withValue(host) {
                    await Parts(root:root).face(id:id,input:input,version:version)
                }
            }
        }
        return waitingWords(await waitingFaces!.sourceChanged(id:"today-readout",epoch:waitingEpoch,input:input))
    }
    public var dreamUnavailable = false
    private var readCount = 0
    public var isReading: Bool { readCount > 0 }
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private lazy var dayRead = LatestRead()

    public nonisolated init() {}

    deinit {
        sourceTask?.cancel()
    }

    public func start(engine: NativeAgentEngine,
               activeSessionID: @escaping @MainActor () -> String,
               refreshQueues: @escaping @MainActor () async -> Void,
               publishWorkStatus: @escaping @MainActor () async -> Void) {
        stop()
        let root = engine.dataRoot
        let transcripts = WorkOverviewRead.todaySessionIDs(engine).compactMap {
            NativeAgentChatSessionID.normalizedPathComponent($0)
                .map { root.appendingPathComponent("chat/messages/\($0).jsonl") }
        }
        sourceTask = Task { [weak self, weak engine] in
            await EventDeadlinePhysiology.refreshOnChanges(paths: [
                root.appendingPathComponent("workflows/approvals/requests.json"),
                root.appendingPathComponent("notifications/inbox.jsonl"),
                root.appendingPathComponent("memory/memory.sqlite"),
                root.appendingPathComponent("memory/memory.sqlite-wal"),
                root.appendingPathComponent("trust/policy.json"),
                root.appendingPathComponent("scheduler/jobs.json"),
                root.appendingPathComponent("dream_diary", isDirectory: true),
                root.appendingPathComponent("chat/sessions.json"),
                root.appendingPathComponent("chat/messages", isDirectory: true),
            ] + transcripts, notifications: [.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, AbilityStore.didChange]) {
                await refreshQueues()
                await publishWorkStatus()
                if let engine { await self?.refresh(engine, activeSessionID: activeSessionID()) }
            }
        }
    }

    public func stop() {
        sourceTask?.cancel()
        sourceTask = nil
    }

    public func refresh(_ engine: NativeAgentEngine, activeSessionID: String) async {
        readCount += 1
        defer { readCount -= 1 }
        await dayRead.read({
            let source = await TodaySource.read(engine, activeSessionID: activeSessionID)
            var snapshot = TodaySnapshot()
            snapshot.loaded = true
            snapshot.memoryUnreadable = source.memoryUnreadable
            do {
                let input = JSONValue.object(source.input)
                if dayInput != input { dayInput=input; dayEpoch += 1 }
                if dayFaces == nil {
                    let root=engine.dataRoot
                    dayFaces=PartFaces(dataRoot:root) { id,input,version in
                        let host=AppToolExecutor.authoredProgramHost(dataRoot:root) { _,_ in nil }
                        return await OwnedProgramInvocation.$host.withValue(host) {
                            await Parts(root:root).face(id:id,input:input,version:version)
                        }
                    }
                }
                let projected=await dayFaces!.sourceChanged(id:"today-readout",epoch:dayEpoch,input:input)
                if projected.status != .ready {
                    throw projected.error ?? PartCallError(code:projected.status.rawValue,message:"The Today projection is unavailable.")
                }
                if projected.face == nil { throw PartCallError(code:"bad_face",message:"The Today projection returned no face.") }
                let decision=TodayDecision(face:projected.face!)
                var unavailable = source.unavailable + decision.omissions
                func bindRows(_ rows: [TodayDecision.Row]) -> [TodayRow] {
                    rows.compactMap { row in
                        do { return try source.row(row) }
                        catch {
                            unavailable.append("Today row \(row.id) omitted: " + error.localizedDescription)
                            return nil
                        }
                    }
                }
                let did = bindRows(decision.did)
                let ahead = bindRows(decision.ahead)
                snapshot.ahead = ahead
                let byID = Dictionary((did + ahead).map { ($0.id,$0) }, uniquingKeysWith: { first, _ in first })
                snapshot.kept = byID["kept"]; snapshot.dream = byID["dream"]
                snapshot.facing = byID["facing"] ?? byID["facingDream"]
                snapshot.nextDream = byID["nextDream"]
                snapshot.recollection = did.first { $0.id.hasPrefix("recollection:") }
                let earlier = decision.earlier.compactMap { group -> TodayEarlierNote? in
                    do {
                        let notes = try group.sources.map { key -> (InboxItemRecord,Date) in
                            if let fact = source.facts[key], let note = fact.note { return (note,fact.at) }
                            throw PartCallError(code: "unbound_source", message: "Earlier note names an unknown source: " + key)
                        }.sorted { $0.1 > $1.1 }
                        if notes.isEmpty { throw PartCallError(code: "unbound_source", message: "Earlier note has no source.") }
                        return TodayEarlierNote(id: group.sources.joined(separator: "|"), title: group.title,
                            isFailure: group.failure, count: group.count, at: notes[0].1,
                            oldest: notes.last!.1, newest: notes[0].0)
                    } catch {
                        unavailable.append("Earlier note \(group.sources.joined(separator: "|")) omitted: " + error.localizedDescription)
                        return nil
                    }
                }
                var items: [String: InboxItemRecord] = [:]
                let boundIDs = Set(did.map(\.id))
                for row in decision.did where row.sources.count == 1 && boundIDs.contains(row.id) {
                    if let note = source.facts[row.sources[0]]?.note { items[row.id] = note }
                }
                snapshot.projectionError = unavailable.isEmpty ? nil : unavailable.joined(separator: "; ")
                return (snapshot,did,earlier,items,source.dreamUnavailable)
            } catch {
                snapshot.projectionError = "Today unavailable: " + error.localizedDescription
                return (snapshot,[],[],[:],source.dreamUnavailable)
            }
        }, publish: {
            (snapshot, didRows, earlierNotes, noteItems, dreamUnavailable) = $0
        })
    }

}
