// DetachedChatPanel — free-floating chat windows for individual sessions.
//
// Drag a session card off the sidebar onto the desktop and it spawns one
// of these panels (Phase 1 W1.3, separate commit). The panel hosts a
// stripped chat surface (DetachedChatPanelView) bound to that single
// sessionId — no model picker, persona switcher, or sidebar. Multiple
// sessions can be detached and arranged anywhere on screen.
//
// Design notes:
//   - NSPanel (not NSWindow) so they don't clutter the Dock or window menu
//   - .titled + .closable + .resizable + .miniaturizable so the user can
//     drag/size them like terminal sessions; key-window override so the
//     input field accepts keystrokes
//   - One panel per sessionId, enforced by DetachedChatWindowController.
//     Re-detach attempts on an already-detached session focus the existing
//     panel instead of creating a duplicate (the user's constraint, 2026-06-08:
//     "if one is pulled out there then thats it").
//   - Per-session frame autosave (`DetachedChatPanel.<sessionId>`) so each
//     window remembers position + size across launches
//   - Auto-pins the session to the chat strip on open (via
//     AppModel.pinChatSessionForDetachedWindow), so "close them all" stays
//     a one-place operation
//   - Persistence: UserDefaults `NativeAgent.detachedChatSessionIds`
//     (comma-separated). AppDelegate restores panels on launch.
//
// Built on detached-chat-windows Phase 0 (per-session storage in AppModel:
// chatMessagesBySession + helpers), commit 53fc8be0.

import SwiftUI
import AppKit

/// NSPanel subclass mirroring SpotlightOverlay's key-window override.
/// Detached chat panels are normal app windows (not non-activating HUDs),
/// so they take key/main focus — but using NSPanel keeps them out of the
/// Dock and window menu.
final class DetachedChatPanel: NSPanel {
    /// The chat session this panel is bound to. Immutable for the panel's
    /// lifetime — re-detach attempts on the same id focus this panel.
    let sessionId: String

    init(sessionId: String, contentRect: NSRect) {
        self.sessionId = sessionId
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle]
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .visible
        self.isMovableByWindowBackground = false
        self.animationBehavior = .documentWindow
        // Floor on resize — prevents collapsing the window into a sliver.
        self.contentMinSize = NSSize(width: 420, height: 320)
        let autosaveKey = "DetachedChatPanel.\(sessionId)"
        self.setFrameAutosaveName(autosaveKey)
        self.setFrameUsingName(autosaveKey)
    }

    /// Whether a saved frame currently exists on disk for this panel's
    /// autosave key. The controller checks this at open time to decide
    /// whether to `center()` — a restored window keeps its saved position;
    /// a brand-new one centers. NSWindow persists autosaved frames under
    /// the "NSWindow Frame <autosaveName>" UserDefaults key.
    static func hasSavedFrame(sessionId: String) -> Bool {
        let key = "NSWindow Frame DetachedChatPanel.\(sessionId)"
        return UserDefaults.standard.string(forKey: key) != nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Controller

/// One-per-app coordinator for detached chat panels. Owns the panel
/// lifecycle, enforces one-panel-per-sessionId, persists the open-set
/// across launches, and exposes open/close/focus to the drag-off intercept
/// + context-menu fallback (added in later W1.x waves).
@MainActor
final class DetachedChatWindowController {
    static let shared = DetachedChatWindowController()

    private var panels: [String: DetachedChatPanel] = [:]
    private var hostingControllers: [String: NSHostingController<AnyView>] = [:]
    private weak var appModel: AppModel?

    /// UserDefaults key for the persisted open-set (comma-separated
    /// sessionIds). AppDelegate reads this on launch and replays open().
    private static let persistKey = "NativeAgent.detachedChatSessionIds"

    private init() {}

    /// Inject the AppModel after it constructs (mirrors SpotlightOverlay's
    /// attach pattern — the controller is a singleton that predates the
    /// AppModel, so the reference comes in via this hook).
    func attach(appModel: AppModel) {
        self.appModel = appModel
        observeAppearancePreference()
    }

    // MARK: - Appearance

    /// The app's dark-mode preference. SwiftUI's `.preferredColorScheme` inside
    /// the hosted view styles the CONTENT only — the panel's titlebar is AppKit
    /// chrome and needs the window's own appearance set, or a dark panel wears a
    /// light title bar (User, 2026-07-25).
    private static var preferredAppearance: NSAppearance? {
        UserDefaults.standard.bool(forKey: "nativeagent.darkMode")
            ? NSAppearance(named: .darkAqua)
            : nil  // nil = follow the system, matching the main Window scene
    }

    private var appearanceObserver: NSObjectProtocol?

    /// Keep open panels in sync when the preference flips while they are up.
    private func observeAppearancePreference() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            // Task rather than MainActor.assumeIsolated: queue: .main makes
            // main-thread delivery likely, not guaranteed by the type system,
            // and assumeIsolated would trap if that ever changed.
            Task { @MainActor in
                DetachedChatWindowController.shared.applyAppearanceToOpenPanels()
            }
        }
    }

    private func applyAppearanceToOpenPanels() {
        let appearance = Self.preferredAppearance
        for panel in panels.values where panel.appearance != appearance {
            panel.appearance = appearance
        }
    }

    /// True if a panel is already open for this session.
    func isDetached(_ sessionId: String) -> Bool {
        panels[sessionId] != nil
    }

    /// Keep a proposed window frame fully on a visible screen. Picks the
    /// screen containing `near` (the drop point) when possible, else the
    /// main screen, and nudges the frame inside that screen's visibleFrame.
    private static func clampFrameToScreen(_ frame: NSRect, near point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let vis = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
        if f.minX < vis.minX { f.origin.x = vis.minX }
        if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }
        if f.minY < vis.minY { f.origin.y = vis.minY }
        return f
    }

    /// Open (or focus, if already open) a detached panel for `sessionId`.
    ///
    /// - origin: optional screen-coordinate top-left for first-open (the
    ///   drag-off intercept passes the cursor location). When nil, the
    ///   panel uses its autosaved frame or centers on screen.
    func open(sessionId: String, origin: NSPoint? = nil) {
        // One-per-sessionId guard — also the focus path for re-detach.
        if let existing = panels[sessionId] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let appModel else {
            NSLog("[DetachedChatPanel] open(%@) before attach(appModel:) — skipping", sessionId)
            return
        }
        // Validate the session still exists. A relaunch-restore for a
        // deleted session would otherwise spawn a panel bound to a dead id.
        // BUT: only prune when sessions are actually LOADED. An empty
        // chatSessions means "not loaded yet" (restore fired before the
        // session list arrived) — pruning then would silently drop a valid
        // persisted window. Skip without pruning; the retry in
        // restoreFromPersist(after:) catches it once sessions load.
        if !appModel.chatSessions.contains(where: { $0.id == sessionId }) {
            if appModel.chatSessions.isEmpty {
                NSLog("[DetachedChatPanel] open(%@) — sessions not loaded yet; deferring", sessionId)
            } else {
                NSLog("[DetachedChatPanel] open(%@) — session not found; pruning persist set", sessionId)
                removeFromPersist(sessionId)
            }
            return
        }

        let title = appModel.chatSessions.first(where: { $0.id == sessionId })?.displayTitle
            ?? "Chat \(sessionId.prefix(6))"
        let size = NSSize(width: 520, height: 600)
        let initialFrame: NSRect
        if let origin {
            // `origin` is the drop point in screen coords (bottom-left
            // origin). Place the window's TOP-LEFT near the drop, i.e.
            // frame origin = (drop.x, drop.y - height). 2026-06-08 W1.3
            // live-verify fix: CLAMP to the visible screen so a drop near
            // the bottom of the display doesn't push the window offscreen
            // (origin.y - 600 going negative left the window invisible
            // below the dock — the drag appeared to do nothing).
            let raw = NSPoint(x: origin.x, y: origin.y - size.height)
            initialFrame = Self.clampFrameToScreen(NSRect(origin: raw, size: size),
                                                   near: origin)
        } else {
            initialFrame = NSRect(origin: .zero, size: size)
        }

        let panel = DetachedChatPanel(sessionId: sessionId, contentRect: initialFrame)
        panel.title = title
        panel.delegate = panelDelegate
        panel.appearance = Self.preferredAppearance

        let view = DetachedChatPanelView(sessionId: sessionId)
            .environment(appModel)
        let hosting = NSHostingController(rootView: AnyView(view))
        panel.contentViewController = hosting

        // Center only a brand-new no-origin window. If a saved frame was
        // restored in init (setFrameUsingName), keep its position —
        // centering would clobber the user's chosen placement on relaunch.
        if origin == nil, !DetachedChatPanel.hasSavedFrame(sessionId: sessionId) {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)

        panels[sessionId] = panel
        hostingControllers[sessionId] = hosting

        // Auto-pin BEFORE persisting so a crash between the two leaves a
        // pinned session without a detached panel (recoverable), not the
        // reverse.
        appModel.pinChatSessionForDetachedWindow(sessionId)
        addToPersist(sessionId)
    }

    /// Close the panel for `sessionId` if open. The windowWillClose
    /// delegate callback handles dict + persist cleanup.
    func close(sessionId: String) {
        panels[sessionId]?.close()
    }

    /// Focus the existing panel for `sessionId` (used when the user clicks
    /// a detached session's sidebar row — W1.5).
    func focus(sessionId: String) {
        panels[sessionId]?.makeKeyAndOrderFront(nil)
    }

    /// Restore detached panels on launch from the persisted set. Waits up
    /// to ~10s for AppModel.chatSessions to load before giving up, so a
    /// slow cold-start session fetch doesn't drop the user's detached
    /// windows. Each open() is idempotent (one-per-sessionId) and the
    /// not-loaded-yet guard means early polls are harmless no-ops.
    func restoreFromPersist() {
        let saved = persistedSet()
        guard !saved.isEmpty else { return }
        Task { @MainActor in
            // Poll for sessions to load (≤ ~10s), then restore.
            for _ in 0..<40 {
                if !(appModel?.chatSessions.isEmpty ?? true) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)  // 0.25s
            }
            for sid in saved {
                open(sessionId: sid, origin: nil)
            }
        }
    }

    // MARK: - Persist set

    private func persistedSet() -> [String] {
        let raw = UserDefaults.standard.string(forKey: Self.persistKey) ?? ""
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func saveSet(_ ids: [String]) {
        UserDefaults.standard.set(ids.joined(separator: ","), forKey: Self.persistKey)
    }

    private func addToPersist(_ sessionId: String) {
        var ids = persistedSet()
        guard !ids.contains(sessionId) else { return }
        ids.append(sessionId)
        saveSet(ids)
    }

    private func removeFromPersist(_ sessionId: String) {
        let ids = persistedSet().filter { $0 != sessionId }
        saveSet(ids)
    }

    // MARK: - Delegate forwarder

    private lazy var panelDelegate: PanelDelegate = {
        let d = PanelDelegate()
        d.onWillClose = { [weak self] sessionId in
            self?.handleWillClose(sessionId: sessionId)
        }
        return d
    }()

    private func handleWillClose(sessionId: String) {
        panels.removeValue(forKey: sessionId)
        hostingControllers.removeValue(forKey: sessionId)
        removeFromPersist(sessionId)
        // Do NOT auto-unpin — the user wants the pinned-strip entry to stick
        // around even after the floating window is dismissed.
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    var onWillClose: ((String) -> Void)?

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? DetachedChatPanel else { return }
        onWillClose?(panel.sessionId)
    }
}
