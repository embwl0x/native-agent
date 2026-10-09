import AppToolRuntime
import ChatOrchestration
import SwiftUI
import ApprovalInbox
import CoreGraphics
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Studio
import Senses

// User, 2026-10-04 (plan page, Agent reviewed): the Work pane. A column beside
// the chat, like Claude's panes, that only READS what the turn is doing —
// opening or closing it never touches the work itself. "Let User feel me here,
// not watch a dashboard perform being busy." Main window only; Simple view and
// the detached chat windows have none.

/// What the pane shows. `make` carries the ref the Make studio opens.
enum WorkPaneTab: Hashable {
    case steps
    case screen
    case make(ref: String?)
    case sense

    enum Kind: Hashable { case steps, screen, make, sense }

    var kind: Kind {
        switch self {
        case .steps: .steps
        case .screen: .screen
        case .make: .make
        case .sense: .sense
        }
    }
}

/// The pane's one owner, shared by the header button, the menu, the turn
/// card, the auto-open and the agent's `pane.show`. Whether it is open lives
/// in defaults, so views read it through `@AppStorage(openKey)` and it
/// survives a relaunch; the tab and which turns User closed it in live here.
@MainActor
@Observable
final class WorkPaneState {
    static let shared = WorkPaneState()
    static let openKey = "NativeAgent.workPane.open"
    /// The pane opened itself (or she opened it) for a turn's steps or
    /// screen; it closes again once nothing is running. User's own open, and
    /// one for something new in Make, stay open. In defaults, so a pane left
    /// open that way closes on the next launch too.
    static let transientKey = "NativeAgent.workPane.transient"
    static let widthKey = "NativeAgent.workPane.width"
    /// ⌘0: the rail and the conversations column hidden, chat fills the window.
    static let sidebarsHiddenKey = "NativeAgent.shell.sidebarsHidden"

    var tab: WorkPaneTab = .steps {
        didSet { if case .make(let ref) = tab { makeRef = ref } }
    }
    /// The last ref Make was opened on, so the tab keeps it across a switch.
    private(set) var makeRef: String?
    /// Turns that were running when User closed the pane. User closing it wins:
    /// nothing but User reopens it for those turns.
    @ObservationIgnored private var closedByUser: Set<String> = []
    /// Turns the pane already opened itself for: once per turn.
    @ObservationIgnored private var autoOpened: Set<String> = []

    private var isOpen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.openKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.openKey) }
    }

    private var transient: Bool {
        get { UserDefaults.standard.bool(forKey: Self.transientKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.transientKey) }
    }

    /// Nothing is running: a pane that opened itself goes again.
    func closeIfIdle() {
        guard transient else { return }
        transient = false
        isOpen = false
    }

    /// User's own open or close: the header button, ⌥⌘0.
    func userToggle(appModel: AppModel) {
        if isOpen {
            closedByUser = Set(appModel.engine.turns.activeTurnIDsBySession.values)
            transient = false
            isOpen = false
        } else {
            userShow(tab)
        }
    }

    func userShow(_ tab: WorkPaneTab) {
        closedByUser = []
        self.tab = tab
        transient = false
        isOpen = true
    }

    func userClosed(turnID: String?) -> Bool {
        turnID.map(closedByUser.contains) ?? false
    }

    /// `pane.show` / `pane.hide`. The composer verb has already refused a
    /// show in a turn User closed the pane during.
    func agentShow(_ tab: WorkPaneTab) {
        self.tab = tab
        if !isOpen || transient { transient = tab.kind != .make }
        isOpen = true
    }

    func agentHide() {
        transient = false
        isOpen = false
    }

    /// User picked a tab in a pane that opened itself: it is his now.
    func keep() { transient = false }

    /// The turn on screen produced its first showable screen: open on Screen,
    /// once per turn, unless User closed the pane during it. Already open, it
    /// stays on whatever tab User is reading.
    /// Something new landed in Make during a turn (an image she generated,
    /// a mockup she added): the pane pops it up, unless User closed it this turn.
    func autoOpenMake(turnID: String) {
        guard !closedByUser.contains(turnID) else { return }
        tab = .make(ref: nil)
        transient = false
        isOpen = true
    }

    func autoOpen(turnID: String, running: some Sequence<String>) {
        guard !closedByUser.contains(turnID), !autoOpened.contains(turnID) else { return }
        autoOpened = autoOpened.intersection(running).union([turnID])
        guard !isOpen else { return }
        tab = .screen
        transient = true
        isOpen = true
    }
}

// MARK: - The pane

struct WorkPane: View {
    static let defaultWidth = 420.0
    static let widthRange = 320.0...760.0
    /// How narrow the pane may get when the window itself is too tight to
    /// give it the width User chose; the chat keeps its own floor first.
    static let floorWidth = 240.0

    @Environment(AppModel.self) private var appModel
    @AppStorage(WorkPaneState.widthKey) private var storedWidth = WorkPane.defaultWidth
    @State private var dragWidth: Double?
    @State private var dragStart: Double?
    @State private var senses = SensesSurfaceState()
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        let state = WorkPaneState.shared
        // A screenshot's copy is 1280 wide, not the window's width. At the
        // width User gave the pane it squeezed the chat to its 380 floor, and
        // the composer wrapped tall and spilled into the pane. The copy draws
        // the pane at its floor so the chat keeps its room column, as on screen.
        let width = quietOffscreenRead ? Self.floorWidth : dragWidth ?? storedWidth
        let sessionId = appModel.activeChatSessionId
        HStack(spacing: 0) {
            seam(width: width)
            VStack(alignment: .leading, spacing: 0) {
                Picker("Work", selection: Binding(
                    get: { state.tab.kind },
                    set: { kind in
                        state.keep()
                        switch kind {
                        case .steps: state.tab = .steps
                        case .screen: state.tab = .screen
                        case .make: state.tab = .make(ref: state.makeRef)
                        case .sense: state.tab = .sense
                        }
                    }
                )) {
                    Text("Steps").tag(WorkPaneTab.Kind.steps)
                    Text("Screen").tag(WorkPaneTab.Kind.screen)
                    Text("Make").tag(WorkPaneTab.Kind.make)
                    if senses.interactiveView != nil || state.tab == .sense {
                        Text("Sense").tag(WorkPaneTab.Kind.sense)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                .padding(.top, 6)
                .padding(.bottom, 8)

                Group {
                    switch state.tab {
                    case .steps: WorkPaneSteps(sessionId: sessionId)
                    case .screen: WorkPaneScreen(sessionId: sessionId)
                    case .make(let ref): WorkPaneMake(ref: ref)
                    case .sense:
                        if let view = senses.interactiveView {
                            WorkPaneSenseView(presentation: view)
                        } else {
                            Text("No sense view is open.")
                                .font(ShellType.label).foregroundStyle(NativeAgentShell.secondary)
                                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: Self.floorWidth, idealWidth: width, maxWidth: width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work pane")
        .accessibilityIdentifier("chat.work-pane")
        .liveTask { await senses.observe() }
    }

    /// The hairline between chat and pane, and the handle that resizes it.
    private func seam(width: Double) -> some View {
        Rectangle()
            .fill(NativeAgentShell.hairline)
            .frame(width: 1)
            .ignoresSafeArea(edges: .top)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                dragWidth = min(max(start - value.translation.width, Self.widthRange.lowerBound),
                                                Self.widthRange.upperBound)
                            }
                            .onEnded { _ in
                                if let dragWidth { storedWidth = dragWidth }
                                dragWidth = nil
                                dragStart = nil
                            }
                    )
                    .accessibilityHidden(true)
            }
    }
}

// MARK: - Steps

/// The turn's steps as one-liners: what is happening now on top with a soft
/// live dot, what finished below it with a check. Pending approvals for this
/// chat sit above them, as the same card the transcript shows — one shared
/// inbox, so answering here answers there.
struct WorkPaneSteps: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel

    /// The finished steps, newest first, and what is happening now. Stream
    /// bumps and repeats of one action collapse; a terminal reason is the
    /// turn's outcome, not a step.
    static func steps(_ turn: TurnPresentationState) -> (now: String?, done: [String]) {
        var seen: [String] = []
        for activity in turn.activities where !activity.phase.isTerminal {
            guard let detail = activity.detail, seen.last != detail else { continue }
            seen.append(detail)
        }
        let now = turn.isTerminal ? nil : turn.currentAction
        if let now, seen.last == now { seen.removeLast() }
        return (now, seen.reversed())
    }

    /// The live line when the turn has no named action: it is thinking, or
    /// writing the reply.
    static func liveLine(_ turn: TurnPresentationState) -> String {
        turn.currentAction ?? (turn.streamedTextLength > 0 ? "Writing the reply" : "Thinking")
    }

    private var pendingApprovals: [ApprovalRecord] {
        appModel.engine.approvals.records.filter {
            $0.status == "pending" && !$0.isAgentsOwnDecision
                && ($0.chatOriginSessionId == sessionId || $0.chatCardSessionId == sessionId)
                && ApprovalPayloadPreviewPresentation.canResolve($0)
        }
    }

    var body: some View {
        let turn = appModel.engine.turns.lifecycle(for: sessionId)?.presentation
        let steps = turn.map(Self.steps) ?? (now: nil, done: [])
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pendingApprovals) { approval in
                    InlineApprovalCard(message: InlineApprovalCard.message(for: approval))
                }
                if let turn, !turn.isTerminal {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PulsingDot(color: NativeAgentShell.secondary, size: 7, animates: true)
                            .frame(width: 12)
                        line(steps.now ?? Self.liveLine(turn), style: NativeAgentShell.text)
                    }
                } else {
                    Text(steps.done.isEmpty
                         ? "When I'm working on something, my steps show up here."
                         : "Here's what I did last time.")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                ForEach(Array(steps.done.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.tertiary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        line(step, style: NativeAgentShell.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Done: \(step)")
                }
            }
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .padding(.bottom, NativeAgentShellLayout.roomGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ text: String, style: Color) -> some View {
        Text(text)
            .font(ShellType.label)
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }
}

// MARK: - Screen

/// What the turn is looking at while it drives the Mac, full pane width. The
/// capture side has already painted out every secure field, and the picture
/// never leaves this process.
struct WorkPaneScreen: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let preview = appModel.engine.turns.screenPreview(for: sessionId),
           preview.isShowable, let image = preview.image {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                                .strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5)
                        )
                        .accessibilityLabel("What I am looking at: \(preview.caption)")
                    Text(preview.caption)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.text)
                    Text("Secure fields are painted out, and this picture is not saved.")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                .padding(.bottom, NativeAgentShellLayout.roomGutter)
            }
        } else {
            Text("When I drive the Mac or the browser, what I see shows here.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.tertiary)
                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        }
    }
}

// MARK: - Make

/// The Make studio (WorkPaneMakeView.swift): what she made, in versions.
struct WorkPaneMake: View {
    let ref: String?

    var body: some View { WorkPaneMakeView(ref: ref) }
}

// MARK: - Header button

/// The room header's Work button. With the pane closed while a turn runs it
/// is the slim pill — "● Working · what is happening" — and a click opens the
/// pane. Idle, it is the word Work. It reads the turn itself so the header,
/// and ChatView above it, never observe turn state.
struct WorkPaneHeaderButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(WorkPaneState.openKey) private var isOpen = false

    var body: some View {
        let sessionId = appModel.activeChatSessionId
        let turn = appModel.engine.turns.lifecycle(for: sessionId)?.presentation
        let working = !isOpen && turn.map { !$0.isTerminal } == true
        Button { WorkPaneState.shared.userToggle(appModel: appModel) } label: {
            HStack(spacing: 6) {
                if working, let turn {
                    PulsingDot(color: NativeAgentShell.secondary, size: 6, animates: true)
                    Text(pillLine(turn, sessionId: sessionId))
                } else {
                    Text("Work")
                }
            }
            .font(ShellType.label)
            .foregroundStyle(isOpen ? NativeAgentShell.text : NativeAgentShell.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            // Reduce Transparency asks for more opacity, never less.
            .background { if reduceTransparency { Capsule().fill(NativeAgentShell.room) } }
            .glassEffect(reduceTransparency ? .identity : HouseGlass.plate.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide the Work pane (⌥⌘0)" : "Show the Work pane (⌥⌘0)")
        .accessibilityLabel(isOpen ? "Hide Work pane" : "Show Work pane")
        .accessibilityIdentifier("chat.work-button")
    }

    /// While the Mac is being driven the verb's own words win, as on the turn
    /// card; otherwise the turn's current action.
    private func pillLine(_ turn: TurnPresentationState, sessionId: String) -> String {
        let preview = appModel.engine.turns.screenPreview(for: sessionId)
        let what = preview?.isShowable == true ? preview?.caption : turn.currentAction
        // Cut at a word, short enough to sit beside the status dot.
        return what.map { "Working · " + TodayWords.bounded($0, limit: 36) } ?? "Working"
    }
}

// MARK: - Auto-open

/// Zero-size: opens the pane on Screen the first time the turn on screen
/// produces a showable screen (it started driving the Mac or the browser).
/// Plain chat turns never produce one, so they never open it.
struct WorkPaneAutoOpen: View {
    @Environment(AppModel.self) private var appModel
    /// The newest Make version seen; `.none` until the studio is first read,
    /// so a first artifact in an empty studio still counts as new.
    @State private var lastMake: String?? = .none
    @State private var makeRefs: [String] = []

    var body: some View {
        let turns = appModel.engine.turns
        let sessionId = appModel.activeChatSessionId
        let showing = turns.screenPreview(for: sessionId)?.isShowable == true
            ? turns.activeTurnIDsBySession[sessionId] : nil
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Nothing running anywhere: a pane that opened itself closes.
            .onChange(of: turns.activeTurnIDsBySession.isEmpty, initial: true) { _, idle in
                if idle { WorkPaneState.shared.closeIfIdle() }
            }
            .onChange(of: showing) { _, turnID in
                guard let turnID else { return }
                WorkPaneState.shared.autoOpen(turnID: turnID, running: turns.activeTurnIDsBySession.values)
            }
            // A new Make version while this chat's turn runs pops up in the pane.
            // Every ref's meta is watched; a new ref restarts this with its meta too.
            .task(id: makeRefs) {
                let studio = MakeStudio(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
                try? FileManager.default.createDirectory(at: studio.root, withIntermediateDirectories: true)
                await ViewFileRefreshTask.run(paths: [studio.root] + makeRefs.map { studio.folder($0).appendingPathComponent("meta.json") }) {
                    let refs = ((try? FileManager.default.contentsOfDirectory(atPath: studio.root.path)) ?? [])
                        .filter(MakeStudio.isRef).sorted()
                    let newest = studio.newestRef().flatMap(studio.meta).map { "\($0.ref) \($0.versions.count)" }
                    defer {
                        lastMake = .some(newest)
                        if refs != makeRefs { makeRefs = refs }
                    }
                    guard let lastMake, newest != lastMake,
                          let turnID = appModel.engine.turns.activeTurnIDsBySession[appModel.activeChatSessionId]
                    else { return }
                    WorkPaneState.shared.autoOpenMake(turnID: turnID)
                }
            }
    }
}

// MARK: - Menu

/// View ▸ Hide Sidebar (⌘0), Show Work Pane (⌥⌘0), Show Shotgun (its chosen
/// shortcut) and, in dark mode, Warmth in the glass (Simple's words).
struct ShellViewCommands: Commands {
    let appModel: AppModel
    @AppStorage(WorkPaneState.sidebarsHiddenKey) private var sidebarsHidden = false
    @AppStorage(WorkPaneState.openKey) private var workPaneOpen = false
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @AppStorage(ShotgunShortcut.storageKey) private var shotgunShortcut = ShotgunShortcut.optionSpace.rawValue
    /// Simple's settings menu carries the same switch; this is Advanced's.
    @AppStorage(MoodTintPreference.key) private var warmth = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(sidebarsHidden ? "Show Sidebar" : "Hide Sidebar") { sidebarsHidden.toggle() }
                .keyboardShortcut("0", modifiers: .command)
            Button(workPaneOpen ? "Hide Work Pane" : "Show Work Pane") {
                WorkPaneState.shared.userToggle(appModel: appModel)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            // Only Advanced has a Work pane (the agent's show_pane refuses the same).
            .disabled(SimpleViewMode.resolved(viewMode) != SimpleViewMode.advanced)
            // Shown with the chosen shortcut; the item works even when another
            // app owns that shortcut or it is off.
            Button(ShotgunController.shared.isShown ? "Hide Shotgun" : "Show Shotgun") {
                ShotgunController.shared.toggle()
            }
            .keyboardShortcut((ShotgunShortcut(rawValue: shotgunShortcut) ?? .optionSpace).menuModifiers
                .map { KeyboardShortcut(.space, modifiers: $0) })
            // The warmth only lands in dark mode (MoodTintGate), so it is
            // offered only there.
            if AppearanceController.shared.isDark {
                Divider()
                Toggle("Warmth in the glass", isOn: $warmth)
            }
        }
    }
}
