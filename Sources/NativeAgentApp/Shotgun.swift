// Shotgun (User, 2026-10-04): when the agent starts driving the Mac in the chat
// on screen, the main window steps aside and this small floating glass chat
// takes its place — she drives, User rides shotgun. User's rulings:
//   1. She sees straight through it and clicks straight through it, so it
//      never needs moving (PersonOnlyWindows in Core: her captures leave it
//      out, her own pointer events fall through it, her keystrokes wait while
//      its composer has the keyboard).
//   2. While it is up, Stop is the only hand-back: his input anywhere never
//      takes the Mac from her (MacAttention). She has her own pointer: her
//      pointer actions unhook his mouse for their length and put his cursor
//      back (AgentPointerHold in MacControl), and AgentPointerOverlay below
//      shows where hers is.
// The composer's Shotgun switch turns the stepping aside off; the Shotgun
// shortcut (⌥Space by default, chosen in Settings) and View ▸ Show Shotgun
// work either way.

import AppKit
import Carbon.HIToolbox
import MacControl
import NativeAgentCore
import SwiftUI

/// Non-activating, so clicking it never takes the front from the app she is
/// working in; key only when its composer needs the keyboard. Titled (with
/// the title bar hidden) so its edges resize it; folded into the name pill it
/// goes borderless.
final class ShotgunPanel: NSPanel {
    static let fullStyle: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]
    static let pillStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    static let minSize = NSSize(width: 320, height: 360)
    static let maxSize = NSSize(width: 640, height: 900)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: ShotgunController.defaultSize),
            styleMask: Self.fullStyle,
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        // Ruling 1: out of every capture that honours it. Her own captures
        // also leave it out by window number (PersonOnlyWindows).
        sharingType = .none
        setFull(true)
    }

    /// Full: resizable within User's bounds, no traffic lights. Pill: borderless.
    func setFull(_ full: Bool) {
        styleMask = full ? Self.fullStyle : Self.pillStyle
        contentMinSize = full ? Self.minSize : NSSize(width: 60, height: 24)
        contentMaxSize = full ? Self.maxSize : NSSize(width: 640, height: 200)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Shotgun shortcut. A picker, not a key recorder.
enum ShotgunShortcut: String, CaseIterable, Identifiable {
    case optionSpace = "option-space"
    case controlOptionSpace = "control-option-space"
    case shiftCommandSpace = "shift-command-space"
    case off

    static let storageKey = "NativeAgent.shotgun.shortcut"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .shiftCommandSpace: "⇧⌘Space"
        case .off: "Off"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .shiftCommandSpace: UInt32(shiftKey | cmdKey)
        case .off: nil
        }
    }

    var menuModifiers: SwiftUI.EventModifiers? {
        switch self {
        case .optionSpace: .option
        case .controlOptionSpace: [.control, .option]
        case .shiftCommandSpace: [.shift, .command]
        case .off: nil
        }
    }

    static var current: ShotgunShortcut {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .optionSpace
    }
}

@MainActor
@Observable
final class ShotgunController: NSObject, NSWindowDelegate {
    static let shared = ShotgunController()
    /// The composer's switch. On: NativeAgent steps aside when she starts driving.
    static let enabledKey = "NativeAgent.shotgun.enabled"
    /// Where User last left it: the panel's bottom-right corner, "x,y".
    static let cornerKey = "NativeAgent.shotgun.corner"
    /// The size User last gave it, "w,h".
    static let sizeKey = "NativeAgent.shotgun.size"
    static let defaultSize = NSSize(width: 400, height: 560)
    /// Inside the screen's visible frame: above the Dock, below the menu bar.
    static let margin: CGFloat = 16
    /// How long "Done" stays open before it folds into the name pill.
    static let collapseAfter: Duration = .seconds(120)

    private(set) var isShown = false
    /// Folded into the small name pill after a finished turn.
    private(set) var collapsed = false
    /// False while the person holds the Mac (human takeover), so Resume shows.
    private(set) var driverAllowed = MacAttentionSessionStore.shared.currentDriverAllowed
    /// The shortcut that could not be registered, if any (another app has it).
    private(set) var shortcutTaken: ShotgunShortcut?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var panel: ShotgunPanel?
    /// The main window Shotgun stepped aside for, until it is brought back.
    @ObservationIgnored private var hiddenMain: NSWindow?
    /// The turn that already stepped aside: once per turn, so a main window
    /// User brought back stays back.
    @ObservationIgnored private var steppedAsideTurn: String?
    /// True while the panel is placed or animated, so only User's drag becomes
    /// the remembered spot.
    @ObservationIgnored private var placing = false
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var toldTaken: Set<ShotgunShortcut> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickAwayMonitor: Any?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    /// Her pointer, drawn where her last pointer action happened.
    @ObservationIgnored private let agentPointer = AgentPointerOverlay()
    /// Where her last pointer action was (CGEvent space): the screen she drives.
    @ObservationIgnored private var lastAgentPoint: CGPoint?

    private override init() { super.init() }

    func attach(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        PersonOnlyWindows.install(passPointerThrough: { Self.onMain { $0.passPointerThrough() } })
        PersonOnlyWindows.observeAgent(
            motor: {
                DispatchQueue.main.async { MainActor.assumeIsolated { ShotgunController.shared.maybeStepAside() } }
            },
            pointer: { point, pressed in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { ShotgunController.shared.agentPointerMoved(to: point, pressed: pressed) }
                }
            }
        )
        applyShortcut()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { ShotgunController.shared.appBecameActive() } })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { ShotgunController.shared.windowBecameKey(window) }
        })
        observeTurns()
        Task { @MainActor in
            for await _ in await MacAttentionSessionStore.shared.driverChanges() {
                ShotgunController.shared.driverAllowed = MacAttentionSessionStore.shared.currentDriverAllowed
            }
        }
    }

    // MARK: - User's controls

    /// The shortcut and View ▸ Show/Hide Shotgun.
    func toggle() {
        if isShown { hide() } else { show(from: nil, makeKey: true) }
    }

    /// The name pill: Shotgun opens back out where it was.
    func unfold() { setCollapsed(false) }

    /// Open / Expand: NativeAgent comes back as it was, and Shotgun goes.
    func expand() {
        let main = hiddenMain ?? Self.mainWindow()
        hiddenMain = nil
        hide()
        NSApp.activate(ignoringOtherApps: true)
        if let main {
            main.alphaValue = 1
            main.makeKeyAndOrderFront(nil)
        } else {
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        }
    }

    /// ×: Shotgun closes fully. NativeAgent stays wherever it is.
    func close() { hide() }

    /// Resume, while the person holds the Mac: the same handback as the
    /// composer's "Let agent use Mac", from the person's own click.
    func resume() {
        guard let generation = MacAttentionSessionStore.shared.userHandoffGeneration() else { return }
        Task { await MacAttentionSessionStore.shared.giveAgentControl(userGeneration: generation) }
    }

    /// After a send from Shotgun: the keyboard goes back to the app in front
    /// (the one she is driving), and her held keystrokes go on. Ordering out
    /// drops key; ordering back in does not take it.
    func giveKeyboardBack() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        publish()
    }

    /// The turn on screen finished (true) or is running again (false). Done
    /// folds into the name pill after two minutes, or at the person's next
    /// click in another app.
    func setDone(_ done: Bool) {
        collapseTask?.cancel()
        collapseTask = nil
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
        guard done else {
            setCollapsed(false)
            return
        }
        guard isShown, !collapsed else { return }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(for: Self.collapseAfter)
            guard !Task.isCancelled else { return }
            ShotgunController.shared.collapse()
        }
        // A global monitor only sees events sent to other apps: a click in
        // Shotgun itself never folds it.
        // Its own top edge (the hidden title bar) is handled by the window
        // server and reaches this monitor too: a click on Shotgun is not away.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard ShotgunController.shared.panel?.frame.contains(point) != true else { return }
                ShotgunController.shared.collapse()
            }
        }
    }

    private func collapse() {
        collapseTask?.cancel()
        collapseTask = nil
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
        guard isShown else { return }
        setCollapsed(true)
    }

    /// Into the name pill (borderless, sized by the pill itself) or back out
    /// to the size User gave it, keeping the bottom-right corner.
    private func setCollapsed(_ fold: Bool) {
        guard collapsed != fold else { return }
        collapsed = fold
        guard let panel else { return }
        placing = true
        panel.setFull(!fold)
        if !fold {
            let corner = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
            let size = savedSize()
            panel.setFrame(clampToScreen(NSRect(x: corner.x - size.width, y: corner.y,
                                                width: size.width, height: size.height),
                                         screen: panel.screen), display: true)
        }
        placing = false
        publish()
    }

    // MARK: - Shortcut

    /// Registers the chosen shortcut, replacing the last. A shortcut another
    /// app already owns is said once, in plain words; the View menu item
    /// keeps working.
    func applyShortcut() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        shortcutTaken = nil
        if hotKeyHandler == nil {
            var pressed = EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ -> OSStatus in
                    guard let event, let id = hotKeyID(of: event),
                          id.signature == fourCharCode("NASG"), id.id == 2
                    else { return OSStatus(eventNotHandledErr) }
                    Task { @MainActor in ShotgunController.shared.toggle() }
                    return noErr
                },
                1,
                &pressed,
                nil,
                &hotKeyHandler
            )
        }
        let shortcut = ShotgunShortcut.current
        guard let modifiers = shortcut.carbonModifiers else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), modifiers, EventHotKeyID(signature: fourCharCode("NASG"), id: 2),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            shortcutTaken = shortcut
            nativeLog("[Shotgun] %@ could not be registered: %d", shortcut.title, status)
            if toldTaken.insert(shortcut).inserted {
                NativeAgentNotifications.post(
                    title: "\(shortcut.title) is taken",
                    body: "Another app already uses \(shortcut.title), so it can't show Shotgun. Pick another in Settings, or use View ▸ Show Shotgun."
                )
            }
            return
        }
        hotKeyRef = ref
    }

    // MARK: - Stepping aside

    /// The turn on screen, while a Mac verb of it is running (its live screen
    /// pane opens with the first Mac verb of the turn).
    private func drivingTurnID() -> String? {
        guard let appModel else { return nil }
        let turns = appModel.engine.turns
        let sessionId = appModel.activeChatSessionId
        guard turns.isBusy(sessionId), turns.screenPreview(for: sessionId) != nil else { return nil }
        return turns.activeTurnIDsBySession[sessionId]
    }

    private func observeTurns() {
        let busy = withObservationTracking {
            _ = drivingTurnID()
            return appModel.map { $0.engine.turns.isBusy($0.activeChatSessionId) } ?? false
        } onChange: {
            Task { @MainActor in
                ShotgunController.shared.observeTurns()
                ShotgunController.shared.maybeStepAside()
            }
        }
        // The drive is over: her pointer goes.
        if !busy { agentPointer.fade() }
    }

    /// A real Mac drive, at its first move: her hands just moved — a click,
    /// key or accessibility press, or a hand-moving verb starting — while the
    /// chat on screen runs a Mac verb. A look, a quiet page read, an offscreen
    /// render and background browser work move no hands here, so they never
    /// step aside. Once per turn.
    private func maybeStepAside() {
        guard let turnID = drivingTurnID(), turnID != steppedAsideTurn,
              PersonOnlyWindows.secondsSinceAgentHands() < 3 else { return }
        steppedAsideTurn = turnID
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        stepAside()
    }

    private func agentPointerMoved(to point: CGPoint, pressed: Bool) {
        lastAgentPoint = point
        agentPointer.show(at: point, pressed: pressed, name: appModel?.agentDisplayName ?? "")
    }

    /// The main window fades and orders out (never minimizes); Shotgun comes
    /// in from where the composer was. Shotgun stays after the turn ends.
    private func stepAside() {
        setCollapsed(false)
        let main = Self.mainWindow().flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        show(from: main.map { Self.composerRect(in: $0.frame) }, makeKey: false)
        guard let main else { return }
        hiddenMain = main
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            main.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                // Brought back mid-fade: leave it on screen.
                guard ShotgunController.shared.hiddenMain === main else { return }
                main.orderOut(nil)
                main.alphaValue = 1
            }
        }
    }

    /// Dock click, ⌘Tab, the menu bar item: User brought NativeAgent forward.
    /// The agent putting NativeAgent back at the end of a task is not him, and
    /// never yanks the window back.
    private func appBecameActive() {
        guard hiddenMain != nil, MacPersonInput.activeSecondsAgo() != nil else { return }
        expand()
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window, window !== panel, window === Self.mainWindow() else { return }
        if hiddenMain === window { hiddenMain = nil }
        if isShown { hide() }
    }

    // MARK: - The panel

    private func makePanel() -> ShotgunPanel {
        if let panel { return panel }
        let panel = ShotgunPanel()
        if let appModel {
            let hosting = NSHostingView(rootView: AnyView(
                ShotgunView { size in ShotgunController.shared.pillSizeChanged(size) }
                    .environment(appModel)
            ))
            // The window follows the view's measured size, not the reverse.
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        panel.delegate = self
        self.panel = panel
        return panel
    }

    private func show(from start: NSRect?, makeKey: Bool) {
        let panel = makePanel()
        panel.appearance = DetachedChatWindowController.preferredAppearance()
        if isShown {
            panel.orderFrontRegardless()
            if makeKey { panel.makeKey() }
            return
        }
        isShown = true
        setCollapsed(false)
        let target = placedFrame()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        placing = true
        panel.alphaValue = 0
        panel.setFrame(
            reduceMotion ? target : NSRect(origin: (start ?? target).origin, size: target.size),
            display: false
        )
        panel.orderFrontRegardless()
        if makeKey { panel.makeKey() }
        publish()
        // Reduce Motion: a plain cross-fade in place.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.2 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        } completionHandler: {
            Task { @MainActor in
                ShotgunController.shared.placing = false
                ShotgunController.shared.publish()
            }
        }
    }

    private func hide() {
        guard isShown, let panel else { return }
        isShown = false
        setDone(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                let controller = ShotgunController.shared
                guard !controller.isShown else { return }
                panel.orderOut(nil)
                panel.ignoresMouseEvents = false
                controller.publish()
            }
        }
    }

    /// The folded pill measured itself: the window hugs it, keeping the
    /// bottom-right corner where it is.
    private func pillSizeChanged(_ size: CGSize) {
        guard collapsed, let panel, size.width > 0, size.height > 0 else { return }
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        placing = true
        panel.setFrame(clampToScreen(NSRect(x: old.maxX - size.width, y: old.minY,
                                            width: size.width, height: size.height),
                                     screen: panel.screen), display: true)
        placing = false
        publish()
    }

    private func savedSize() -> NSSize {
        let parts = (UserDefaults.standard.string(forKey: Self.sizeKey) ?? "")
            .split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return Self.defaultSize }
        return NSSize(
            width: min(max(parts[0], ShotgunPanel.minSize.width), ShotgunPanel.maxSize.width),
            height: min(max(parts[1], ShotgunPanel.minSize.height), ShotgunPanel.maxSize.height)
        )
    }

    /// User's remembered spot and size while that spot is on a screen, else
    /// the bottom-right corner of the screen she is driving. Always inside
    /// that screen's visible frame, `margin` in from its edges.
    private func placedFrame() -> NSRect {
        let size = savedSize()
        let parts = (UserDefaults.standard.string(forKey: Self.cornerKey) ?? "")
            .split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            let saved = NSRect(x: parts[0] - size.width, y: parts[1], width: size.width, height: size.height)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: parts[0] - 1, y: parts[1] + 1)) }) {
                return clampToScreen(saved, screen: screen)
            }
        }
        let screen = drivenScreen()
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            .insetBy(dx: Self.margin, dy: Self.margin)
        return clampToScreen(NSRect(x: visible.maxX - size.width, y: visible.minY,
                                    width: size.width, height: size.height), screen: screen)
    }

    /// The screen of her last pointer action, else the one in front.
    private func drivenScreen() -> NSScreen? {
        if let point = lastAgentPoint {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoa = NSPoint(x: point.x, y: primaryHeight - point.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) { return screen }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Inside the visible frame (above the Dock, below the menu bar), `margin`
    /// in, shrinking to fit a small screen.
    private func clampToScreen(_ frame: NSRect, screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? drivenScreen())?.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin),
              visible.width > 0, visible.height > 0 else { return frame }
        var fitted = frame
        fitted.size.width = min(fitted.width, visible.width)
        fitted.size.height = min(fitted.height, visible.height)
        return DetachedChatFramePlacement.clamp(fitted, within: visible)
    }

    /// Where the composer sits in the main window: bottom centre.
    private static func composerRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - defaultSize.width / 2, y: frame.minY + 24, width: defaultSize.width, height: 120)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(NativeAgentAppCoordinator.mainSceneID) == true }
    }

    // MARK: - Rulings 1 and 2, through Core's registry

    /// Tells Core what of User's is on screen, in CGEvent coordinates, and
    /// whether its composer holds the keyboard.
    private func publish() {
        guard let panel, isShown || panel.isVisible else {
            PersonOnlyWindows.update([], keyHeld: false)
            return
        }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let frame = panel.frame
        PersonOnlyWindows.update(
            [.init(number: panel.windowNumber, frame: CGRect(
                x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height))],
            keyHeld: panel.isKeyWindow
        )
    }

    /// Her pointer event is about to land on Shotgun: it falls through to the
    /// app behind, and the panel takes clicks again a moment after her last
    /// one (PersonOnlyWindows.pointerPassThroughSeconds). Never left on.
    private func passPointerThrough() {
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        restorePointer(after: PersonOnlyWindows.pointerPassThroughSeconds)
    }

    private func restorePointer(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if let left = PersonOnlyWindows.endPointerPassThroughIfIdle() {
                    ShotgunController.shared.restorePointer(after: left)
                } else {
                    ShotgunController.shared.panel?.ignoresMouseEvents = false
                }
            }
        }
    }

    /// Core's hook runs on whatever thread posts her event, and must finish
    /// before the event is posted.
    nonisolated private static func onMain(_ body: @MainActor (ShotgunController) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(ShotgunController.shared) }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { body(ShotgunController.shared) } }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        rememberFrame()
        publish()
    }

    func windowDidResize(_ notification: Notification) {
        rememberFrame()
        publish()
    }

    /// Only User's own drag or resize becomes the remembered spot and size.
    private func rememberFrame() {
        guard let panel, !placing, !collapsed else { return }
        let frame = panel.frame
        UserDefaults.standard.set("\(frame.maxX),\(frame.minY)", forKey: Self.cornerKey)
        UserDefaults.standard.set("\(frame.width),\(frame.height)", forKey: Self.sizeKey)
    }

    func windowDidBecomeKey(_ notification: Notification) { publish() }
    func windowDidResignKey(_ notification: Notification) { publish() }
}
