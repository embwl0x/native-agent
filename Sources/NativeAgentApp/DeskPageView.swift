import StandingBots
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

// MARK: - Metrics

enum DeskPageMetrics {
    // On the shell's one ramp (ShellType): a row's title is the 16 step, its
    // sentence and its meta line the 13 step. 11 is not on the scale.
    static let titleSize: CGFloat = ShellType.bodySize
    static let lineSize: CGFloat = ShellType.labelSize
    static let metaSize: CGFloat = ShellType.labelSize
    /// How many rows a fold shows before it says how many more there are.
    static let foldRowCap = 60
}

extension DeskPageContent {
    static func githubMeta(_ item: GitHubCommandItem, now: Date) -> String {
        let state = DeskGitHubStatePillPresentation.pill(for: item).label.lowercased()
        let when = DeskRelativeTimePresentation.text(
            forISO: item.motorUpdatedAt ?? item.updatedAt, now: now)
        return "\(item.repository) · #\(item.number) · \(state) · \(when)"
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
    @State private var readCount = 0
    @State private var now = Date()
    @State private var openFolds: Set<String> = []
    @State private var projectRows: [DeskPageContent.ProjectRow] = []
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
    @State private var watchGeneration: UInt64 = 0
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
                    .disabled(readCount > 0)
                    Button("Find item", systemImage: "magnifyingglass") { showingPalette = true }
                        .help("Find an item (⌘K)")
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

                PageReadStatus(
                    isReading: !snapshot.loaded || readCount > 0,
                    text: !snapshot.loaded ? "Reading the Desk…" : readCount > 0 ? "Refreshing the Desk…" : nil
                )

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
                        AliveGroupCard(lazy: true) {
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
            .houseSurface(in: Rectangle())
        }
        // The one ⌘K palette, with the Desk's rows and verbs in it.
        .sheet(isPresented: $showingPalette) {
            CommandPaletteView(
                isPresented: $showingPalette,
                desk: DeskPaletteScope(rows: paletteRows, selectedHandle: selectedHandle,
                                       onSelect: select, onCommand: applyPaletteCommand))
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
            guard !quietOffscreenRead else { return }
            showingPalette = true
        }
        .onChange(of: showingPalette) { _, open in
            guard !open, let handle = watcherSelection else { return }
            withAnimation(NativeAgentMotion.standard) { scroller.scrollTo(handle, anchor: .center) }
        }
        .task {
            guard !quietOffscreenRead else { return }
            liveUpdatesMounted = true
            appModel.deskHoldsCommandPalette = true
            await bindLiveUpdates()
        }
        .onDisappear {
            guard !quietOffscreenRead else { return }
            liveUpdatesMounted = false
            watchGeneration &+= 1
            appModel.deskHoldsCommandPalette = false
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
        .quietReadTask(id: rootRouteVersion) {
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

    @State private var ownerItems: [DeskItem] = []

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
                        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                            Text(row.title).font(ShellType.rowTitle).foregroundStyle(NativeAgentShell.text)
                            Text(row.summary).font(ShellType.label).foregroundStyle(NativeAgentShell.secondary).lineLimit(3)
                            Text([row.stateLabel(at: now), row.location].compactMap { $0 }.joined(separator: " · "))
                                .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("desk.overview.\(row.id)")
                    .contextMenu {
                        if row.reference.kind == .desk,
                           let item = items.first(where: { $0.handle == row.reference.id }), item.requiresOwnerInput {
                            Button("Reply") { askAbout(DeskPageContent.draft(about: item)) }
                            Button("Already handled") { close(item) }
                        }
                    }
                }
            }
        }
    }

    // MARK: projects

    private func projectRow(_ row: DeskPageContent.ProjectRow) -> some View {
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
    /// Derived once per load: `body` asked for it several times per redraw,
    /// and each ask rebuilt every row and parsed every timestamp.
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
        static let other = "other"
        static let history = "history"
    }

    @State private var blockedItems: [DeskItem] = []
    @State private var watchItems: [DeskItem] = []
    @State private var staleItems: [DeskItem] = []
    @State private var otherItems: [DeskItem] = []
    @State private var historyItems: [DeskItem] = []
    @State private var historyExecutions: [WorkshopExecution.WorkshopExecutionRecord] = []

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
            catch { return UserFacingError.message(error, action: "show the result") }
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
        withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.arrive, reduceMotion: reduceMotion)) {
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
        .transition(NativeAgentMotion.arrivalFade)
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
                    line: DeskPageContent.itemDetail(item, in: items),
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
                              line: DeskPageContent.itemDetail(item, in: items),
                              meta: "\(item.status.displayLabel) · \(item.project)")
        }
        .buttonStyle(.plain)
        .id("desk:\(item.handle)")
    }

    @ViewBuilder
    private var liveActivityContent: some View {
        switch liveActivity {
        case .quiet:
            EmptyView()
        case .unavailable(let reason):
            if snapshot.loaded {
                Text("Live Activity unavailable: \(reason)").font(.caption).foregroundStyle(.orange)
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
            let outcome = await router.perform(action)
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
            if outcome.shouldRefresh { await reload() }
            actionInFlight = nil
        }
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
        guard !quietOffscreenRead, let handle = appModel.pendingDeskHandle else { return }
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

    private func bindLiveUpdates() async {
        guard !quietOffscreenRead, liveUpdatesMounted else { return }
        watchGeneration &+= 1
        let generation = watchGeneration
        do {
            let paths = try await Task.detached(priority: .utility) {
                try await DeskFacade(dataRoot: PersistenceCore.defaultDataRoot()).liveUpdatePaths()
            }.value
            guard !Task.isCancelled, liveUpdatesMounted, generation == watchGeneration else { return }
            liveUpdateError = nil
            DeskLiveReloader.shared.activate(
                subscriber: liveSubscriberID,
                paths: paths,
                reload: { _ = await reload() })
        } catch {
            guard !Task.isCancelled, liveUpdatesMounted, generation == watchGeneration else { return }
            liveUpdateError = UserFacingError.message(error, action: "turn on Desk live updates")
        }
    }

    /// Returns true only when this read published its snapshot: a cancelled
    /// read, or one that lost the load gate, returns false and leaves the
    /// board — and any pending handle — to whoever did publish.
    @discardableResult
    @MainActor
    private func reload() async -> Bool {
        readCount += 1
        defer { readCount -= 1 }
        // Taken BEFORE the awaits, checked after: a read that lost the race
        // publishes nothing at all, rather than half-replacing the board.
        let token = loadGate.begin()
        _ = await appModel.refreshSchedulerJobs()
        // The page's own root, the one its actions and bot reads use.
        let desk = DeskFacade(dataRoot: PersistenceCore.defaultDataRoot())
        let (loaded, missed, timed, presentationNow, loadedNags, hour, hourUnavailable) = await desk.loadPage()
        let loadedHour = hourUnavailable
            ? DeskHerHourPresentation.State.line(text: "Her hour’s saved state is unavailable.", symbol: "exclamationmark.triangle")
            : DeskHerHourPresentation.state(installed: true, entry: hour, now: presentationNow)
        let hourExpiry = hour.flatMap { UserDisplayFormatters.parseISOTimestamp($0.at) }
            .map { DeskRelativeTimePresentation.nextRefreshAt(for: $0, now: presentationNow) }
        let jobStamps = appModel.engine.desk.jobs.compactMap(\.nextRunAt)
        let projection = await Task.detached(priority: .userInitiated) {
            DeskPageContent.project(snapshot: loaded, now: presentationNow, nags: loadedNags,
                                    timedBots: timed, jobStamps: jobStamps, hourExpiry: hourExpiry)
        }.value
        await bindLiveUpdates()
        guard !Task.isCancelled, loadGate.accepts(token) else { return false }
        now = presentationNow
        snapshot = loaded
        (projectRows, ownerItems, blockedItems, watchItems, staleItems, otherItems, historyItems, historyExecutions, _) = projection
        nagConfig = loadedNags
        herHour = loadedHour
        if !quietOffscreenRead, liveUpdatesMounted {
            DeskLiveReloader.shared.scheduleRefresh(subscriber: liveSubscriberID, at: projection.8)
        }
        missedBots = missed
        timedBots = timed
        // A completed publish. A pending banner handle gets another look here.
        loadStamp &+= 1
        return true
    }

    /// Bumped once per accepted publish, so a waiting notification handle is
    /// re-checked against every board that actually lands.
    @State private var loadStamp = 0

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

struct DeskActionNotice: Equatable {
    let text: String
    let isError: Bool
}

/// What the Desk says after a veto settles. Every outcome gets a line — a
/// refused write must never look like a completed one.
enum DeskPursuitVetoNotice {
    static func receipt(for outcome: WorkshopObservatoryVetoHandler.Outcome) -> DeskActionNotice {
        switch outcome {
        case .completed:
            return DeskActionNotice(text: "Pursuit vetoed and closed.", isError: false)
        case .alreadyVetoed:
            return DeskActionNotice(text: "Pursuit was already vetoed.", isError: false)
        case .inFlight:
            return DeskActionNotice(text: "That veto is still being written.", isError: false)
        case .failed(let detail):
            return DeskActionNotice(text: "Veto failed: \(detail)", isError: true)
        }
    }
}

extension DeskExecutionPresentation {
    struct Pill: Sendable, Equatable {
        let label: String
        let tone: DeskPresentationTone
    }

    static func pill(for status: String) -> Pill {
        switch status {
        case "running": return Pill(label: "running", tone: .info)
        case "queued": return Pill(label: "queued", tone: .neutral)
        case "blocked_on_approval": return Pill(label: "needs approval", tone: .warning)
        case "completed": return Pill(label: "done", tone: .success)
        case "failed": return Pill(label: "failed", tone: .danger)
        case "cancelled": return Pill(label: "cancelled", tone: .neutral)
        default:
            let human = status.replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Pill(label: human.isEmpty ? "unknown status" : "unknown: \(human)", tone: .neutral)
        }
    }

    static func verificationLabel(_ verification: WorkshopVerificationRecord) -> String {
        switch verification.status {
        case .satisfied:
            let methods = verification.methods.map { method in
                switch method {
                case "exact_output": return "exact output"
                case "file_bytes": return "file bytes"
                default: return method.replacingOccurrences(of: "_", with: " ")
                }
            }.filter { !$0.isEmpty }.joined(separator: " + ")
            return methods.isEmpty ? "verified" : "verified: \(methods)"
        case .failed:
            return "verification failed"
        case .unverified:
            return "completed; outcome not independently verified"
        }
    }
}


/// HER HOUR, on the Desk — personality-depth item 9.
///
/// One line, at the bottom, saying what she did with the hour that was hers. It
/// is a TRACE, not a task: it has no action, no count, no badge, and it never
/// becomes a row User has to clear. The lane writes no desk ops (Agent's veto —
/// her aesthetic life is not board work), so this reads the lane's own bounded
/// file directly and renders its newest entry.
///
/// ABSENT when the lane is not installed. Not "off", not a placeholder, not a
/// zero — absent, exactly the way the lane itself is absent when the switch is
/// off. A Desk that shows "Her hour: disabled" would be advertising a feature at
/// a man who turned it off.
enum DeskHerHourPresentation {
    enum State: Sendable, Equatable {
        case absent
        /// Her own closing line, plus how long ago. Nothing else: no verdict,
        /// no outcome adjective we chose, no progress.
        case line(text: String, symbol: String)
    }

    /// The whole rule. Pure, so the Desk's claim about her hour is testable
    /// without a running app or an installed lane.
    static func state(
        installed: Bool,
        entry: StudioWanderLane.TraceEntry?,
        now: Date
    ) -> State {
        guard installed, let entry else { return .absent }
        let words = entry.line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return .absent }
        let when = DeskRelativeTimePresentation.text(forISO: entry.at, now: now)
        return .line(text: "\(bounded(words)) · \(when)", symbol: symbol(entry.outcome))
    }

    /// Icons, not labels. The three endings are equal in standing — a decline is
    /// not a lesser outcome — so none of them gets a word here that ranks it.
    static func symbol(_ outcome: StudioWanderLane.Outcome) -> String {
        switch outcome {
        case .chose: return "eye"
        case .declined: return "moon.zzz"
        case .noArtifact: return "eye.slash"
        }
    }

    static let maximumCharacters = 160

    private static func bounded(_ value: String) -> String {
        value.truncated(to: maximumCharacters, keeping: maximumCharacters - 1)
    }
}

enum DeskGitHubCallbackFailurePresentation {
    struct Detail: Equatable, Sendable {
        let message: String
        let noWorkObserved: Bool?
    }

    private static let failedStatuses: Set<String> = [
        "failed", "failure", "error", "stalled", "timeout", "timed_out",
        "canceled", "cancelled", "completed_without_reply",
    ]
    private static let successfulStatuses: Set<String> = ["completed", "ok", "success"]

    static func detail(for item: GitHubCommandItem) -> Detail? {
        let status = (item.lastCallbackStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let error = nonEmpty(item.lastCallbackErrorMessage)
        let noWorkObserved = item.lastCallbackNoWorkObserved

        if failedStatuses.contains(status) {
            return Detail(
                message: error ?? fallbackMessage(for: status),
                noWorkObserved: noWorkObserved
            )
        }

        // A non-success status paired with an error/resend-safety field is
        // conflicting callback evidence. Surface it rather than silently
        // treating an unknown producer spelling as a healthy completion.
        guard !successfulStatuses.contains(status), error != nil || noWorkObserved != nil else {
            return nil
        }
        let statusText = status.isEmpty ? "no usable status" : "status \(status)"
        return Detail(
            message: error ?? "Codex callback returned \(statusText) without an error detail.",
            noWorkObserved: noWorkObserved
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fallbackMessage(for status: String) -> String {
        switch status {
        case "completed_without_reply":
            return "Codex callback ended without a final result."
        case "stalled":
            return "Codex callback stalled without an error detail."
        case "timeout", "timed_out":
            return "Codex callback timed out without an error detail."
        default:
            return "Codex callback failed without an error detail."
        }
    }
}
