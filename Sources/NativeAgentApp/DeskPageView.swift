// DeskPageView.swift
// THE DESK, IN HER WORDS. (ui-simplify 2026-09-02, lane D.)
//
// User on the old Desk: "we've made it better, still looks like a mess; make it
// more human friendly to see everything." The old page put five numbered tiles,
// twenty-one Jira-shaped blocked tickets and a hundred and twenty-one watcher
// rows edge to edge, all at full weight. Everything was visible and nothing
// was legible.
//
// Same data, new shape — Today's shape:
//
//   · One centred column, the word "Desk" on the door. No icon toolbar, no
//     segmented control: Schedule and Research are folded rows further down
//     the SAME page.
//   · Three things at most on first paint — what's waiting on him, what I'm
//     working on, and one folded row that says how much is blocked.
//   · Counts are spelled ("Twenty-one things are blocked"), never tiled.
//   · A blocked row gets ONE plain-words reason, cut at a word boundary. The
//     full ticket prose stays on the classic page.
//   · No coloured badges anywhere. A state is a word in the meta line.
//
// Every row reads from the SAME stores the classic Desk reads, in the same
// order, with the same failure honesty — literally the same function, now that
// the read lives in `DeskBoardRead` (DeskBoardRead.swift) and both pages call
// it. An unreadable lane says so instead of rendering as calm:
//
//   desk items          SwiftNativeDeskStore.liveState()
//   in progress         DeskProgramFamilyPresentation.families + the workshop
//                       runner's non-terminal executions (DeskExecutionPresentation)
//   waiting on you      OwnerAttentionPolicy.waitsOnOwner + approval-parked
//                       executions + the GitHub `needsUser` bucket
//   blocked             DeskItemPresentation.needsEyes minus the owner's own
//   watching / stale    DeskBoardLayout.watches + DeskItemPresentation.staleThresholdDays
//   GitHub Watcher      GitHubCommandStore.liveState().items, bucketed by
//                       DeskGitHubBucket
//   schedule            AppModel.jobs (AppModel.refreshSchedulerJobs)
//
// NOTHING is deleted from the classic Desk: DeskHubView still renders the old
// page in the classic shell, and this page opens it in a sheet for every action
// that has no home here yet.
//
// Alive glass (User approved the mockup, 2026-09-23): the same lanes, drawn from
// AlivePageKit — a serif "Desk" with one counts sentence, what's waiting in one
// group card, what I'm working on as a two-column grid of rings, projects as
// one group card with a bar each, and every remaining fold as one quiet line
// of counts. Each count still opens its own fold.

import SwiftUI
import AppKit
import PersistenceCore
import SelfImprovement
import WorkshopExecution

// MARK: - Words

/// Counts on this page are spelled, the way Today spells them. `TodayWords`
/// stops at ten (its lists are never longer); a desk is, so the same rule is
/// carried up to nine hundred and ninety-nine and falls back to numerals past
/// that rather than inventing a mouthful.
enum DeskPageWords {
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
    static func spelledLower(_ count: Int) -> String {
        guard count >= 0 else { return String(count) }
        if (1...10).contains(count) { return TodayWords.spelledLower(count) }
        return lower(count)
    }

    /// Sentence-leading: "Twenty-one".
    static func spelled(_ count: Int) -> String {
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

    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }

    /// "a hundred and five" is right after "I'm watching" and wrong after "the
    /// other". The article goes when a determiner already leads the phrase.
    static func withoutArticle(_ words: String) -> String {
        words.hasPrefix("a ") ? String(words.dropFirst(2)) : words
    }
}

// MARK: - Metrics

enum DeskPageMetrics {
    // On the shell's one ramp (ShellType): a row's title is the 16 step, its
    // sentence and its meta line the 13 step. 11 is not on the scale.
    static let titleSize: CGFloat = ShellType.bodySize
    static let lineSize: CGFloat = ShellType.labelSize
    static let metaSize: CGFloat = ShellType.labelSize
    static let rowRadius: CGFloat = 10
    /// How many rows a fold shows before it says how many more there are.
    static let foldRowCap = 60
    /// Finished work is bounded harder than the board: it is a shelf of what
    /// just landed, not an archive. The full history stays on the classic desk.
    static let finishedRowCap = 5
}

// MARK: - The snapshot

/// One read of every store this page renders, taken off the main actor. Each
/// lane keeps its own honesty: a lane that could not be read contributes zero
/// rows AND a reason, never silent calm.
struct DeskPageSnapshot: Sendable {
    var loaded = false
    var items: [DeskItem] = []
    var deskUnavailable: String?
    var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    var github: DeskLaneState<GitHubCommandItem> = .rows([])
    /// The same derived sequencing the projection renders (blockers, held
    /// rows, subtree rollups). Computed ONCE per read, off the main actor,
    /// because the projects lane asks it a question per row and `body` runs
    /// far more often than the board changes.
    var plan = DeskSequencing.Plan()

    static let empty = DeskPageSnapshot()

    /// The SAME store read the classic Desk performs (`DeskBoardRead`), minus
    /// the parts only the classic Desk renders — the sequencing plan and alias
    /// map it does not ask for, and her hour, which the classic page reads on
    /// the main actor. Same stores, same order, same failure classification,
    /// because it is the same function.
    static func load(root: URL) async -> DeskPageSnapshot {
        let read = await DeskBoardRead.load(root: root)
        var snapshot = DeskPageSnapshot()
        snapshot.loaded = true
        snapshot.items = read.items
        snapshot.deskUnavailable = read.deskError
        snapshot.executions = read.executions
        snapshot.github = read.github
        snapshot.plan = DeskSequencing.compute(
            DeskState(items: read.items, generatedTs: ""))
        return snapshot
    }
}

// MARK: - What the page says about that snapshot

/// Pure projections. Every slice below is the SAME predicate the classic Desk
/// counts with, so the two pages can never disagree about the board.
enum DeskPageContent {
    static func active(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.activeItems(items)
    }

    /// His to clear: a live row that names the owner as the party it waits on.
    static func waitingOnOwner(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(active(items).filter(OwnerAttentionPolicy.waitsOnOwner))
    }

    /// Real, visible, and NOT his — the classic page's "Blocked" tile exactly.
    static func blocked(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(
            active(items)
                .filter(DeskItemPresentation.needsEyes)
                .filter { !OwnerAttentionPolicy.waitsOnOwner($0) })
    }

    // MARK: projects

    /// The ordinary projects — the ones he handed over and nobody is running
    /// this second. They had no lane on this page at all: a project with a
    /// plan under it appeared only once a delegation family or a Workshop
    /// execution existed, so "the conference" was invisible between the day he
    /// asked for it and the day something started executing.
    ///
    /// Everything already shown elsewhere is subtracted, so no row is said
    /// twice: the waiting card owns his questions, the blocked fold owns the
    /// stuck ones, and "what I'm working on" owns the families.
    static func projects(_ items: [DeskItem], excluding shown: Set<String>) -> [DeskItem] {
        active(items)
            .filter { $0.parent == nil }
            .filter { $0.kind == .project || $0.kind == .plan }
            .filter { [.now, .next, .todo].contains($0.status) }
            .filter { !OwnerAttentionPolicy.waitsOnOwner($0) }
            .filter { !DeskItemPresentation.needsEyes($0) }
            .filter { !shown.contains($0.handle) }
    }

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

    /// The first child that could actually be started: `now` over `next` over
    /// `todo`, and never one the plan says is held. A held child is not a next
    /// step — advertising it is how a board lies about being ready.
    static func nextStep(
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

    static func watches(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.watches(active(items))
    }

    /// The watches still worth his eye: everything that has moved inside the
    /// week. A stale one recedes into the fold below on its own, and one update
    /// brings it straight back here — no housekeeping, nothing lost.
    static func freshWatches(_ items: [DeskItem], now: Date) -> [DeskItem] {
        let quiet = Set(staleWatches(items, now: now).map(\.handle))
        return watches(items).filter { !quiet.contains($0.handle) }
    }

    /// The classic page's "Stale 7d+": watch rows untouched past the threshold
    /// that are not already counted as blocked or flagged.
    static func staleWatches(_ items: [DeskItem], now: Date) -> [DeskItem] {
        watches(items).filter { item in
            guard item.status != .blocked, item.status != .flag else { return false }
            guard let at = UserDisplayFormatters.parseISOTimestamp(item.updatedAt) else { return false }
            return Int(now.timeIntervalSince(at) / 86_400) >= DeskItemPresentation.staleThresholdDays
        }
    }

    /// ONE plain sentence for why a row is stuck. The classic page prints the
    /// whole stamped reason on every row, which is how twenty-one items became
    /// a wall of the same paragraph; this cuts at a word boundary and never
    /// carries markdown.
    static func stuckReason(_ item: DeskItem) -> String {
        if let raw = item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return TodayWords.line(raw, limit: 96)
        }
        if let waiting = item.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines),
           !waiting.isEmpty {
            return "Waiting on \(TodayWords.line(waiting, limit: 60))."
        }
        if item.status == .flag { return "Flagged for a second look." }
        return "Blocked, with no reason written down."
    }

    static func title(_ item: DeskItem) -> String {
        let named = TodayWords.line(item.title, limit: 110)
        return named.isEmpty ? item.handle : named
    }

    // MARK: GitHub

    static func githubNeedingAHand(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .actionNeeded })
    }

    static func githubNeedsOwner(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .needsUser })
    }

    static func githubRest(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        let claimed = Set(
            (githubNeedingAHand(items) + githubNeedsOwner(items)).map(\.itemId))
        return DeskAttentionStrip.sortedGitHubItems(items.filter { !claimed.contains($0.itemId) })
    }

    /// The remainder fold holds everything the two attention groups did not
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
    static func githubMeta(_ item: GitHubCommandItem, now: Date) -> String {
        let state = DeskGitHubStatePillPresentation.pill(for: item).label.lowercased()
        let when = DeskRelativeTimePresentation.text(
            forISO: item.motorUpdatedAt ?? item.updatedAt, now: now)
        return "\(item.repository) · #\(item.number) · \(state) · \(when)"
    }

    // MARK: Schedule

    /// Only enabled jobs run. The rows beneath this headline already say
    /// "Paused." for the rest, so counting every saved record made the fold
    /// contradict its own contents.
    /// A missed occurrence is neither running nor paused, so it is counted on
    /// its own: nothing ran, and the page says so instead of staying silent.
    /// `bots` is the unpaused bots on a schedule; each one runs on a timer too.
    static func scheduleHeadline(_ jobs: [SchedulerJob], missed: Int = 0, bots: Int = 0) -> String {
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

    static func scheduleLine(_ job: SchedulerJob) -> String {
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

// MARK: - The page

struct DeskPageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let rootRouteVersion: Int

    init(rootRouteVersion: Int = 0) {
        self.rootRouteVersion = rootRouteVersion
    }

    @State private var snapshot = DeskPageSnapshot.empty
    @State private var now = Date()
    @State private var openFolds: Set<String> = []
    @State private var sheet: DeskPageSheet?
    @State private var actionNotice: String?
    @State private var actionInFlight: String?
    /// Only the NEWEST read may publish. `reload()` is called from four racing
    /// places — first paint, the poll, a route to the root, and every action
    /// that closes a sheet — and a slow early read landing after a fast later
    /// one would put stale items back on the board. Same gate the classic Desk
    /// takes (DeskView.load).
    @State private var loadGate = LatestAsyncRequestGate()

    private var voice: AgentVoice { AgentVoice.current(name: appModel.agentDisplayName) }
    /// The poll runs only when he can actually see this page: not while the
    /// window is in the background, and not while a sheet is over it.
    private var pollingEnabled: Bool { scenePhase == .active && sheet == nil }
    private var items: [DeskItem] { snapshot.items }
    private var githubItems: [GitHubCommandItem] { snapshot.github.items }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                // Looking something up is an action, not a count: a quiet
                // button on the header's baseline, not an item in the line.
                HStack(alignment: .firstTextBaseline) {
                    AlivePageHeader(title: "Desk", line: headerLine)
                    Spacer(minLength: 12)
                    Button { sheet = .research } label: {
                        Label("Look something up", systemImage: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desk.open-research")
                }

                ForEach(laneTrouble, id: \.self) { trouble in
                    Text(trouble)
                        .font(.system(size: DeskPageMetrics.lineSize))
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("desk.lane-trouble")
                }

                if hasWaiting { waitingCard }

                if !workingRows.isEmpty {
                    VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                        AliveEyebrow("What I'm working on")
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(workingRows) { row in
                                DeskWorkingCard(title: row.title, detail: row.detail, fraction: row.fraction)
                            }
                        }
                    }
                }

                if !projectRows.isEmpty {
                    VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                        AliveEyebrow("Projects")
                        let parked = projectRows.filter(\.parked)
                        let parkedOpen = openFolds.contains(Fold.parked)
                        AliveGroupCard {
                            ForEach(projectRows.filter { !$0.parked }) { row in projectRow(row) }
                            if !parked.isEmpty {
                                Button { toggleFold(Fold.parked) } label: {
                                    HStack(spacing: 6) {
                                        Text("Parked (\(parked.count))")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(NativeAgentShell.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(ShellType.captionSemibold)
                                            .foregroundStyle(NativeAgentShell.secondary)
                                            .rotationEffect(.degrees(parkedOpen ? 90 : 0))
                                            .accessibilityHidden(true)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(parkedOpen ? "Open" : "Folded")
                                .accessibilityIdentifier("desk.fold.parked")
                            }
                            if parkedOpen {
                                ForEach(parked) { row in projectRow(row) }
                            }
                        }
                    }
                }

                foldsSection

                if let notice = actionNotice {
                    Text(notice)
                        .font(.system(size: DeskPageMetrics.metaSize))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityIdentifier("desk.action-notice")
                }

                if snapshot.loaded, laneTrouble.isEmpty, !hasWaiting, workingRows.isEmpty,
                   projectRows.isEmpty, finishedRows.isEmpty, boardIsEmpty {
                    Text("Nothing on the board right now. I'll keep watching.")
                        .font(.system(size: 15))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, TodayMetrics.topPadding)
            .motionArrival(when: snapshot.loaded)
            .padding(.bottom, 32)
            .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A route to the Desk is a route to its ROOT: the folds close, the
        // stores are re-read. Same contract DeskHubView keeps for its modes.
        // This is also first paint — one task, owned by the view, instead of a
        // detached `Task {}` from onChange that outlived it.
        .liveTask(id: rootRouteVersion) {
            openFolds.removeAll()
            let published = await reload()
            // First paint has rows now: a notification click that arrived
            // before this page existed opens its item here. This is also the
            // one place that may give up on a handle — the reload the route
            // asked for has finished, so an item still missing is not coming.
            //
            // Only the reload that actually PUBLISHED this route's board may
            // give up. One that was cancelled, or that lost the load gate to a
            // newer read, proves nothing about what is on the board — and the
            // handle it would clear may belong to a click newer than itself.
            guard published, !Task.isCancelled else { return }
            openPendingDeskItem(scroller, giveUpIfMissing: true)
        }
        // The classic page binds DeskLiveReloader, and this page cannot: that
        // coordinator is a single-slot singleton (one `reload` closure, one set
        // of watched paths), and this page opens the classic Desk in a sheet —
        // DeskView would take the binding on appear and clear it on dismiss,
        // leaving this page with no live reload at all. So the poll stays, and
        // it is gated instead: paused while the scene is not active and while a
        // sheet is over the page. Inventoried in script/timer_inventory.tsv.
        .liveTask(id: pollingEnabled) {
            guard pollingEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await reload()
            }
        }
        .sheet(item: $sheet) { which in
            DeskPageSheetHost(sheet: which, voice: voice) {
                sheet = nil
                Task { await reload() }
            }
        }
        // A click on a Desk reminder banner while this page is already up.
        .onChange(of: appModel.pendingDeskHandle) { openPendingDeskItem(scroller) }
        // ...and every load that lands after it. The handle may have been set
        // against a snapshot that did not have the item yet.
        .onChange(of: loadStamp) { openPendingDeskItem(scroller) }
        }
    }

    // MARK: waiting on you

    private var ownerItems: [DeskItem] { DeskPageContent.waitingOnOwner(items) }

    private var approvalExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        let ids = Set(DeskExecutionPresentation.slice(snapshot.executions.items).approvalIDs)
        return DeskAttentionStrip.sortedApprovals(
            snapshot.executions.items.filter { ids.contains($0.id) })
    }

    private var githubNeedsOwner: [GitHubCommandItem] {
        DeskPageContent.githubNeedsOwner(githubItems)
    }

    private var hasWaiting: Bool {
        !ownerItems.isEmpty || !approvalExecutions.isEmpty || !githubNeedsOwner.isEmpty
    }

    /// One sentence of counts the page already holds. Nothing is said before
    /// the board is read, or while a lane is unreadable: a short board must
    /// not claim "nothing in motion".
    private var headerLine: String? {
        guard snapshot.loaded, laneTrouble.isEmpty else { return nil }
        let moving = workingRows.count
        let projects = projectRows.filter { !$0.parked }.count
        // The one shared definition Today's header counts too.
        let waiting = WaitingOnYou.count(appModel, deskItems: items)
        var parts: [String] = []
        parts.append(moving == 0
            ? "nothing in motion"
            : "\(DeskPageWords.spelledLower(moving)) \(DeskPageWords.plural(moving, "thing", "things")) in motion")
        if projects > 0 {
            parts.append("\(DeskPageWords.spelledLower(projects)) \(DeskPageWords.plural(projects, "project", "projects"))")
        }
        parts.append(waiting == 0 ? "nothing waiting on you" : "\(DeskPageWords.spelledLower(waiting)) waiting on you")
        return TodayWords.capitalizedFirst(parts.joined(separator: ", ")) + "."
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            // Narrower than the header's "waiting on you" (no approvals or
            // memories; parked runs and GitHub calls instead), so named apart.
            AliveEyebrow("On the desk for you")
            AliveGroupCard(waiting: true) {
                waitingRows
            }
            .accessibilityIdentifier("desk.waiting-on-you")
        }
    }

    @ViewBuilder
    private var waitingRows: some View {
        ForEach(approvalExecutions, id: \.id) { execution in
            DeskPageWaitingRow(
                title: TodayWords.line(execution.title, limit: 110),
                line: "It's parked until you say yes.",
                actionTitle: "Take a look",
                isBusy: false
            ) {
                _ = NativeAgentAppCoordinator.shared.request(.activity(.approvals))
            }
        }

        // She asked a question; the answer is a reply, not a verdict on the
        // whole project. "Mark it done" closed the item — the one control
        // on the row did the one thing an answer is not — so it is gone,
        // and the row's action is the draft handoff that already existed
        // on its title. An item he handled elsewhere still closes, on the
        // row's own menu, which adds no chrome to the page.
        ForEach(ownerItems, id: \.handle) { item in
            DeskPageWaitingRow(
                title: DeskPageContent.title(item),
                line: DeskPageContent.stuckReason(item),
                actionTitle: "Reply",
                isBusy: actionInFlight == item.handle,
                action: { askAbout(Self.draft(about: item)) },
                alreadyHandled: { close(item) }
            )
            .id("desk:\(item.handle)")
        }

        ForEach(githubNeedsOwner, id: \.itemId) { item in
            DeskPageWaitingRow(
                title: DeskPageContent.githubTitle(item),
                line: "\(item.repository) #\(item.number) needs your call.",
                actionTitle: "Show me",
                isBusy: false
            ) {
                openFolds.insert(Fold.github)
            }
        }
    }

    // MARK: what I'm working on

    private struct WorkingRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        /// Parts done over parts, or steps done over the plan. Nil when the
        /// row carries no count at all — the ring then shows no arc.
        let fraction: Double?
    }

    /// "Running, step two of five." + "3m ago" → "Running, step two of five · 3m ago".
    private static func detail(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The classic "In progress" lane, in sentences: delegation families first
    /// (she is running several lanes under one parent), then the executions
    /// that are actually on the bench.
    private var workingRows: [WorkingRow] {
        var rows: [WorkingRow] = []
        for family in DeskProgramFamilyPresentation.families(from: laneOfItems) {
            // The ring and the words read the SAME two numbers; the subtitle
            // carries progress and the next step, never the title again.
            let lanes = family.lanes.count
            let done = family.lanes.filter { $0.status == .done }.count
            let next = family.lanes.first { $0.status == .now }
                ?? family.lanes.first { !$0.status.isTerminal }
            rows.append(WorkingRow(
                id: "family:\(family.id)",
                title: TodayWords.line(family.parentTitle, limit: 110),
                detail: Self.detail(
                    "\(done) of \(lanes) \(DeskPageWords.plural(lanes, "part", "parts")) done",
                    next.map { "Next: \(TodayWords.line($0.title, limit: 60))" } ?? ""),
                fraction: lanes > 0 ? Double(done) / Double(lanes) : nil
            ))
        }
        let benchIDs = Set(DeskExecutionPresentation.slice(snapshot.executions.items).benchIDs)
        for execution in snapshot.executions.items where benchIDs.contains(execution.id) {
            let state = DeskExecutionPresentation.pill(for: execution.status).label
            let planned = execution.plan.count
            let done = min(execution.stepsCompleted.count, planned)
            let next = done < planned ? TodayWords.line(execution.plan[done].description, limit: 60) : ""
            rows.append(WorkingRow(
                id: "execution:\(execution.id)",
                title: TodayWords.line(execution.title, limit: 110),
                detail: Self.detail(
                    TodayWords.capitalizedFirst(planned > 0 ? "\(state), \(done) of \(planned) steps done" : state),
                    next.isEmpty
                        ? DeskRelativeTimePresentation.text(forISO: execution.updatedAt, now: now)
                        : "Next: \(next)"),
                fraction: planned > 0 ? Double(done) / Double(planned) : nil
            ))
        }
        return rows
    }

    // MARK: projects

    private struct ProjectRow: Identifiable {
        let id: String
        let title: String
        let line: String
        let meta: String
        /// The plan's "x of y done", when the board has one; the row then
        /// shows a bar instead of `meta`.
        var done: Int? = nil
        var total: Int? = nil
        let draft: String
        /// Untouched for two weeks, or a 0-of-N plan nobody has moved in a
        /// week: it sits in the folded "Parked" group, not with the live work.
        var parked = false
    }

    private var deskState: DeskState { DeskState(items: items, generatedTs: "") }

    private func projectRow(_ row: ProjectRow) -> some View {
        DeskProjectRow(
            title: row.title,
            line: row.line,
            meta: row.meta,
            done: row.done,
            total: row.total,
            onOpenTitle: { askAbout(row.draft) })
            .id("desk:\(row.id)")
    }

    /// The ordinary projects, each with its next step and — when something is
    /// actually executing for it — that execution's progress on the SAME row.
    /// The project and the run it spawned were on two different surfaces (and
    /// the run under a second, Workshop-named item); joined by `deskHandle`,
    /// they read as one piece of work again.
    private var projectRows: [ProjectRow] {
        guard snapshot.deskUnavailable == nil else { return [] }
        let state = deskState
        let plan = snapshot.plan
        let familyParents = Set(DeskProgramFamilyPresentation.families(from: laneOfItems).map(\.id))
        let rows = DeskPageContent.projects(items, excluding: familyParents)
        return rows.map { item in
            let handles = Set([item.handle] + state.children(of: item.handle).map(\.handle))
            let live = snapshot.executions.items
                .filter { $0.deskHandle.map(handles.contains) ?? false }
                .filter { DeskParking.executionIsLive(status: $0.status) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
            var meta = DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now)
            var counts: (done: Int, total: Int)?
            if let live {
                let label = DeskExecutionPresentation.pill(for: live.status).label
                let step = DeskExecutionPresentation.progress(
                    status: live.status,
                    planCount: live.plan.count,
                    completedCount: live.stepsCompleted.count)
                meta = step.map { "\(label), \($0)" } ?? label
            } else if let itemPlan = plan.byHandle[item.handle], itemPlan.totalCount > 0 {
                meta = "\(itemPlan.doneCount) of \(itemPlan.totalCount) done"
                counts = (itemPlan.doneCount, itemPlan.totalCount)
            }
            // One Parked rule, shared with the agent's home (DeskParking).
            let parked = DeskParking.isParked(item, in: state, plan: plan, live: live != nil, now: now)
            return ProjectRow(
                id: item.handle,
                title: DeskPageContent.title(item),
                line: DeskPageContent.projectLine(item, in: state, plan: plan),
                meta: meta,
                done: counts?.done,
                total: counts?.total,
                draft: Self.draft(about: item),
                parked: parked)
        }
    }

    /// The families projection wants the lane state, not the bare array, so a
    /// failed desk read contributes no families rather than a false calm.
    private var laneOfItems: DeskLaneState<DeskItem> {
        if let reason = snapshot.deskUnavailable { return .unavailable(reason) }
        return .rows(items)
    }

    // MARK: the board — everything else, folded

    private enum Fold {
        static let finished = "finished"
        static let blocked = "blocked"
        static let watching = "watching"
        static let github = "github"
        static let githubRest = "github-rest"
        static let schedule = "schedule"
        static let parked = "parked"
        static let stale = "stale"
        static let ideas = "ideas"
    }

    private var blockedItems: [DeskItem] { DeskPageContent.blocked(items) }
    /// Only the watches that have moved this week. The quiet ones are named
    /// once, in the grey line at the foot of the page.
    private var watchItems: [DeskItem] { DeskPageContent.freshWatches(items, now: now) }
    private var staleItems: [DeskItem] { DeskPageContent.staleWatches(items, now: now) }

    private var boardIsEmpty: Bool {
        blockedItems.isEmpty && watchItems.isEmpty && githubItems.isEmpty && appModel.jobs.isEmpty
    }

    // MARK: finished work

    private struct FinishedRow: Identifiable {
        let id: String
        let title: String
        let result: String
        let meta: String
        let draft: String
    }

    /// Work that finished, with the thing it produced. Finishing used to mean
    /// a row changing where it sat — the result itself lived in the execution
    /// record and in a shortened Desk note, and this page never showed either.
    /// So: the newest terminal executions that belong to a Desk item, each
    /// carrying its OWN result text and its OWN verification words — including
    /// "completed; outcome not independently verified", which is the whole
    /// point of showing it rather than a green tick.
    private var finishedRows: [FinishedRow] {
        let terminal = ["completed", "failed", "cancelled"]
        return snapshot.executions.items
            .filter { terminal.contains($0.status) }
            .filter { $0.deskHandle?.isEmpty == false }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(DeskPageMetrics.finishedRowCap)
            .map { execution in
                let verdict = execution.verification
                    .map(DeskExecutionPresentation.verificationLabel)
                    ?? (execution.status == "completed"
                        ? "completed; no verification record"
                        : DeskExecutionPresentation.pill(for: execution.status).label)
                var draft = "About the finished work on Desk item "
                    + "\(execution.deskHandle ?? ""): \(execution.title)"
                draft += "\n\nWhat you reported: \(Self.resultText(execution))"
                draft += "\nVerification: \(verdict)"
                return FinishedRow(
                    id: execution.id,
                    title: TodayWords.line(execution.title, limit: 110),
                    result: Self.resultText(execution),
                    meta: "\(verdict) · "
                        + DeskRelativeTimePresentation.text(forISO: execution.updatedAt, now: now),
                    draft: draft)
            }
    }

    /// The execution's own result, never a re-description of it. An execution
    /// that finished without writing one says so instead of borrowing the
    /// objective and reading as a result.
    private static func resultText(_ execution: WorkshopExecution.WorkshopExecutionRecord) -> String {
        switch execution.result {
        case .string(let value) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .null:
            return "It finished without writing down a result."
        default:
            return "It finished with a structured result; the receipts hold it."
        }
    }

    // MARK: the rest of the board — one quiet line of counts

    private struct FoldCount: Identifiable {
        let id: String
        /// The short count on the line.
        let label: String
        /// The fold's own sentence: its header when open, and its spoken name.
        let title: String
    }

    /// Every fold the page keeps, as one count each: only the ones with
    /// something in them, except the timer fold, which stays reachable on an
    /// empty board. Numerals on this line: it is scanned, not read.
    private var foldCounts: [FoldCount] {
        var out: [FoldCount] = []
        let finished = finishedRows.count
        if finished > 0 {
            out.append(FoldCount(
                id: Fold.finished,
                label: "\(finished) ready to look at",
                title: "\(DeskPageWords.spelled(finished)) \(DeskPageWords.plural(finished, "thing is", "things are")) ready to look at"))
        }
        if !blockedItems.isEmpty {
            let count = blockedItems.count
            out.append(FoldCount(
                id: Fold.blocked,
                label: "\(count) blocked",
                title: "\(DeskPageWords.spelled(count)) \(DeskPageWords.plural(count, "thing is", "things are")) blocked"))
        }
        if !watchItems.isEmpty {
            let count = watchItems.count
            out.append(FoldCount(
                id: Fold.watching,
                label: "\(count) on watch",
                title: "I'm keeping an eye on \(DeskPageWords.spelledLower(count)) \(DeskPageWords.plural(count, "thing", "things"))"))
        }
        if !githubItems.isEmpty {
            let count = githubItems.count
            let noun = githubItems.allSatisfy { $0.kind == .pullRequest }
                ? DeskPageWords.plural(count, "pull request", "pull requests")
                : "pull requests and issues"
            out.append(FoldCount(
                id: Fold.github,
                label: "\(count) \(noun)",
                title: DeskPageContent.githubHeadline(githubItems)))
        }
        let jobs = appModel.jobs
        let running = jobs.filter(\.enabled).count + timedBots.count
        var timer = running == 0 ? "nothing on a timer" : "\(running) on a timer"
        if !missedBots.isEmpty {
            timer += ", \(missedBots.count) \(DeskPageWords.plural(missedBots.count, "missed run", "missed runs"))"
        }
        out.append(FoldCount(
            id: Fold.schedule,
            label: timer,
            title: DeskPageContent.scheduleHeadline(jobs, missed: missedBots.count, bots: timedBots.count)))
        let stale = staleItems.count
        if stale > 0 {
            // Quiet for a while, and quiet on its own: these rows have already
            // left "on watch", and one update puts them back there. Nothing to
            // clear, so nothing asks him to clear it.
            out.append(FoldCount(
                id: Fold.stale,
                label: "\(stale) quiet for a week",
                title: "\(DeskPageWords.spelled(stale)) \(DeskPageWords.plural(stale, "item hasn't", "items haven't")) moved in a week"))
        }
        // Evolution proposals filed as prose that nobody has turned into a diff.
        if !ideas.isEmpty {
            out.append(FoldCount(
                id: Fold.ideas,
                label: "\(ideas.count) \(DeskPageWords.plural(ideas.count, "idea", "ideas")) waiting for a diff",
                title: "\(DeskPageWords.spelled(ideas.count)) \(DeskPageWords.plural(ideas.count, "idea is", "ideas are")) waiting for a diff"))
        }
        return out
    }

    @ViewBuilder
    private var foldsSection: some View {
        let counts = foldCounts
        VStack(alignment: .leading, spacing: 12) {
            // Each count its own item in the flow, spaced apart rather than
            // joined with "·", so a wrapped line never starts on a separator.
            AliveFlow(spacing: 18, lineSpacing: 6) {
                ForEach(Array(counts.enumerated()), id: \.element.id) { index, count in
                    foldCountButton(count, first: index == 0)
                }
            }
            // Each open fold opens under the line, in the line's order.
            ForEach(counts.filter { openFolds.contains($0.id) }) { count in
                openFold(count)
            }
        }
    }

    private func foldCountButton(_ count: FoldCount, first: Bool) -> some View {
        let isOpen = openFolds.contains(count.id)
        return Button { toggleFold(count.id) } label: {
            Text(first ? TodayWords.capitalizedFirst(count.label) : count.label)
                .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.title)
        .accessibilityValue(isOpen ? "Open" : "Folded")
        .accessibilityIdentifier(foldIdentifier(count.id))
        .font(.system(size: 13))
    }

    private func foldIdentifier(_ key: String) -> String {
        switch key {
        case Fold.finished: "desk.finished"
        case Fold.stale: "desk.stale-line"
        default: "desk.fold.\(key)"
        }
    }

    private func toggleFold(_ key: String) {
        withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion)) {
            if openFolds.contains(key) { openFolds.remove(key) } else { openFolds.insert(key) }
        }
    }

    /// An open fold: its own sentence as a header that folds it again, then
    /// exactly the rows the fold always held.
    private func openFold(_ count: FoldCount) -> some View {
        AliveGroupCard {
            Button { toggleFold(count.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(count.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Folds this away")
            .accessibilityIdentifier("desk.fold")
            foldContent(count.id)
        }
        .transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion))
    }

    @ViewBuilder
    private func foldContent(_ key: String) -> some View {
        switch key {
        case Fold.finished:
            finishedContent
        case Fold.blocked:
            ForEach(cap(blockedItems), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: DeskPageContent.stuckReason(item),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
            }
            overflowLine(blockedItems.count)
        case Fold.watching:
            ForEach(cap(watchItems), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
            }
            overflowLine(watchItems.count)
        case Fold.github:
            githubContent
        case Fold.schedule:
            scheduleContent
        case Fold.stale:
            ForEach(cap(staleItems), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
            }
            overflowLine(staleItems.count)
        case Fold.ideas:
            ForEach(cap(ideas), id: \.id) { idea in
                DeskPageDetailRow(
                    title: TodayWords.line(idea.title, limit: 96),
                    line: "",
                    meta: UserDisplayFormatters.relativeISOTimestamp(idea.createdAt, unitsStyle: .abbreviated, fallback: ""))
            }
            overflowLine(ideas.count)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var finishedContent: some View {
        ForEach(finishedRows) { row in
            VStack(alignment: .leading, spacing: 3) {
                Button { askAbout(row.draft) } label: {
                    Text(row.title)
                        .font(.system(size: DeskPageMetrics.titleSize, weight: .semibold))
                        .foregroundStyle(NativeAgentShell.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(row.result)
                    .font(.system(size: DeskPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.meta)
                    .font(.system(size: DeskPageMetrics.metaSize))
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("desk.finished-row")
        }
    }

    @ViewBuilder
    private var githubContent: some View {
        let hands = DeskPageContent.githubNeedsOwner(githubItems)
            + DeskPageContent.githubNeedingAHand(githubItems)
        ForEach(cap(hands), id: \.itemId) { item in
            DeskPageDetailRow(
                title: DeskPageContent.githubTitle(item),
                line: "",
                meta: DeskPageContent.githubMeta(item, now: now))
        }
        overflowLine(hands.count)
        let rest = DeskPageContent.githubRest(githubItems)
        if !rest.isEmpty {
            let restOpen = openFolds.contains(Fold.githubRest)
            Button { toggleFold(Fold.githubRest) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(DeskPageContent.githubRestTitle(rest))
                        .font(.system(size: DeskPageMetrics.lineSize, weight: .medium))
                        .foregroundStyle(NativeAgentShell.secondary)
                    Image(systemName: "chevron.right")
                        .font(ShellType.captionSemibold)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .rotationEffect(.degrees(restOpen ? 90 : 0))
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(restOpen ? "Open" : "Folded")
            .accessibilityIdentifier("desk.fold.github-rest")
            if restOpen {
                ForEach(cap(rest), id: \.itemId) { item in
                    DeskPageDetailRow(
                        title: DeskPageContent.githubTitle(item),
                        line: "",
                        meta: DeskPageContent.githubMeta(item, now: now))
                }
                overflowLine(rest.count)
            }
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        ForEach(timedBots) { bot in
            DeskPageDetailRow(
                title: TodayWords.line(bot.name, limit: 110),
                line: bot.line,
                meta: bot.nextRun.map { DeskRelativeTimePresentation.text(for: $0, now: now) } ?? "")
        }
        ForEach(missedBots) { bot in
            DeskPageDetailRow(
                title: TodayWords.line(bot.name, limit: 110),
                line: bot.line,
                meta: BotsShelfRecord.shortDate(bot.dueAt))
        }
        ForEach(appModel.jobs) { job in
            DeskPageDetailRow(
                title: TodayWords.line(job.name, limit: 110),
                line: DeskPageContent.scheduleLine(job),
                meta: job.nextRunAt.map {
                    DeskRelativeTimePresentation.text(forISO: $0, now: now)
                } ?? "")
        }
        Button("Open the schedule") { sheet = .schedule }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("desk.open-schedule")
    }

    // MARK: lane honesty

    /// One plain sentence per unreadable lane. A lane that failed must never
    /// render as an empty, calm board.
    private var laneTrouble: [String] {
        var out: [String] = []
        if snapshot.deskUnavailable != nil {
            out.append("I couldn't read the board just now, so this page is short a section.")
        }
        if snapshot.executions.unavailableReason != nil {
            out.append("I couldn't read what's running, so \u{201C}what I'm working on\u{201D} may be short.")
        }
        if snapshot.github.unavailableReason != nil {
            out.append("I couldn't read the GitHub watcher just now.")
        }
        return out
    }

    // MARK: pieces

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { openFolds.contains(key) },
            set: { isOpen in
                if isOpen { openFolds.insert(key) } else { openFolds.remove(key) }
            })
    }

    private func cap<T>(_ rows: [T]) -> [T] {
        Array(rows.prefix(DeskPageMetrics.foldRowCap))
    }

    @ViewBuilder
    private func overflowLine(_ total: Int) -> some View {
        if total > DeskPageMetrics.foldRowCap {
            let hidden = total - DeskPageMetrics.foldRowCap
            // The line already names where the rest are; now it goes there.
            // It is also the page's only remaining door to the full desk, which
            // "Clear them" used to hold open.
            Button("\(DeskPageWords.spelled(hidden)) more, on the full desk.") { sheet = .classicDesk }
                .buttonStyle(.plain)
                .font(.system(size: DeskPageMetrics.metaSize))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("desk.open-full-desk")
        }
    }

    // MARK: actions

    /// The SAME mutation seam the classic desk's buttons use — one
    /// `desk_close` through `DeskToolDispatchRouter`, same ledger, same gate.
    private func close(_ item: DeskItem) {
        guard actionInFlight == nil else { return }
        actionInFlight = item.handle
        actionNotice = nil
        let action = DeskQuickAction.close(
            handle: item.handle,
            outcome: DeskQuickAction.deskCloseOutcome)
        let router = DeskToolDispatchRouter(dataRoot: PersistenceCore.defaultDataRoot())
        Task { @MainActor in
            let outcome = await DeskActionRunner.perform(action, via: router)
            actionNotice = outcome.message
            actionInFlight = nil
            await reload()
        }
    }

    /// The one seam between this page and the conversation: a row hands Chat a
    /// draft that carries the item's own handle, so her next turn acts on the
    /// SAME durable item instead of a retold version of it. Every row on this
    /// page that opens something uses it — waiting, projects, finished work.
    @MainActor
    private func askAbout(_ draft: String) {
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }

    /// What a row says when it reaches Chat: the item by handle, and the reason
    /// she stored — whole, not the row's shortened line.
    private static func draft(about item: DeskItem) -> String {
        let reason = [item.blockedReason, item.waitingOn]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var draft = "Desk item \(item.handle): \(item.title)"
        if let reason { draft += "\n\nWhat you wrote: \(reason)" }
        return draft
    }

    /// A click on a Desk reminder banner names an item; bringing THAT item into
    /// view is all this does. It waits for rows — a `scrollTo` before the load
    /// lands is a no-op — and clears the handle so the click opens once.
    ///
    /// Sol P1, 2026-09-13: a click while the Desk was ALREADY mounted lost the
    /// item. The route bumps `rootRouteVersion` and the handle is set after it,
    /// so `onChange` ran against the PREVIOUS snapshot — already `loaded`, and
    /// without the item — consumed the handle and scrolled nowhere, and the
    /// reload that followed published the row to a page no longer looking for
    /// it. So the handle is held until the item is actually on the board:
    /// every completed load re-checks (`loadStamp`), and only the reload that
    /// followed the route gives up (`giveUpIfMissing`) when the item is not
    /// there at all.
    @MainActor
    private func openPendingDeskItem(_ scroller: ScrollViewProxy, giveUpIfMissing: Bool = false) {
        guard let handle = appModel.pendingDeskHandle else { return }
        guard snapshot.loaded, items.contains(where: { $0.handle == handle }) else {
            if giveUpIfMissing { appModel.pendingDeskHandle = nil }
            return
        }
        appModel.pendingDeskHandle = nil
        // A row inside a closed fold cannot be scrolled to; open the fold it
        // lives in first.
        if blockedItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.blocked) }
        if watchItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.watching) }
        if projectRows.contains(where: { $0.parked && $0.id == handle }) { openFolds.insert(Fold.parked) }
        withAnimation(NativeAgentMotion.standard) { scroller.scrollTo("desk:\(handle)", anchor: .center) }
    }

    /// Returns true only when this read published its snapshot: a cancelled
    /// read, or one that lost the load gate, returns false and leaves the
    /// board — and any pending handle — to whoever did publish.
    @discardableResult
    @MainActor
    private func reload() async -> Bool {
        // Taken BEFORE the awaits, checked after: a read that lost the race
        // publishes nothing at all, rather than half-replacing the board.
        let token = loadGate.begin()
        _ = await appModel.refreshSchedulerJobs()
        let loaded = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(root: PersistenceCore.defaultDataRoot())
        }.value
        let missed = await Task.detached(priority: .userInitiated) {
            DeskMissedBot.load(root: PersistenceCore.defaultDataRoot())
        }.value
        // Unattended work off: no bot runs on its own, so none is on a timer.
        var timed: [DeskTimedBot] = []
        if await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: PersistenceCore.defaultDataRoot()) {
            timed = await Task.detached(priority: .userInitiated) {
                DeskTimedBot.load(root: PersistenceCore.defaultDataRoot())
            }.value
        }
        // Agent, 2026-09-02: thirty-five evolution proposals sat in needs_diff
        // since June and never reached anyone. They are ideas waiting for a
        // diff; the page says so.
        let waitingIdeas = (try? await EvolutionProposalStore(dataRoot: PersistenceCore.defaultDataRoot())
            .list(statuses: [.needsDiff])) ?? []
        guard !Task.isCancelled, loadGate.accepts(token) else { return false }
        now = Date()
        snapshot = loaded
        ideas = waitingIdeas
        missedBots = missed
        timedBots = timed
        // A completed publish. A pending banner handle gets another look here.
        loadStamp &+= 1
        return true
    }

    /// Bumped once per accepted publish, so a waiting notification handle is
    /// re-checked against every board that actually lands.
    @State private var loadStamp = 0

    @State private var ideas: [EvolutionProposal] = []
    /// Scheduled bot occurrences that never ran, counted apart from the timers.
    @State private var missedBots: [DeskMissedBot] = []
    /// Unpaused bots on a schedule, counted with the timers.
    @State private var timedBots: [DeskTimedBot] = []
}

// MARK: - Sheets

/// The surfaces this page folds to but does not re-implement. Nothing is lost:
/// the classic Desk, the scheduler and research all open in full.
enum DeskPageSheet: String, Identifiable {
    case classicDesk
    case schedule
    case research

    var id: String { rawValue }
}

private struct DeskPageSheetHost: View {
    let sheet: DeskPageSheet
    let voice: AgentVoice
    let onDone: () -> Void

    private var title: String {
        switch sheet {
        case .classicDesk: "\(voice.Possessive) full desk"
        case .schedule: "What runs on a timer"
        case .research: "Look something up"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(ShellType.bodySemibold)
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            Group {
                switch sheet {
                case .classicDesk: DeskView()
                case .schedule: SchedulerView()
                case .research: ResearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 700)
    }
}

// MARK: - Row furniture

/// The page's only section chrome: a small-caps label.
struct DeskPageSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: DeskPageMetrics.metaSize, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(NativeAgentShell.secondary)
    }
}

/// One thing in motion: a ring, the name, one line. Fixed height, so the grid
/// reads as a grid.
struct DeskWorkingCard: View {
    let title: String
    let detail: String
    let fraction: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AliveProgressRing(fraction: fraction)
            VStack(alignment: .leading, spacing: 3) {
                Text(TodayWords.bounded(title, limit: 48))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !detail.isEmpty {
                    Text(TodayWords.bounded(detail, limit: 64))
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 74)
        .aliveCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("desk.row")
    }
}

/// One project inside the Projects card: the name (the way into Chat about
/// it), its next step, and a bar when the board counts its parts.
struct DeskProjectRow: View {
    let title: String
    let line: String
    let meta: String
    var done: Int? = nil
    var total: Int? = nil
    /// The title is how he says something about this piece of work: it opens
    /// Chat with the item's handle attached. The name of the thing IS the way in.
    let onOpenTitle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Button(action: onOpenTitle) {
                    Text(TodayWords.bounded(title, limit: 64))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NativeAgentShell.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("desk.row.open")
                if !line.isEmpty {
                    Text(TodayWords.bounded(line, limit: 90))
                        .font(.system(size: 12))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(height: line.isEmpty ? TodayMetrics.rowContentHeightSingle : 34, alignment: .leading)
            Spacer(minLength: 12)
            if let done, let total, total > 0 {
                AliveProgressBar(done: done, total: total)
            } else if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityIdentifier("desk.row")
    }
}

/// A row inside an open fold. Same type sizes, no card — the fold itself is the
/// card, so twenty-one of these read as one block instead of twenty-one boxes.
struct DeskPageDetailRow: View {
    let title: String
    let line: String
    let meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: DeskPageMetrics.titleSize, weight: .semibold))
                .foregroundStyle(NativeAgentShell.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if !line.isEmpty {
                Text(line)
                    .font(.system(size: DeskPageMetrics.lineSize, weight: .medium))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: DeskPageMetrics.metaSize))
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("desk.detail-row")
    }
}

/// One folded row: a sentence, a chevron, and whatever it opens onto — the same
/// gesture Today's kept-moments row uses.
struct DeskPageFoldRow<Content: View>: View {
    let title: String
    let meta: String?
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: DeskPageMetrics.titleSize, weight: .semibold))
                    .foregroundStyle(NativeAgentShell.text)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(ShellType.captionSemibold)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Spacer(minLength: 8)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: DeskPageMetrics.metaSize))
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            }
            // The gesture belongs to the HEADER, not the card: with sixty rows
            // open, a click anywhere would otherwise fold them away again.
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(NativeAgentMotion.respecting(
                    NativeAgentMotion.quick, reduceMotion: reduceMotion
                )) { isOpen.toggle() }
            }
            .accessibilityAddTraits(.isButton)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 2)
                .transition(NativeAgentMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: DeskPageMetrics.rowRadius, style: .continuous)
                .fill(NativeAgentShell.quietFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DeskPageMetrics.rowRadius, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("desk.fold")
    }
}

/// One thing waiting on him, named, with its one action beside it.
struct DeskPageWaitingRow: View {
    let title: String
    let line: String
    let actionTitle: String
    let isBusy: Bool
    let action: () -> Void
    /// Closing an item he already dealt with somewhere else. It is not the
    /// row's job — answering is — so it lives on the row's menu rather than
    /// adding a second button to the page's most crowded card.
    var alreadyHandled: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AliveWaitingDot()
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "Something needs you" : TodayWords.bounded(title, limit: 80))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !line.isEmpty {
                    Text(TodayWords.bounded(line, limit: 100))
                        .font(.system(size: 13))
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(height: line.isEmpty ? TodayMetrics.rowContentHeightSingle : TodayMetrics.rowContentHeight,
                   alignment: .leading)
            Spacer(minLength: 12)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hazeTinted(.button)
                    .accessibilityIdentifier("desk.waiting.action")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if let alreadyHandled {
                Button("I already handled this", action: alreadyHandled)
                    .accessibilityIdentifier("desk.waiting.close")
            }
        }
    }
}
