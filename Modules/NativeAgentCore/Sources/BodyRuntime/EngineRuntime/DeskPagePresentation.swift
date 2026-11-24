import Foundation
import OSLog
import PersistenceCore
import NativeAgentShared
import DeskCore
// Blueprint: | `DeskPagePresentation.swift` | Desk page snapshots, measured activity, parking and next state deadline; stuck-reason and chat-draft words |
public struct DeskPageSnapshot: Sendable {
    public let id = UUID()
    public var board: DeskBoardRead?
    public var loaded: Bool { board != nil }
    public var items: [DeskItem] { board?.items ?? [] }
    /// The agent’s queue resolves by id without becoming a row on the user’s board.
    public var boardItems: [DeskItem] { board?.deskState?.board.items ?? [] }
    public var deskUnavailable: String? { board?.deskError }
    public var generatedTs: String? { board?.deskState?.generatedTs }
    public var agentJobs: DeskLaneState<AgentJob> { board?.agentJobs ?? .rows([]) }
    public var overview: WorkOverview? { board?.overview }
    /// Derive rows and readiness once off the main actor from the same board and frozen clock.
    public var plan = DeskSequencing.Plan()
    public var now = Date.distantPast
    public var times: [OneClock.Time] = []
    public var nagConfig = DeskNagConfig()
    public var nagConfigError: String?
    public var botScheduleError: String?
    public var wanderHour: DeskWanderHourPresentation.State = .absent
    public var missedBots: [DeskMissedBot] = []
    public var timedBots: [DeskTimedBot] = []
    public var rows: DeskPageContent.Content = (.quiet, [], nil)

    public static let empty = DeskPageSnapshot()
    public init() {}

    public init(read: DeskBoardRead) {
        board = read
    }
}

/// Project the hour's latest thought without creating a Desk task; the person's off switch keeps it absent.
public enum DeskWanderHourPresentation {
    public enum State: Sendable, Equatable {
        case absent
        /// The recorded thought's outcome, without judging an encounter or a journal entry.
        case line(text: String, symbol: String, at: String? = nil)
    }

    static func state(
        installed: Bool,
        entry: StudioWanderLane.ThoughtReading?
    ) -> State {
        guard installed, let entry else { return .absent }
        switch entry.outcome {
        case .hit: return .line(text: "My hour: a thought that acted.", symbol: "eye", at: entry.at)
        case .empty: return .line(text: "My hour: a thought left quiet.", symbol: "moon.zzz", at: entry.at)
        case .withheld: return .line(text: "My hour: left quiet on its own record.", symbol: "moon.zzz", at: entry.at)
        case .failed: return .line(text: "My hour: a thought could not settle.", symbol: "exclamationmark.circle", at: entry.at)
        }
    }
}

public enum DeskPageContent {
    /// Activity, top-level parking and the next state change measured from one board revision.
    public typealias Content = (activity: DeskLiveActivityPresentation.State, parked: Set<String>, deadline: Date?)

    public static func active(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.activeItems(items)
    }

    /// Bound stuck reasons to one plain sentence; retain the complete stamped reason in the inspector.
    public static func stuckReason(_ item: DeskItem, in items: [DeskItem]) -> String {
        if let raw = item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return TodayWords.line(raw, limit: 96)
        }
        if let waiting = item.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines),
           !waiting.isEmpty {
            return "Waiting on \(TodayWords.line(waiting, limit: 60))."
        }
        let blockers = items.filter { item.blockedOn.contains($0.handle) && !$0.status.isTerminal }
        if !blockers.isEmpty {
            return "Blocked on " + blockers.map { "desk.\($0.alias)" }.joined(separator: ", ") + "."
        }
        if let note = item.notes.last?.text.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return "Last note: \(TodayWords.line(note, limit: 96))"
        }
        return "Blocked, with no reason written down."
    }

    /// Chat carries the stored reason whole, not the row’s clipped presentation.
    static func draft(about item: DeskItem) -> String {
        let reason = [item.blockedReason, item.waitingOn]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var draft = "Desk item \(item.handle): \(item.title)"
        if let reason { draft += "\n\nWhat you wrote: \(reason)" }
        return draft
    }

    static func project(snapshot loaded: DeskPageSnapshot, now presentationNow: Date) -> Content {
        let evidence = DeskMovementPresentation.evidence(loaded.agentJobs.items)
        let items = loaded.boardItems
        var parked: Set<String> = []
        var parkingExpiry: Date?
        if loaded.deskUnavailable == nil {
            let state = DeskState(items: items, generatedTs: "")
            for item in DeskBoardLayout.activeItems(items) where item.parent == nil {
                let handles = DeskParking.subtreeHandles(item.handle, in: loaded.plan.children)
                let live = loaded.agentJobs.items.contains { $0.desk.map(handles.contains) == true && !$0.state.isTerminal }
                let parking = DeskParking.parking(item, in: state, plan: loaded.plan, live: live, now: presentationNow)
                if parking.parked { parked.insert(item.handle) }
                if let boundary = parking.boundary, boundary > presentationNow {
                    parkingExpiry = min(parkingExpiry ?? boundary, boundary)
                }
            }
        }
        let lane: DeskLaneState<DeskItem> = loaded.deskUnavailable.map { .unavailable($0) } ?? .rows(items)
        let activity = DeskLiveActivityPresentation.make(deskItems: lane, jobs: loaded.agentJobs,
                                                        evidence: evidence,
                                                        generatedTs: loaded.generatedTs, now: presentationNow)
        let movementExpiry = loaded.agentJobs.items.filter { $0.state == .working }.map {
            $0.updatedAt.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let deferExpiry = items.compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }
            .filter { $0 > presentationNow }.min()
        let muteExpiry = loaded.nagConfigError == nil && loaded.nagConfig.mutedUntil != DeskNagConfig.indefiniteMuteSentinel
            ? loaded.nagConfig.mutedUntil.flatMap(DeskSequencing.parseDeferStamp) : nil
        let nowExpiry = items.filter { $0.status == .now }.compactMap {
            NativeTimestampFormat.parseOptionalISO8601FractionalFirst($0.updatedAt)?.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let deadline = [activity.nextRefreshAt, movementExpiry, deferExpiry, muteExpiry, nowExpiry, parkingExpiry]
            .compactMap { $0 }.filter { $0 > presentationNow }.min()
        return (activity, parked, deadline)
    }
}

public enum DeskPageWords {
    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]

    public static func spelledLower(_ count: Int) -> String {
        guard count >= 0 else { return String(count) }
        if (1...10).contains(count) { return TodayWords.spelledLower(count) }
        return lower(count)
    }

    private static func lower(_ count: Int) -> String {
        if count < 20 { return ones[count] }
        if count < 100 {
            let tensWord = tens[count / 10]
            return count % 10 == 0 ? tensWord : "\(tensWord)-\(ones[count % 10])"
        }
        if count < 1_000 {
            let hundreds = count / 100
            let head = hundreds == 1 ? "a hundred" : "\(ones[hundreds]) hundred"
            return count % 100 == 0 ? head : "\(head) and \(lower(count % 100))"
        }
        return String(count)
    }
}
