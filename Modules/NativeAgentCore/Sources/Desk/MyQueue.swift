import Foundation
import PersistenceCore
// Blueprint: | `MyQueue.swift` | `MyQueue` enum; checked optional conditions and unavailable readiness; When.timeReading owns ISO/system local date acceptance and ambiguity; scheduledMigrationMarker and migrationReady read the durable launch commit; `entries`, `add`, `isReady`, `releaseSignal`, `releaseNews`; person moments require a transition after filing, news/body releases carry the exact condition and postdate its filing and handling; signal matching respects colon/file boundaries, releases revalidate under the Desk lock; `When.isPrompt` keeps prompt moments out of free-time quiet; `Entry.owedToPerson` reads recorded origin and canonical session kind |

/// MY QUEUE: what she said she would do later, kept as Desk
/// items of hers until she marks each done or dropped. A step's `DeskStep`
/// says when it is ready, so one waiting on User or a card does not nag her.
public enum MyQueue {
    public static let project = "my queue"

    /// The one-time launch transaction's durable commit. Restored scheduler
    /// rows never import more steps after this boundary.
    public static func scheduledMigrationMarker(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("scheduler/.intentions-finished")
    }

    public static func migrationReady(_ step: DeskStep, dataRoot: URL) -> Bool {
        step.scheduledJobID == nil || (try? Data(contentsOf: scheduledMigrationMarker(dataRoot: dataRoot))) != nil
    }

    public struct Entry: Sendable {
        public let item: DeskItem
        public let step: DeskStep
        /// Her name for it, as home and `item` use it.
        public var name: String { "desk." + item.alias }
        /// Queued on a turn a peer steered. Its steer applies only where this
        /// step resumes; reading it on the Desk carries none of it.
        public var peerBorn: Bool { !(step.peers.isEmpty && step.elevated.isEmpty) }
        public func owedToPerson(dataRoot: URL) -> Bool { step.owedToPerson(dataRoot: dataRoot) }
    }

    /// The open queue step an item is, or nil. Its newest step ref wins: a
    /// step queued again with a new condition, or re-filed on her own turn.
    public static func entry(_ item: DeskItem) -> Entry? {
        guard item.project == project, !item.status.isTerminal else { return nil }
        guard let step = item.step else { return nil }
        return Entry(item: item, step: step)
    }

    /// Open steps, newest first.
    public static func entries(_ state: DeskState) -> [Entry] {
        state.items.compactMap(entry).sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    // MARK: - When

    public enum When: Equatable, Sendable {
        case nextTurn, ownTurn
        /// A noticed repeat waits for the same free time as her own turn.
        case quiet
        case userWrites(door: String?)
        case userHere, userAway
        case news(String)
        case signal(String)
        case afterCard(String)
        case at(Date)
        /// An intention's rhythm: each occurrence of the step's `rhythm` is a moment.
        case every

        /// `next_turn`, `own_turn`, `when_user_messages[ <door>]`,
        /// `when_user_here`, `when_user_away`, `on_news <words>`, `on <signal>`,
        /// `after_card <approval id>` (or `card`), `at <ISO/local time>`, a plain local date/time, `every`
        /// (the step's rhythm); nil when it is none of these.
        public init?(_ raw: String?, card: String? = nil) {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == ":" })
            let head = parts.first.map { $0.lowercased() } ?? ""
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch head {
            case "", "next_turn": self = .nextTurn
            case "own_turn": self = .ownTurn
            case "quiet": self = .quiet
            case "when_user_messages": self = .userWrites(door: rest.isEmpty ? nil : rest.lowercased())
            case "when_user_here": self = .userHere
            case "when_user_away": self = .userAway
            case "on_news":
                guard !rest.isEmpty else { return nil }
                self = .news(rest)
            case "on":
                guard !rest.isEmpty, !rest.hasPrefix("schedule:") else { return nil }
                if rest.hasPrefix("file.changed:") {
                    let path = String(rest.dropFirst("file.changed:".count))
                    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    self = .signal("file.changed:" + (path as NSString).expandingTildeInPath)
                } else { self = .signal(rest) }
            case "after_card":
                let id = rest.isEmpty ? (card ?? "") : rest
                guard !id.isEmpty else { return nil }
                self = .afterCard(id)
            case "at":
                guard let date = Self.time(rest) else { return nil }
                self = .at(date)
            case "every": self = .every
            default:
                guard let date = Self.time(text) else { return nil }
                self = .at(date)
            }
        }

        static func time(_ text: String) -> Date? {
            timeReading(text).date
        }

        /// One reading for acceptance and refusal: never interpret an unrecognized
        /// fragment as a complete moment. Persist accepted dates as absolute ISO.
        public static func timeReading(_ raw: String) -> (date: Date?, interpretation: String) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            func read(_ date: Date) -> String {
                ISO8601DateFormatter().string(from: date) + " (Mac zone " + TimeZone.current.identifier + ")"
            }
            func local(_ date: Date, reading: String) -> (date: Date?, interpretation: String) {
                // A repeated local clock minute has two real instants. Ask for
                // the offset rather than silently selecting one in autumn.
                var calendar = Calendar.current
                calendar.timeZone = .current
                let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
                let beforeDay = calendar.startOfDay(for: date).addingTimeInterval(-1)
                let first = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .first)
                let last = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .last)
                if let first, let last, first != last {
                    return (nil, reading + "; this local clock time occurs twice: " + read(first) + " or " + read(last) + "; supply an ISO timestamp with its UTC offset")
                }
                return (date, reading)
            }
            if let date = DeskClock.parseISO(text) { return (date, read(date)) }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = .current
            format.isLenient = false
            for pattern in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                format.dateFormat = pattern
                if let date = format.date(from: text), format.string(from: date) == text { return local(date, reading: read(date)) }
            }
            guard !text.isEmpty else { return (nil, "no date/time words were supplied") }
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
                return (nil, "the system date reader is unavailable; supply an ISO timestamp with its zone")
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = detector.matches(in: text, range: range)
            let readings = matches.compactMap { match -> String? in
                guard let date = match.date, let span = Range(match.range, in: text) else { return nil }
                return "\"" + String(text[span]) + "\" as " + read(date)
            }.joined(separator: "; ")
            guard matches.count == 1, let match = matches.first, match.range == range, let date = match.date,
                  match.duration == 0 else {
                return (nil, readings.isEmpty ? "the system found no date/time" : "the system read " + readings + "; it did not identify one complete instant")
            }
            return match.timeZone == nil || match.timeZone?.identifier == TimeZone.current.identifier
                ? local(date, reading: "the system read " + readings) : (date, "the system read " + readings)
        }

        /// The stored form; an after_card's id rides `DeskStep.card`.
        public var stored: String {
            switch self {
            case .nextTurn: "next_turn"
            case .ownTurn: "own_turn"
            case .quiet: "quiet"
            case .userWrites(let door): "when_user_messages" + (door.map { " " + $0 } ?? "")
            case .userHere: "when_user_here"
            case .userAway: "when_user_away"
            case .news(let words): "on_news " + words
            case .signal(let name): "on " + name
            case .afterCard: "after_card"
            case .at(let date): "at " + ISO8601DateFormatter().string(from: date)
            case .every: "every"
            }
        }

        public var card: String? { if case .afterCard(let id) = self { id } else { nil } }
        /// Its moment brings it back promptly, without waiting for free-time quiet.
        public var isPrompt: Bool {
            switch self { case .at, .every, .userHere, .userAway, .news, .signal: true; default: false }
        }
    }

    public static func when(_ entry: Entry) -> When? {
        guard !entry.step.when.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return When(entry.step.when, card: entry.step.card)
    }

    // MARK: - Until

    /// When an intention is done. `once` (no until) closes after direct `say`
    /// delivery, otherwise it is hers to close; a time
    /// closes it then; `standing` keeps a rhythm until she drops it; any other
    /// words are a condition she checks each time it comes up.
    public enum Until: Equatable, Sendable {
        case once
        case time(Date)
        case standing
        case words(String)

        public init(_ raw: String?) {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            if text.isEmpty || lower == "once" { self = .once }
            else if lower == "standing" { self = .standing }
            else if lower.hasPrefix("at "), let date = When.time(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)) { self = .time(date) }
            else if let date = When.time(text) { self = .time(date) }
            else { self = .words(text) }
        }

        public var stored: String? {
            switch self {
            case .once: nil
            case .time(let date): "at " + ISO8601DateFormatter().string(from: date)
            case .standing: "standing"
            case .words(let words): words
            }
        }

        public var endsAt: Date? { if case .time(let date) = self { date } else { nil } }
    }

    public static func until(_ entry: Entry) -> Until { Until(entry.step.until) }

    /// Its time ran out: an until time has passed.
    public static func isOver(_ entry: Entry, at now: Date) -> Bool {
        until(entry).endsAt.map { now >= $0 } ?? false
    }

    // MARK: - Ready

    /// What decides readiness, from the caller's world.
    public struct Context: Sendable {
        public var now: Date
        /// Her own turn (a wake), not one User or a peer started.
        public var ownTurn: Bool
        /// Cards User approved whose calls confirmed success.
        public var completedCards: Set<String>
        /// Whether User has written since a time, on a door or (nil) any door.
        public var userWrote: @Sendable (_ door: String?, _ since: Date) throws -> Bool
        /// A rhythm's occurrence that is due now (`IntentionClock.occurrence`), or nil.
        public var occurrence: @Sendable (_ step: DeskStep, _ now: Date) -> Date?
        /// Current person presence and the time it changed into that state.
        public var presence: @Sendable () -> (here: Bool, since: Date)?

        public init(now: Date, ownTurn: Bool, completedCards: Set<String>,
                    userWrote: @escaping @Sendable (_ door: String?, _ since: Date) throws -> Bool,
                    occurrence: @escaping @Sendable (_ step: DeskStep, _ now: Date) -> Date? = { _, _ in nil },
                    presence: @escaping @Sendable () -> (here: Bool, since: Date)? = { nil }) {
            self.now = now; self.ownTurn = ownTurn; self.completedCards = completedCards; self.userWrote = userWrote
            self.occurrence = occurrence
            self.presence = presence
        }
    }

    public enum Readiness: Sendable {
        case ready, waiting, unavailable(String)
    }

    public static func readiness(_ entry: Entry, _ context: Context) -> Readiness {
        guard when(entry) != nil else {
            return .unavailable("The saved condition '\(entry.step.when)' is unavailable. Repair this step's condition before continuing it.")
        }
        do { return try checkedReady(entry, context) ? .ready : .waiting }
        catch { return .unavailable("Readiness is unavailable: \(error.localizedDescription). Repair the named evidence before continuing this step.") }
    }

    public static func isReady(_ entry: Entry, _ context: Context) -> Bool {
        if case .ready = readiness(entry, context) { return true }
        return false
    }

    private static func checkedReady(_ entry: Entry, _ context: Context) throws -> Bool {
        guard entry.step.status != "stopped", !isOver(entry, at: context.now), let condition = when(entry) else { return false }
        switch condition {
        case .nextTurn: return true
        case .ownTurn, .quiet: return context.ownTurn
        case .afterCard(let id): return context.completedCards.contains(id)
        case .at(let date): return context.now >= date
        case .every: return context.occurrence(entry.step, context.now) != nil
        case .userHere, .userAway:
            guard let filed = DeskClock.parseISO(entry.step.filedAt ?? entry.item.openedAt),
                  let presence = context.presence(), presence.since > filed else { return false }
            return presence.here == (condition == .userHere)
        case .news, .signal:
            return !releaseNotes(for: entry).isEmpty
        case .userWrites(let door):
            guard let since = DeskClock.parseISO(entry.step.filedAt ?? entry.item.updatedAt) else { return false }
            return try context.userWrote(door, since)
        }
    }

    /// Release evidence belongs to the current condition revision and is
    /// consumed by her next handling note. Text is presentation, never identity.
    public static func releaseNotes(for entry: Entry) -> [DeskNote] {
        guard let condition = when(entry),
              let filed = DeskClock.parseISO(entry.step.filedAt ?? entry.item.openedAt) else { return [] }
        let handled = entry.item.notes.filter { $0.author == "agent" }
            .compactMap { DeskClock.parseISO($0.ts) }.max()
        let floor = max(filed, handled ?? filed)
        return entry.item.notes.filter {
            $0.author == "system" && $0.releaseCondition == condition.stored
                && DeskClock.parseISO($0.ts).map { $0 > floor } == true
        }
    }

    // MARK: - Changes

    /// Body vocabulary has colon-delimited families; a file's children also
    /// belong to its path. Resolve file spellings exactly as the shared watch does.
    public static func signalMatches(_ signal: String, pattern: String, dataRoot: URL) -> Bool {
        let prefix = "file.changed:"
        if pattern.hasPrefix(prefix), signal.hasPrefix(prefix) {
            let path = NativeAgentWorkspaceRoot.resolveFileEntryPath(String(pattern.dropFirst(prefix.count)), dataRoot: dataRoot).path
            let arrived = NativeAgentWorkspaceRoot.resolveFileEntryPath(String(signal.dropFirst(prefix.count)), dataRoot: dataRoot).path
            return arrived == path || arrived.hasPrefix(path == "/" ? path : path + "/")
        }
        return signal == pattern || signal.hasPrefix(pattern + ":")
    }

    /// One signal releases every matching open intention from the state under
    /// the canonical lock: a closure or refile that landed first wins.
    public static func releaseSignal(_ signal: String, summary: String, store: SwiftNativeDeskStore, at now: Date,
                                     suppressing echoes: Set<String> = []) async throws -> Bool {
        guard !signal.hasPrefix("schedule:"), !["held", "resumed"].contains(signal) else { return false }
        return try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            var feed = try await store.readFeedUnlocked()
            let state = try store.inCurrentLife(SwiftNativeDeskStore.compact(base: feed.base, feed.ops))
            var released = false
            for entry in entries(state) {
                guard !echoes.contains(entry.item.handle),
                      case .signal(let pattern)? = when(entry), entry.step.status != "stopped",
                      !isOver(entry, at: now), signalMatches(signal, pattern: pattern, dataRoot: store.dataRoot) else { continue }
                let note = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: entry.item.handle,
                    body: .appendNote(text: "Released: " + signal + (summary.isEmpty ? "" : " " + summary), author: "system",
                                      releaseCondition: When.signal(pattern).stored))
                feed = try await store.appendAndRecompactUnlocked(note, feed: feed).feed
                released = true
            }
            return released
        }
    }

    /// Embedding weighed one snapshot. Revalidate it, its rest and the current
    /// topic under the same lock that appends the release.
    public static func releaseNews(_ expected: Entry, summary: String, store: SwiftNativeDeskStore,
                                   at now: Date, rest: TimeInterval) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let feed = try await store.readFeedUnlocked()
            let state = try store.inCurrentLife(SwiftNativeDeskStore.compact(base: feed.base, feed.ops))
            guard let item = state.items.first(where: { $0.handle == expected.item.handle }), let entry = Self.entry(item),
                  entry.step.when == expected.step.when, entry.step.filedAt == expected.step.filedAt,
                  case .news(let topic)? = when(entry), entry.step.status != "stopped", !isOver(entry, at: now) else { return false }
            guard let filed = DeskClock.parseISO(entry.step.filedAt ?? item.openedAt) else {
                throw DeskError.journalUnavailable(path: store.opsPath.path, reason: "\(item.handle) has an unreadable condition filing timestamp")
            }
            let last = item.notes.filter {
                $0.author == "system" && $0.releaseCondition == When.news(topic).stored
                    && DeskClock.parseISO($0.ts).map { $0 > filed } == true
            }.compactMap { DeskClock.parseISO($0.ts) }.max()
            guard last.map({ now.timeIntervalSince($0) >= rest }) ?? true else { return false }
            let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: item.handle,
                body: .appendNote(text: "Released: news: " + summary, author: "system", releaseCondition: When.news(topic).stored))
            _ = try await store.appendAndRecompactUnlocked(op, feed: feed)
            return true
        }
    }

    public enum Change: String, Sendable { case added, reused, updated }

    /// Queue a step. The same words already open answer with that item; a
    /// new condition, card or call she gives them herself is recorded on it,
    /// with its originating conversation and every recorded peer (re-filing never
    /// launders a steer). An inferred repeat never overrides: a promise said
    /// again on a later turn must not unlink the card it waits on.
    public static func add(_ step: DeskStep, store: SwiftNativeDeskStore) async throws -> (entry: Entry, change: Change) {
        try await store.addQueueStep(step)
    }

    public static func update(_ entry: Entry, step: DeskStep, store: SwiftNativeDeskStore) async throws -> Entry {
        try await store.addQueueStep(step, replacing: entry).entry
    }

    /// Open inferred steps at most; a promise past this is not filed.
    public static let inferredCap = 20

    public struct Full: LocalizedError {
        public var errorDescription: String? { "MY QUEUE already holds \(MyQueue.inferredCap) inferred steps" }
    }

    public struct Superseded: Error, LocalizedError, Sendable {
        public init() {}
        public var errorDescription: String? { "The queued step changed or closed before settlement; the newer state was kept." }
    }

    /// Done or dropped: only the unchanged snapshot closes and leaves MY QUEUE.
    public static func finish(_ entry: Entry, dropped: Bool, why: String, store: SwiftNativeDeskStore) async throws {
        guard try await store.closeItemIfUnchanged(entry.item.handle, expectedUpdatedAt: entry.item.updatedAt,
                                                   outcomeSummary: why, canceled: dropped) else {
            throw Superseded()
        }
    }

    /// A skill run still stopped at turn end waits here
    /// for her own turn, and holds what it landed until she resumes or drops it.
    public static func skillRunPrefix(skill: String, run: String) -> String { "Resume \(skill) run \(run):" }

    /// The run a "Resume … run <id>:" step waits on, or nil.
    public static func skillRun(in words: String) -> String? {
        guard words.hasPrefix("Resume "), let range = words.range(of: #" run (run-[0-9a-f]{8}):"#, options: .regularExpression)
        else { return nil }
        return String(words[range].dropFirst(5).dropLast())
    }

    public static func skillRunWords(skill: String, run: String, question: String, held: [String]) -> String {
        skillRunPrefix(skill: skill, run: run) + " \(question) (held by run \(run)"
            + (held.isEmpty ? "" : ": " + held.joined(separator: ", ")) + ")"
    }

    public static func entry(_ handle: String, store: SwiftNativeDeskStore) async throws -> Entry? {
        try await store.liveState().items.first { $0.handle == handle }.flatMap(entry)
    }
}
