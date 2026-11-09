import NativeAgentShared

// Blueprint: | `Shotgun.swift` | `ShotgunController`: person-only driving chat; scoped Stop/Resume, placement and fade settlement |

import AppKit
import Observation
import QuartzCore
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
        // The body excludes this window from agent captures; person recordings retain it.
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

    var menuModifiers: SwiftUI.EventModifiers? {
        switch self {
        case .optionSpace: .option
        case .controlOptionSpace: [.control, .option]
        case .shiftCommandSpace: [.shift, .command]
        case .off: nil
        }
    }

    @MainActor static var current: ShotgunShortcut? {
        guard let raw = ApplicationLifetime.shared.appModel?.facePreference(storageKey, as: String.self) else { return nil }
        return Self(rawValue: raw)
    }
}

@MainActor
@Observable
final class ShotgunController: NSObject, NSWindowDelegate {
    static let shared = ShotgunController()
    static let enabledKey = "NativeAgent.shotgun.enabled"
    /// Preserve user placement across launches as a bottom-right corner.
    static let cornerKey = "NativeAgent.shotgun.corner"
    /// Preserve the user's chosen panel size across launches.
    static let sizeKey = "NativeAgent.shotgun.size"
    static let defaultSize = NSSize(width: 400, height: 560)
    /// Keep the panel clear of the Dock and menu bar.
    static let margin: CGFloat = 16

    private(set) var isShown = false
    private(set) var collapsed = false
    /// Human takeover must expose Resume instead of claiming agent control.
    var driverAllowed: Bool? {
        appModel?.face.slot(.macControl).select("driverAllowed", as: MacControlFace.self) { $0?.driverAllowed }
    }

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var panel: ShotgunPanel?
    /// Retain the displaced main window so opening restores the same window.
    @ObservationIgnored private var hiddenMain: NSWindow?
    /// Step aside once per turn so a window the user brings back stays back.
    @ObservationIgnored private var steppedAsideTurn: String?
    /// Bind running state and Stop to the driving session, including turns without a Mac lifecycle.
    private(set) var driver: DriverIdentity? {
        didSet { if let driver { selectedSessionID = driver.session } }
    }
    /// Keep the conversation visible after driving authority ends.
    private(set) var selectedSessionID: String?
    /// Ignore programmatic placement so only user drags become remembered positions.
    @ObservationIgnored private var placing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickAwayMonitor: Any?
    @ObservationIgnored private let agentPointer = AgentPointerOverlay()
    /// CGEvent coordinates identify the screen being driven.
    @ObservationIgnored private var lastAgentPoint: CGPoint?

    private override init() { super.init() }

    func attach(appModel: AppModel) {
        guard self.appModel == nil else { return }
        self.appModel = appModel
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in ShotgunController.shared.appBecameActive() } })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ShotgunController.shared.windowBecameKey(NSApp.keyWindow) }
        })
        observeTurns()
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
        guard let appModel, let session = driver?.session ?? selectedSessionID else { return }
        guard NativePersonInput.currentActivation else { return }
        guard let generation = appModel.face.slot(.macControl).value(as: MacControlFace.self)?.handoffGeneration else {
            appModel.statusText = "Mac control has no confirmed hand-back generation."
            return
        }
        Task { @MainActor in
            do {
                try FaceWindowReply.check(await appModel.client.act(.handBackMacControl(expectedGeneration: generation)))
                if case .rejected(let message) = await appModel.startChatTurnForSession(
                    "Mac control has returned; continue from the recorded results.", sessionId: session
                ) { appModel.statusText = message }
            } catch { appModel.setFailureStatus(error, action: "resume Mac control") }
        }
    }

    /// Return the keyboard to the driven app after sending; ordering back in must not take key.
    func giveKeyboardBack() {
        guard let panel, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        publish()
    }

    /// A click away folds completed work without taking the person's focus.
    func setDone(_ done: Bool) {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
        guard done else {
            setCollapsed(false)
            return
        }
        guard isShown, !collapsed else { return }
        // Global events include the hidden title bar; clicks on Shotgun itself must not fold it.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                let point = NSEvent.mouseLocation
                guard ShotgunController.shared.panel?.frame.contains(point) != true else { return }
                ShotgunController.shared.collapse()
            }
        }
    }

    private func collapse() {
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

    // MARK: - Stepping aside

    /// Prefer the visible chat's drive so Shotgun follows the work the user is watching.
    private func drivingTurnID() -> String? { drivingSession()?.turn }

    private func drivingSession() -> (session: String, turn: String)? {
        guard let appModel else { return nil }
        guard let turns = appModel.turnSessionsFace else { return nil }
        let active = appModel.activeChatSessionId
        for sessionId in [active] + turns.activeTurnIDs.keys.sorted().filter({ $0 != active }) {
            let drives = appModel.turnPart("busyWithPreview", for: sessionId) { $0?.isBusy == true && $0?.preview != nil }
            if drives, let id = turns.activeTurnIDs[sessionId] { return (sessionId, id) }
        }
        return nil
    }

    private func observeTurns() {
        guard appModel != nil else { return }
        let busy = withObservationTracking {
            _ = drivingTurnID()
            guard let model = appModel, let turns = model.turnSessionsFace else { return nil as Bool? }
            return turns.activeTurnIDs.keys.contains { model.turnPart("isBusy", for: $0) { $0?.isBusy == true } } as Bool?
        } onChange: {
            Task { @MainActor in
                ShotgunController.shared.observeTurns()
            }
        }
        if busy == false { agentPointer.fade() }
        releaseDriverIfDone()
    }

    /// Driver ownership must end when its turn leaves flight on this root.
    private func releaseDriverIfDone() {
        if let driver, let turns = appModel?.turnSessionsFace, !turns.inFlightTurnIDs.contains(driver.turn) {
            self.driver = nil
        }
    }

    /// Hide the main window before a screen-dependent call returns, subject to the composer switch.
    /// The user bringing it back always wins.
    func stepAsideForScreen(driver named: DriverIdentity?) async throws {
        try Task.checkCancellation()
        // Bind the call's session first so remote driving cannot attach to the visible chat.
        let driving = named ?? drivingSession().map { DriverIdentity(session: $0.session, turn: $0.turn) }
        if let driving { driver = driving }
        guard let enabled = appModel?.facePreference(Self.enabledKey, as: Bool.self) else {
            throw WireFailure(code: "shotgun_preference_unavailable", message: "Shotgun's setting has not reached this window.",
                cause: "Wait for my settings face before moving the window aside.", effects: .none)
        }
        guard enabled else { return }
        guard Self.mainWindow().map({ $0.isVisible && !$0.isMiniaturized }) == true else { return }
        // A window the user brought back during this turn must stay visible.
        if let driving {
            guard driving.turn != steppedAsideTurn else { return }
            steppedAsideTurn = driving.turn
        }
        // Settlement must release the fade waiter even if the person brings the window back.
        await withCheckedContinuation { continuation in stepAside { continuation.resume() } }
        try Task.checkCancellation()
        try await synchronizeProtection()
    }

    func showPointer(_ presentation: PointerPresentation) async throws {
        if let driver = presentation.driver { self.driver = driver }
        let point = CGPoint(x: presentation.x, y: presentation.y)
        lastAgentPoint = point
        agentPointer.show(at: point, pressed: presentation.pressed, name: presentation.name ?? appModel?.agentDisplayName ?? "")
        try await agentPointer.synchronize()
    }

    func handsMoved(_ named: DriverIdentity?) async throws {
        let driving = named ?? drivingSession().map { DriverIdentity(session: $0.session, turn: $0.turn) }
        try await stepAsideForScreen(driver: driving)
    }

    /// AppKit's ordinary completion block must enter without actor isolation;
    /// only its UI work is scheduled on the main actor.
    nonisolated static func animationCompletion(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> () -> Void {
        { Task { @MainActor in completion() } }
    }

    /// Order out rather than minimize so Shotgun can replace the window without a Dock animation.
    private func stepAside(completion: @escaping @MainActor @Sendable () -> Void) {
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

    /// Activation restores the displaced window the person can bring forward.
    private func appBecameActive() {
        guard hiddenMain != nil else { return }
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
        guard parts.count == 2, let width = parts.first, let height = parts.dropFirst().first else { return Self.defaultSize }
        return NSSize(
            width: min(max(width, ShotgunPanel.minSize.width), ShotgunPanel.maxSize.width),
            height: min(max(height, ShotgunPanel.minSize.height), ShotgunPanel.maxSize.height)
        )
    }

    /// Keep remembered placement only on an available screen and clamp it inside that screen's visible frame.
    private func placedFrame() -> NSRect {
        let size = savedSize()
        let parts = (UserDefaults.standard.string(forKey: Self.cornerKey) ?? "")
            .split(separator: ",").compactMap { Double($0) }
        if parts.count == 2, let x = parts.first, let y = parts.dropFirst().first {
            let saved = NSRect(x: x - size.width, y: y, width: size.width, height: size.height)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: x - 1, y: y + 1)) }) {
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

    /// Publish CGEvent-space geometry and keyboard ownership so Core can protect the person's window.
    private func publish() {
        let shown = panel.flatMap { isShown || $0.isVisible ? $0 : nil }
        RendererProtection.shared.publishShotgun(window: shown)
    }

    func connect(client: PipeFaceClient) {
        RendererProtection.shared.connect(client: client)
        publish()
    }

    func synchronizeProtection() async throws {
        publish()
        try await RendererProtection.shared.publishAndWait()
    }

    func preparePointer(operation: UUID, at point: CGPoint, driver: DriverIdentity?) throws {
        if let driver { self.driver = driver }
        try RendererProtection.shared.preparePointer(operation: operation, at: point)
    }

    func disconnect() {
        RendererProtection.shared.disconnect()
        panel?.ignoresMouseEvents = false
        agentPointer.close()
        hide()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        appModel = nil
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
        let corner = "\(frame.maxX),\(frame.minY)"
        let size = "\(frame.width),\(frame.height)"
        if UserDefaults.standard.string(forKey: Self.cornerKey) != corner { UserDefaults.standard.set(corner, forKey: Self.cornerKey) }
        if UserDefaults.standard.string(forKey: Self.sizeKey) != size { UserDefaults.standard.set(size, forKey: Self.sizeKey) }
    }

    func windowDidBecomeKey(_ notification: Notification) { publish() }
    func windowDidResignKey(_ notification: Notification) { publish() }
}
