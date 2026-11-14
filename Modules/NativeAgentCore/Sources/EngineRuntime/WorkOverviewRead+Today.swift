import Foundation
import Observation
import Experiences
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
import ChatToolRuntime
import Desk
import AuthoredCapabilities
import AppToolRuntime
import ToolExecution
import Senses
import AgentConversations
import TrustCenter
import AgentWorkspace
import TurnTrace
import TriggerScheduler
// Blueprint: | `WorkOverviewRead+Today.swift` | Source-specific Today readings and the off-main owner posting its finished `today-readout` face |

// MARK: - Plain-words formatting

public enum TodayWords {
    /// Spell counts so the page reads as lived experience rather than queue depth.
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

    public static func spelledLower(_ count: Int) -> String {
        spelled(count).lowercased()
    }

    /// Sources contain Markdown; show only words in a single line. Keep truncation in `bounded` so stripping preserves complete prose.
    public static func plain(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        text = unlinked(text)
        let lines = text.split(whereSeparator: \.isNewline).map { rawLine -> String in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            var wasHeading = false
            while let first = line.first, first == "#" || first == ">" {
                wasHeading = wasHeading || first == "#"
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            // Add a full stop when folding headings into running prose.
            if wasHeading, let last = line.last, !".!?:".contains(last) { line += "." }
            for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
                line.removeFirst(bullet.count)
            }
            // Preserve underscores because they often belong to identifiers; Markdown emphasis and escapes are not display words.
            line.removeAll { $0 == "*" || $0 == "`" || $0 == "\\" }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip link destinations but preserve bare brackets because they often carry actual words.
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

    /// Prefer nearby sentence or word boundaries; never split words or characters.
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

    /// Strip before bounding every displayed line.
    public static func line(_ text: String, limit: Int = 180) -> String {
        bounded(plain(text), limit: limit)
    }

    /// One pill's words: the prose before the first file path or machine id, bounded at a word, with an ellipsis where it was cut. Paths and ids
    /// that open the words are skipped; empty when the words hold nothing else.
    static func spoken(_ text: String, limit: Int) -> String {
        var kept: [Substring] = []
        var cut = false
        for word in plain(text).split(separator: " ") {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>\"'“”‘’.,;:!?"))
            // A handle is a word, an underscore, then a machine id (desk_3F2A…): the word in front does not make it prose.
            let handle = bare.range(of: "_[0-9A-Fa-f-]{8,}", options: .regularExpression) != nil
            if isPath(bare) || handle || (bare.contains(where: \.isHexDigit) && withoutIDs(bare).isEmpty) {
                if kept.isEmpty { continue }
                cut = true
                break
            }
            kept.append(word)
        }
        var head = kept.joined(separator: " ")
        while let last = head.last, " :;,([{\"'“‘–—-".contains(last) { head.removeLast() }
        let short = bounded(head, limit: limit)
        return cut && short == head && !head.isEmpty ? head + "…" : short
    }

    /// A file path or URL: rooted (`/`, `~/`, and `./` once its dots are trimmed), a scheme's `//`, a second slash, or a slash before a file extension.
    private static func isPath(_ word: String) -> Bool {
        let slashes = word.filter { $0 == "/" }.count
        guard slashes > 0, word.count > 1 else { return false }
        if word.hasPrefix("/") || word.hasPrefix("~/") || slashes > 1 { return true }
        guard let name = word.split(separator: "/").last, let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Use the system’s localized short time and the shared display zone for every user-facing clock.
    public static func clock(_ date: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Name dates beyond the adjacent week so distant runs cannot look like this week’s weekday.
    public static func weekday(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        guard abs(date.timeIntervalSince(now)) >= 6.5 * 86_400 else { return date.formatted(style.weekday(.abbreviated)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year())
    }

    /// Remove machine ids and tidy leftover punctuation so routing cannot leak into prose.
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

    /// Show how long an open note has waited; never label earlier-day obligations as today.
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)) }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated))
    }

    /// Shorten source prose without rewriting it.
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

    /// Accept both ISO-8601 timestamp shapes current stores write.
    public static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeTimestampFormat.parseISO8601FractionalFirst(text)
    }

}

// MARK: - The dream digest

/// Share `DreamNight` diary selection with every reader.
public enum TodayDreamDigest {
    public static func parse(_ markdown: String) -> (title: String, mood: String)? {
        guard let dream = DreamNight(markdown).latest, let title = dream.title else { return nil }
        return (title, dream.mood ?? "")
    }
}

extension WorkOverviewRead {
    static let sessionsScanned = 8

    public static func waitingApprovals(_ approvals: [ApprovalRecord]) -> [ApprovalRecord] {
        approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }
    }

    public static func waitingOnDesk(total: Int?, approvals: Int) -> Int {
        max(0, (total ?? 0) - approvals)
    }

    public static func waitingDeskInput(count: Int, split: (items: Int, notes: Int)?) -> JSONValue {
        .object(["mode": .string("waiting"), "count": .int(Int64(count)), "countWord": .string(DeskPageWords.spelledLower(count)),
            "split": split.map { .object(["items": .int(Int64($0.items)), "notes": .int(Int64($0.notes)),
                "itemsWord": .string(DeskPageWords.spelledLower($0.items)), "notesWord": .string(DeskPageWords.spelledLower($0.notes))]) } ?? .null])
    }

    public static func waitingSplit(kinds: [WorkOverviewReference.Kind: Int]?, onDesk: Int) -> (items: Int, notes: Int)? {
        guard let kinds else { return nil }
        let items = kinds[.desk] ?? 0, notes = kinds[.inbox] ?? 0
        return items + notes == onDesk ? (items, notes) : nil
    }

    static func conversationSurfaces(_ sessions: [NativeAgentShared.ChatSession],
                                     openingLines: [String: ChatShellOpeningLine.OpeningLine]) -> [String: String] {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        return Dictionary(sessions.filter {
            guard ($0.messageCount ?? 0) > 0,
                  let at = TodayWords.parseTimestamp($0.updatedAt ?? $0.createdAt),
                  calendar.isDate(at, inSameDayAs: now) else { return false }
            return !ChatShellConversationRow.isWorking($0) && !ChatShellConversationRow.isAgentOwn($0, reading: openingLines)
        }
            .map { ($0.id, ChatShellConversationRow.surface(for: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    static func todaySessionIDs(_ sessions: [NativeAgentShared.ChatSession]) -> [String] {
        sessions
            .filter { $0.archived != true }
            .sorted { ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt) }
            .prefix(WorkOverviewRead.sessionsScanned)
            .map(\.id)
    }

}

private enum TodayFeed: String, CaseIterable, Hashable, Sendable {
    case clock, approvals, notes, waiting, trials, thinking, moments, dream, schedule, toward, intentions, conversations
}

private enum TodayChange: Hashable, Sendable {
    case all
    case feed(TodayFeed)
    case index
    case contacts
    case transcript(String)
}

/// A source's finished facts and destinations; a failed source carries its own gap beside its healthy siblings.
private struct TodaySource: Sendable, Equatable {
    var input: [String: JSONValue] = [:]
    /// What each of the face's rows may lead to, by the row's key.
    var keys: [String: JSONValue] = [:]
    /// The person's decisions waiting, drawn by the stem beside the face.
    var levers: [PartFace.Row] = []
    /// The night's trials, the same section Home draws (`TrialLevers`): the person's Set aside wherever the person is.
    var trials: PartFace.Section?
    var owed = false
    var approvalCount: Int?
    var waitingCount: Int?
    var waitingKinds: [WorkOverviewReference.Kind: Int]?
    var phoneWaiting = false
    var phoneKnown = false
    var unavailable: [String] = []
    /// The earliest instant at which these finished time-dependent facts must be read again.
    var deadline: Date?

    static func approvals(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        do {
            let rows = try await SwiftNativeApprovalInbox(root: engine.dataRoot).list(filter: .all)
            let approvals = WorkOverviewRead.waitingApprovals(rows)
            source.approvalCount = approvals.count
            source.levers = approvals.map { approval in
                let matter = approval.matter
                return PartFace.Row(id: "approval:" + approval.id, title: matter.title,
                    detail: TodayWords.line(matter.summary), tone: .attention, open: "approval:" + approval.id)
            }
            source.owed = !approvals.isEmpty
        } catch {
            source.unavailable.append("Approvals source unavailable: " + error.localizedDescription)
            source.owed = true
        }
        return source
    }

    static func notes(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        do {
            let forPerson = ForPerson.at(engine.dataRoot)
            let items = try await forPerson.inbox()
            // The agent's own decisions fold by their owner's kind and say their owner's count; read after the inbox, this reading holds its rows.
            var decided: [String: (kind: String, count: Int?)] = [:]
            for matter in try await forPerson.matters() {
                guard let kind = BodyDecidedRow.kind(of: matter) else { continue }
                let count = matter.face?.row?.value.flatMap { Int($0) }
                decided[matter.id] = (kind: kind, count: count.flatMap { $0 > 0 ? $0 : nil })
            }
            source.input["sourceStates"] = .object(["notes": .string(items.isEmpty ? "empty" : "available")])
            let asks = items.filter { $0.requiresOwnerInput && !$0.hasLinkedApproval }.sorted { $0.created_at > $1.created_at }
            let waiting = asks.map { item -> JSONValue in
                source.keys["card:" + item.id] = .object(["open": .string("card:" + item.id)])
                return .object(["id": .string("card:" + item.id), "title": .string(item.title), "detail": .string(TodayWords.line(item.summary))])
            }
            let notes = items.filter { $0.isActivityPending && !$0.isSystemLane }.compactMap { item -> JSONValue? in
                if let at = TodayWords.parseTimestamp(item.created_at) {
                    let key = "inbox:" + item.id
                    // Only native owner job identity may bind a folded group.
                    let job = item.relatedDelegationID.flatMap { $0.isEmpty ? nil : $0 }
                    let decision = decided[item.id]
                    if decision != nil, decision?.count == nil { source.unavailable.append("Decision count unreadable: " + item.id) }
                    source.keys[key] = .object(["open": .string("card:" + item.id)])
                    return .object(["key": .string(key), "at": .double(at.timeIntervalSince1970), "today": .bool(today(at)),
                        "source": .string(item.source), "title": .string(TodayWords.withoutIDs(TodayWords.line(item.title,limit:90))),
                        "summary": .string(TodayWords.withoutIDs(TodayWords.firstSentence(item.summary))), "job": job.map(JSONValue.string) ?? .null,
                        "kind": decision.map { JSONValue.string($0.kind) } ?? .null,
                        "decisions": decision?.count.map { JSONValue.int(Int64($0)) } ?? .null])
                }
                source.unavailable.append("Note time unavailable: " + item.id)
                return nil
            }
            source.input["waitingRows"] = .array(waiting)
            source.input["notes"] = .array(notes)
            source.owed = !waiting.isEmpty
        } catch {
            source.input["sourceStates"] = .object(["notes": .string("unavailable")])
            source.input["waitingRows"] = .array([])
            source.input["notes"] = .array([])
            source.unavailable.append("Notes source unavailable: " + error.localizedDescription)
            source.owed = true
        }
        return source
    }

    static func waiting(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let state = await MainActor.run {
            (standing: engine.sync.standing, waitingCount: engine.desk.ownerWaitingCount, waitingKinds: engine.desk.ownerWaitingKinds)
        }
        source.waitingCount = state.waitingCount
        source.waitingKinds = state.waitingKinds
        source.phoneKnown = state.standing != nil
        if let phone = state.standing?.waitingLine {
            source.levers = [PartFace.Row(id: "phone", title: phone, tone: .attention, open: "page:pairing")]
            source.phoneWaiting = true
        }
        source.owed = source.phoneWaiting
        return source
    }

    static func trials(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let name = await engine.persona.displayName
        let read = Result { try TrialLevers.read(dataRoot: engine.dataRoot) }
        source.trials = TrialLevers.section(read, agent: name.isEmpty ? "The agent" : String(name.prefix(40)), now: Date())
        return source
    }

    static func thinking(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let now = Date()
        do {
            let thinking = try await TurnTraceThinkingReader.shared.read(dataRoot: engine.dataRoot, now: now)
            func counts(_ value: TurnTraceThinkingReader.Counts) -> JSONValue {
                .object(["calls": .int(Int64(value.calls)), "turns": .int(Int64(value.turns))])
            }
            // Counts describe a day/week, not an event at the moment this packet was read.
            source.input["thinking"] = .object(["state": .string("available"),
                "today": counts(thinking.today), "week": counts(thinking.week)])
        } catch {
            source.unavailable.append("Thinking source unavailable: " + error.localizedDescription)
            source.input["thinking"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        return source
    }

    static func moments(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        var moments: [JSONValue] = [], unreadable = false
        do {
            let kept = try await engine.memory.listMemory(kind: MemoryMoments.kind)
            for record in kept {
                if let at = TodayWords.parseTimestamp(record.createdAt), today(at) {
                    let quote = TodayWords.plain(record.extras?.objectValue?["quote"]?.stringValue ?? "")
                    let body = quote.isEmpty ? TodayWords.plain(record.text) : quote
                    if !body.isEmpty {
                        let key = "moment:" + record.id
                        moments.append(.object(["key": .string(key), "at": .double(at.timeIntervalSince1970),
                            "quote": .string(TodayWords.bounded(body, limit: 200))]))
                    }
                } else if TodayWords.parseTimestamp(record.createdAt) == nil {
                    unreadable = true
                }
            }
            source.input["moments"] = .object(["state": .string(unreadable ? "partial" : "available"), "rows": .array(moments)])
        } catch {
            source.input["moments"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        return source
    }

    static func dream(_ engine: NativeAgentEngine) async -> Self {
        var source = Self(), unavailable = false
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        do {
            let enabled = try await engine.cognitionView.dreamEnabled()
            let diary = try await engine.cognitionView.readDreamDiary(limit: 1, enabled: enabled)
            if (diary.unreadableEntries ?? 0) > 0 {
                unavailable = true
                source.unavailable.append("Dream diary has unreadable entries.")
            }
            if let entry = diary.entries.first {
                let markdown = entry.text
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unavailable = true
                    source.unavailable.append("Dream entry is empty.")
                }
                if let at = TodayWords.parseTimestamp(entry.modifiedAt), today(at) {
                    if let digest = TodayDreamDigest.parse(markdown) {
                        source.input["dream"] = .object(["state": .string(unavailable ? "partial" : "available"),
                            "title": .string(digest.title), "mood": .string(digest.mood), "at": .double(at.timeIntervalSince1970)])
                        source.keys["dream"] = .object(["open": .string("dream:" + entry.date)])
                    } else {
                        unavailable = true
                        source.unavailable.append("Dream title unavailable.")
                        source.input["dream"] = .object(["state": .string("unavailable"), "reason": .string("Dream title unavailable.")])
                    }
                } else if TodayWords.parseTimestamp(entry.modifiedAt) == nil {
                    unavailable = true
                    source.input["dream"] = .object(["state":.string("unavailable"),"reason":.string("Dream time unavailable.")])
                } else { source.input["dream"] = .object(["state": .string("empty")]) }
            } else { source.input["dream"] = .object(["state": .string("empty")]) }
        } catch {
            source.input["dream"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        return source
    }

    static func schedule(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let reading = await engine.nextNightReading()
        source.input["nextDream"] = .object(reading)
        if reading["state"] == .string("unavailable"), let reason = reading["reason"]?.stringValue {
            source.unavailable.append(reason)
        }
        return source
    }

    static func toward(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        if let toward = await engine.cognitionView.towardRead() {
            let weekday=toward.dueAt.formatted(Date.FormatStyle(calendar:calendar,timeZone:calendar.timeZone).weekday(.wide))
            source.input["toward"] = .object(["state":.string("available"),"label": .string(TodayWords.line(toward.displayLabel)),
                "past":.bool(toward.dueAt <= now),"hour":.int(Int64(calendar.component(.hour,from:toward.dueAt))),
                "today":.bool(today(toward.dueAt)),"tomorrow":.bool(calendar.isDateInTomorrow(toward.dueAt)),
                "weekday":.string(weekday),"at":.double(toward.dueAt.timeIntervalSince1970)])
        } else { source.input["toward"] = .object(["state":.string(engine.cognition == nil ? "unavailable" : "empty")]) }
        return source
    }

    static func intentions(_ engine: NativeAgentEngine) async -> Self {
        var source = Self()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        do {
            let state = try await engine.desk.store.liveState()
            let horizon = now.addingTimeInterval(7 * 86_400)
            let intentions = MyQueue.entries(state).compactMap { entry -> JSONValue? in
                guard entry.step.status != "stopped", !MyQueue.isOver(entry, at: now) else { return nil }
                let next: Date?
                guard let condition = MyQueue.when(entry) else { return nil }
                switch condition {
                case .at(let at): next = at
                case .every: next = IntentionClock.next(entry.step, after: now)
                default: next = nil
                }
                guard let next, next >= now, next <= horizon,
                      MyQueue.until(entry).endsAt.map({ next < $0 }) ?? true else { return nil }
                source.deadline = min(source.deadline ?? next, next)
                let key = "intention:" + entry.item.handle
                // The pill carries its first words; the face keeps every word as the row's detail.
                return .object(["key": .string(key), "at": .double(next.timeIntervalSince1970),
                    "time": .string(shown(next, now: now, calendar: calendar)), "words": .string(entry.step.words),
                    "title": .string(TodayWords.spoken(entry.step.words, limit: 60))])
            }
            source.input["intentions"] = .object(["state": .string("available"), "rows": .array(intentions)])
        } catch {
            source.unavailable.append("Intentions source unavailable: " + error.localizedDescription)
            source.input["intentions"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        return source
    }

    /// An intention's next time: the clock alone today, else its day and clock.
    private static func shown(_ date: Date, now: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "'at' HH:mm" : "EEE MMM d 'at' HH:mm"
        return format.string(from: date)
    }

}

/// Conversation evidence is prepared once per changed transcript; contact changes only rename the retained evidence.
private struct TodayConversations: Sendable {
    private struct Builder: Sendable {
        let key: String
        let agent: String
        let peer: String?
        let at: Date
    }
    private struct Transcript: Sendable {
        var first: Date?
        var human: Date?
        var builders: [Builder] = []
        var issue: String?
    }
    private var sessions: [NativeAgentShared.ChatSession] = []
    private var openings: [String: ChatShellOpeningLine.OpeningLine] = [:]
    private var indexIssue: String?
    private var names: [String: String]?
    private var namesIssue: String?
    private var transcripts: [String: Transcript] = [:]

    var watchedSessions: [String] { WorkOverviewRead.todaySessionIDs(sessions) }

    mutating func read(_ changes: Set<TodayChange>, engine: NativeAgentEngine,
                       arm: @Sendable ([String]) async -> Void) async throws -> TodaySource {
        let all = changes.contains(.all)
        var changed = Set(changes.compactMap { change -> String? in
            if case .transcript(let id) = change { return id }
            return nil
        })
        if all { transcripts.removeAll() }
        if all || changes.contains(.index) {
            do {
                let path = engine.dataRoot.appendingPathComponent("chat/sessions.json")
                let current = try await SwiftNativePersistenceCore.withFileLock(path) {
                    try ChatSessionIndexFile.loadObjectRowsForMutation(at: path).map(NativeAgentShared.ChatSession.init(row:))
                }
                let previous = Dictionary(sessions.map { ($0.id, ChatShellOpeningLine.revision(for: $0)) },
                                          uniquingKeysWith: { first, _ in first })
                for row in current where previous[row.id] != ChatShellOpeningLine.revision(for: row) { changed.insert(row.id) }
                sessions = current
                openings = await engine.transcripts.openingLines.reading
                indexIssue = nil
                let selected = Set(watchedSessions)
                transcripts = transcripts.filter { selected.contains($0.key) }
            } catch is CancellationError { throw CancellationError() }
            catch { indexIssue = "Conversation source unavailable: " + error.localizedDescription }
        }
        if all || changes.contains(.contacts) {
            do {
                names = Dictionary(try AgentPeerStore(dataRoot: engine.dataRoot).list().map { ($0.id, $0.name) },
                                   uniquingKeysWith: { first, _ in first })
                namesIssue = nil
            } catch { namesIssue = "Collaboration names unavailable: " + error.localizedDescription }
        }
        if all || changes.contains(.index) { await arm(watchedSessions) }
        for id in watchedSessions where changed.contains(id) || transcripts[id] == nil {
            try Task.checkCancellation()
            guard NativeAgentChatSessionID.normalizedPathComponent(id) == id else {
                transcripts[id] = Transcript(issue: "Transcript \(id): invalid conversation identity.")
                continue
            }
            do {
                let began = ContinuousClock.now
                let reading = try await engine.transcripts.readTranscript(safeSessionId: id, cached: true)
                transcripts[id] = Self.evidence(reading.messages, session: id)
                ModuleLog.app("[today-source] feed=transcript duration=\(began.duration(to: .now))", level: .debug)
            } catch is CancellationError { throw CancellationError() }
            catch {
                var retained = transcripts[id] ?? Transcript()
                retained.issue = "Transcript \(id): " + error.localizedDescription
                transcripts[id] = retained
            }
        }
        return source()
    }

    private static func evidence(_ messages: [ChatMessage], session: String) -> Transcript {
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        var result = Transcript()
        for message in messages {
            guard message.sessionId == nil || message.sessionId == session,
                  let at = TodayWords.parseTimestamp(message.createdAt), at <= now, calendar.isDate(at, inSameDayAs: now) else { continue }
            if result.first == nil { result.first = at }
            let automated = SessionMessageProvenance.make(role: message.role, source: message.source,
                hasEnvelope: message.metadata?.envelope != nil, surface: message.metadata?.envelope?.surface,
                agent: message.metadata?.envelope?.agent)?.isAutomated == true
            if result.human == nil, message.role == "user", !automated { result.human = at }
            guard message.role == "user", !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let origin = message.metadata?.origin, let surface = origin.surface, PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                  let agent = origin.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty else { continue }
            let sourced = Set(([agent] + (origin.peerSources ?? [])).filter { $0.hasPrefix("peer:") })
            let peer = message.metadata?.envelope?.verifiedUserId
                ?? (sourced.count == 1 ? sourced.first.map { String($0.dropFirst(5)) } : nil)
            result.builders.append(Builder(key: "builder:" + session + ":" + message.id, agent: agent, peer: peer, at: at))
        }
        return result
    }

    private func source() -> TodaySource {
        var source = TodaySource()
        if let indexIssue { source.unavailable.append(indexIssue) }
        if let namesIssue { source.unavailable.append(namesIssue) }
        source.input["sourceStates"] = .object([
            "conversations": .string(indexIssue != nil ? "unavailable" : sessions.isEmpty ? "empty" : "available")
        ])
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        let surfaces = WorkOverviewRead.conversationSurfaces(sessions, openingLines: openings)
        var conversations: [JSONValue] = [], builders: [JSONValue] = []
        for session in sessions {
            if let issue = openings[session.id]?.issue { source.unavailable.append("Conversation \(session.id): " + issue) }
            if let end = TodayWords.parseTimestamp(session.updatedAt ?? session.createdAt), calendar.isDate(end, inSameDayAs: now),
               (session.messageCount ?? 0) > 0, let surface = surfaces[session.id] {
                let began = TodayWords.parseTimestamp(session.createdAt) ?? end
                let reading = transcripts[session.id]
                let start = reading?.human ?? reading?.first ?? (calendar.isDate(began, inSameDayAs: now) ? began : nil)
                let key = "conversation:" + session.id
                source.keys[key] = .object(["open": .string("chat:" + session.id)])
                conversations.append(.object(["key": .string(key), "surface": .string(surface),
                    "at": .double((start ?? end).timeIntervalSince1970),
                    "start": start.map { .double($0.timeIntervalSince1970) } ?? .null, "end": .double(end.timeIntervalSince1970)]))
            }
        }
        for (id, reading) in transcripts.sorted(by: { $0.key < $1.key }) {
            if let issue = reading.issue { source.unavailable.append(issue) }
            guard namesIssue == nil, let names else { continue }
            for builder in reading.builders {
                let display = builder.peer.flatMap { names[$0] }
                    ?? (builder.peer == nil && builder.agent != "agent" ? TodayWords.capitalizedFirst(builder.agent) : "another agent")
                source.keys[builder.key] = .object(["open": .string("chat:" + id)])
                builders.append(.object(["key": .string(builder.key), "session": .string(id),
                    "agent": .string(TodayWords.line(display, limit: 80)), "at": .double(builder.at.timeIntervalSince1970)]))
            }
        }
        func ordered(_ rows: [JSONValue]) -> JSONValue {
            .array(rows.sorted { ($0.objectValue?["key"]?.stringValue ?? "") < ($1.objectValue?["key"]?.stringValue ?? "") })
        }
        source.input["conversations"] = ordered(conversations)
        source.input["builders"] = ordered(builders)
        return source
    }
}

/// Today lives with its sources; doors only draw the last face it posted.
public actor TodayReadout {
    private weak var engine: NativeAgentEngine?
    private var sources: [TodayFeed: TodaySource] = [:]
    private var conversations = TodayConversations()
    private var pending: Set<TodayChange> = []
    private var reading: Task<Void, Never>?
    private struct Watch: Sendable {
        let paths: Set<URL>
        let task: Task<Void, Never>
    }
    private var watches: [TodayChange: Watch] = [:]
    private var observing = false
    private var tokens: [ObservationNotifications] = []
    private var inboxTask: Task<Void, Never>?
    private var cognitionTask: Task<Void, Never>?
    private var personaTask: Task<Void, Never>?
    private var intentionsDeadline: Task<Void, Never>?

    public init() {}

    deinit {
        reading?.cancel()
        watches.values.forEach { $0.task.cancel() }
        tokens.forEach { $0.cancel() }
        inboxTask?.cancel()
        cognitionTask?.cancel()
        personaTask?.cancel()
        intentionsDeadline?.cancel()
    }

    public func start(engine: NativeAgentEngine) async {
        guard self.engine == nil else { return }
        self.engine = engine
        pending.insert(.all)
        let root = engine.dataRoot
        let changes = await ForPerson.at(root).changes()
        inboxTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.changed(.feed(.notes))
            }
        }
        cognitionTask = Task { [weak self, cognitionView = engine.cognitionView] in
            for await _ in await cognitionView.changes() {
                guard !Task.isCancelled else { return }
                await self?.changed(.feed(.toward))
            }
        }
        personaTask = Task { @MainActor [weak self, persona = engine.persona] in
            let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { changes.continuation.finish() }
            var previous: String?
            var iterator = changes.stream.makeAsyncIterator()
            while !Task.isCancelled {
                // Arm the next publication before yielding; unrelated profile changes only rearm the name observation.
                let name = withObservationTracking { persona.displayName } onChange: { changes.continuation.yield(()) }
                if previous != name {
                    previous = name
                    await self?.changed(.feed(.trials))
                }
                guard await iterator.next() != nil else { return }
            }
        }
        let notificationChanges: [Notification.Name: TodayChange] = [
            .NSSystemTimeZoneDidChange: .all, .NSCalendarDayChanged: .all, .NSSystemClockDidChange: .all,
            .turnTraceTerminalPersisted: .feed(.thinking),
            TranscriptsFacade.sessionIndexDidChange: .index,
            ConnectorFaceChange.phone: .feed(.waiting)
        ]
        // Notifications carry invalidations only; non-Sendable notification objects never enter the actor.
        tokens = notificationChanges.map { name, change in
            ObservationNotifications(names: [name]) { [weak self] in Task { await self?.changed(change) } }
        }
        await rewatch([])
        observing = true
        changed(.all)
    }

    /// Owner publications that have no distinct persisted path (Desk's waiting counts) invalidate their dependent facts.
    func waitingChanged() { changed(.feed(.waiting)) }

    private func changed(_ change: TodayChange) {
        pending.insert(change)
        guard observing, let engine, reading == nil else { return }
        reading = Task { [weak self] in
            guard let self else { return }
            await self.drain(engine)
        }
    }

    /// Exact file identities, selected diary entries and symlink chains are held by the shared source observation.
    private func rewatch(_ sessions: [String]) async {
        guard let engine else { return }
        let root = engine.dataRoot
        let fields: [(TodayChange, [String])] = [
            (.feed(.approvals), ["workflows/approvals/requests.json"]),
            (.feed(.trials), ["abilities/state.json"]),
            (.feed(.moments), ["memory/memory.sqlite", "memory/memory.sqlite-wal"]),
            (.feed(.schedule), ["trust/policy.json", "mind/rhythm.json", "cognition/user_turn.json",
                                "experiences/experiences.sqlite", "experiences/experiences.sqlite-wal"]),
            (.feed(.dream), ["trust/policy.json", "dream_diary/"]),
            (.feed(.intentions), ["desk/desk_ops.jsonl", "desk/desk_ops_base.json"]),
            (.index, ["chat/sessions.json"]),
            (.contacts, ["agents/peers.json"])
        ]
        var selected = Dictionary(uniqueKeysWithValues: fields.map { change, paths in
            (change, Set(paths.map { root.appendingPathComponent($0).standardizedFileURL }))
        })
        for id in sessions {
            guard let safe = NativeAgentChatSessionID.normalizedPathComponent(id) else { continue }
            selected[.transcript(id)] = [root.appendingPathComponent("chat/messages/\(safe).jsonl").standardizedFileURL]
        }
        for (change, paths) in selected where watches[change]?.paths != paths {
            let observation = await EventDeadlinePhysiology.readEvents(paths: Array(paths), directoryFiles: engine.pageDirectoryFiles,
                                                                       fileReading: engine.pageFileReading)
            let previous = watches[change]
            let task = Task { [weak self] in
                for await _ in observation.stream {
                    guard !Task.isCancelled else { break }
                    await self?.changed(change)
                }
                await observation.cancel()
            }
            watches[change] = Watch(paths: paths, task: task)
            previous?.task.cancel()
        }
        for change in watches.keys where selected[change] == nil { watches.removeValue(forKey: change)?.task.cancel() }
    }

    /// An in-flight read finishes; all intervening edges form one next read of the latest source state.
    private func drain(_ engine: NativeAgentEngine) async {
        defer { reading = nil }
        while !pending.isEmpty, !Task.isCancelled {
            var changes = pending
            pending.removeAll()
            if sources[.conversations] == nil { changes.formUnion([.index, .contacts]) }
            var feeds = Set(changes.compactMap { change -> TodayFeed? in
                if case .feed(let feed) = change { return feed }
                return nil
            })
            if changes.contains(.all) { feeds.formUnion(TodayFeed.allCases) }
            feeds.formUnion(TodayFeed.allCases.filter { sources[$0] == nil })
            feeds.insert(.clock)
            if changes.contains(.index) || changes.contains(.contacts) || changes.contains(where: {
                if case .transcript = $0 { return true }; return false
            }) { feeds.insert(.conversations) }
            do {
                let sequence = try await ExperienceStore.at(engine.dataRoot).lastDetailSeq()
                guard let epoch = UInt64(exactly: sequence ?? 0) else {
                    throw PartCallError(code: "invalid_sequence", message: "Today's record position is invalid.")
                }
                var changed = false
                for feed in TodayFeed.allCases where feeds.contains(feed) {
                    try Task.checkCancellation()
                    let began = ContinuousClock.now
                    let source: TodaySource
                    switch feed {
                    case .clock:
                        source = TodaySource(input: ["hour": .int(Int64(Calendar.autoupdatingCurrent.component(.hour, from: Date())))])
                    case .approvals: source = await TodaySource.approvals(engine)
                    case .notes: source = await TodaySource.notes(engine)
                    case .waiting: source = await TodaySource.waiting(engine)
                    case .trials: source = await TodaySource.trials(engine)
                    case .thinking: source = await TodaySource.thinking(engine)
                    case .moments: source = await TodaySource.moments(engine)
                    case .dream: source = await TodaySource.dream(engine)
                    case .schedule: source = await TodaySource.schedule(engine)
                    case .toward: source = await TodaySource.toward(engine)
                    case .intentions:
                        source = await TodaySource.intentions(engine)
                        intentionsDeadline?.cancel()
                        intentionsDeadline = source.deadline.map { deadline in
                            Task { [weak self] in
                                do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                                catch { return }
                                await self?.changed(.feed(.intentions))
                            }
                        }
                    case .conversations:
                        var conversations = self.conversations
                        source = try await conversations.read(changes, engine: engine) { [weak self] sessions in
                            await self?.rewatch(sessions)
                        }
                        self.conversations = conversations
                    }
                    let differs = sources[feed] != source
                    ModuleLog.app("[today-source] feed=\(feed.rawValue) duration=\(began.duration(to: .now)) changed=\(differs)", level: .debug)
                    if differs {
                        sources[feed] = source
                        changed = true
                    }
                }
                try Task.checkCancellation()
                let published = await engine.pages.snapshots["today"]
                guard changed || published?.status == .unavailable else { continue }
                let packet = packet(epoch: epoch)
                let began = ContinuousClock.now
                await engine.pages.sourceChanged(id: "today-readout", page: "today", epoch: packet.epoch, input: packet.facts,
                    owed: packet.owed, levers: packet.levers.isEmpty ? nil : packet.levers, bound: true)
                ModuleLog.app("[today-source] feed=projection duration=\(began.duration(to: .now)) pending=\(pending.count)", level: .debug)
            } catch is CancellationError { return }
            catch {
                let current = await engine.pages.snapshots["today"]
                await engine.pages.sourceChanged(id: "today-readout", page: "today", epoch: current?.sourceEpoch ?? 0, input: .object([:]),
                    unavailable: error.localizedDescription, owed: current?.owed ?? false, levers: current?.levers, bound: true)
            }
        }
    }

    private func packet(epoch: UInt64) -> PartFaces.Packet {
        var input: [String: JSONValue] = [:], keys: [String: JSONValue] = [:], states: [String: JSONValue] = [:]
        var levers: [PartFace.Row] = [], trials: PartFace.Section?, owed = false, gaps: [String] = []
        for feed in TodayFeed.allCases {
            guard let source = sources[feed] else { continue }
            for (field, value) in source.input where field != "sourceStates" { input[field] = value }
            if let values = source.input["sourceStates"]?.objectValue { states.merge(values) { _, new in new } }
            keys.merge(source.keys) { _, new in new }
            levers += source.levers
            if let section = source.trials { trials = section }
            owed = owed || source.owed
            gaps += source.unavailable
        }
        let waiting = sources[.waiting]
        let total = waiting?.waitingCount
        let approvals = sources[.approvals]?.approvalCount
        let phoneWaiting = waiting?.phoneWaiting == true
        let notesKnown = states["notes"].map { $0 == .string("available") || $0 == .string("empty") } == true
        var readable = total != nil && approvals != nil && notesKnown && waiting?.phoneKnown == true
        let count: JSONValue
        if let total {
            let sum = total.addingReportingOverflow(phoneWaiting ? 1 : 0)
            if sum.overflow || sum.partialValue < 0 {
                count = .null
                readable = false
                gaps.append("Waiting count unavailable: the owner's count is outside its valid range.")
            } else { count = .int(Int64(sum.partialValue)) }
        } else { count = .null }
        input["waiting"] = .object(["count": count, "readable": .bool(readable)])
        if let total, let approvals {
            let onDesk = WorkOverviewRead.waitingOnDesk(total: total, approvals: approvals)
            let split = WorkOverviewRead.waitingSplit(kinds: waiting?.waitingKinds, onDesk: onDesk)
            let count = split?.items ?? onDesk
            if count > 0 {
                input["waitingDesk"] = WorkOverviewRead.waitingDeskInput(count: count, split: split.map { ($0.items, 0) })
                keys["desk"] = .object(["open": .string("page:desk")])
                owed = true
            }
        }
        input["sourceStates"] = .object(states)
        input["availability"] = .object(["state": .string(gaps.isEmpty ? "available" : "partial"),
                                         "unavailable": .array(gaps.map(JSONValue.string))])
        var characters = Set<String>()
        func collect(_ value: JSONValue) {
            switch value {
            case .string(let text):
                for version in [text, TodayWords.plain(text), text.uppercased()] {
                    for character in version where String(character).utf16.count > 1 { characters.insert(String(character)) }
                }
            case .array(let rows): rows.forEach(collect)
            case .object(let fields): fields.values.forEach(collect)
            default: break
            }
        }
        input.values.forEach(collect)
        let clusters = characters.sorted { left, right in
            left.utf16.count != right.utf16.count ? left.utf16.count > right.utf16.count : left < right
        }
        input["clusters"] = .array(clusters.map(JSONValue.string))
        for (key, open) in [("approvals", "page:today/approvals"), ("inbox", "page:today/inbox"),
                            ("rem", "page:today/cognitionProposals")] {
            keys[key] = .object(["open": .string(open)])
        }
        input["keys"] = .object(keys)
        let decisions = levers.isEmpty ? [] : [PartFace.Section(id: "decisions", title: "Your decisions", style: .list, rows: levers)]
        return PartFaces.Packet(facts: .object(input), epoch: epoch, levers: decisions + [trials].compactMap { $0 }, owed: owed)
    }
}
