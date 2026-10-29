import Foundation
import PersistenceCore
// Blueprint: | `MyQueue.swift` | `MyQueue` enum; `entries`, `add`, `isReady`; `Entry.owedToPerson` derives reply obligation from recorded origin and canonical session kind, independent of readiness and taint |

/// MY QUEUE: what she said she would do later, kept as Desk
/// items of hers until she marks each done or dropped. A step's `DeskStep`
/// says when it is ready, so one waiting on User or a card does not nag her.
public enum MyQueue {
    public static let project = "my queue"

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
        case afterCard(String)
        case at(Date)

        /// `next_turn`, `own_turn`, `when_user_messages[ <door>]`,
        /// `after_card <approval id>` (or `card`), `at <ISO time>`; nil when
        /// it is none of these.
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
            case "after_card":
                let id = rest.isEmpty ? (card ?? "") : rest
                guard !id.isEmpty else { return nil }
                self = .afterCard(id)
            case "at":
                guard let date = Self.time(rest) else { return nil }
                self = .at(date)
            default: return nil
            }
        }

        static func time(_ text: String) -> Date? {
            if let date = DeskClock.parseISO(text) { return date }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            for pattern in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
                format.dateFormat = pattern
                if let date = format.date(from: text) { return date }
            }
            return nil
        }

        /// The stored form; an after_card's id rides `DeskStep.card`.
        public var stored: String {
            switch self {
            case .nextTurn: "next_turn"
            case .ownTurn: "own_turn"
            case .quiet: "quiet"
            case .userWrites(let door): "when_user_messages" + (door.map { " " + $0 } ?? "")
            case .afterCard: "after_card"
            case .at(let date): "at " + ISO8601DateFormatter().string(from: date)
            }
        }

        public var card: String? { if case .afterCard(let id) = self { id } else { nil } }
    }

    public static func when(_ entry: Entry) -> When {
        When(entry.step.when, card: entry.step.card) ?? .nextTurn
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
        public var userWrote: @Sendable (_ door: String?, _ since: Date) -> Bool

        public init(now: Date, ownTurn: Bool, completedCards: Set<String>,
                    userWrote: @escaping @Sendable (_ door: String?, _ since: Date) -> Bool) {
            self.now = now; self.ownTurn = ownTurn; self.completedCards = completedCards; self.userWrote = userWrote
        }
    }

    public static func isReady(_ entry: Entry, _ context: Context) -> Bool {
        guard entry.step.status != "stopped" else { return false }
        switch when(entry) {
        case .nextTurn: return true
        case .ownTurn, .quiet: return context.ownTurn
        case .afterCard(let id): return context.completedCards.contains(id)
        case .at(let date): return context.now >= date
        case .userWrites(let door):
            guard let since = DeskClock.parseISO(entry.step.filedAt ?? entry.item.updatedAt) else { return false }
            return context.userWrote(door, since)
        }
    }

    // MARK: - Changes

    public enum Change: String, Sendable { case added, reused, updated }

    /// Queue a step. The same words already open answer with that item; a
    /// new condition, card or call she gives them herself is recorded on it,
    /// with its originating conversation and every recorded peer (re-filing never
    /// launders a steer). An inferred repeat never overrides: a promise said
    /// again on a later turn must not unlink the card it waits on.
    public static func add(_ step: DeskStep, store: SwiftNativeDeskStore) async throws -> (entry: Entry, change: Change) {
        try await store.addQueueStep(step)
    }

    /// Open inferred steps at most; a promise past this is not filed.
    public static let inferredCap = 20

    public struct Full: LocalizedError {
        public var errorDescription: String? { "MY QUEUE already holds \(MyQueue.inferredCap) inferred steps" }
    }

    public struct Superseded: Error, LocalizedError, Sendable {
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
