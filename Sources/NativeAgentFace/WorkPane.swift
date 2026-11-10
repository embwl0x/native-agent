import SwiftUI
import NativeAgentShared

// Blueprint: | `WorkPane.swift` | Pane state and native Make/Sense hosts; shared Steps, Screen facts and read documents |

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
    var selectedMakeVersions: [String: String] = [:]
    /// User closure wins for all running turns; only the user can reopen the pane for them.
    @ObservationIgnored private var closedByUser: Set<String> = []
    @ObservationIgnored private var pendingUserClose = false
    /// Track auto-opened turns so each may open the pane only once.
    @ObservationIgnored private var autoOpened: Set<String> = []

    private var isOpen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.openKey) }
        set {
            guard isOpen != newValue else { return }
            UserDefaults.standard.set(newValue, forKey: Self.openKey)
        }
    }

    private var transient = false

    func snapshot(appModel: AppModel) -> WorkPaneSnapshot {
        let name: String
        let reference: String?
        switch tab {
        case .steps: name = "steps"; reference = nil
        case .screen: name = "screen"; reference = nil
        case .make(let ref):
            name = "make"
            reference = ref ?? appModel.face.slot(.makeShelf).value(as: MakeShelfFace.self)?.newest
        case .sense: name = "sense"; reference = nil
        }
        return .init(isVisible: isOpen, tab: name, reference: reference, version: reference.flatMap { selectedMakeVersions[$0] })
    }

    /// Close only auto-opened panes so idle settlement preserves the user's open choice.
    func closeIfIdle() {
        guard transient else { return }
        transient = false
        isOpen = false
    }

    func userToggle(appModel: AppModel) {
        if isOpen {
            if let turns = appModel.turnSessionsFace { closedByUser = Set(turns.activeTurnIDs.values) }
            else { pendingUserClose = true }
            transient = false
            isOpen = false
        } else {
            userShow(tab)
        }
    }

    func userShow(_ tab: WorkPaneTab) {
        closedByUser = []
        pendingUserClose = false
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
        guard !pendingUserClose, !closedByUser.contains(turnID) else { return }
        tab = .make(ref: nil)
        transient = false
        isOpen = true
    }

    func autoOpen(turnID: String, running: some Sequence<String>) {
        guard !pendingUserClose, !closedByUser.contains(turnID), !autoOpened.contains(turnID) else { return }
        autoOpened = autoOpened.intersection(running).union([turnID])
        guard !isOpen else { return }
        tab = .screen
        transient = true
        isOpen = true
    }

    func receiveActiveTurns(_ turns: [String: String]) {
        if pendingUserClose {
            closedByUser.formUnion(turns.values)
            pendingUserClose = false
        }
        if turns.isEmpty { closeIfIdle() }
    }
}

// MARK: - The pane

struct WorkPane: View {
    static let defaultWidth = 420.0
    static let minimumWidth = 320.0
    /// Preserve chat's minimum width before honoring the user's chosen pane width.
    static let floorWidth = 240.0

    let maximumWidth: Double
    @Environment(AppModel.self) private var appModel
    @FacePreference(WorkPaneState.widthKey) private var storedWidth = WorkPane.defaultWidth
    @State private var dragWidth: Double?
    @State private var dragStart: Double?
    private var sense: SenseViewFace? { appModel.face.slot(.senseView).value(as: SenseViewFace.self) }
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    var body: some View {
        FacePreferences(keys: [WorkPaneState.widthKey]) { preferenceContent }
    }

    @ViewBuilder private var preferenceContent: some View {
        let state = WorkPaneState.shared
        // Snapshot width is fixed; use the pane floor so the chat and composer retain their room.
        let width = quietOffscreenRead ? Self.floorWidth : min(dragWidth ?? storedWidth, maximumWidth)
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
                    if sense?.html != nil || state.tab == .sense {
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
                        if let sense {
                            WorkPaneSenseView(presentation: sense)
                        } else { FaceReadStatus(state: nil) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: Self.floorWidth, idealWidth: width, maxWidth: width)
        .onChange(of: storedWidth) { if dragStart == nil { dragWidth = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work pane")
        .accessibilityIdentifier("chat.work-pane")
        .modifier(FaceObservation(demand: .key(.senseView)))
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
                                // As wide as the person drags it, short of the reading room's column.
                                let lower = min(Self.minimumWidth, maximumWidth)
                                dragWidth = min(max(start - value.translation.width, lower), maximumWidth)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                guard let dragWidth else { return }
                                // The pane holds where it was let go until the saved width comes back from the body.
                                if dragWidth == storedWidth { self.dragWidth = nil } else { storedWidth = dragWidth }
                            }
                    )
                    .accessibilityHidden(true)
            }
    }
}

// MARK: - Steps

/// Derive step outcomes from tool results, not terminal reasons; an approval draws only as its conversation's row, never here.
/// The line and the rows each read their own part of the turn, so a tick of the line never redraws a row.
struct WorkPaneSteps: View {
    let sessionId: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.section) {
                WorkPaneStepsLine(sessionId: sessionId)
                WorkPaneStepRows(sessionId: sessionId)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NativeAgentShellLayout.roomGutter)
            .padding(.bottom, NativeAgentShellLayout.roomGutter)
        }
    }
}

/// What she is doing now, read alone: it changes as often as she moves.
private struct WorkPaneStepsLine: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text(appModel.turnPart("stepsLine", for: sessionId, WorkPaneFace.stepsLine))
            .font(.title3).foregroundStyle(.secondary)
    }
}

/// The steps, read alone: they redraw only when a step starts or ends, and each keeps its row by its id.
private struct WorkPaneStepRows: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()

    var body: some View {
        let steps = appModel.turnPart("steps", for: sessionId) { $0?.steps ?? [] }
        if !steps.isEmpty {
            FaceView(face: WorkPaneFace.steps(steps), door: ReadOnlyFaceDoor(), session: session)
        }
    }
}

// MARK: - Screen

/// Draw the source's masked picture or bounded returned read from this conversation's slot.
struct WorkPaneScreen: View {
    let sessionId: String
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let preview = appModel.turnFace(for: sessionId)?.preview, !preview.caption.isEmpty || preview.imageError != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let image = preview.imageData {
                        TurnPreviewImage(data: image, caption: preview.caption)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 0.5)
                            )
                            .accessibilityLabel("What I am looking at: \(preview.caption)")
                    } else if let failure = preview.imageError {
                        Text(failure).font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
                    } else if let readText = preview.readText {
                        FaceDocumentContent(text: readText, format: "code")
                            .accessibilityLabel("What I read: \(readText)")
                    }
                    FaceView(face: WorkPaneFace.screen(preview), open: { _ in }, act: { _, _, _ in })
                }
                .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                .padding(.bottom, NativeAgentShellLayout.roomGutter)
            }
            // The picture is fitted to the width, so a scroll bar that takes width would appear and hide without end; none is drawn.
            .scrollIndicators(.never)
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
        preferenceContent
    }

    @ViewBuilder private var preferenceContent: some View {
        let sessionId = appModel.activeChatSessionId
        let turn = appModel.turnFace(for: sessionId)
        let working = !isOpen && turn?.isWorking == true
        Button { WorkPaneState.shared.userToggle(appModel: appModel) } label: {
            HStack(spacing: 6) {
                if working, let turn {
                    PulsingDot(color: NativeAgentShell.secondary, size: 6, animates: true)
                    Text(turn.workPill ?? "Working")
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

}

// MARK: - Auto-open

/// Open only when a turn produces a screen; ordinary chat must not open the pane.
struct WorkPaneAutoOpen: View {
    @Environment(AppModel.self) private var appModel
    /// Start at none so the first artifact in an empty studio still counts as new.
    @State private var lastMake: String?? = .none
    private var makeSignal: String?? {
        appModel.face.slot(.makeShelf).select("newest", as: MakeShelfFace.self) {
            guard let value = $0, value.state == .ready else { return nil }
            return .some(value.newest.map { ref in ref + " " + String(value.versions.filter { $0.reference == ref }.count) })
        }
    }

    var body: some View {
        let roster = appModel.turnSessionsFace
        let sessionId = appModel.activeChatSessionId
        let turn = appModel.turnFace(for: sessionId)
        let showing = turn?.preview?.isShowable == true ? turn?.activeTurnID : nil
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: roster?.activeTurnIDs, initial: true) { _, active in
                if let active { WorkPaneState.shared.receiveActiveTurns(active) }
            }
            .onChange(of: showing) { _, turnID in
                guard let turnID else { return }
                WorkPaneState.shared.autoOpen(turnID: turnID, running: roster?.activeTurnIDs.values.map { $0 } ?? [])
            }
            .modifier(FaceObservation(demand: .key(.makeShelf)))
            .onChange(of: makeSignal, initial: true) { _, signal in
                guard let newest = signal else { return }
                defer { lastMake = .some(newest) }
                guard let lastMake, newest != lastMake,
                      let turnID = appModel.turnFace(for: appModel.activeChatSessionId)?.activeTurnID
                else { return }
                WorkPaneState.shared.autoOpenMake(turnID: turnID)
            }
    }
}

// MARK: - Menu

struct ShellViewCommands: Commands {
    let appModel: AppModel
    private var sidebarsHidden: Bool? { appModel.facePreference(WorkPaneState.sidebarsHiddenKey, as: Bool.self) }
    @AppStorage(WorkPaneState.openKey) private var workPaneOpen = false
    private var viewMode: String? { appModel.facePreference(ShellViewMode.key, as: String.self) }
    private var shotgunShortcut: String? { appModel.facePreference(ShotgunShortcut.storageKey, as: String.self) }
    private var warmth: Bool? { appModel.facePreference("uiMoodTint", as: Bool.self) }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            if let sidebarsHidden {
                Button(sidebarsHidden ? "Show Sidebar" : "Hide Sidebar") {
                    appModel.setFacePreference(.bool(!sidebarsHidden), for: WorkPaneState.sidebarsHiddenKey)
                }
                .keyboardShortcut("0", modifiers: .command)
            } else { Button("Reading Sidebar preference…") {}.disabled(true) }
            Button(workPaneOpen ? "Hide Work Pane" : "Show Work Pane") {
                WorkPaneState.shared.userToggle(appModel: appModel)
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            // Offer Work only in Advanced, matching the agent action's visibility rule.
            .disabled(viewMode != ShellViewMode.advanced)
            // Keep the menu action usable even if another app owns the configured shortcut.
            Button(ShotgunController.shared.isShown ? "Hide Shotgun" : "Show Shotgun") {
                ShotgunController.shared.toggle()
            }
            .keyboardShortcut(shotgunShortcut.flatMap(ShotgunShortcut.init(rawValue:))?.menuModifiers
                .map { KeyboardShortcut(.space, modifiers: $0) })
            // Offer warmth only in dark mode because MoodTintGate applies it only there.
            if AppearanceController.shared.isDark {
                Divider()
                if let warmth {
                    Toggle("Warmth in the glass", isOn: Binding(get: { warmth }, set: { value in
                        appModel.setFacePreference(.bool(value), for: "uiMoodTint")
                    }))
                } else { Button("Reading Warmth preference…") {}.disabled(true) }
            }
        }
    }
}
