import Foundation
import OSLog
import ChatOrchestration
import PersistenceCore
import StandingBots
import NativeAgentShared
import Desk
import GitHubConnector
import TriggerScheduler
import WorkshopExecution
public enum DeskLaneState<Row: Sendable>: Sendable {
    case unavailable(String)
    case rows([Row])

    public static var maxReasonChars: Int { 240 }

    /// Every failure notice on the Desk uses this cap. Keeping the truncation
    /// at the state boundary makes an unreadable store visible without letting
    /// an untrusted error string take over the board.
    public static func boundedReason(_ reason: String) -> String {
        String(reason.prefix(maxReasonChars))
    }

    public var items: [Row] {
        if case .rows(let rows) = self { return rows }
        return []
    }

    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// A throwing read: the error text IS the reason, bounded.
    public static func failed(_ error: any Error) -> DeskLaneState {
        .unavailable(boundedReason("\(error)"))
    }
}

extension DeskLaneState where Row == WorkshopExecutionRecord {
    public static func classify(rows: [WorkshopExecutionRecord], root: URL) -> DeskLaneState {
        if let failure = rows.first(where: { $0.id == "queue-unavailable" && $0.status == "unavailable" }),
           case .object(let result) = failure.result, case .string(let detail)? = result["error"] {
            var isDirectory: ObjCBool = false
            let reason = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                ? "execution root is not a directory" : detail
            return .unavailable(boundedReason("Couldn't read the execution record(s) store — \(reason)"))
        }
        return .rows(rows)
    }
}

public enum DeskGitHubWaitingRollup {
    public static let toggleKey = "gh:waiting-upstream"
    private static let palettePrefix = "ghwait:"

    public static func paletteRows(in items: [GitHubCommandItem]) -> [DeskPaletteRow] {
        items.compactMap { item in
            guard case .waitingUpstream = item.state else { return nil }
            return DeskPaletteRow(
                handle: paletteHandle(for: item),
                alias: "GH",
                title: item.title.isEmpty ? "\(item.repository) #\(item.number)" : item.title,
                project: item.repository,
                status: "waiting upstream",
                isActionable: false
            )
        }
    }

    public static func paletteHandle(for item: GitHubCommandItem) -> String {
        palettePrefix + item.itemId
    }

    public static func isPaletteHandle(_ handle: String) -> Bool {
        handle.hasPrefix(palettePrefix)
    }

    /// Produces the sole expansion key for a currently persisted waiting row.
    /// A stale palette result, an arbitrary string, or a row whose watcher
    /// state advanced since the palette opened must not expand anything.
    public static func revealKeys(
        forPaletteHandle handle: String,
        in items: [GitHubCommandItem]
    ) -> [String] {
        guard let item = items.first(where: { paletteHandle(for: $0) == handle }),
              case .waitingUpstream = item.state
        else { return [] }
        return [toggleKey]
    }
}

public enum DeskMovementPresentation {
    public static func evidence(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> [String: DeskExecutionEvidence] {
        Dictionary(grouping: executions.filter { $0.deskHandle != nil }, by: { $0.deskHandle! })
            .compactMapValues { rows in
                rows.max { $0.updatedAt < $1.updatedAt }.map {
                    DeskExecutionEvidence(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt)
                }
            }
    }

    public static func activity(_ item: DeskItem, evidence: DeskExecutionEvidence?, now: Date) -> DeskActivityState {
        DeskActivityState.item(status: item.status.rawValue, kind: item.kind.rawValue,
            deferred: item.deferUntil != nil, updatedAt: item.updatedAt, evidence: evidence, now: now)
    }
}

public enum DeskLiveActivityPresentation {
    public static let defaultActiveWindow: TimeInterval = DeskActivityState.movementWindow
    public static let staleAfter: TimeInterval = 5 * 60
    public static let visibleRowCap = 4
    private static let boundaryEpsilon: TimeInterval = 0.001

    public struct Row: Identifiable, Sendable, Equatable {
        public let item: DeskItem
        public let updatedAt: Date
        public let now: Date
        public var id: String { item.handle }
        public var summary: String {
            let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary, !summary.isEmpty { return summary }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Untitled desk item" : title
        }
        public var assignee: String {
            let trimmed = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return "Unassigned" }
            return trimmed
        }
        public var lastUpdateText: String { "last update \(DeskRelativeTimePresentation.text(for: updatedAt, now: now))" }
        public var progress: DeskProgress? { item.progress }
    }

    public struct Content: Sendable, Equatable {
        public let rows: [Row]
        public let overflowCount: Int
        public let generatedAt: Date
        public let now: Date
        public let isStale: Bool
        public var asOfText: String { "as of \(DeskRelativeTimePresentation.text(for: generatedAt, now: now))" }
        /// The next semantic boundary only: snapshot becomes stale or one
        /// active row ages out. DeskLiveReloader sleeps to this exact instant;
        /// there is no periodic freshness timer.
        public let nextRefreshAt: Date?

        /// Every row eligible for this section, including the deterministic
        /// overflow disclosed by "+N more". This is never a hidden store total.
    }

    public enum State: Sendable, Equatable {
        case unavailable(String)
        case quiet
        case rows(Content)

        public var nextRefreshAt: Date? {
            guard case .rows(let content) = self else { return nil }
            return content.nextRefreshAt
        }
    }

    public static func make(
        deskItems: DeskLaneState<DeskItem>,
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>,
        generatedTs: String?,
        now: Date,
        activeWindow: TimeInterval = defaultActiveWindow,
        rowCap: Int = visibleRowCap,
        staleLimit: TimeInterval = staleAfter
    ) -> State {
        if let reason = deskItems.unavailableReason {
            return .unavailable(reason)
        }
        if let reason = executions.unavailableReason {
            return .unavailable(reason)
        }

        let window = max(0, activeWindow)
        let evidence = DeskMovementPresentation.evidence(executions.items)
        let candidates = deskItems.items.compactMap { item -> (DeskItem, Date)? in
            guard !item.requiresOwnerInput,
                  DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now) == .working,
                  let updated = DeskActivityState.movementDate(evidence[item.handle]?.lastMovementAt)
            else { return nil }
            guard max(0, now.timeIntervalSince(updated)) <= window else { return nil }
            return (item, updated)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            if left.0.updatedAt != right.0.updatedAt {
                return left.0.updatedAt > right.0.updatedAt
            }
            return left.0.handle < right.0.handle
        }

        // Blank slate and ordinary quiet state collapse completely, including
        // a blank generatedTs from an empty canonical feed.
        guard !candidates.isEmpty else { return .quiet }

        guard let generatedTs,
              let generatedAt = DeskProjection.parseTimestamp(generatedTs)
        else {
            return .unavailable("The Desk snapshot has no readable generated timestamp.")
        }

        let limit = max(0, staleLimit)
        let snapshotAge = max(0, now.timeIntervalSince(generatedAt))
        let stale = snapshotAge > limit
        let cap = max(0, rowCap)
        let visible = candidates.prefix(cap).map { item, updated in
            Row(item: item, updatedAt: updated, now: now)
        }

        var boundaries = candidates.compactMap { _, updated -> Date? in
            let expiry = updated.addingTimeInterval(window + boundaryEpsilon)
            return expiry > now ? expiry : nil
        }
        if !stale {
            let staleBoundary = generatedAt.addingTimeInterval(limit + boundaryEpsilon)
            if staleBoundary > now { boundaries.append(staleBoundary) }
        }

        return .rows(Content(
            rows: visible,
            overflowCount: max(0, candidates.count - visible.count),
            generatedAt: generatedAt,
            now: now,
            isStale: stale,
            nextRefreshAt: boundaries.min()
        ))
    }

}

public enum DeskProgramFamilyPresentation {
    public struct Lane: Identifiable, Sendable, Equatable {
        public let item: DeskItem
        public var id: String { item.handle }
        public var status: DeskStatus { item.status }
    }

    public struct Family: Identifiable, Sendable, Equatable {
        public let parent: DeskItem
        public let lanes: [Lane]
        fileprivate let newestUpdate: Date?
        public var id: String { parent.handle }
    }

    public static func families(from deskItems: DeskLaneState<DeskItem>, executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord>, now: Date) -> [Family] {
        guard deskItems.unavailableReason == nil, executions.unavailableReason == nil else { return [] }
        return families(from: deskItems.items, executions: executions.items, now: now)
    }

    public static func families(from items: [DeskItem], executions: [WorkshopExecution.WorkshopExecutionRecord], now: Date) -> [Family] {
        let evidence = DeskMovementPresentation.evidence(executions)
        // A canonical store cannot produce duplicate handles, but this is a UI
        // projection over durable bytes: retaining the first row is safer than
        // trapping if a damaged/manual fixture reaches the presentation seam.
        let byHandle = items.reduce(into: [String: DeskItem]()) { result, item in
            if result[item.handle] == nil { result[item.handle] = item }
        }
        var lanesByParent: [String: [DeskItem]] = [:]
        for item in items {
            guard let raw = item.laneOf?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw != item.handle,
                  byHandle[raw] != nil
            else { continue }
            lanesByParent[raw, default: []].append(item)
        }

        return items.compactMap { parent -> Family? in
            guard let lanes = lanesByParent[parent.handle], !lanes.isEmpty,
                  ([parent] + lanes).contains(where: {
                      !$0.requiresOwnerInput && DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now) == .working
                  })
            else { return nil }
            let newest = ([parent] + lanes)
                .compactMap { DeskProjection.parseTimestamp($0.updatedAt) }
                .max()
            return Family(parent: parent, lanes: lanes.map { Lane(item: $0) }, newestUpdate: newest)
        }.sorted { left, right in
            if left.newestUpdate != right.newestUpdate {
                return (left.newestUpdate ?? .distantPast) > (right.newestUpdate ?? .distantPast)
            }
            return left.id < right.id
        }
    }
}

public enum DeskExecutionPresentation {
    public struct Slice: Sendable, Equatable {
        public let benchIDs: [String]
        public let approvalIDs: [String]
        public let recentDoneIDs: [String]
    }
    private static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled"]
    public static func slice(_ executions: [WorkshopExecution.WorkshopExecutionRecord]) -> Slice {
        let approval = executions.filter { $0.status == "blocked_on_approval" }
        let bench = executions.filter {
            $0.status != "blocked_on_approval" && !terminalStatuses.contains($0.status)
        }
        let recent = Array(executions
            .filter { terminalStatuses.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt })
        return Slice(
            benchIDs: bench.map(\.id),
            approvalIDs: approval.map(\.id),
            recentDoneIDs: recent.map(\.id))
    }
}

public struct DeskPageSnapshot: Sendable {
    public var loaded = false
    public var items: [DeskItem] = []
    public var deskUnavailable: String?
    public var generatedTs: String?
    public var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    public var github: DeskLaneState<GitHubCommandItem> = .rows([])
    /// The same derived sequencing the projection renders (blockers, held
    /// rows, subtree rollups). Computed ONCE per read, off the main actor,
    /// because the projects lane asks it a question per row and `body` runs
    /// far more often than the board changes.
    public var plan = DeskSequencing.Plan()
    public var overview: WorkOverview?

    public static let empty = DeskPageSnapshot()

    /// One canonical board read, with sequencing derived from those same items.
    public static func load(desk: DeskFacade) async -> DeskPageSnapshot {
        let read = await desk.loadBoard(includeOverview: true)
        var snapshot = DeskPageSnapshot()
        snapshot.loaded = true
        // Her MY QUEUE is hers, not a row on his board.
        snapshot.items = read.items.filter { $0.project != MyQueue.project }
        snapshot.deskUnavailable = read.deskError
        snapshot.generatedTs = read.deskState?.generatedTs
        snapshot.executions = read.executions
        snapshot.overview = read.overview
        snapshot.github = read.github
        snapshot.plan = DeskSequencing.compute(
            DeskState(items: snapshot.items, generatedTs: ""))
        return snapshot
    }
}

public enum DeskAttentionStrip {
    public static func sortedGitHubItems(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.createdAt != r.createdAt { return l.createdAt > r.createdAt }
            return l.itemId < r.itemId
        }
    }

    public static func sortedDeskItems(_ items: [DeskItem]) -> [DeskItem] {
        items.sorted { l, r in
            if l.updatedAt != r.updatedAt { return l.updatedAt > r.updatedAt }
            if l.openedAt != r.openedAt { return l.openedAt > r.openedAt }
            return l.handle < r.handle
        }
    }

}

public enum DeskGitHubBucket: String, CaseIterable, Sendable {
    case actionNeeded = "Action needed"
    case legacyWork = "Finishing prior work"
    case needsOwner = "Needs you"
    case waiting = "Waiting upstream"
    case attention = "Attention"
    case resolved = "Recently resolved"

    public static func bucket(for state: GitHubCommandItemState) -> Self {
        switch state {
        case .detected, .needsCodex: return .actionNeeded
        case .codexWorking, .verifying: return .legacyWork
        case .needsOwner: return .needsOwner
        case .waitingUpstream: return .waiting
        case .attention: return .attention
        case .resolved: return .resolved
        }
    }

}

public enum DeskPageContent {
    public static func active(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.activeItems(items)
    }

    public static func waitingOnOwner(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(active(items).filter(OwnerAttentionPolicy.waitsOnOwner))
    }

    public static func blocked(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(
            active(items)
                .filter(DeskProjection.needsEyes)
                .filter { !OwnerAttentionPolicy.waitsOnOwner($0) })
    }

    public static func projects(_ items: [DeskItem], excluding shown: Set<String>) -> [DeskItem] {
        active(items)
            .filter { $0.parent == nil }
            .filter { $0.kind == .project || $0.kind == .plan }
            .filter { [.now, .next, .todo].contains($0.status) }
            .filter { !OwnerAttentionPolicy.waitsOnOwner($0) }
            .filter { !DeskProjection.needsEyes($0) }
            .filter { !shown.contains($0.handle) }
    }

    public static func nextStep(
        _ item: DeskItem,
        in state: DeskState,
        plan: DeskSequencing.Plan
    ) -> DeskItem? {
        let kids = state.children(of: item.handle)
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
            guard let at = DeskProjection.parseTimestamp(item.updatedAt) else { return false }
            return Int(now.timeIntervalSince(at) / 86_400) >= DeskProjection.staleThresholdDays
        }
    }

    public static func githubNeedingAHand(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .actionNeeded })
    }

    public static func githubNeedsOwner(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .needsOwner })
    }

    public static func githubAttention(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .attention })
    }

    public static func githubRest(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        let claimed = Set(
            (githubNeedingAHand(items) + githubNeedsOwner(items) + githubAttention(items)).map(\.itemId))
        return DeskAttentionStrip.sortedGitHubItems(items.filter { !claimed.contains($0.itemId) })
    }
}

extension DeskPageContent {
    public static func projectRows(_ snapshot: DeskPageSnapshot, now: Date) -> [(
        item: DeskItem, execution: WorkshopExecutionRecord?, activity: DeskActivityState, parked: Bool
    )] {
        guard snapshot.deskUnavailable == nil else { return [] }
        let state = DeskState(items: snapshot.items, generatedTs: "")
        let evidence = DeskMovementPresentation.evidence(snapshot.executions.items)
        let familyParents = Set(DeskProgramFamilyPresentation.families(
            from: DeskLaneState.rows(snapshot.items), executions: snapshot.executions, now: now).map(\.id))
        return projects(snapshot.items, excluding: familyParents).map { item in
            let handles = DeskParking.subtreeHandles(item.handle, in: state)
            let live = snapshot.executions.items
                .filter { $0.deskHandle.map(handles.contains) ?? false }
                .filter { DeskParking.executionIsLive(status: $0.status) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
            return (item, live,
                DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now),
                DeskParking.isParked(item, in: state, plan: snapshot.plan, live: live != nil, now: now))
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

    /// Mid-sentence: "twenty-one", "a hundred and twenty-one".
    public static func spelledLower(_ count: Int) -> String {
        guard count >= 0 else { return String(count) }
        if (1...10).contains(count) { return TodayWords.spelledLower(count) }
        return lower(count)
    }

    /// Sentence-leading: "Twenty-one".
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

    /// "a hundred and five" is right after "I'm watching" and wrong after "the
    /// other". The article goes when a determiner already leads the phrase.
    public static func withoutArticle(_ words: String) -> String {
        words.hasPrefix("a ") ? String(words.dropFirst(2)) : words
    }
}

public extension DeskPageContent {

    // MARK: projects

    /// One sentence about where a project actually stands: what is holding it,
    /// or what comes next, or — when the board says nothing — that nothing is
    /// named. Derived from the same sequencing plan the projection renders, so
    /// this line and the desk text cannot disagree.
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

    /// One plain sentence for why a row is stuck. The inspector keeps the
    /// whole stamped reason on every row, which is how twenty-one items became
    /// a wall of the same paragraph; this cuts at a word boundary and never
    /// carries markdown. Without a written reason, the open items it waits on
    /// or its latest note say why before "no reason" does.
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

    // MARK: GitHub

    /// The remainder fold holds everything the three attention groups did not
    /// claim: work in progress, work waiting upstream, and work already closed.
    /// Closed work is finished, not moving, and waiting is not movement either,
    /// so the title counts what the fold actually holds.
    static func githubRestTitle(_ rest: [GitHubCommandItem]) -> String {
        let closed = rest.filter { DeskGitHubBucket.bucket(for: $0.state) == .resolved }.count
        let open = rest.count - closed
        let others = rest.count == 1
            ? "The other one"
            : "The other \(DeskPageWords.withoutArticle(DeskPageWords.spelledLower(rest.count)))"
        let verb = rest.count == 1 ? "is" : "are"
        if open == 0 { return "\(others) \(verb) closed" }
        if closed == 0 { return "\(others) \(verb) open, none needing a hand" }
        return "\(others): \(DeskPageWords.spelledLower(open)) still open, "
            + "\(DeskPageWords.spelledLower(closed)) closed"
    }

    /// "a hundred and twenty-one pull requests, sixteen need a hand". The noun
    /// tells the truth about the mix: the watcher tracks issues too.
    static func githubHeadline(_ items: [GitHubCommandItem]) -> String {
        let total = items.count
        let hands = githubNeedingAHand(items).count + githubNeedsOwner(items).count
            + githubAttention(items).count
        let allPRs = items.allSatisfy { $0.kind == .pullRequest }
        let noun: String
        if allPRs {
            noun = DeskPageWords.plural(total, "pull request", "pull requests")
        } else {
            noun = "pull requests and issues"
        }
        let head = "I'm watching \(DeskPageWords.spelledLower(total)) \(noun)"
        guard hands > 0 else { return head + ", none of them need a hand" }
        return "\(head), \(DeskPageWords.spelledLower(hands)) need\(hands == 1 ? "s" : "") a hand"
    }

    static func githubTitle(_ item: GitHubCommandItem) -> String {
        let named = TodayWords.line(item.title, limit: 110)
        return named.isEmpty ? "\(item.repository) #\(item.number)" : named
    }

    /// repo · number · state-as-a-word · when. No pill, no colour.

    // MARK: Schedule

    /// Only enabled jobs run. The rows beneath this headline already say
    /// "Paused." for the rest, so counting every saved record made the fold
    /// contradict its own contents.
    /// A missed occurrence is neither running nor paused, so it is counted on
    /// its own: nothing ran, and the page says so instead of staying silent.
    /// `bots` is the unpaused bots on a schedule; each one runs on a timer too.
    static func scheduleHeadline(_ jobs: [ScheduledJob], missed: Int = 0, bots: Int = 0) -> String {
        let paused = jobs.count - jobs.filter(\.enabled).count
        let running = jobs.count - paused + bots
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

@MainActor
public final class WorkStatusPublication {
    private var widgetContainerUnavailableLogged = false
    private var workStatusInFlight = false
    private var workStatusDirty = false
    public init() {}

    /// One read of the overview sets the one "needs you" count, runs the
    /// needs-you push and feeds the widget. Desk writes, refreshes and turn
    /// activity publish changes without polling.
    public func publishWorkStatus(engine: NativeAgentEngine, displayName: @MainActor () -> String,
                                  publishAttention: @MainActor (Int?, [WorkOverviewReference.Kind: Int]?) -> Void,
                                  reloadWidget: @escaping @Sendable () -> Void) async {
        guard !workStatusInFlight else { workStatusDirty = true; return }
        workStatusInFlight = true
        defer { workStatusInFlight = false }
        repeat {
            workStatusDirty = false
            let board = await engine.desk.loadBoard(includeOverview: true)
            let overview = board.overview!
            let waiting = overview.unavailable.isEmpty ? overview.needsYouCount : nil
            publishAttention(waiting, overview.unavailable.isEmpty && overview.omittedNeedsYou == 0
                ? Dictionary(grouping: overview.needsYou, by: \.reference.kind).mapValues(\.count) : nil)
            if let items = board.deskState?.items { await engine.deviceSync?.evaluateNeedsUser(items: items) }
            if #available(macOS 27, *) { await publishWidgetStatus(board, engine: engine, name: displayName(), waiting: waiting, reload: reloadWidget) }
        } while workStatusDirty
    }

    @available(macOS 27, *)
    private func publishWidgetStatus(_ board: DeskBoardRead, engine: NativeAgentEngine, name: String,
                                     waiting: Int?, reload: @escaping @Sendable () -> Void) async {
        guard !widgetContainerUnavailableLogged else { return }
        let busy = engine.turns.visiblyWorkingSessionIDs
        let replying = engine.turns.replyingSessions
        let movements = Dictionary(uniqueKeysWithValues: busy.compactMap { id in
            engine.turns.lifecycle(for: id).map { (id, $0.presentation) }
        })
        let containerUnavailable = await Task.detached(priority: .utility) { () -> Bool in
            let url: URL
            do {
                url = try NativeAgentWidgetSnapshot.fileURL()
            } catch {
                Logger(subsystem: "NativeAgent", category: "Widget").notice("Widget status disabled: App Group container unavailable")
                return true
            }
            let status: String
            var activityExpiresAt: Date?
            if let count = waiting {
                let desk = board.items
                let executions = board.executions
                let now = Date()
                let active = busy.filter { id in
                    guard let movement = movements[id],
                          [.working, .tool, .delegation, .retrying].contains(movement.phase) else { return false }
                    return movement.lastMovementAt <= now && now.timeIntervalSince(movement.lastMovementAt) < DeskActivityState.movementWindow
                }
                let evidence = DeskMovementPresentation.evidence(executions.items)
                // Each item's activity once, and only if the chain below gets that
                // far; it was re-derived for every item in each of six passes.
                lazy var activities = desk.map { ($0, DeskMovementPresentation.activity($0, evidence: evidence[$0.handle], now: now)) }
                let work = executions.items.filter({
                    DeskActivityState.execution(.init(deskHandle: $0.deskHandle, status: $0.status, updatedAt: $0.updatedAt, lastMovementAt: $0.lastMovementAt), now: now) == .working
                }).max(by: { ($0.lastMovementAt ?? "") < ($1.lastMovementAt ?? "") })
                if let latest = active.compactMap({ id -> (id: String, movement: Date)? in
                    guard let movement = movements[id]?.lastMovementAt else { return nil }
                    return (id, movement)
                }).max(by: { $0.movement < $1.movement }),
                   latest.movement >= (DeskActivityState.movementDate(work?.lastMovementAt) ?? .distantPast) {
                    status = replying.contains(latest.id) ? "Replying…" : "Thinking…"
                    activityExpiresAt = latest.movement.addingTimeInterval(DeskActivityState.movementWindow)
                } else if count > 0 {
                    status = "Waiting on you"
                } else if let work {
                    status = "Working on \(work.title)"
                    activityExpiresAt = DeskActivityState.movementDate(work.lastMovementAt)?.addingTimeInterval(DeskActivityState.movementWindow)
                } else if !busy.isEmpty {
                    status = "Activity unconfirmed"
                } else if activities.contains(where: { $0.1 == .stale }) {
                    status = "Stale work — activity unconfirmed"
                } else if activities.contains(where: { !$0.0.status.isTerminal && $0.1 == .unknown }) {
                    status = "Activity unknown"
                } else if activities.contains(where: { $0.1 == .queued }) {
                    status = "Work queued"
                } else if activities.contains(where: { $0.1 == .watching }) {
                    status = "Watching"
                } else if activities.contains(where: { $0.1 == .deferred }) {
                    status = "Work deferred"
                } else if activities.contains(where: { $0.1 == .blocked }) {
                    status = "Work blocked"
                } else {
                    status = "Activity unknown"
                }
            } else {
                status = "Status unavailable"
            }
            do {
                let snapshot = NativeAgentWidgetSnapshot(
                    name: name, status: status, waitingCount: waiting, updatedAt: Date(), activityExpiresAt: activityExpiresAt
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        let previous = try NativeAgentWidgetSnapshot.read()
                        if previous.name == snapshot.name, previous.status == status, previous.waitingCount == waiting,
                           previous.activityExpiresAt == activityExpiresAt {
                            return false
                        }
                    } catch {
                        // This projection is disposable; repair it from the checked owners.
                        Logger(subsystem: "NativeAgent", category: "Widget").error("Replacing unreadable status projection: \(error.localizedDescription, privacy: .public)")
                    }
                }
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                reload()
            } catch {
                Logger(subsystem: "NativeAgent", category: "Widget").error("Status publication failed: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }.value
        if containerUnavailable { widgetContainerUnavailableLogged = true }
    }
}
public enum DeskPresentationTone: Sendable, Equatable {
    case neutral
    case info
    case success
    case warning
    case danger
}

/// Shared relative-time vocabulary for every timestamp rendered on Desk rows.
/// Callers provide the frozen presentation clock, which keeps tests and exact
/// freshness boundaries deterministic without introducing a timer.
public enum DeskRelativeTimePresentation {
    public static func text(forISO raw: String, now: Date) -> String {
        guard let date = UserDisplayFormatters.parseISOTimestamp(raw) else {
            return "unknown"
        }
        return text(for: date, now: now)
    }

    public static func text(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 {
            let remaining = -seconds
            switch remaining {
            case ..<60: return "in less than a minute"
            case ..<3_600: return "in \(Int(ceil(remaining / 60)))m"
            case ..<86_400: return "in \(Int(ceil(remaining / 3_600)))h"
            default: return "in \(Int(ceil(remaining / 86_400)))d"
            }
        }
        switch seconds {
        case ..<90: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    /// The next change in this vocabulary, rather than a periodic clock tick.
    public static func nextRefreshAt(for date: Date, now: Date) -> Date {
        let remaining = date.timeIntervalSince(now)
        if remaining > 0 {
            let unit: TimeInterval
            switch remaining {
            case ..<60: return date
            case ..<3_600: unit = 60
            case ..<86_400: unit = 3_600
            default: unit = 86_400
            }
            let boundary = max(unit, (ceil(remaining / unit) - 1) * unit)
            return date.addingTimeInterval(-boundary + 0.001)
        }
        let seconds = max(0, now.timeIntervalSince(date))
        let boundary: TimeInterval
        switch seconds {
        case ..<90: boundary = 90
        case ..<3_600: boundary = (floor(seconds / 60) + 1) * 60
        case ..<86_400: boundary = (floor(seconds / 3_600) + 1) * 3_600
        default: boundary = (floor(seconds / 86_400) + 1) * 86_400
        }
        return date.addingTimeInterval(boundary)
    }
}

public enum DeskItemPresentation {
    public struct BlockedPill: Sendable, Equatable {
        public let text: String
        public let targetHandle: String
    }

    public static func blockedPill(
        plan: DeskSequencing.ItemPlan,
        aliases: [String: String],
        cap: Int = 3
    ) -> BlockedPill? {
        let resolved = plan.effectiveBlockers.compactMap { handle in
            aliases[handle].map { (handle: handle, alias: $0) }
        }
        guard let first = resolved.first else { return nil }
        let shown = resolved.prefix(max(cap, 1)).map(\.alias).joined(separator: ", ")
        let overflow = resolved.count - min(resolved.count, max(cap, 1))
        return BlockedPill(
            text: "waiting on \(shown)" + (overflow > 0 ? " +\(overflow)" : ""),
            targetHandle: first.handle)
    }

    public static func nagBellSymbol(config: DeskNagConfig, now: Date) -> String {
        if config.isMuted(now: now) { return "bell.slash" }
        return config.enabled ? "bell.fill" : "bell"
    }

    /// The whole-board store failure is rendered next to lane failures, so it
    /// shares their precise bounded-error contract instead of creating a second
    /// arbitrary limit at the top of the Desk.
    public struct Freshness: Sendable, Equatable {
        public let text: String
        public let isStale: Bool
        public let isKnown: Bool
    }

    /// The row's timestamp claim. A malformed timestamp is unknown, never
    /// fresh; blocked and flagged rows retain a plain age because their status
    /// already carries the urgent signal.
    public static func freshness(for item: DeskItem, now: Date) -> Freshness {
        let facts = DeskProjection.freshness(item, now: now)
        guard let date = facts.date else {
            return Freshness(text: "unknown", isStale: false, isKnown: false)
        }
        let plain = DeskRelativeTimePresentation.text(for: date, now: now)
        return Freshness(text: facts.isStale ? "\(facts.days)d stale" : plain, isStale: facts.isStale, isKnown: true)
    }

}

public enum DeskGitHubStatePillPresentation {
    public struct Pill: Equatable {
        public let label: String
        public let tone: DeskPresentationTone
    }

    public static let stalledCallbackStatus = "stalled"

    public static func pill(for item: GitHubCommandItem) -> Pill {
        switch item.state {
        case .detected, .needsCodex:
            return Pill(label: "Action needed", tone: .warning)
        case .codexWorking:
            return Pill(label: "Codex working", tone: .info)
        case .verifying:
            return Pill(label: "Verifying", tone: .info)
        case .needsOwner:
            return Pill(label: "Needs you", tone: .warning)
        case let .waitingUpstream(kind):
            return Pill(label: waitingLabel(for: kind), tone: .neutral)
        case let .attention(reason):
            return attentionPill(reason: reason, callbackStatus: item.lastCallbackStatus)
        case .resolved:
            return Pill(label: "Resolved", tone: .success)
        }
    }

    public static func waitingLabel(for kind: GitHubCommandWaitingKind) -> String {
        switch kind {
        case .review: return "Waiting for review"
        case .ci: return "Waiting for checks"
        case .maintainer: return "Waiting for maintainer"
        case .readyToMerge: return "Ready to merge"
        }
    }

    private static func attentionPill(
        reason: GitHubCommandAttentionReason,
        callbackStatus: String?
    ) -> Pill {
        let label: String
        switch reason {
        case .dispatchFailed: label = "Dispatch failed"
        case .codexFailed:
            label = normalizedCallbackStatus(callbackStatus) == stalledCallbackStatus
                ? "Codex stalled"
                : "Codex no result"
        case .verificationFailed: label = "GitHub still actionable"
        case .verificationReadFailed: label = "GitHub verification unreadable"
        case .callbackOverdue: label = "Codex stalled"
        case .codexBusy: label = "Legacy Codex retry"
        case .stale: label = "Stale observation"
        case .contradictoryState: label = "State needs review"
        }
        return Pill(label: label, tone: .danger)
    }

    private static func normalizedCallbackStatus(_ status: String?) -> String {
        status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}


public extension DeskPageContent {
    struct ProjectRow: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let line: String
        public let meta: String
        /// The plan's "x of y done", when the board has one; the row then
        /// shows a bar instead of `meta`.
        public var done: Int? = nil
        public var total: Int? = nil
        public let draft: String
        /// Untouched for two weeks, or a 0-of-N plan nobody has moved in a
        /// week: it sits in the folded "Parked" group, not with the live work.
        public var parked = false
    }

    /// "Running, step two of five." + "3m ago" → "Running, step two of five · 3m ago".
    private static func detail(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func computeProjectRows(snapshot: DeskPageSnapshot, now: Date) -> [ProjectRow] {
        guard snapshot.deskUnavailable == nil else { return [] }
        let state = DeskState(items: snapshot.items, generatedTs: "")
        let plan = snapshot.plan
        return DeskPageContent.projectRows(snapshot, now: now).map { facts in
            let item = facts.item
            let live = facts.execution
            let activity = facts.activity.label
            var meta = Self.detail(activity, DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
            var counts: (done: Int, total: Int)?
            if let live {
                let label = DeskActivityState.execution(.init(deskHandle: live.deskHandle, status: live.status, updatedAt: live.updatedAt, lastMovementAt: live.lastMovementAt), now: now).label
                let step = DeskExecutionPresentation.progress(
                    status: live.status,
                    planCount: live.plan.count,
                    completedCount: live.stepsCompleted.count)
                meta = step.map { "\(label), \($0)" } ?? label
            } else if let itemPlan = plan.byHandle[item.handle], itemPlan.totalCount > 0 {
                meta = Self.detail(activity, "\(itemPlan.doneCount) of \(itemPlan.totalCount) done")
                counts = (itemPlan.doneCount, itemPlan.totalCount)
            }
            // One Parked rule, shared with the agent's home (DeskParking).
            return ProjectRow(
                id: item.handle,
                title: DeskPageContent.title(item),
                line: DeskPageContent.projectLine(item, in: state, plan: plan),
                meta: meta,
                done: counts?.done,
                total: counts?.total,
                draft: draft(about: item),
                parked: facts.parked)
        }
    }

    /// What a row says when it reaches Chat: the item by handle, and the reason
    /// she stored — whole, not the row's shortened line.
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
    ) -> (projects: [ProjectRow], owner: [DeskItem], blocked: [DeskItem], watches: [DeskItem],
          stale: [DeskItem], other: [DeskItem], history: [DeskItem],
          executions: [WorkshopExecutionRecord], deadline: Date?) {
        let projects = computeProjectRows(snapshot: loaded, now: presentationNow)
        let items = loaded.items
        let owner = DeskPageContent.waitingOnOwner(items)
        let blocked = DeskPageContent.blocked(items)
        let watches = DeskPageContent.freshWatches(items, now: presentationNow)
        let stale = DeskPageContent.staleWatches(items, now: presentationNow)
        let shown = Set((owner + blocked + watches + stale).map(\.handle) + projects.map(\.id))
        let other = DeskAttentionStrip.sortedDeskItems(DeskPageContent.active(items).filter { !shown.contains($0.handle) })
        let history = DeskAttentionStrip.sortedDeskItems(items.filter { $0.status.isTerminal })
        let executions = loaded.executions.items.filter { ["completed", "failed", "cancelled"].contains($0.status) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let lane: DeskLaneState<DeskItem> = loaded.deskUnavailable.map { .unavailable($0) } ?? .rows(items)
        let activity = DeskLiveActivityPresentation.make(deskItems: lane, executions: loaded.executions,
                                                        generatedTs: loaded.generatedTs, now: presentationNow)
        let movementExpiry = loaded.executions.items.filter { $0.status == "running" }.compactMap {
            DeskActivityState.movementDate($0.lastMovementAt)?.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let watchExpiry = DeskPageContent.watches(items).compactMap {
            UserDisplayFormatters.parseISOTimestamp($0.updatedAt)?.addingTimeInterval(
                Double(DeskProjection.staleThresholdDays) * 86_400)
        }.filter { $0 > presentationNow }.min()
        let deferExpiry = items.compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }
            .filter { $0 > presentationNow }.min()
        let muteExpiry = loadedNags.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
            ? nil : loadedNags.mutedUntil.flatMap(DeskSequencing.parseDeferStamp)
        let nowExpiry = items.filter { $0.status == .now }.compactMap {
            DeskActivityState.movementDate($0.updatedAt)?.addingTimeInterval(DeskActivityState.movementWindow)
        }.filter { $0 > presentationNow }.min()
        let state = DeskState(items: items, generatedTs: "")
        let familyParents = Set(DeskProgramFamilyPresentation.families(
            from: lane, executions: loaded.executions, now: presentationNow).map(\.id))
        let parkingExpiry = DeskPageContent.projects(items, excluding: familyParents).compactMap { item -> Date? in
            let handles = DeskParking.subtreeHandles(item.handle, in: state)
            guard !loaded.executions.items.contains(where: {
                $0.deskHandle.map(handles.contains) == true && DeskParking.executionIsLive(status: $0.status)
            }), let touched = DeskParking.lastTouch(item, in: state) else { return nil }
            let plan = loaded.plan.byHandle[item.handle]
            let days = plan.map { $0.totalCount > 0 && $0.doneCount == 0 } == true
                ? DeskParking.untouchedPlanDays : DeskParking.quietDays
            return touched.addingTimeInterval(Double(days) * 86_400)
        }.filter { $0 > presentationNow }.min()
        let relativeStamps = items.map(\.updatedAt)
            + items.compactMap { $0.pursuit?.lastWorkedAt }
            + loaded.executions.items.map(\.updatedAt)
            + loaded.executions.items.compactMap(\.lastMovementAt)
            + loaded.github.items.map { $0.motorUpdatedAt ?? $0.updatedAt }
            + jobStamps
            + [loaded.generatedTs].compactMap { $0 }
        let relativeDates = relativeStamps.compactMap(UserDisplayFormatters.parseISOTimestamp)
            + timedSnapshot.compactMap(\.nextRun)
        let relativeExpiry = relativeDates.map {
            DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: presentationNow)
        }.min()
        let deadline = [activity.nextRefreshAt, movementExpiry, watchExpiry, deferExpiry, muteExpiry,
                        nowExpiry, parkingExpiry, relativeExpiry, hourExpiry]
            .compactMap { $0 }.filter { $0 > presentationNow }.min()
        return (projects, owner, blocked, watches, stale, other, history, executions, deadline)
    }
}

extension DeskExecutionPresentation {
    public static func progress(status: String, planCount: Int, completedCount: Int) -> String? {
        guard status == "running", planCount > 0 else { return nil }
        return "step \(min(max(completedCount + 1, 1), planCount)) of \(planCount)"
    }

}
