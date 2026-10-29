import StandingBots
import SwiftUI
import AppKit
import PersistenceCore
import Desk
import EngineRuntime
import TriggerScheduler
import WorkshopExecution
import Cognition
import BackgroundLoops
import NativeAgentShared
import ApprovalInbox
import NotificationInbox

// Blueprint: | `DeskPageView.swift` | `DeskPageView`: canonical work page, state, navigation and actions; store/execution failures stay distinct |

struct DeskPageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage(StudioWanderLane.enabledDefaultsKey) private var studioWanderEnabled = false
    @AppStorage("cognitiveSubstrateEnabled") private var cognitiveSubstrateEnabled = true

    let rootRouteVersion: Int

    init(rootRouteVersion: Int = 0) {
        self.rootRouteVersion = rootRouteVersion
    }

    @State var overviewSelection: WorkOverviewRow?
    private var desk: DeskFacade { appModel.engine.desk }
    var snapshot: DeskPageSnapshot { desk.page }
    private var readCount: Int { desk.readCount }
    var now: Date { snapshot.now }
    @State var openFolds: Set<String> = []
    private var projectRows: [DeskPageContent.ProjectRow] { snapshot.rows.projects }
    @State var sheet: DeskPageSheet?
    @State private var actionNotice: DeskActionNotice?
    @State private var actionInFlight: String?
    @State private var selectedHandle: String?
    @State private var inspectorMode: DeskPaletteQuery.Verb?
    @State private var showingPalette = false
    @State private var showingNags = false
    private var nagConfig: DeskNagConfig { snapshot.nagConfig }
    @State var revealCounts: [String: Int] = [:]
    private var herHour: DeskHerHourPresentation.State { snapshot.herHour }
    private var liveUpdateError: String? { desk.liveUpdateError }
    var items: [DeskItem] { snapshot.boardItems }
    private var selectedItem: DeskItem? { items.first { $0.handle == selectedHandle } }
    private var paletteRows: [DeskPaletteRow] {
        DeskPageContent.active(items).map(DeskPaletteRow.init(item:))
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                // Lookup actions share the header baseline.
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
                    // ContentView owns the New Task sheet; the page requests presentation.
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
                                       onSelect: inspect, onCommand: applyPaletteCommand))
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCommandPaletteRequest)) { _ in
            guard !quietOffscreenRead else { return }
            showingPalette = true
        }
        .task {
            guard !quietOffscreenRead else { return }
            appModel.deskHoldsCommandPalette = true
        }
        .onDisappear {
            guard !quietOffscreenRead else { return }
            appModel.deskHoldsCommandPalette = false
        }
        .onChange(of: studioWanderEnabled) { signalLiveUpdate() }
        .onChange(of: cognitiveSubstrateEnabled) { signalLiveUpdate() }
        // Root navigation closes folds and reloads in the view-owned task.
        .quietReadTask(id: rootRouteVersion) {
            openFolds.removeAll()
            revealCounts.removeAll()
            selectedHandle = nil
            inspectorMode = nil
            let published = await reload()
            // Only a published, uncancelled root refresh may discard a missing reminder target.
            guard published, !Task.isCancelled else { return }
            openPendingDeskItem(scroller, giveUpIfMissing: true)
        }
        .sheet(item: $overviewSelection) { row in
            MacWorkOverviewDetail(reference: row.reference) {
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
        // A later snapshot may contain the pending reminder target.
        .onChange(of: snapshot.id) { openPendingDeskItem(scroller) }
        }
    }

    // MARK: waiting on you
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

    // MARK: lane honesty
    /// An unreadable lane says so rather than rendering as an empty board.
    private var laneTrouble: [String] {
        var out: [String] = []
        if let liveUpdateError { out.append(liveUpdateError) }
        if snapshot.deskUnavailable != nil {
            out.append("I couldn't read the board just now, so this page is short a section.")
        }
        if snapshot.executions.unavailableReason != nil {
            out.append("I couldn't read what's running, so \u{201C}what I'm working on\u{201D} may be short.")
        }
        return out
    }

    // MARK: actions
    @ViewBuilder
    private var liveActivityContent: some View {
        switch snapshot.rows.activity {
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

    func inspect(_ handle: String) {
        inspectorMode = nil
        selectedHandle = handle
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
        let router = DeskToolDispatchRouter(dataRoot: appModel.engine.dataRoot)
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
        let handler = desk.vetoHandler
        Task { @MainActor in
            let outcome = await handler.veto(handle)
            actionNotice = DeskPursuitVetoNotice.receipt(for: outcome)
            if outcome.shouldRefresh { await reload() }
            actionInFlight = nil
        }
    }

    /// Close through the canonical Desk router, ledger and gate.
    private func close(_ item: DeskItem) {
        perform(.close(
            handle: item.handle,
            outcome: DeskQuickAction.deskCloseOutcome))
    }

    /// Every row opens Chat with a draft carrying the same durable item's handle.
    @MainActor
    private func askAbout(_ draft: String) {
        NotificationCenter.default.post(name: .openChatDraftRequest, object: draft)
    }

    /// Hold the reminder target until it appears; only the post-route reload may discard a missing target.
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
        // Open the target's fold before scrolling to its row.
        if blockedItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.blocked) }
        if watchItems.contains(where: { $0.handle == handle }) { openFolds.insert(Fold.watching) }
        if projectRows.contains(where: { $0.parked && $0.id == handle }) { openFolds.insert(Fold.parked) }
        withAnimation(NativeAgentMotion.standard) { scroller.scrollTo("desk:\(handle)", anchor: .center) }
    }

    private func signalLiveUpdate() {
        guard !quietOffscreenRead else { return }
        Task { await desk.signalRefresh() }
    }

    @discardableResult
    @MainActor
    private func reload() async -> Bool {
        return await desk.refresh()
    }

}
