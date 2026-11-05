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
import Desk
import AuthoredCapabilities
import AppToolRuntime
import ToolExecution
import Senses
import AgentConversations
import TrustCenter
import AgentWorkspace
import TurnTrace
import Experiences
// Blueprint: | `WorkOverviewRead+Today.swift` | Frozen Today sources at the experience record's sequence; engine.pages projects today-readout.js |

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

    /// Use the system’s localized short time and the shared display zone for every user-facing clock.
    public static func clock(_ date: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Use the system interval formatter so shared periods remain localized.
    public static func clockSpan(_ start: Date, _ end: Date, calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        guard clock(start, calendar: calendar) != clock(end, calendar: calendar), start < end else {
            return clock(start, calendar: calendar)
        }
        let style = Date.IntervalFormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        return (start..<end).formatted(style)
    }

    /// Name dates beyond the adjacent week so distant runs cannot look like this week’s weekday.
    public static func weekday(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        guard abs(date.timeIntervalSince(now)) >= 6.5 * 86_400 else { return date.formatted(style.weekday(.abbreviated)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year())
    }

    /// Use actual date and hour so early-morning dreams cannot appear as tonight’s.
    public static func dayWord(_ date: Date, now: Date = Date(), calendar: Calendar = Calendar.autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 18 ? "Tonight" : "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
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

    @MainActor
    public static func conversationSurfaces(_ sessions: [NativeAgentShared.ChatSession],
                                            openingLines: ChatShellOpeningLine) -> [String: String] {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        return Dictionary(sessions.filter {
            guard ($0.messageCount ?? 0) > 0,
                  let at = TodayWords.parseTimestamp($0.updatedAt ?? $0.createdAt),
                  calendar.isDate(at, inSameDayAs: now) else { return false }
            return !ChatShellConversationRow.isWorking($0) && !ChatShellConversationRow.isAgentOwn($0, openingLines: openingLines)
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

private struct TodaySource: Sendable {
    var input: [String: JSONValue] = [:]
    let epoch: UInt64
    var owed = false
    var memoryUnreadable = false
    var dreamUnavailable = false
    var unavailable: [String] = []

    @MainActor
    static func read(_ engine: NativeAgentEngine, activeSessionID: String) async throws -> TodaySource {
        // Read the record position before the packet so a later packet cannot be replaced by an older reader.
        let seq = try await ExperienceStore.at(engine.dataRoot).lastDetailSeq()
        var source = TodaySource(epoch: UInt64(seq ?? 0))
        source.input["recordSeq"] = seq.map(JSONValue.int) ?? .null
        var characterSet = Set<String>()
        let now = Date(), calendar = Calendar.autoupdatingCurrent
        func today(_ at: Date) -> Bool { calendar.isDate(at, inSameDayAs: now) }
        let sessions: [NativeAgentShared.ChatSession]
        var sessionState = "available"
        do {
            let path = engine.dataRoot.appendingPathComponent("chat/sessions.json")
            sessions = try await SwiftNativePersistenceCore.withFileLock(path) {
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
        let approvals = WorkOverviewRead.waitingApprovals(engine.approvals.records)
        let asks = engine.inbox.items.filter { $0.requiresOwnerInput && !$0.hasLinkedApproval }.sorted { $0.created_at > $1.created_at }
        var waiting = approvals.map { approval -> JSONValue in
            let title = ApprovalWords.title(action: approval.action, title: approval.title, reason: approval.reason)
            return .object(["id": .string("approval:" + approval.id), "title": .string(title.isEmpty ? approval.action : title),
                "detail": .string(TodayWords.line(approval.reason)), "open": .string("approval:" + approval.id)])
        }
        waiting += asks.map { item in
            .object(["id": .string("card:" + item.id), "title": .string(item.title),
                "detail": .string(TodayWords.line(item.summary)), "open": .string("card:" + item.id)])
        }
        if let line = engine.sync.standing?.waitingLine {
            waiting.append(.object(["id": .string("phone"), "title": .string(line), "open": .string("page:pairing")]))
        }
        let onDesk = WorkOverviewRead.waitingOnDesk(total: engine.desk.ownerWaitingCount, approvals: approvals.count)
        let split = WorkOverviewRead.waitingSplit(kinds: engine.desk.ownerWaitingKinds, onDesk: onDesk)
        let deskCount = split?.items ?? onDesk
        if deskCount > 0 { source.input["waitingDesk"] = WorkOverviewRead.waitingDeskInput(count: deskCount, split: split.map { ($0.items, 0) }) }
        source.input["waitingRows"] = .array(waiting)
        source.owed = !waiting.isEmpty || deskCount > 0
        do {
            let thinking = try await TurnTraceThinkingReader.shared.read(dataRoot: engine.dataRoot, now: now)
            func counts(_ value: TurnTraceThinkingReader.Counts) -> JSONValue {
                .object(["calls": .int(Int64(value.calls)), "turns": .int(Int64(value.turns))])
            }
            source.input["thinking"] = .object(["state": .string("available"), "at": .double(now.timeIntervalSince1970),
                "today": counts(thinking.today), "week": counts(thinking.week)])
        } catch {
            source.unavailable.append("Thinking source unavailable: " + error.localizedDescription)
            source.input["thinking"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        var moments: [JSONValue] = []
        do {
            let kept = try await SwiftNativeMemoryV2.resolvedOwner(dataRoot: engine.dataRoot).listMemory(kind: MemoryMoments.kind)
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
            if (diary.unreadableEntries ?? 0) > 0 {
                source.dreamUnavailable = true
                source.unavailable.append("Dream diary has unreadable entries.")
            }
            if let entry = diary.entries.first {
                let markdown = entry.text
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    source.dreamUnavailable = true
                    source.unavailable.append("Dream entry is empty.")
                }
                if let at = TodayWords.parseTimestamp(entry.modifiedAt), today(at) {
                    if let digest = TodayDreamDigest.parse(markdown) {
                        source.input["dream"] = .object(["state": .string(source.dreamUnavailable ? "partial" : "available"),
                            "title": .string(digest.title), "mood": .string(digest.mood), "at": .double(at.timeIntervalSince1970),
                            "open": .string("dream:" + entry.date)])
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
        do {
        let dreamEnabled = try await engine.cognitionView.dreamEnabled()
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
        source.input["nextDream"] = .object([
            "state":.string(next != nil ? "available" : scheduleUnavailable ? "unavailable" : "empty"),
            "enabled":.bool(dreamEnabled),
            "at":next.map { .double($0.timeIntervalSince1970) } ?? .null])
        } catch {
            source.dreamUnavailable = true
            source.unavailable.append(error.localizedDescription)
            source.input["nextDream"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        if let toward = await engine.cognitionView.towardRead() {
            let weekday=toward.dueAt.formatted(Date.FormatStyle(calendar:calendar,timeZone:calendar.timeZone).weekday(.wide))
            source.input["toward"] = .object(["state":.string("available"),"label": .string(TodayWords.line(toward.displayLabel)),
                "past":.bool(toward.dueAt <= now),"hour":.int(Int64(calendar.component(.hour,from:toward.dueAt))),
                "today":.bool(today(toward.dueAt)),"tomorrow":.bool(calendar.isDateInTomorrow(toward.dueAt)),
                "weekday":.string(weekday),"at":.double(toward.dueAt.timeIntervalSince1970)])
        } else { source.input["toward"] = .object(["state":.string(engine.cognition == nil ? "unavailable" : "empty")]) }
        do {
            let state = try await engine.desk.store.liveState()
            let horizon = now.addingTimeInterval(7 * 86_400)
            let intentions = MyQueue.entries(state).compactMap { entry -> JSONValue? in
                guard MyQueue.migrationReady(entry.step, dataRoot: engine.dataRoot),
                      entry.step.status != "stopped", !MyQueue.isOver(entry, at: now) else { return nil }
                let next: Date?
                guard let condition = MyQueue.when(entry) else { return nil }
                switch condition {
                case .at(let at): next = at
                case .every: next = IntentionClock.next(entry.step, after: now)
                default: next = nil
                }
                guard let next, next >= now, next <= horizon,
                      MyQueue.until(entry).endsAt.map({ next < $0 }) ?? true else { return nil }
                let key = "intention:" + entry.item.handle
                return .object(["key": .string(key), "at": .double(next.timeIntervalSince1970),
                    "time": .string(ResidentWake.shown(next)), "words": .string(entry.step.words)])
            }
            source.input["intentions"] = .object(["state": .string("available"), "rows": .array(intentions)])
        } catch {
            source.unavailable.append("Intentions source unavailable: " + error.localizedDescription)
            source.input["intentions"] = .object(["state": .string("unavailable"), "reason": .string(error.localizedDescription)])
        }
        var builders: [JSONValue] = []
        var loaded: [String: [ChatMessage]] = [:]
        for id in WorkOverviewRead.todaySessionIDs(sessions) {
            do {
                let transcript = try await engine.transcripts.loadTranscript(sessionId: id, cached: true)
                loaded[id] = transcript.messages
            } catch { source.unavailable.append("Transcript \(id): \(error.localizedDescription)") }
        }
        // Read open-thread rows from the same canonical owner.
        if !activeSessionID.isEmpty { loaded[activeSessionID] = engine.transcripts.messages(for: activeSessionID) }
        let surfaces = WorkOverviewRead.conversationSurfaces(sessions, openingLines: engine.transcripts.openingLines)
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
                                source: message.source, hasEnvelope: message.metadata?.envelope != nil,
                                surface: message.metadata?.envelope?.surface, agent: message.metadata?.envelope?.agent)?.isAutomated != true
                            return (at,human)
                        }
                        return nil
                    }
                    if let first = turns.first { start = turns.first(where: { $0.1 })?.0 ?? first.0 }
                }
                let key = "conversation:" + session.id
                conversations.append(.object(["key": .string(key), "surface": .string(surface),
                    "open": .string("chat:" + session.id), "at": .double((start ?? end).timeIntervalSince1970),
                    "start":start.map { .double($0.timeIntervalSince1970) } ?? .null,"end":.double(end.timeIntervalSince1970)]))
            }
        }
        // Admit provenance from recorded evidence, never titles or prose.
        let contacts: [AgentPeerContact]?
        do { contacts = try AgentPeerStore(dataRoot: engine.dataRoot).list() }
        catch {
            contacts = nil
            source.unavailable.append("Collaboration names unavailable: " + error.localizedDescription)
        }
        for (sessionID, messages) in loaded {
            for message in messages {
                if (message.sessionId == nil || message.sessionId == sessionID), message.role == "user",
                   !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let origin = message.metadata?.origin,
                   let surface = origin.surface, PeerTurnEffectPolicy.isPeerBridge(surface: surface),
                   let agent = origin.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty,
                   let contacts,
                   let at = TodayWords.parseTimestamp(message.createdAt), at <= now, today(at) {
                    // A peer's reply to the agent's send is authored "agent" and names its one sender in peerSources.
                    let sourced = Set(([agent] + (origin.peerSources ?? [])).filter { $0.hasPrefix("peer:") })
                    let peerID = message.metadata?.envelope?.verifiedUserId
                        ?? (sourced.count == 1 ? sourced.first.map { String($0.dropFirst(5)) } : nil)
                    let name = peerID.flatMap { id in contacts.first { $0.id == id }?.name }
                    // A named agent is a proper name; one that did not name itself stays "another agent" mid-sentence.
                    let display = name ?? (peerID == nil && agent != "agent" ? TodayWords.capitalizedFirst(agent) : "another agent")
                    let key = "builder:" + sessionID + ":" + message.id
                    builders.append(.object([
                        "key": .string(key),
                        "session": .string(sessionID), "open": .string("chat:" + sessionID),
                        "agent": .string(TodayWords.line(display, limit: 80)),
                        "at":.double(at.timeIntervalSince1970)]))
                }
            }
        }
        let notes = engine.inbox.items.filter { $0.isActivityPending && !$0.isSystemLane }.compactMap { item -> JSONValue? in
            if let at = TodayWords.parseTimestamp(item.created_at) {
                let key = "inbox:" + item.id
                // Only native owner job identity may bind a folded group.
                let job = item.relatedDelegationID.flatMap { $0.isEmpty ? nil : $0 }
                return .object(["key": .string(key), "open": .string("card:" + item.id),
                    "at": .double(at.timeIntervalSince1970), "today": .bool(today(at)),
                    "source": .string(item.source), "title": .string(TodayWords.withoutIDs(TodayWords.line(item.title,limit:90))),
                    "summary": .string(TodayWords.withoutIDs(TodayWords.firstSentence(item.summary))), "job": job.map(JSONValue.string) ?? .null])
            }
            source.unavailable.append("Note time unavailable: " + item.id)
            return nil
        }
        source.input["conversations"] = .array(conversations
            .sorted { ($0.objectValue?["key"]?.stringValue ?? "") < ($1.objectValue?["key"]?.stringValue ?? "") })
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
        try Task.checkCancellation()
        return source
    }

}

/// Feeds the page owner; the face is the only Today model every door reads.
@MainActor
@Observable
public final class TodayReadout {
    private var readCount = 0
    public var isReading: Bool { readCount > 0 }
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    @ObservationIgnored private lazy var sourceRead = LatestRead()
    @ObservationIgnored private var watchedSessions: [String] = []
    /// The conversation the Mac has open, read live rather than from disk; empty when no door has one open.
    @ObservationIgnored public var activeSessionID = ""
    /// What a door that is showing Today also refreshes on each change (the Mac's queues and work status); nil when no door shows it.
    @ObservationIgnored public var extras: (@MainActor () async -> Void)?

    public nonisolated init() {}

    deinit {
        sourceTask?.cancel()
        inboxTask?.cancel()
    }

    /// Today is read by its owner from launch, at every change of what it reads, for every door; no door's view starts it. A change in
    /// today's conversations re-arms the watch over their transcripts.
    public func start(engine: NativeAgentEngine) {
        stop()
        let root = engine.dataRoot
        watchedSessions = WorkOverviewRead.todaySessionIDs(engine)
        let transcripts = watchedSessions.compactMap {
            NativeAgentChatSessionID.normalizedPathComponent($0)
                .map { root.appendingPathComponent("chat/messages/\($0).jsonl") }
        }
        let refresh: @MainActor @Sendable () async -> Void = { [weak self, weak engine] in
            guard let self, let engine else { return }
            await self.extras?()
            await self.refresh(engine, activeSessionID: self.activeSessionID)
        }
        // What is for the person lives in memory (ForPerson); its changes wake Today, never a file watch.
        inboxTask = Task {
            let debouncer = StoreReloadDebouncer(delay: .milliseconds(250)) { await refresh() }
            await debouncer.setVisible(true)
            for await _ in await ForPerson.at(root).changes() {
                guard !Task.isCancelled else { break }
                await debouncer.signal()
            }
            await debouncer.cancel()
        }
        sourceTask = Task {
            await EventDeadlinePhysiology.refreshOnChanges(paths: [
                root.appendingPathComponent("workflows/approvals/requests.json"),
                root.appendingPathComponent("memory/memory.sqlite"),
                root.appendingPathComponent("memory/memory.sqlite-wal"),
                root.appendingPathComponent("trust/policy.json"),
                root.appendingPathComponent("scheduler/jobs.json"),
                root.appendingPathComponent("desk/desk_ops.jsonl"),
                root.appendingPathComponent("desk/desk_ops_base.json"),
                root.appendingPathComponent("dream_diary", isDirectory: true),
                root.appendingPathComponent("chat/sessions.json"),
                root.appendingPathComponent("chat/messages", isDirectory: true),
            ] + transcripts, notifications: [.NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
                .turnTraceTerminalPersisted, AbilityStore.didChange]) { [weak self, weak engine] in
                await refresh()
                guard let self, let engine else { return }
                if WorkOverviewRead.todaySessionIDs(engine) != self.watchedSessions { self.start(engine: engine) }
            }
        }
    }

    public func stop() {
        sourceTask?.cancel()
        sourceTask = nil
        inboxTask?.cancel()
        inboxTask = nil
    }

    public func refresh(_ engine: NativeAgentEngine, activeSessionID: String) async {
        readCount += 1
        defer { readCount -= 1 }
        let epoch = engine.pages.snapshots["today"]?.sourceEpoch ?? 0
        var packet: Result<TodaySource, Error>?
        await sourceRead.read({
            do { return Result<TodaySource, Error>.success(try await TodaySource.read(engine, activeSessionID: activeSessionID)) }
            catch { return .failure(error) }
        }, publish: { packet = $0 })
        guard let packet, !Task.isCancelled else { return }
        switch packet {
        case .success(let source):
            await engine.pages.sourceChanged(id: "today-readout", page: "today", epoch: source.epoch,
                input: .object(source.input), owed: source.owed)
        case .failure(let error):
            if error is CancellationError { return }
            // A failed record read publishes only its cause, never an empty day.
            await engine.pages.publish(page: "today", epoch: epoch) { throw error }
        }
    }
}
