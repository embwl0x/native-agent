// DeskPageView.swift
// The primary Desk: canonical work in plain words, with item actions in place.
// Store, execution, GitHub and schedule lanes retain their own failure states.

import SwiftUI
import AppKit
import PersistenceCore
import Desk
import GitHubConnector
import SelfImprovement
import TriggerScheduler
import WorkshopExecution
import Cognition
import BackgroundLoops
import NativeAgentShared
import ApprovalInbox
import NotificationInbox

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
    /// How many rows a fold shows before it says how many more there are.
    static let foldRowCap = 60
    /// Finished work is bounded harder than the board: it is a shelf of what
    /// just landed, not an archive. The history fold keeps older records reachable.
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
    var generatedTs: String?
    var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    var github: DeskLaneState<GitHubCommandItem> = .rows([])
    /// The same derived sequencing the projection renders (blockers, held
    /// rows, subtree rollups). Computed ONCE per read, off the main actor,
    /// because the projects lane asks it a question per row and `body` runs
    /// far more often than the board changes.
    var plan = DeskSequencing.Plan()
    var overview: WorkOverview?

    static let empty = DeskPageSnapshot()

    /// One canonical board read, with sequencing derived from those same items.
    static func load(desk: DeskFacade) async -> DeskPageSnapshot {
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

// MARK: - What the page says about that snapshot

/// Pure projections over the canonical board.
enum DeskPageContent {
    static func active(_ items: [DeskItem]) -> [DeskItem] {
        DeskBoardLayout.activeItems(items)
    }

    /// His to clear: a live row that names the owner as the party it waits on.
    static func waitingOnOwner(_ items: [DeskItem]) -> [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(active(items).filter(OwnerAttentionPolicy.waitsOnOwner))
    }

    /// Visible blocks that do not wait on the owner.
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

    /// Watch rows untouched past the freshness threshold
    /// that are not already counted as blocked or flagged.
    static func staleWatches(_ items: [DeskItem], now: Date) -> [DeskItem] {
        watches(items).filter { item in
            guard item.status != .blocked, item.status != .flag else { return false }
            guard let at = UserDisplayFormatters.parseISOTimestamp(item.updatedAt) else { return false }
            return Int(now.timeIntervalSince(at) / 86_400) >= DeskItemPresentation.staleThresholdDays
        }
    }

    /// One plain sentence for why a row is stuck. The inspector keeps the
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
        return "Blocked, with no reason written down."
    }

    static func itemDetail(_ item: DeskItem) -> String {
        if item.status == .blocked { return stuckReason(item) }
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

    static func githubNeedingAHand(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .actionNeeded })
    }

    static func githubNeedsOwner(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .needsUser })
    }

    static func githubAttention(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        DeskAttentionStrip.sortedGitHubItems(
            items.filter { DeskGitHubBucket.bucket(for: $0.state) == .attention })
    }

    static func githubRest(_ items: [GitHubCommandItem]) -> [GitHubCommandItem] {
        let claimed = Set(
            (githubNeedingAHand(items) + githubNeedsOwner(items) + githubAttention(items)).map(\.itemId))
        return DeskAttentionStrip.sortedGitHubItems(items.filter { !claimed.contains($0.itemId) })
    }

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

// MARK: - The page

struct DeskPageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false
    @AppStorage("cognitiveSubstrateEnabled") private var cognitiveSubstrateEnabled = true

    let rootRouteVersion: Int

    init(rootRouteVersion: Int = 0) {
        self.rootRouteVersion = rootRouteVersion
    }

    @State private var overviewSelection: WorkOverviewRow?
    @State private var snapshot = DeskPageSnapshot.empty
    @State private var now = Date()
    @State private var openFolds: Set<String> = []
    @State private var sheet: DeskPageSheet?
    @State private var actionNotice: DeskActionNotice?
    @State private var actionInFlight: String?
    @State private var selectedHandle: String?
    @State private var inspectorMode: DeskPaletteQuery.Verb?
    @State private var showingPalette = false
    @State private var watcherSelection: String?
    @State private var showingNags = false
    @State private var nagConfig = DeskNagConfig()
    @State private var revealCounts: [String: Int] = [:]
    @State private var herHour: DeskHerHourPresentation.State = .absent
    @State private var liveUpdateError: String?
    @State private var liveSubscriberID = UUID()
    @State private var liveUpdatesMounted = false
    @State private var vetoHandler = WorkshopObservatoryVetoHandler(
        dataRoot: PersistenceCore.defaultDataRoot())
    /// Only the NEWEST read may publish. `reload()` is called from racing
    /// places — store events, a route to the root, and every action
    /// that closes a sheet — and a slow early read landing after a fast later
    /// one would put stale items back on the board.
    @State private var loadGate = LatestAsyncRequestGate()

    private var items: [DeskItem] { snapshot.items }
    private var githubItems: [GitHubCommandItem] { snapshot.github.items }
    private var selectedItem: DeskItem? { items.first { $0.handle == selectedHandle } }
    private var paletteRows: [DeskPaletteRow] {
        DeskPageContent.active(items).map(DeskPaletteRow.init(item:))
            + DeskGitHubWaitingRollup.paletteRows(in: githubItems)
    }
    private var liveActivity: DeskLiveActivityPresentation.State {
        DeskLiveActivityPresentation.make(deskItems: laneOfItems, executions: snapshot.executions,
                                          generatedTs: snapshot.generatedTs, now: now)
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                // Looking something up is an action, not a count: a quiet
                // button on the header's baseline, not an item in the line.
                HStack(alignment: .firstTextBaseline) {
                    AlivePageHeader(title: "Desk", line: headerLine)
                    Spacer(minLength: 12)
                    Button {
                        Task { @MainActor in
                            let accepted = await reload()
                            actionNotice = DeskActionNotice(
                                text: accepted ? "Desk refreshed." : "Refresh superseded by newer Desk data.",
                                isError: !accepted)
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh Desk")
                    .help("Refresh the desk")
                    Button("Find item", systemImage: "magnifyingglass") { showingPalette = true }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                        .accessibilityIdentifier("desk.find-item")
                    Button("Reminders", systemImage: DeskItemPresentation.nagBellSymbol(config: nagConfig, now: now)) {
                        showingNags = true
                    }
                    .accessibilityValue(nagConfig.isMuted(now: now) ? "Muted" : nagConfig.enabled ? "On" : "Off")
                    .popover(isPresented: $showingNags) {
                        DeskNagsPanel(items: items, selectedHandle: selectedHandle,
                                      selectedTitle: selectedItem?.title, perform: { perform($0) },
                                      config: nagConfig, isBusy: actionInFlight != nil)
                    }
                    // ContentView owns the New Task sheet (a sheet attached
                    // here presents only once on macOS); the page posts.
                    Button {
                        NotificationCenter.default.post(name: .newWorkshopTaskRequest, object: nil)
                    } label: {
                        Label("New task", systemImage: "plus")
                            .font(.system(size: 13))
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("desk.new-task")
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

                liveActivityContent

                overviewContent

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

                if case .line(let text, let symbol) = herHour {
                    Label(text, systemImage: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if snapshot.loaded, laneTrouble.isEmpty, snapshot.overview?.now.isEmpty == true,
                   snapshot.overview?.needsYou.isEmpty == true, projectRows.isEmpty,
                   snapshot.overview?.recentlyDone.isEmpty == true, boardIsEmpty {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let notice = actionNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(notice.text)
                            .font(.system(size: DeskPageMetrics.metaSize))
                            .foregroundStyle(notice.isError ? NativeAgentShell.trouble : NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("desk.action-notice")
                        Spacer(minLength: 0)
                        Button { actionNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(notice.isError ? "Dismiss Desk error" : "Dismiss Desk confirmation")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                if let item = selectedItem {
                    DeskItemInspector(item: item, items: items, plan: snapshot.plan,
                                      now: now, isBusy: actionInFlight != nil, mode: inspectorMode,
                                      perform: { perform($0) },
                                      addNote: { text, completion in
                                          perform(.note(handle: item.handle, text: text), completion: completion)
                                      }, veto: { veto(item.handle) },
                                      select: { inspect($0) },
                                      dismiss: { selectedHandle = nil; inspectorMode = nil })
                        .id(item.handle)
                }
            }
            .background(.regularMaterial)
        }
        .sheet(isPresented: $showingPalette) {
            DeskCommandPaletteView(rows: paletteRows, selectedHandle: selectedHandle,
                                   onSelect: select,
                                   onCommand: applyPaletteCommand, isPresented: $showingPalette)
        }
        .onChange(of: showingPalette) { _, open in
            guard !open, let handle = watcherSelection else { return }
            withAnimation(NativeAgentMotion.standard) { scroller.scrollTo(handle, anchor: .center) }
        }
        .task {
            guard !quietOffscreenRead else { return }
            liveUpdatesMounted = true
            bindLiveUpdates()
        }
        .onDisappear {
            guard !quietOffscreenRead else { return }
            liveUpdatesMounted = false
            DeskLiveReloader.shared.deactivate(subscriber: liveSubscriberID)
        }
        .onChange(of: scenePhase) {
            guard !quietOffscreenRead else { return }
            DeskLiveReloader.shared.refreshVisibility(subscriber: liveSubscriberID)
        }
        .onChange(of: studioWanderEnabled) { signalLiveUpdate() }
        .onChange(of: cognitiveSubstrateEnabled) { signalLiveUpdate() }
        // A route to the Desk is a route to its ROOT: the folds close, the
        // stores are re-read.
        // This is also first paint — one task, owned by the view, instead of a
        // detached `Task {}` from onChange that outlived it.
        .liveTask(id: rootRouteVersion) {
            openFolds.removeAll()
            revealCounts.removeAll()
            selectedHandle = nil
            inspectorMode = nil
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
        .sheet(item: $overviewSelection) { row in
            MacWorkOverviewDetail(row: row, capturedAt: snapshot.overview?.capturedAt ?? "") {
                overviewSelection = nil
                Task { await reload() }
            }
        }
        .sheet(item: $sheet) { which in
            DeskPageSheetHost(sheet: which) {
                sheet = nil
                Task { await reload() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deskTaskCreated)) { _ in
            guard !quietOffscreenRead else { return }
            Task { await reload() }
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

    private var headerLine: String? { snapshot.overview?.headline }

    @ViewBuilder
    private var overviewContent: some View {
        if let overview = snapshot.overview {
            ForEach(overview.unavailable, id: \.self) { Text($0).foregroundStyle(NativeAgentShell.trouble) }
            overviewSection("Now", rows: overview.now)
            overviewSection("Needs you", rows: overview.needsYou, waiting: true)
            if let overflow = overview.needsYouOverflow {
                Text(overflow).font(.caption).foregroundStyle(NativeAgentShell.secondary)
            }
            overviewSection("Recently done", rows: overview.recentlyDone)
            if overview.omittedNow > 0 || overview.omittedRecentlyDone > 0 {
                Text("\(overview.omittedNow) other work items and \(overview.omittedRecentlyDone) older results remain in the board and history below.")
                    .font(.caption).foregroundStyle(NativeAgentShell.secondary)
            }
        }
    }

    private func overviewSection(_ title: String, rows: [WorkOverviewRow], waiting: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            AliveEyebrow(title)
            AliveGroupCard(waiting: waiting) {
                if rows.isEmpty { Text("Nothing here.").foregroundStyle(NativeAgentShell.secondary) }
                ForEach(rows) { row in
                    Button {
                        if row.reference.kind == .desk, items.contains(where: { $0.handle == row.reference.id }) {
                            inspect(row.reference.id)
                        } else { overviewSelection = row }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).font(.headline).foregroundStyle(NativeAgentShell.text)
                            Text(row.summary).foregroundStyle(NativeAgentShell.secondary).lineLimit(3)
                            Text([row.stateLabel(at: now), row.location].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desk.overview.\(row.id)")
                    .contextMenu {
                        if row.reference.kind == .desk,
                           let item = items.first(where: { $0.handle == row.reference.id }), item.requiresOwnerInput {
                            Button("Reply") { askAbout(Self.draft(about: item)) }
                            Button("Already handled") { close(item) }
                        }
                    }
                }
            }
        }
    }

    /// "Running, step two of five." + "3m ago" → "Running, step two of five · 3m ago".
    private static func detail(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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
            .contextMenu { Button("Details and actions") { inspect(row.id) } }
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
        let evidence = DeskMovementPresentation.evidence(snapshot.executions.items)
        let familyParents = Set(DeskProgramFamilyPresentation.families(from: laneOfItems, executions: snapshot.executions, now: now).map(\.id))
        let rows = DeskPageContent.projects(items, excluding: familyParents)
        return rows.map { item in
            let handles = DeskParking.subtreeHandles(item.handle, in: state)
            let live = snapshot.executions.items
                .filter { $0.deskHandle.map(handles.contains) ?? false }
                .filter { DeskParking.executionIsLive(status: $0.status) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
            let activity = DeskMovementPresentation.activity(item, evidence: evidence[item.handle], now: now).label
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
        static let blocked = "blocked"
        static let watching = "watching"
        static let github = "github"
        static let githubAttention = "github-attention"
        static let githubRest = "github-rest"
        static let schedule = "schedule"
        static let parked = "parked"
        static let stale = "stale"
        static let ideas = "ideas"
        static let other = "other"
        static let history = "history"
    }

    private var blockedItems: [DeskItem] { DeskPageContent.blocked(items) }
    /// Only the watches that have moved this week. The quiet ones are named
    /// once, in the grey line at the foot of the page.
    private var watchItems: [DeskItem] { DeskPageContent.freshWatches(items, now: now) }
    private var staleItems: [DeskItem] { DeskPageContent.staleWatches(items, now: now) }
    private var otherItems: [DeskItem] {
        let shown = Set(ownerItems.map(\.handle) + blockedItems.map(\.handle)
                        + watchItems.map(\.handle) + staleItems.map(\.handle) + projectRows.map(\.id))
        return DeskAttentionStrip.sortedDeskItems(DeskPageContent.active(items).filter { !shown.contains($0.handle) })
    }
    private var historyItems: [DeskItem] {
        DeskAttentionStrip.sortedDeskItems(items.filter { $0.status.isTerminal })
    }
    private var historyExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        snapshot.executions.items.filter { ["completed", "failed", "cancelled"].contains($0.status) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    private var boardIsEmpty: Bool {
        blockedItems.isEmpty && watchItems.isEmpty && otherItems.isEmpty
            && githubItems.isEmpty && appModel.engine.desk.jobs.isEmpty
    }

    // MARK: finished work

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
            do { return try execution.result.serialize(pretty: true) }
            catch { return "Result unavailable: \(error.localizedDescription)" }
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
        if !otherItems.isEmpty {
            out.append(FoldCount(id: Fold.other, label: "\(otherItems.count) other items",
                                 title: "Other work and pursuits"))
        }
        let history = historyItems.count + historyExecutions.count
        if history > 0 {
            out.append(FoldCount(id: Fold.history, label: "\(history) in history", title: "Finished history"))
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
        let jobs = appModel.engine.desk.jobs
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
        case Fold.other:
            ForEach(cap(otherItems, key: key), id: \.handle) { item in itemDetailRow(item) }
            overflowLine(otherItems.count, key: key)
        case Fold.history:
            ForEach(cap(historyItems, key: key), id: \.handle) { item in itemDetailRow(item) }
            overflowLine(historyItems.count, key: key)
            ForEach(cap(historyExecutions, key: "execution-history"), id: \.id) { execution in
                let meta = execution.verification.map(DeskExecutionPresentation.verificationLabel)
                    ?? DeskExecutionPresentation.pill(for: execution.status).label
                // Opens the canonical record, which shows the whole result.
                Button {
                    overviewSelection = WorkOverviewRow(reference: .init(kind: .execution, id: execution.id),
                        title: execution.title, summary: "", detail: Self.resultText(execution),
                        state: meta, updatedAt: execution.updatedAt)
                } label: {
                    DeskPageDetailRow(title: execution.title, line: Self.resultText(execution), meta: meta)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            overflowLine(historyExecutions.count, key: "execution-history")
        case Fold.blocked:
            ForEach(cap(blockedItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: DeskPageContent.itemDetail(item),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(blockedItems.count, key: key)
        case Fold.watching:
            ForEach(cap(watchItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(watchItems.count, key: key)
        case Fold.github:
            githubContent
        case Fold.schedule:
            scheduleContent
        case Fold.stale:
            ForEach(cap(staleItems, key: key), id: \.handle) { item in
                DeskPageDetailRow(
                    title: DeskPageContent.title(item),
                    line: TodayWords.line(item.summary ?? item.project, limit: 96),
                    meta: DeskRelativeTimePresentation.text(forISO: item.updatedAt, now: now))
                    .id("desk:\(item.handle)")
                    .contextMenu { Button("Details and actions") { inspect(item.handle) } }
            }
            overflowLine(staleItems.count, key: key)
        case Fold.ideas:
            ForEach(cap(ideas, key: key), id: \.id) { idea in
                DeskPageDetailRow(
                    title: TodayWords.line(idea.title, limit: 96),
                    line: "",
                    meta: UserDisplayFormatters.relativeISOTimestamp(idea.createdAt, unitsStyle: .abbreviated, fallback: ""))
            }
            overflowLine(ideas.count, key: key)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var githubContent: some View {
        let hands = DeskPageContent.githubNeedsOwner(githubItems)
            + DeskPageContent.githubNeedingAHand(githubItems)
        ForEach(cap(hands, key: Fold.github), id: \.itemId) { item in
            githubRow(item)
        }
        overflowLine(hands.count, key: Fold.github)
        let attention = DeskPageContent.githubAttention(githubItems)
        if !attention.isEmpty {
            AliveEyebrow(DeskGitHubBucket.attention.rawValue)
            ForEach(cap(attention, key: Fold.githubAttention), id: \.itemId) { item in
                githubRow(item)
            }
            overflowLine(attention.count, key: Fold.githubAttention)
        }
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
                ForEach(cap(rest, key: Fold.githubRest), id: \.itemId) { item in
                    githubRow(item)
                }
                overflowLine(rest.count, key: Fold.githubRest)
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
        ForEach(appModel.engine.desk.jobs) { job in
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
        if let liveUpdateError { out.append(liveUpdateError) }
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

    private func cap<T>(_ rows: [T], key: String) -> [T] {
        Array(rows.prefix(revealCounts[key] ?? DeskPageMetrics.foldRowCap))
    }

    @ViewBuilder
    private func overflowLine(_ total: Int, key: String) -> some View {
        let visible = revealCounts[key] ?? DeskPageMetrics.foldRowCap
        if total > visible {
            Button("Show \(min(total - visible, DeskPageMetrics.foldRowCap)) more") {
                revealCounts[key] = visible + DeskPageMetrics.foldRowCap
            }
                .buttonStyle(.plain)
                .font(.system(size: DeskPageMetrics.metaSize))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("desk.show-more.\(key)")
        }
    }

    // MARK: actions

    private func githubRow(_ item: GitHubCommandItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DeskPageDetailRow(title: DeskPageContent.githubTitle(item),
                              line: item.blocker.map { "\($0.detail) — \($0.owner)" }
                                  ?? item.finalReceipt ?? item.workLog.last?.summary ?? "",
                              meta: DeskPageContent.githubMeta(item, now: now))
            if let failure = DeskGitHubCallbackFailurePresentation.detail(for: item) {
                Text(failure.message).font(.caption).foregroundStyle(.red)
                if let noWork = failure.noWorkObserved {
                    Text(noWork ? "no work ran — resend safe" : "partial work possible")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .id(DeskGitHubWaitingRollup.paletteHandle(for: item))
    }

    private func itemDetailRow(_ item: DeskItem) -> some View {
        Button { inspect(item.handle) } label: {
            DeskPageDetailRow(title: DeskPageContent.title(item),
                              line: DeskPageContent.itemDetail(item),
                              meta: "\(item.status.rawValue) · \(item.project)")
        }
        .buttonStyle(.plain)
        .id("desk:\(item.handle)")
    }

    @ViewBuilder
    private var liveActivityContent: some View {
        switch liveActivity {
        case .quiet:
            EmptyView()
        case .unavailable(let notice):
            if snapshot.loaded {
                Text("\(notice.title): \(notice.detail)").font(.caption).foregroundStyle(.orange)
            }
        case .rows(let content):
            VStack(alignment: .leading, spacing: 8) {
                Text(content.asOfText)
                    .font(.caption)
                    .foregroundStyle(content.isStale ? Color.orange : Color.secondary)
                ForEach(content.rows) { row in
                    Button { inspect(row.id) } label: {
                        DeskPageDetailRow(title: row.summary,
                                          line: row.progress.map { "\($0.done) of \($0.total) · \($0.note ?? "")" } ?? "",
                                          meta: "\(row.assignee) · \(row.lastUpdateText)")
                    }
                    .buttonStyle(.plain)
                }
                if content.overflowCount > 0 {
                    Button("Find the other \(content.overflowCount) active items") { showingPalette = true }
                }
            }
        }
    }

    private func inspect(_ handle: String) {
        inspectorMode = nil
        selectedHandle = handle
    }

    private func select(_ handle: String) {
        if DeskGitHubWaitingRollup.isPaletteHandle(handle) {
            guard !DeskGitHubWaitingRollup.revealKeys(forPaletteHandle: handle, in: githubItems).isEmpty else { return }
            selectedHandle = handle
            inspectorMode = nil
            openFolds.insert(Fold.github)
            openFolds.insert(Fold.githubRest)
            revealCounts[Fold.githubRest] = githubItems.count
            watcherSelection = handle
        } else {
            watcherSelection = nil
            inspect(handle)
        }
    }

    private func applyPaletteCommand(_ verb: DeskPaletteQuery.Verb, handle: String) {
        guard actionInFlight == nil else {
            actionNotice = DeskActionNotice(text: DeskPaletteCommandApplication.actionInFlightMessage, isError: true)
            return
        }
        switch DeskPaletteCommandApplication.resolve(verb: verb, handle: handle, activeItems: DeskPageContent.active(items)) {
        case .dispatch(let action): perform(action)
        case .beginDefer(let handle): inspectorMode = .deferItem; selectedHandle = handle
        case .beginNote(let handle): inspectorMode = .note; selectedHandle = handle
        case .refused(let message): actionNotice = DeskActionNotice(text: message, isError: true)
        }
    }

    private func perform(_ action: DeskQuickAction, completion: ((Bool) -> Void)? = nil) {
        guard actionInFlight == nil else { return }
        inspectorMode = nil
        switch action {
        case .close(let handle, _), .closeIfCurrent(let handle, _, _), .setStatus(let handle, _),
             .defer_(let handle, _), .note(let handle, _): actionInFlight = handle
        default: actionInFlight = "desk-action"
        }
        actionNotice = nil
        let router = DeskToolDispatchRouter(dataRoot: PersistenceCore.defaultDataRoot())
        Task { @MainActor in
            let outcome = await DeskActionRunner.perform(action, via: router)
            actionNotice = DeskActionNotice(text: outcome.message, isError: !outcome.ok)
            await reload()
            actionInFlight = nil
            completion?(outcome.ok)
        }
    }

    private func veto(_ handle: String) {
        guard actionInFlight == nil else { return }
        actionInFlight = handle
        let handler = vetoHandler
        Task { @MainActor in
            let outcome = await handler.veto(handle)
            actionNotice = DeskPursuitVetoNotice.receipt(for: outcome)
            if WorkshopObservatoryVetoPresentation.shouldRefresh(after: outcome) { await reload() }
            actionInFlight = nil
        }
    }

    private static func readHerHour(dataRoot: URL, now: Date) async -> (state: DeskHerHourPresentation.State, nextRefreshAt: Date?) {
        guard await NativeCognitionRuntime.studioWanderIsInstalled(dataRoot: dataRoot) else { return (.absent, nil) }
        let state: StudioWanderLane.State
        do { state = try await StudioWanderLane.loadState(dataRoot: dataRoot) }
        catch { return (.line(text: "Her hour’s saved state is unavailable.", symbol: "exclamationmark.triangle"), nil) }
        let presentation = DeskHerHourPresentation.state(installed: true, entry: state.trace.last, now: now)
        let deadline = state.trace.last.flatMap { UserDisplayFormatters.parseISOTimestamp($0.at) }
            .map { DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: now) }
        return (presentation, deadline)
    }

    /// The canonical mutation seam — one
    /// `desk_close` through `DeskToolDispatchRouter`, same ledger, same gate.
    private func close(_ item: DeskItem) {
        perform(.close(
            handle: item.handle,
            outcome: DeskQuickAction.deskCloseOutcome))
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
        selectedHandle = handle
        inspectorMode = nil
        // A row inside a closed fold cannot be scrolled to; open the fold it
        // lives in first.
        if blockedItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.blocked) }
        if watchItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.watching) }
        if projectRows.contains(where: { $0.parked && $0.id == handle }) { openFolds.insert(Fold.parked) }
        withAnimation(NativeAgentMotion.standard) { scroller.scrollTo("desk:\(handle)", anchor: .center) }
    }

    private func signalLiveUpdate() {
        guard !quietOffscreenRead else { return }
        DeskLiveReloader.shared.sourceDidChange(subscriber: liveSubscriberID)
    }

    private func bindLiveUpdates() {
        guard !quietOffscreenRead, liveUpdatesMounted else { return }
        do {
            liveUpdateError = DeskLiveReloader.shared.activate(
                subscriber: liveSubscriberID,
                paths: try Self.liveUpdatePaths(dataRoot: PersistenceCore.defaultDataRoot()),
                reload: { _ = await reload() })
        } catch {
            liveUpdateError = "Desk live updates are unavailable: \(error.localizedDescription)"
        }
    }

    /// Exact sources formerly covered by the page's poll. Watching the record
    /// names in every existing directory also catches a first write after a
    /// reservation, and repairs to a record that could not yet be decoded.
    private static func liveUpdatePaths(dataRoot: URL) throws -> [URL] {
        let executions = dataRoot.appendingPathComponent("workshop/executions", isDirectory: true)
        var paths = [
            SwiftNativeDeskStore(dataRoot: dataRoot).opsPath,
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            SwiftNativeApprovalInbox(root: dataRoot).approvalsPath,
            LiveNotificationInbox.livePath(dataRoot: dataRoot),
            GitHubCommandStore(dataRoot: dataRoot).opsPath,
            GitHubCommandStore(dataRoot: dataRoot).basePath,
            executions,
            DeskFacade(dataRoot: dataRoot).jobsPath,
            dataRoot.appendingPathComponent("bots/definitions", isDirectory: true),
            dataRoot.appendingPathComponent("bots/runner-jobs.json"),
            EvolutionProposalStore(dataRoot: dataRoot).storePath,
            DeskNagConfigStore(dataRoot: dataRoot).configPath,
            StudioWanderLane.statePath(dataRoot: dataRoot),
            dataRoot.appendingPathComponent("trust/policy.json"),
        ]
        let directories: [URL]
        do {
            directories = try FileManager.default.contentsOfDirectory(
                at: executions, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return paths
        }
        for directory in directories where try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            paths.append(ExecutionRecordFile.canonicalPath(in: directory))
            paths.append(ExecutionRecordFile.legacyPath(in: directory))
        }
        return paths
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
        // The page's own root, the one its actions and bot reads use.
        let desk = DeskFacade(dataRoot: PersistenceCore.defaultDataRoot())
        let loaded = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(desk: desk)
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
        let presentationNow = Date()
        let loadedNags = await DeskNagConfigStore(dataRoot: PersistenceCore.defaultDataRoot()).load()
        let loadedHour = await Self.readHerHour(dataRoot: PersistenceCore.defaultDataRoot(), now: presentationNow)
        guard !Task.isCancelled, loadGate.accepts(token) else { return false }
        now = presentationNow
        snapshot = loaded
        nagConfig = loadedNags
        herHour = loadedHour.state
        if !quietOffscreenRead, liveUpdatesMounted {
            bindLiveUpdates()
            let movementExpiry = snapshot.executions.items.filter { $0.status == "running" }.compactMap {
                DeskActivityState.movementDate($0.lastMovementAt)?.addingTimeInterval(DeskActivityState.movementWindow)
            }.filter { $0 > presentationNow }.min()
            let watchExpiry = DeskPageContent.watches(items).compactMap {
                UserDisplayFormatters.parseISOTimestamp($0.updatedAt)?.addingTimeInterval(
                    Double(DeskItemPresentation.staleThresholdDays) * 86_400)
            }.filter { $0 > presentationNow }.min()
            let deferExpiry = items.compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }
                .filter { $0 > presentationNow }.min()
            let muteExpiry = nagConfig.mutedUntil == DeskNagConfig.indefiniteMuteSentinel
                ? nil : nagConfig.mutedUntil.flatMap(DeskSequencing.parseDeferStamp)
            let nowExpiry = items.filter { $0.status == .now }.compactMap {
                DeskActivityState.movementDate($0.updatedAt)?.addingTimeInterval(DeskActivityState.movementWindow)
            }.filter { $0 > presentationNow }.min()
            let state = deskState
            let familyParents = Set(DeskProgramFamilyPresentation.families(
                from: laneOfItems, executions: snapshot.executions, now: now).map(\.id))
            let parkingExpiry = DeskPageContent.projects(items, excluding: familyParents).compactMap { item -> Date? in
                let handles = DeskParking.subtreeHandles(item.handle, in: state)
                guard !snapshot.executions.items.contains(where: {
                    $0.deskHandle.map(handles.contains) == true && DeskParking.executionIsLive(status: $0.status)
                }), let touched = DeskParking.lastTouch(item, in: state) else { return nil }
                let plan = snapshot.plan.byHandle[item.handle]
                let days = plan.map { $0.totalCount > 0 && $0.doneCount == 0 } == true
                    ? DeskParking.untouchedPlanDays : DeskParking.quietDays
                return touched.addingTimeInterval(Double(days) * 86_400)
            }.filter { $0 > presentationNow }.min()
            let relativeStamps = items.map(\.updatedAt)
                + items.compactMap { $0.pursuit?.lastWorkedAt }
                + snapshot.executions.items.map(\.updatedAt)
                + snapshot.executions.items.compactMap(\.lastMovementAt)
                + githubItems.map { $0.motorUpdatedAt ?? $0.updatedAt }
                + appModel.engine.desk.jobs.compactMap(\.nextRunAt)
                + waitingIdeas.map(\.createdAt)
                + [snapshot.generatedTs].compactMap { $0 }
            let relativeDates = relativeStamps.compactMap(UserDisplayFormatters.parseISOTimestamp)
                + timed.compactMap(\.nextRun)
            let relativeExpiry = relativeDates.map {
                DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: presentationNow)
            }.min()
            DeskLiveReloader.shared.scheduleRefresh(
                subscriber: liveSubscriberID,
                at: [liveActivity.nextRefreshAt, movementExpiry, watchExpiry, deferExpiry, muteExpiry,
                     nowExpiry, parkingExpiry, relativeExpiry, loadedHour.nextRefreshAt]
                    .compactMap { $0 }.filter { $0 > presentationNow }.min())
        }
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

/// The focused surfaces the page opens without duplicating their controls.
enum DeskPageSheet: String, Identifiable {
    case schedule
    case research

    var id: String { rawValue }
}

private struct DeskPageSheetHost: View {
    let sheet: DeskPageSheet
    let onDone: () -> Void

    private var title: String {
        switch sheet {
        case .schedule: "What runs on a timer"
        case .research: "Look something up"
        }
    }

    var body: some View {
        PageSheetHost(title: title, onDone: onDone) {
            switch sheet {
            case .schedule: SchedulerView()
            case .research: ResearchView()
            }
        }
    }
}

/// A full surface a page folds to but does not re-implement, in a sheet: its
/// title and Done, then the surface itself. The Desk and Today both open
/// theirs this way.
struct PageSheetHost<Content: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder let content: () -> Content

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
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 700)
    }
}

// MARK: - Row furniture

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
    var details: (() -> Void)? = nil

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
            if let details { Button("Details and actions", action: details) }
            if let alreadyHandled {
                Button("I already handled this", action: alreadyHandled)
                    .accessibilityIdentifier("desk.waiting.close")
            }
        }
    }
}
