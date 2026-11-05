import AppToolRuntime
import ChatSessionWork
import SwiftUI
import ApprovalTransactions
import ApprovalInbox
import CoreGraphics
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Studio
import Senses

// Blueprint: | `WorkPane.swift` | `WorkPaneState`, `WorkPane`: read-only tabs, visibility and turn-driven auto-open |

// Pane visibility must never change the work it observes.

/// Carry Make identity so opening the tab reaches the same artifact.
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

/// Share pane ownership across controls and actions; persist visibility across launches.
/// Keep tab selection and user-closed turn identities local to this owner.
@MainActor
@Observable
final class WorkPaneState {
    static let shared = WorkPaneState()
    static let openKey = "NativeAgent.workPane.open"
    /// Auto-opened panes close when work ends; user opens and new Make artifacts stay open.
    /// Persist auto-open state so an idle pane also closes after relaunch.
    static let transientKey = "NativeAgent.workPane.transient"
    static let widthKey = "NativeAgent.workPane.width"
    static let sidebarsHiddenKey = "NativeAgent.shell.sidebarsHidden"

    var tab: WorkPaneTab = .steps {
        didSet { if case .make(let ref) = tab { makeRef = ref } }
    }
    /// Retain Make identity across tab switches so selection cannot jump to another artifact.
    private(set) var makeRef: String?
    /// User closure wins for all running turns; only the user can reopen the pane for them.
    @ObservationIgnored private var closedByUser: Set<String> = []
    /// Track auto-opened turns so each may open the pane only once.
    @ObservationIgnored private var autoOpened: Set<String> = []

    private var isOpen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.openKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.openKey) }
    }

    private var transient: Bool {
        get { UserDefaults.standard.bool(forKey: Self.transientKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.transientKey) }
    }

    /// Close only auto-opened panes so idle settlement preserves the user's open choice.
    func closeIfIdle() {
        guard transient else { return }
        transient = false
        isOpen = false
    }

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

    /// The composer already refuses reopening a pane the user closed during this turn.
    func agentShow(_ tab: WorkPaneTab) {
        self.tab = tab
        if !isOpen || transient { transient = tab.kind != .make }
        isOpen = true
    }

    func agentHide() {
        transient = false
        isOpen = false
    }

    /// Choosing a tab makes an auto-opened pane user-owned so settlement cannot close it.
    func keep() { transient = false }

    /// Auto-open once for a first screen or new Make artifact unless the user closed this turn.
    /// Preserve the selected tab when the pane is already open.
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
    /// Preserve chat's minimum width before honoring the user's chosen pane width.
    static let floorWidth = 240.0

    @Environment(AppModel.self) private var appModel
    @AppStorage(WorkPaneState.widthKey) private var storedWidth = WorkPane.defaultWidth
    @State private var dragWidth: Double?
    @State private var dragStart: Double?
    private var senses: SensesFacade { appModel.engine.senses }
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        let state = WorkPaneState.shared
        // Snapshot width is fixed; use the pane floor so the chat and composer retain their room.
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
                    case .make(let ref): WorkPaneMakeView(ref: ref)
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
    }

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

/// Derive step outcomes from tool results, not terminal reasons; share approvals with the transcript inbox.
struct WorkPaneSteps: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel

    /// Collapse streaming repeats and exclude terminal reasons so the step list reflects actual actions.
    static func steps(_ turn: TurnPresentationState)
        -> (now: String?, done: [(text: String, outcome: TurnPresentationActivity.Outcome?)]) {
        var seen: [(text: String, outcome: TurnPresentationActivity.Outcome?)] = []
        for activity in turn.activities where !activity.phase.isTerminal {
            guard let detail = activity.detail, seen.last?.text != detail else { continue }
            seen.append((detail, activity.outcome))
        }
        let now = turn.isTerminal ? nil : turn.writing?.line ?? turn.currentAction
        if let now, seen.last?.text == now { seen.removeLast() }
        return (now, seen.reversed())
    }

    /// With no named action, distinguish thinking from writing instead of inventing a tool step.
    static func liveLine(_ turn: TurnPresentationState) -> String {
        turn.currentAction ?? (turn.streamedTextLength > 0 ? "Writing the reply" : "Thinking")
    }

    private var pendingApprovals: [ApprovalRecord] {
        appModel.engine.approvals.records.filter {
            $0.status == "pending" && !$0.isAgentsOwnDecision
                && ($0.chatOriginSessionId == sessionId || $0.chatCardSessionId == sessionId)
                && ApprovalChatCards.canResolve($0)
        }
    }

    var body: some View {
        let turn = appModel.engine.turns.lifecycle(for: sessionId)?.presentation
        let steps = turn.map(Self.steps) ?? (now: nil, done: [])
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pendingApprovals) { approval in
                    InlineApprovalCard(message: ChatMessage(approval: approval))
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
                        Image(systemName: step.outcome == .ok ? "checkmark" : "xmark")
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.tertiary)
                            .opacity(step.outcome == nil ? 0 : 1)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        line(step.text, style: NativeAgentShell.secondary)
                    }
                    .accessibilityElement(children: .combine)
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

/// Capture already redacts secure fields; keep the screen picture inside this process.
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

// MARK: - Header button

/// Observe busy state in this leaf so Work status cannot invalidate the header or ChatView.
struct WorkPaneHeaderButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(WorkPaneState.openKey) private var isOpen = false

    var body: some View {
        let sessionId = appModel.activeChatSessionId
        let turn = appModel.engine.turns.lifecycle(for: sessionId)?.presentation
        let working = !isOpen && (appModel.engine.turns.isBusy(sessionId) || appModel.engine.turns.isStreaming(sessionId))
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

    /// Prefer the driving verb's words so Work status agrees with the turn card.
    private func pillLine(_ turn: TurnPresentationState, sessionId: String) -> String {
        let preview = appModel.engine.turns.screenPreview(for: sessionId)
        let what = preview?.isShowable == true ? preview?.caption : turn.currentAction
        // Cut at words so the short status remains readable beside its dot.
        return what.map { "Working · " + TodayWords.bounded($0, limit: 36) } ?? "Working"
    }
}

// MARK: - Auto-open

/// Open only when a turn produces a screen; ordinary chat must not open the pane.
struct WorkPaneAutoOpen: View {
    @Environment(AppModel.self) private var appModel
    /// Start at none so the first artifact in an empty studio still counts as new.
    @State private var lastMake: String?? = .none
    private var makeShelf: MakeStudio.Shelf { appModel.engine.make }

    var body: some View {
        let turns = appModel.engine.turns
        let sessionId = appModel.activeChatSessionId
        let showing = turns.screenPreview(for: sessionId)?.isShowable == true
            ? turns.activeTurnIDsBySession[sessionId] : nil
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: turns.activeTurnIDsBySession.isEmpty, initial: true) { _, idle in
                if idle { WorkPaneState.shared.closeIfIdle() }
            }
            .onChange(of: showing) { _, turnID in
                guard let turnID else { return }
                WorkPaneState.shared.autoOpen(turnID: turnID, running: turns.activeTurnIDsBySession.values)
            }
            .task {
                makeShelf.start()
            }
            .onChange(of: makeShelf.loaded ? makeShelf.newest.map { "\($0.ref) \($0.versions.count)" } ?? "" : nil, initial: true) { _, signal in
                guard let signal else { return }
                let newest = signal.isEmpty ? nil : signal
                defer { lastMake = .some(newest) }
                guard let lastMake, newest != lastMake,
                      let turnID = appModel.engine.turns.activeTurnIDsBySession[appModel.activeChatSessionId]
                else { return }
                WorkPaneState.shared.autoOpenMake(turnID: turnID)
            }
    }
}

// MARK: - Menu

struct ShellViewCommands: Commands {
    let appModel: AppModel
    @AppStorage(WorkPaneState.sidebarsHiddenKey) private var sidebarsHidden = false
    @AppStorage(WorkPaneState.openKey) private var workPaneOpen = false
    @AppStorage(SimpleViewMode.key) private var viewMode = ""
    @AppStorage(ShotgunShortcut.storageKey) private var shotgunShortcut = ShotgunShortcut.optionSpace.rawValue
    /// Share the warmth switch with Simple settings so both modes keep the same preference.
    @AppStorage(MoodTintPreference.key) private var warmth = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(sidebarsHidden ? "Show Sidebar" : "Hide Sidebar") { sidebarsHidden.toggle() }
                .keyboardShortcut("0", modifiers: .command)
            Button(workPaneOpen ? "Hide Work Pane" : "Show Work Pane") {
                WorkPaneState.shared.userToggle(appModel: appModel)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            // Offer Work only in Advanced, matching the agent action's visibility rule.
            .disabled(SimpleViewMode.resolved(viewMode) != SimpleViewMode.advanced)
            // Keep the menu action usable even if another app owns the configured shortcut.
            Button(ShotgunController.shared.isShown ? "Hide Shotgun" : "Show Shotgun") {
                ShotgunController.shared.toggle()
            }
            .keyboardShortcut(ShotgunShortcut(rawValue: shotgunShortcut)?.menuModifiers
                .map { KeyboardShortcut(.space, modifiers: $0) })
            // Offer warmth only in dark mode because MoodTintGate applies it only there.
            if AppearanceController.shared.isDark {
                Divider()
                Toggle("Warmth in the glass", isOn: $warmth)
            }
        }
    }
}
