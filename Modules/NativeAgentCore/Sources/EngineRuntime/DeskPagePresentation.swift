import AgentConversations
import Foundation
import Cognition
import OSLog
import PersistenceCore
import StandingBots
import NativeAgentShared
import Desk
import TriggerScheduler
// Blueprint: | `DeskPagePresentation.swift` | Desk page snapshots, attention, project/deadline composition and wording from one frozen board read |
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
    public var jobs: [ScheduledJob] = []
    public var nagConfig = DeskNagConfig()
    public var nagConfigError: String?
    public var botScheduleError: String?
    public var wanderHour: DeskWanderHourPresentation.State = .absent
    public var missedBots: [DeskMissedBot] = []
    public var timedBots: [DeskTimedBot] = []
    public var botsUnavailable: String?
    public var rows: DeskPageContent.Content = ([], [], [], [], [], [], [], [], .quiet, nil)

    public static let empty = DeskPageSnapshot()
    public init() {}

    public init(read: DeskBoardRead) {
        board = read
    }
}

/// Project the newest hour trace without creating a Desk task; an uninstalled part stays absent.
public enum DeskWanderHourPresentation {
    public enum State: Sendable, Equatable {
        case absent
        /// Show the agent’s closing words without adding a verdict or progress claim.
        case line(text: String, symbol: String, at: String? = nil)
    }

    static func state(
        installed: Bool,
        entry: StudioWanderLane.TraceEntry?,
        now: Date
    ) -> State {
        guard installed, let entry else { return .absent }
        let words = entry.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .absent }
        return .line(text: bounded(words), symbol: symbol(entry.outcome), at: entry.at)
    }

    /// Use icons without ranking endings: declining has equal standing.
    static func symbol(_ outcome: StudioWanderLane.Outcome) -> String {
        switch outcome {
        case .chose: return "eye"
        case .declined: return "moon.zzz"
        case .noArtifact: return "eye.slash"
        case .stopped: return "pause.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    static let maximumCharacters = 160

    private static func bounded(_ value: String) -> String {
        value.truncated(to: maximumCharacters, keeping: maximumCharacters - 1)
    }
}

public enum DeskAttentionStrip {
    public static func sortedDeskItems(_ items: [DeskItem]) -> [DeskItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.openedAt != r.openedAt { return l.openedAt > r.openedAt }
            return l.handle < r.handle
        }
    }
}

public enum DeskPageContent {
    public typealias Content = (projects: [ProjectRow], owner: [DeskItem], blocked: [DeskItem],
        watches: [DeskItem], stale: [DeskItem], other: [DeskItem], history: [DeskItem],
        endedJobs: [AgentJob], activity: DeskLiveActivityPresentation.State, deadline: Date?)

    public static func active(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.activeItems(items)
    }

    public static func waitingOnOwner(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(active(items).filter(OwnerAttentionPolicy.waitsOnOwner))
    }

    public static func blocked(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(
            active(items)
                .filter(DeskPage.needsEyes)
                .filter { !OwnerAttentionPolicy.waitsOnOwner($0) })
    }

    public static func projects(_ items: [DeskItem], excluding shown: Set<String>) -> [DeskItem] {
        active(items)
            .filter { $0.parent == nil }
            .filter { $0.kind == .project || $0.kind == .plan }
            .filter { [.now, .next, .todo].contains($0.status) }
            .filter { !OwnerAttentionPolicy.waitsOnOwner($0) }
            .filter { !DeskPage.needsEyes($0) }
            .filter { !shown.contains($0.handle) }
    }

    public static func nextStep(
        _ item: DeskItem,
        in state: DeskState,
        plan: DeskSequencing.Plan
    ) -> DeskItem? {
        let kids = (plan.children[item.handle] ?? [])
            .filter { !$0.status.isTerminal }
            .filter { plan.byHandle[$0.handle]?.isReady ?? true }
        for status in [DeskStatus.now, .next, .todo] {
            if let hit = kids.first(where: { $0.status == status }) { return hit }
        }
        return nil
    }

    public static func watches(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.watches(active(items))
    }

    public static func freshWatches(_ items: [DeskItem], now: Date) -> [DeskItem] {
        let quiet = Set(staleWatches(items, now: now).map(\.handle))
        return watches(items).filter { !quiet.contains($0.handle) }
    }

    public static func staleWatches(_ items: [DeskItem], now: Date) -> [DeskItem] {
        watches(items).filter { item in
            guard item.status != .blocked, item.status != .flag else { return false }
            guard let at = DeskPage.parseTimestamp(item.updatedAt) else { return false }
            let age = now.timeIntervalSince(at)
            return age.isFinite && age / 86_400 >= Double(DeskPage.staleThresholdDays)
        }
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

    public static func spelled(_ count: Int) -> String {
        if (1...10).contains(count) { return TodayWords.spelled(count) }
        return TodayWords.capitalizedFirst(spelledLower(count))
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

    public static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }
}

public extension DeskPageContent {
    // MARK: projects

    /// Derive the project sentence from the rendered sequencing plan so words and board cannot disagree.
    static func projectLine(_ item: DeskItem, in state: DeskState, plan: DeskSequencing.Plan) -> String {
        let itemPlan = plan.byHandle[item.handle]
        if let blockers = itemPlan?.effectiveBlockers, !blockers.isEmpty {
            let named = blockers.compactMap { handle in
                state.items.first { $0.handle == handle }?.title
            }
            if let first = named.first {
                let more = named.count - 1
                return "Held by \(TodayWords.line(first, limit: 70))"
                    + (more > 0 ? " and \(DeskPageWords.spelledLower(more)) more." : ".")
            }
        }
        if let next = nextStep(item, in: state, plan: plan) {
            return "Next: \(TodayWords.line(next.title, limit: 80))."
        }
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return TodayWords.line(summary, limit: 96)
        }
        return "No next step written down yet."
    }

    /// Bound stuck reasons to one plain sentence; retain the complete stamped reason in the inspector.
    static func stuckReason(_ item: DeskItem, in items: [DeskItem]) -> String {
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

    static func itemDetail(_ item: DeskItem, in items: [DeskItem]) -> String {
        if item.status == .blocked { return stuckReason(item, in: items) }
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return TodayWords.line(summary, limit: 96)
        }
        if item.status == .flag { return "Flagged for a second look." }
        return item.status.displayLabel.capitalized
    }

    static func title(_ item: DeskItem) -> String {
        let named = TodayWords.line(item.title, limit: 110)
        return named.isEmpty ? item.handle : named
    }

    // MARK: Schedule

    /// Count enabled jobs and scheduled unpaused helpers; missed occurrences need their own count because neither running nor paused describes them.
    static func scheduleHeadline(_ jobs: [ScheduledJob], missed: Int = 0, bots: Int = 0) -> String {
        guard missed >= 0, bots >= 0 else { return "Timer count unavailable" }
        let paused = jobs.count - jobs.filter(\.enabled).count
        let (running, overflow) = (jobs.count - paused).addingReportingOverflow(bots)
        guard !overflow else { return "Timer count unavailable" }
        var tail = paused > 0 ? ", \(DeskPageWords.spelledLower(paused)) paused" : ""
        if missed > 0 { tail += ", \(DeskPageWords.spelledLower(missed)) missed" }
        if running == 0 {
            guard paused > 0 || missed > 0 else { return "Nothing runs on a timer" }
            return "Nothing runs on a timer" + tail
        }
        return "\(DeskPageWords.spelled(running)) "
            + "\(DeskPageWords.plural(running, "thing runs", "things run")) on a timer" + tail
    }

    static func scheduleLine(_ job: ScheduledJob) -> String {
        if let once = job.onceScheduleDescription {
            return job.enabled ? once : "\(once) Paused."
        }
        guard job.enabled else { return "Paused." }
        guard let seconds = job.intervalSeconds, seconds > 0 else { return "On its own schedule." }
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 1 ? "Once a day." : "Every \(DeskPageWords.spelledLower(days)) days."
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return hours == 1 ? "Every hour." : "Every \(DeskPageWords.spelledLower(hours)) hours."
        }
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "Every minute." : "Every \(DeskPageWords.spelledLower(minutes)) minutes."
    }
}

public extension DeskPageContent {
    struct ProjectRow: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let line: String
        public let meta: String
        /// A plan’s progress bar replaces `meta` when counts exist.
        public var done: Int? = nil
        public var total: Int? = nil
        public let draft: String
        /// Park plans untouched for two weeks, or zero-progress plans untouched for one week, so live work remains visible.
        public var parked = false
    }

    private static func detail(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func computeProjectRows(snapshot: DeskPageSnapshot, evidence: [String: DeskExecutionEvidence], now: Date) -> (rows: [ProjectRow],
        parkingExpiry: Date?) {
        guard snapshot.deskUnavailable == nil else { return ([], nil) }
        let state = DeskState(items: snapshot.boardItems, generatedTs: "")
        let plan = snapshot.plan
        let familyParents = snapshot.agentJobs.unavailableReason == nil ? DeskProgramFamilyPresentation.workingParentIDs(
            from: state.items, evidence: evidence, now: now) : []
        var parkingExpiry: Date?
        let rows = projects(state.items, excluding: familyParents).map { item in
            let handles = DeskParking.subtreeHandles(item.handle, in: plan.children)
            let live = snapshot.agentJobs.items.filter {
                $0.desk.map(handles.contains) == true && !$0.state.isTerminal
            }.sorted { $0.updatedAt > $1.updatedAt }.first
            let parking = DeskParking.parking(item, in: state, plan: plan, live: live != nil, now: now)
            if let boundary = parking.boundary, boundary > now {
                parkingExpiry = min(parkingExpiry ?? boundary, boundary)
            }
            let activity = DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now).label
            var meta = Self.detail(activity, DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
            var counts: (done: Int, total: Int)?
            if let live {
                meta = DeskActivityState.execution(DeskMovementPresentation.evidence(of: live), now: now).label
            } else if let itemPlan = plan.byHandle[item.handle], itemPlan.totalCount > 0 {
                meta = Self.detail(activity, "\(itemPlan.doneCount) of \(itemPlan.totalCount) done")
                counts = (itemPlan.doneCount, itemPlan.totalCount)
            }
            // Share the home’s Parked rule through `DeskParking`.
            return ProjectRow(
                id: item.handle,
                title: DeskPageContent.title(item),
                line: DeskPageContent.projectLine(item, in: state, plan: plan),
                meta: meta,
                done: counts?.done,
                total: counts?.total,
                draft: draft(about: item),
                parked: parking.parked)
        }
        return (rows, parkingExpiry)
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

    static func project(
        snapshot loaded: DeskPageSnapshot, now presentationNow: Date,
        nags loadedNags: DeskNagConfig, timedBots timedSnapshot: [DeskTimedBot],
        jobStamps: [String], hourExpiry: Date?
    ) -> Content {
        let evidence = DeskMovementPresentation.evidence(loaded.agentJobs.items)
        let (projects, parkingExpiry) = computeProjectRows(snapshot: loaded, evidence: evidence, now: presentationNow)
        let items = loaded.boardItems
        let owner = DeskPageContent.waitingOnOwner(items)
        let blocked = DeskPageContent.blocked(items)
        let watches = DeskPageContent.freshWatches(items, now: presentationNow)
        let stale = DeskPageContent.staleWatches(items, now: presentationNow)
        let shown = Set((owner + blocked + watches + stale).map(\.handle) + projects.map(\.id))
        let other = DeskAttentionStrip.sortedDeskItems(DeskPageContent.active(items).filter { !shown.contains($0.handle) })
        let history = DeskAttentionStrip.sortedDeskItems(items.filter { $0.status.isTerminal })
        let endedJobs = loaded.agentJobs.items.filter { $0.state.isTerminal }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let lane: DeskLaneState<DeskItem> = loaded.deskUnavailable.map { .unavailable($0) } ?? .rows(items)
        let activity = DeskLiveActivityPresentation.make(deskItems: lane, jobs: loaded.agentJobs,
                                                        evidence: evidence,
                                                        generatedTs: loaded.generatedTs, now: presentationNow)
        let movementExpiry = loaded.agentJobs.items.filter { $0.state == .working }.map {
            $0.updatedAt.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let watchExpiry = DeskPageContent.watches(items).compactMap {
            UserDisplayFormatters.parseISOTimestamp($0.updatedAt)?.addingTimeInterval(
                Double(DeskPage.staleThresholdDays) * 86_400)
        }.filter { $0 > presentationNow }.min()
        let deferExpiry = items.compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }
            .filter { $0 > presentationNow }.min()
        let muteExpiry = loadedNags.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
            ? nil : loadedNags.mutedUntil.flatMap(DeskSequencing.parseDeferStamp)
        let nowExpiry = items.filter { $0.status == .now }.compactMap {
            DeskActivityState.movementDate($0.updatedAt)?.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let relativeStamps = items.map(\.updatedAt)
            + items.compactMap { $0.pursuit?.lastWorkedAt }
            + loaded.agentJobs.items.map { NativeTimestampFormat.fractionalZulu($0.updatedAt) }
            + jobStamps
            + [loaded.generatedTs].compactMap { $0 }
        let relativeDates = relativeStamps.compactMap(UserDisplayFormatters.parseISOTimestamp)
            + timedSnapshot.compactMap(\.nextRun)
        let relativeExpiry = relativeDates.map {
            DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: presentationNow)
        }.min()
        let dayExpiry = history.isEmpty ? nil : Calendar.current.dateInterval(of: .day, for: presentationNow)?.end
        let deadline = [activity.nextRefreshAt, movementExpiry, watchExpiry, deferExpiry, muteExpiry,
                        nowExpiry, parkingExpiry, relativeExpiry, hourExpiry, dayExpiry]
            .compactMap { $0 }.filter { $0 > presentationNow }.min()
        return (projects, owner, blocked, watches, stale, other, history, endedJobs, activity, deadline)
    }
}
