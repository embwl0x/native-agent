import Foundation
import PersistenceCore
// Blueprint: | `MyQueue.swift` | `MyQueue`, `entries`, `add`, `isReady`, `releaseSignal`, `releaseNews`, `freeAfter`, `shown`, `Entry.owedToPerson` |

/// Desk steps carry readiness so waiting on the person or a card does not nag the agent.
public enum MyQueue {
    public static let project = "my queue"

    /// The agent carries queue intentions and work assigned to her; pursuits have their own admission.
    public static func carries(_ item: DeskItem) -> Bool {
        !item.isPursuit && !item.status.isTerminal && (item.project == project || item.assignee == "agent")
    }

    public static func promiseCaptureID(moment: String, candidate: Int) -> String { "promise:" + moment + ":" + String(candidate) }

    public struct Entry: Sendable {
        public let item: DeskItem
        public let step: DeskStep
        public var name: String { "desk." + item.alias }
        /// Peer steering applies only when the step resumes; reading the Desk cannot activate it.
        public var peerBorn: Bool { !(step.peers.isEmpty && step.elevated.isEmpty) }
        public var owedToPerson: Bool { step.owedToPerson }
    }

    /// The newest step ref owns readiness after a refile or condition change.
    public static func entry(_ item: DeskItem) -> Entry? {
        guard carries(item) else { return nil }
        guard let step = item.step, item.project == project || !step.promiseCaptures.isEmpty else { return nil }
        return Entry(item: item, step: step)
    }

    public static func entries(_ state: DeskState) -> [Entry] {
        state.items.compactMap(entry).sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    // MARK: - When

    /// A door is a surface the person messages from, spelled as that turn's surface. A closed set: an unknown word is refused where it is
    /// accepted, so a step never waits on a door no message arrives through.
    public enum Door: String, CaseIterable, Equatable, Sendable {
        case chat, ios, telegram, slack

        public static var listed: String { allCases.map(\.rawValue).joined(separator: ", ") }
    }

    public enum When: Equatable, Sendable {
        case nextTurn, ownTurn
        /// Inferred repeats require the same free-time quiet as an own turn.
        case quiet
        case userWrites(door: Door?)
        case userHere, userAway
        case news(String)
        case signal(String)
        case afterCard(String)
        case at(Date)
        case every

        public init?(_ raw: String?, card: String? = nil) {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = text.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == ":" })
            let head = parts.first.map { $0.lowercased() } ?? ""
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch head {
            case "", "next_turn": self = .nextTurn
            case "own_turn": self = .ownTurn
            case "quiet": self = .quiet
            case "when_user_messages":
                guard !rest.isEmpty else { self = .userWrites(door: nil); return }
                guard let door = Door(rawValue: rest.lowercased()) else { return nil }
                self = .userWrites(door: door)
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

        /// Reject incomplete fragments and store absolute ISO moments so readiness uses the same time reading.
        public static func timeReading(_ raw: String) -> (date: Date?, interpretation: String) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            func read(_ date: Date) -> String {
                ISO8601DateFormatter().string(from: date) + " (Mac zone " + TimeZone.current.identifier + ")"
            }
            func local(_ date: Date, reading: String) -> (date: Date?, interpretation: String) {
                // Repeated autumn minutes need an explicit offset because either instant would be a guess.
                var calendar = Calendar.current
                calendar.timeZone = .current
                let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
                let beforeDay = calendar.startOfDay(for: date).addingTimeInterval(-1)
                let first = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .first)
                let last = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .last)
                if let first, let last, first != last {
                    return (nil, reading + "; this local clock time occurs twice: " + read(first) + " or " + read(
                        last) + "; supply an ISO timestamp with its UTC offset")
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

        /// Keep after_card identity on DeskStep.card so readiness uses the same approval.
        public var stored: String {
            switch self {
            case .nextTurn: "next_turn"
            case .ownTurn: "own_turn"
            case .quiet: "quiet"
            case .userWrites(let door): "when_user_messages" + (door.map { " " + $0.rawValue } ?? "")
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
    }

    /// When-free work is due this long after the agent's last turn.
    public static let freeAfter: TimeInterval = 30 * 60

    /// A moment as the agent reads it: the time today, or the day and time.
    public static func shown(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = Calendar.current.isDate(date, inSameDayAs: Date()) ? "'at' HH:mm" : "EEE MMM d 'at' HH:mm"
        return format.string(from: date)
    }

    public static func when(_ entry: Entry) -> When? {
        guard !entry.step.when.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return When(entry.step.when, card: entry.step.card)
    }

    // MARK: - Until

    /// Direct one-shot delivery closes itself; rhythms and other conditions remain the agent's decision.
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

    public static func isOver(_ entry: Entry, at now: Date) -> Bool {
        until(entry).endsAt.map { now >= $0 } ?? false
    }

    // MARK: - Ready

    public struct Context: Sendable {
        public var now: Date
        /// Own wakes exclude person- or peer-started turns.
        /// Approval readiness requires the person's approval and confirmed success.
        public var ownTurn: Bool
        public var completedCards: Set<String>
        public var userWrote: @Sendable (_ door: Door?, _ since: Date) throws -> Bool
        public var occurrence: @Sendable (_ step: DeskStep, _ now: Date) -> Date?
        public var presence: @Sendable () -> (here: Bool, since: Date)?

        public init(now: Date, ownTurn: Bool, completedCards: Set<String>,
                    userWrote: @escaping @Sendable (_ door: Door?, _ since: Date) throws -> Bool,
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

    /// Bind release evidence to the current condition and consume it on handling; prose cannot carry identity.
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

    /// Match signal-family and path boundaries with the watch owner's exact file resolution.
    public static func signalMatches(_ signal: String, pattern: String, dataRoot: URL) -> Bool {
        let prefix = "file.changed:"
        if pattern.hasPrefix(prefix), signal.hasPrefix(prefix) {
            let path = NativeAgentWorkspaceRoot.resolveFileEntryPath(String(pattern.dropFirst(prefix.count)), dataRoot: dataRoot).path
            let arrived = NativeAgentWorkspaceRoot.resolveFileEntryPath(String(signal.dropFirst(prefix.count)), dataRoot: dataRoot).path
            return arrived == path || arrived.hasPrefix(path == "/" ? path : path + "/")
        }
        return signal == pattern || signal.hasPrefix(pattern + ":")
    }

    /// Revalidate under the canonical lock so earlier closure or refiling wins.
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

    /// Revalidate the weighed snapshot and topic under the lock that appends the release. Each news line that touches the step is its own release.
    public static func releaseNews(_ expected: Entry, summary: String, store: SwiftNativeDeskStore, at now: Date) async throws -> Bool {
        try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let feed = try await store.readFeedUnlocked()
            let state = try store.inCurrentLife(SwiftNativeDeskStore.compact(base: feed.base, feed.ops))
            guard let item = state.items.first(where: { $0.handle == expected.item.handle }), let entry = Self.entry(item),
                  entry.step.when == expected.step.when, entry.step.filedAt == expected.step.filedAt,
                  case .news(let topic)? = when(entry), entry.step.status != "stopped", !isOver(entry, at: now) else { return false }
            let op = DeskOp(ts: DeskClock.commitStamp(notBefore: feed.maxCommittedTs), handle: item.handle,
                body: .appendNote(text: "Released: news: " + summary, author: "system", releaseCondition: When.news(topic).stored))
            _ = try await store.appendAndRecompactUnlocked(op, feed: feed)
            return true
        }
    }

    public enum Change: String, Sendable { case added, reused, updated }

    public struct PromiseFiling: Sendable {
        public let target: String?
        public let step: DeskStep
        public init(target: String?, step: DeskStep) {
            self.target = target; self.step = step
        }
    }

    public struct PromiseLanding: Sendable {
        public let id: String
        public let change: Change
    }

    /// Land the judgment under the Desk lock, matching selected rows by id in the current carried work.
    public static func capture(_ filings: [PromiseFiling], store: SwiftNativeDeskStore) async throws
        -> [Result<PromiseLanding, Error>] {
        try await SwiftNativePersistenceCore.withFileLock(store.opsPath) {
            let current = try await store.liveState().items.filter(carries)
            var results: [Result<PromiseLanding, Error>] = []
            for filing in filings {
                do {
                    let landing: PromiseLanding
                    if let target = filing.target {
                        guard let item = current.first(where: { $0.handle == target }) else { throw DeskError.unknownHandle(target) }
                        var step = filing.step
                        if let previous = item.step {
                            step = previous
                            step.words = filing.step.words
                            step.when = filing.step.when
                            step.card = filing.step.card
                            step.source = filing.step.source
                            step.promiseCaptures = filing.step.promiseCaptures
                            step.peers = filing.step.peers
                            step.elevated = filing.step.elevated
                            step.preserveOrigin(of: previous)
                        }
                        if let entry = entry(item) {
                            let updated = try await update(entry, step: step, store: store)
                            landing = PromiseLanding(id: updated.name, change: updated.step == entry.step ? .reused : .updated)
                        } else {
                            step.filedAt = DeskClock.commitStamp(notBefore: item.updatedAt)
                            if item.title != step.title {
                                _ = try await store.updateTitle(item.handle, title: step.title)
                            }
                            _ = try await store.addRef(item.handle, ref: DeskRef(kind: .step(step)))
                            landing = PromiseLanding(id: "desk." + item.alias, change: .updated)
                        }
                    } else {
                        let queued = try await store.addQueueStep(filing.step, matchingWords: false)
                        landing = PromiseLanding(id: queued.entry.name, change: queued.change)
                    }
                    results.append(.success(landing))
                } catch { results.append(.failure(error)) }
            }
            return results
        }
    }

    /// Refiling preserves origin and peer steering; inferred repeats cannot overwrite conditions or unlink cards.
    public static func add(_ step: DeskStep, store: SwiftNativeDeskStore) async throws -> (entry: Entry, change: Change) {
        try await store.addQueueStep(step)
    }

    public static func update(_ entry: Entry, step: DeskStep, store: SwiftNativeDeskStore) async throws -> Entry {
        try await store.addQueueStep(step, replacing: entry).entry
    }

    public struct Superseded: Error, LocalizedError, Sendable {
        public init() {}
        public var errorDescription: String? { "The queued step changed or closed before settlement; the newer state was kept." }
    }

    /// Close only the unchanged snapshot so a stale handler cannot drop refiled work.
    public static func finish(_ entry: Entry, dropped: Bool, why: String, store: SwiftNativeDeskStore) async throws {
        guard try await store.closeItemIfUnchanged(entry.item.handle, expectedUpdatedAt: entry.item.updatedAt,
                                                   outcomeSummary: why, canceled: dropped) else {
            throw Superseded()
        }
        if let run = skillRun(in: entry.step.words) {
            do { try PartRunStore.discard(run, root: store.dataRoot) }
            catch { throw RunCleanupFailure(entry: entry, runID: run, underlying: error) }
        }
    }

    public struct RunCleanupFailure: Error, LocalizedError, Sendable {
        public let entry: Entry
        public let runID: String
        public let underlying: any Error
        public var errorDescription: String? { underlying.localizedDescription }
    }

    /// A closed resume step releases its retained run and the reservations that depend on it.
    public static func releaseFinishedRun(words: String, store: SwiftNativeDeskStore) throws {
        if let run = skillRun(in: words) { try PartRunStore.discard(run, root: store.dataRoot) }
    }

    /// Stopped runs retain landed holds while their resume step waits for an own turn.
    public static func skillRunPrefix(skill: String, run: String) -> String { "Resume \(skill) run \(run):" }

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
