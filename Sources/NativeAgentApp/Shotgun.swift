import AttentionRouting
import NativeAgentShared

// Blueprint: | `Shotgun.swift` | `ShotgunController`: person-only driving chat; scoped Stop/Resume, placement and fade settlement |

import AppKit
import AppToolRuntime
import Carbon.HIToolbox
import MacControl
import NativeAgentCore
import SwiftUI

/// Stay non-activating so clicks preserve the driven app; take key only for composer input.
/// Hidden titled chrome permits resizing; the folded pill must be borderless.
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
        // PersonOnlyWindows excludes agent captures; person recordings retain this window.
        sharingType = .readOnly
        setFull(true)
    }

    /// Full mode keeps user sizing; pill mode needs borderless chrome.
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

    static var current: ShotgunShortcut? {
        guard let saved = UserDefaults.standard.object(forKey: storageKey) else { return .optionSpace }
        guard let raw = saved as? String else { return nil }
        return Self(rawValue: raw)
    }
}

@MainActor
@Observable
final class ShotgunController: NSObject, NSWindowDelegate {
    static let shared = ShotgunController()
    static let enabledKey = ShotgunPreference.enabledKey
    /// Preserve user placement across launches as a bottom-right corner.
    static let cornerKey = "NativeAgent.shotgun.corner"
    /// Preserve the user's chosen panel size across launches.
    static let sizeKey = "NativeAgent.shotgun.size"
    static let defaultSize = NSSize(width: 400, height: 560)
    /// Keep the panel clear of the Dock and menu bar.
    static let margin: CGFloat = 16
    static let collapseAfter: Duration = .seconds(120)

    private(set) var isShown = false
    private(set) var collapsed = false
    /// Human takeover must expose Resume instead of claiming agent control.
    private(set) var driverAllowed = MacAttentionSessionStore.shared.currentDriverAllowed
    /// Retain shortcut registration failure so another app's ownership stays visible.
    private(set) var shortcutTaken: ShotgunShortcut?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var panel: ShotgunPanel?
    /// Retain the displaced main window so opening restores the same window.
    @ObservationIgnored private var hiddenMain: NSWindow?
    /// Step aside once per turn so a window the user brings back stays back.
    @ObservationIgnored private var steppedAsideTurn: String?
    /// Bind running state and Stop to the driving session, including turns without a Mac lifecycle.
    private(set) var driver: PersonOnlyWindows.Driver? {
        didSet { if let driver { selectedSessionID = driver.session } }
    }
    /// Keep the conversation visible after driving authority ends.
    private(set) var selectedSessionID: String?
    /// Ignore programmatic placement so only user drags become remembered positions.
    @ObservationIgnored private var placing = false
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var toldTaken: Set<ShotgunShortcut> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickAwayMonitor: Any?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private let agentPointer = AgentPointerOverlay()
    /// CGEvent coordinates identify the screen being driven.
    @ObservationIgnored private var lastAgentPoint: CGPoint?

    private override init() { super.init() }

    func attach(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        PersonOnlyWindows.install(passPointerThrough: { Self.onMain { $0.passPointerThrough() } })
        PersonOnlyWindows.installStepAside { driver in await ShotgunController.shared.stepAsideForScreen(driver: driver) }
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
        // Front-app changes can come from shell or scripts as well as hands; detect turn-driven changes.
        // The person's own keys and clicks must not count as agent driving.
        observers.append(center.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let turn = ShotgunController.shared.agentTurnMovedTheMac() else { return }
                NSApp.unhideWithoutActivation()
                ShotgunController.shared.driveBegan(turn)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard pid != ProcessInfo.processInfo.processIdentifier,
                      let turn = ShotgunController.shared.agentTurnMovedTheMac() else { return }
                ShotgunController.shared.driveBegan(turn)
            }
        })
        // Release remote-driver ownership as soon as its turn leaves flight.
        observers.append(center.addObserver(
            forName: Notification.Name("ChatCancelFlag.inFlightDidChange"), object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { ShotgunController.shared.releaseDriverIfDone() } })
        observeTurns()
        Task { @MainActor in
            for await _ in await MacAttentionSessionStore.shared.driverChanges() {
                ShotgunController.shared.driverAllowed = MacAttentionSessionStore.shared.currentDriverAllowed
            }
        }
    }

    // MARK: - User's controls

    func toggle() {
        if isShown { hide() } else { show(from: nil, makeKey: true) }
    }

    func unfold() { setCollapsed(false) }

    func expand() {
        let main = hiddenMain ?? Self.mainWindow()
        hiddenMain = nil
        hide()
        NSApp.activate()
        if let main {
            main.alphaValue = 1
            main.makeKeyAndOrderFront(nil)
        } else {
            ApplicationLifetime.shared.request(.sidebar(.chat))
        }
    }

    func close() { hide() }

    /// Resume uses the person's own handback authority, just like the main composer.
    func resume() {
        guard let generation = MacAttentionSessionStore.shared.userHandoffGeneration() else { return }
        let session = driver?.session ?? selectedSessionID
        Task { @MainActor in
            await MacAttentionSessionStore.shared.giveAgentControl(userGeneration: generation)
            guard MacAttentionSessionStore.shared.currentDriverAllowed,
                  let appModel = self.appModel, let session else { return }
            // Takeover already returned a tool result; resume through session acceptance, not a parked model.
            if case .rejected(let message) = await appModel.startChatTurnForSession(
                "Mac control has returned; continue from the recorded results.", sessionId: session
            ) { appModel.statusText = message }
        }
    }

    /// Return the keyboard to the driven app after sending; ordering back in must not take key.
    func giveKeyboardBack() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        publish()
    }

    /// Fold completed work after two minutes or a click away so idle Shotgun stays unobtrusive.
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
        // Global events include the hidden title bar; clicks on Shotgun itself must not fold it.
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

    /// Preserve the bottom-right anchor while folding or restoring the user's size.
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

    /// Share shortcut persistence and registration so settings and agent actions cannot disagree.
    func setShortcut(_ shortcut: ShotgunShortcut) throws {
        UserDefaults.standard.set(shortcut.rawValue, forKey: ShotgunShortcut.storageKey)
        applyShortcut()
        if shortcutTaken != nil {
            throw QuietSettingError.unavailable("""
                Saved \(shortcut.title), but macOS could not register it. Choose another Shotgun shortcut in Settings; View → Show \
                Shotgun remains available.
                """)
        }
    }

    /// Report shortcut conflicts while preserving the working View menu action.
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
        guard let shortcut = ShotgunShortcut.current else { return }
        guard let modifiers = shortcut.carbonModifiers else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), modifiers, EventHotKeyID(signature: fourCharCode("NASG"), id: 2),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            shortcutTaken = shortcut
            ModuleLog.app("[Shotgun] %@ could not be registered: %d", shortcut.title, status)
            if toldTaken.insert(shortcut).inserted {
                NativeAgentNotifications.post(
                    title: "\(shortcut.title) is taken",
                    body: "Another app already uses \(shortcut.title), so it can't show Shotgun. Pick another in Settings, or use View ▸ Show Shotgun.",
                    deadline: nil
                )
            }
            return
        }
        hotKeyRef = ref
    }

    // MARK: - Stepping aside

    /// Prefer the visible chat's drive so Shotgun follows the work the user is watching.
    private func drivingTurnID() -> String? { drivingSession()?.turn }

    /// The busy turn whose hands moved: the visible chat's first, then any other in flight.
    private func handsSession() -> (session: String, turn: String)? {
        guard let appModel else { return nil }
        let turns = appModel.engine.turns
        let active = appModel.activeChatSessionId
        for sessionId in [active] + turns.activeTurnIDsBySession.keys.sorted().filter({ $0 != active }) where turns.isBusy(sessionId) {
            if let turn = turns.activeTurnIDsBySession[sessionId] { return (sessionId, turn) }
        }
        return nil
    }

    private func drivingSession() -> (session: String, turn: String)? {
        guard let appModel else { return nil }
        let turns = appModel.engine.turns
        let active = appModel.activeChatSessionId
        for sessionId in [active] + turns.activeTurnIDsBySession.keys.sorted().filter({ $0 != active })
        where turns.isBusy(sessionId) && turns.screenPreview(for: sessionId) != nil {
            if let turn = turns.activeTurnIDsBySession[sessionId] { return (sessionId, turn) }
        }
        return nil
    }

    private func observeTurns() {
        let busy = withObservationTracking {
            _ = drivingTurnID()
            return appModel.map { model in model.engine.turns.activeTurnIDsBySession.keys.contains { model.engine.turns.isBusy($0) } } ?? false
        } onChange: {
            Task { @MainActor in
                ShotgunController.shared.observeTurns()
                ShotgunController.shared.maybeStepAside()
            }
        }
        if !busy { agentPointer.fade() }
        releaseDriverIfDone()
    }

    /// Driver ownership must end when its turn leaves flight on this root.
    private func releaseDriverIfDone() {
        if let driver, let appModel, !appModel.engine.turns.inFlightTurns().contains(where: { $0.turnId == driver.turn }) {
            self.driver = nil
        }
    }

    /// The agent's hands on any app (posted input, an accessibility press or value, a window raised or activated) take it over, so the
    /// busy turn rides shotgun whether or not it has a screen preview yet; looks and offscreen renders move no hands and never trigger it.
    /// Limit this to once per turn so the user can bring the main window back.
    private func maybeStepAside() {
        guard PersonOnlyWindows.secondsSinceAgentHands() < 3, let driving = handsSession(), driving.turn != steppedAsideTurn else { return }
        steppedAsideTurn = driving.turn
        if driver == nil { driver = PersonOnlyWindows.Driver(session: driving.session, turn: driving.turn) }
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        stepAside()
    }

    /// Exclude hardware keys and clicks so the person's own work cannot trigger step-aside.
    fileprivate func agentTurnMovedTheMac() -> PersonOnlyWindows.Driver? {
        let personIdle = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        guard personIdle.allSatisfy({ $0 > 1.5 }) else { return nil }
        return handsSession().map { PersonOnlyWindows.Driver(session: $0.session, turn: $0.turn) }
    }

    /// Once per turn preserves a window the user brought back.
    fileprivate func driveBegan(_ driving: PersonOnlyWindows.Driver) {
        driver = driving
        guard driving.turn != steppedAsideTurn,
              UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        steppedAsideTurn = driving.turn
        stepAside()
    }

    /// Hide the main window before a screen-dependent call returns, subject to the composer switch.
    /// The user bringing it back always wins.
    func stepAsideForScreen(driver named: PersonOnlyWindows.Driver?) async {
        guard !Task.isCancelled else { return }
        // Bind the call's session first so remote driving cannot attach to the visible chat.
        let driving = named ?? drivingSession().map { PersonOnlyWindows.Driver(session: $0.session, turn: $0.turn) }
        if let driving { driver = driving }
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else { return }
        let main = Self.mainWindow().flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        guard let main else { return }
        // Hardware typing keeps this window under the user's fingers; mouse presence alone must not block driving.
        // Posted agent keys do not count as human input.
        if main.isKeyWindow, CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 3 { return }
        // A window the user brought back during this turn must stay visible.
        if let driving {
            guard driving.turn != steppedAsideTurn else { return }
            steppedAsideTurn = driving.turn
        }
        // Settlement must release the fade waiter even if the person brings the window back.
        let done = ScopedWaiter()
        stepAside { done.resume() }
        await done.park()
    }

    private func agentPointerMoved(to point: CGPoint, pressed: Bool) {
        lastAgentPoint = point
        agentPointer.show(at: point, pressed: pressed, name: appModel?.agentDisplayName ?? "")
    }

    /// AppKit's ordinary completion block must enter without actor isolation;
    /// only its UI work is scheduled on the main actor.
    nonisolated static func animationCompletion(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> () -> Void {
        { Task { @MainActor in completion() } }
    }

    /// Order out rather than minimize so Shotgun can replace the window without a Dock animation.
    private func stepAside(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        setCollapsed(false)
        let main = Self.mainWindow().flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        show(from: main.map { Self.composerRect(in: $0.frame) }, makeKey: false)
        guard let main else { completion(); return }
        hiddenMain = main
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            main.animator().alphaValue = 0
        }, completionHandler: Self.animationCompletion {
            defer { completion() }
            // Brought back mid-fade: leave it on screen.
            guard ShotgunController.shared.hiddenMain === main else { return }
            main.orderOut(nil)
            main.alphaValue = 1
        })
    }

    /// Only human activation restores the window; agent activation must not yank it forward.
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
            // Size the window from the view so layout cannot feed back from window dimensions.
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        panel.delegate = self
        self.panel = panel
        return panel
    }

    func applyAppearance(_ appearance: NSAppearance?) {
        panel?.appearance = appearance
    }

    private func show(from start: NSRect?, makeKey: Bool) {
        if !isShown { selectedSessionID = driver?.session ?? appModel?.activeChatSessionId }
        let panel = makePanel()
        applyAppearance(AppearanceController.shared.appearance)
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
        // Reduce Motion permits a stationary crossfade, never travel.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.2 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion { panel.animator().setFrame(target, display: true) }
        }, completionHandler: Self.animationCompletion {
            ShotgunController.shared.placing = false
            ShotgunController.shared.publish()
        })
    }

    private func hide() {
        guard isShown, let panel else { return }
        isShown = false
        setDone(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: Self.animationCompletion {
            let controller = ShotgunController.shared
            guard !controller.isShown else { return }
            panel.orderOut(nil)
            panel.ignoresMouseEvents = false
            controller.publish()
        })
    }

    /// Preserve the bottom-right anchor when fitting the measured pill.
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

    /// Keep remembered placement only on an available screen and clamp it inside that screen's visible frame.
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

    /// Prefer the last pointer action's screen so the panel follows the actual drive.
    private func drivenScreen() -> NSScreen? {
        if let point = lastAgentPoint {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoa = NSPoint(x: point.x, y: primaryHeight - point.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) { return screen }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Clamp and shrink inside the visible frame so the Dock and menu bar remain clear.
    private func clampToScreen(_ frame: NSRect, screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? drivenScreen())?.visibleFrame.insetBy(dx: Self.margin, dy: Self.margin),
              visible.width > 0, visible.height > 0 else { return frame }
        var fitted = frame
        fitted.size.width = min(fitted.width, visible.width)
        fitted.size.height = min(fitted.height, visible.height)
        return DetachedChatFramePlacement.clamp(fitted, within: visible)
    }

    private static func composerRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - defaultSize.width / 2, y: frame.minY + 24, width: defaultSize.width, height: 120)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(ApplicationLifetime.mainSceneID) == true }
    }

    // MARK: - Rulings 1 and 2, through Core's registry

    /// Publish CGEvent-space geometry and keyboard ownership so Core can protect the person's window.
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

    /// Temporarily pass agent clicks through to the driven app; never leave the person's panel noninteractive.
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

    /// Core's hook runs on whatever thread posts the agent's event, and must finish
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

    /// Remember only user drags and resizes, never programmatic placement.
    private func rememberFrame() {
        guard let panel, !placing, !collapsed else { return }
        let frame = panel.frame
        UserDefaults.standard.set("\(frame.maxX),\(frame.minY)", forKey: Self.cornerKey)
        UserDefaults.standard.set("\(frame.width),\(frame.height)", forKey: Self.sizeKey)
    }

    func windowDidBecomeKey(_ notification: Notification) { publish() }
    func windowDidResignKey(_ notification: Notification) { publish() }
}
