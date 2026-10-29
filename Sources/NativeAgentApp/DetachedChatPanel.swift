import NativeAgentCore
import NativeAgentShared

// Blueprint: | `DetachedChatPanel.swift` | `DetachedChatWindowController`: session-window creation, persisted pins/frames, focus, appearance and lifecycle teardown |
// DetachedChatPanel — free-floating chat windows for individual sessions.
//
// Drag a session card off the sidebar onto the desktop and it spawns one
// of these panels. The panel hosts a
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
//     panel instead of creating a duplicate.
//   - Per-session frame autosave (`DetachedChatPanel.<sessionId>`) so each
//     window remembers position + size across launches
//   - Auto-pins the session to the chat strip on open (via
//     AppModel.pinChatSessionForDetachedWindow), so "close them all" stays
//     a one-place operation
//   - Persistence: UserDefaults `NativeAgent.detachedChatSessionIds`
//     (comma-separated). ApplicationLifetime restores panels on launch.
//
import SwiftUI
import AppKit

enum DetachedChatFramePlacement {
    static func place(
        _ frame: NSRect,
        near point: NSPoint,
        visibleFrames: [NSRect],
        fallbackFrame: NSRect?
    ) -> NSRect {
        let usable = visibleFrames.filter { $0.width > 1 && $0.height > 1 }
        let fallback = fallbackFrame.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        guard let visibleFrame = usable.first(where: { $0.contains(point) }) ?? fallback ?? usable.first else {
            return frame
        }
        return clamp(frame, within: visibleFrame)
    }

    static func clamp(_ frame: NSRect, within visibleFrame: NSRect) -> NSRect {
        var clamped = frame
        if clamped.maxX > visibleFrame.maxX { clamped.origin.x = visibleFrame.maxX - clamped.width }
        if clamped.minX < visibleFrame.minX { clamped.origin.x = visibleFrame.minX }
        if clamped.maxY > visibleFrame.maxY { clamped.origin.y = visibleFrame.maxY - clamped.height }
        if clamped.minY < visibleFrame.minY { clamped.origin.y = visibleFrame.minY }
        return clamped
    }
}
/// NSPanel subclass with a key-window override so it accepts keystrokes.
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
/// + context menu.
@MainActor
final class DetachedChatWindowController: NSObject, NSWindowDelegate {
    static let shared = DetachedChatWindowController()

    private var panels: [String: DetachedChatPanel] = [:]
    private weak var appModel: AppModel?
    private let defaults = UserDefaults.standard

    /// UserDefaults key for the persisted open-set (comma-separated
    /// sessionIds). ApplicationLifetime restores these on launch.
    static let persistKey = "NativeAgent.detachedChatSessionIds"

    private override init() { super.init() }

    /// Inject the AppModel after it constructs: the controller is a singleton
    /// that predates the AppModel, so the reference comes in via this hook.
    func attach(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Appearance

    func applyAppearanceToOpenPanels(_ appearance: NSAppearance?) {
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
        DetachedChatFramePlacement.place(
            frame,
            near: point,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackFrame: NSScreen.main?.visibleFrame
        )
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
            ModuleLog.app("[DetachedChatPanel] open(%@) before attach(appModel:) — skipping", sessionId)
            return
        }
        // Validate the session still exists. A relaunch-restore for a
        // deleted session would otherwise spawn a panel bound to a dead id.
        // Only prune after sessions load; restoration waits for that load.
        if !appModel.engine.transcripts.sessions.contains(where: { $0.id == sessionId }) {
            if appModel.engine.transcripts.sessions.isEmpty {
                ModuleLog.app("[DetachedChatPanel] open(%@) — sessions not loaded yet; deferring", sessionId)
            } else {
                ModuleLog.app("[DetachedChatPanel] open(%@) — session not found; pruning persist set", sessionId)
                removeFromPersist(sessionId)
            }
            return
        }

        let title = appModel.engine.transcripts.sessions.first(where: { $0.id == sessionId })?.displayTitle
            ?? "Chat \(sessionId.prefix(6))"
        let size = NSSize(width: 520, height: 600)
        let initialFrame: NSRect
        if let origin {
            // `origin` is the drop point in screen coords (bottom-left
            // origin). Place the window's TOP-LEFT near the drop, i.e.
            // frame origin = (drop.x, drop.y - height). Clamp it to the
            // visible screen so a drop near the bottom stays onscreen.
            let raw = NSPoint(x: origin.x, y: origin.y - size.height)
            initialFrame = Self.clampFrameToScreen(NSRect(origin: raw, size: size),
                                                   near: origin)
        } else {
            initialFrame = NSRect(origin: .zero, size: size)
        }

        let panel = DetachedChatPanel(
            sessionId: sessionId,
            contentRect: initialFrame
        )
        let view = DetachedChatPanelView(sessionId: sessionId).environment(appModel)
        panel.title = title
        panel.appearance = AppearanceController.shared.appearance
        panel.contentViewController = NSHostingController(rootView: AnyView(view))
        panel.delegate = self

        // Center only a brand-new no-origin window. If a saved frame was
        // restored in init (setFrameUsingName), keep its position —
        // centering would clobber the user's chosen placement on relaunch.
        if origin == nil, !DetachedChatPanel.hasSavedFrame(sessionId: sessionId) {
            panel.center()
        }

        panels[sessionId] = panel

        // Auto-pin BEFORE persisting so a crash between the two leaves a
        // pinned session without a detached panel (recoverable), not the
        // reverse.
        appModel.pinChatSessionForDetachedWindow(sessionId)
        addToPersist(sessionId)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Follow a conversation's title into its open panel's titlebar, if any.
    /// Called by the hosted view whenever the session's display title changes.
    func updateTitle(sessionId: String, title: String) {
        guard !title.isEmpty, let panel = panels[sessionId], panel.title != title else { return }
        panel.title = title
    }

    /// Close the panel for `sessionId` if open. The windowWillClose
    /// delegate callback handles dict + persist cleanup.
    func close(sessionId: String) {
        panels[sessionId]?.close()
    }

    /// Focus the existing panel for `sessionId` (used when the user clicks
    /// a detached session's sidebar row).
    func focus(sessionId: String) {
        panels[sessionId]?.makeKeyAndOrderFront(nil)
    }

    /// Restore detached panels after the canonical session load completes.
    func restoreFromPersist() {
        let saved = persistedSet()
        guard !saved.isEmpty else { return }
        Task { @MainActor in
            guard let appModel else { return }
            await appModel.engine.transcripts.sessionTransactions.waitForLoadCompletion()
            for sid in saved { open(sessionId: sid, origin: nil) }
        }
    }

    // MARK: - Persist set

    private func persistedSet() -> [String] {
        let raw = defaults.string(forKey: Self.persistKey) ?? ""
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func saveSet(_ ids: [String]) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.persistKey)
        } else {
            defaults.set(ids.joined(separator: ","), forKey: Self.persistKey)
        }
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

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? DetachedChatPanel else { return }
        let sessionId = panel.sessionId
        panels.removeValue(forKey: sessionId)
        removeFromPersist(sessionId)
        // Do NOT auto-unpin — the user wants the pinned-strip entry to stick
        // around even after the floating window is dismissed.
    }
}
