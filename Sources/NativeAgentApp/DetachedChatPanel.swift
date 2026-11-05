import NativeAgentCore
import NativeAgentShared

// Blueprint: | `DetachedChatPanel.swift` | `DetachedChatWindowController`: session windows, pins, frames, focus and teardown |
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
/// NSPanel avoids Dock/window-menu entries; key/main overrides let its composer accept keystrokes.
final class DetachedChatPanel: NSPanel {
    /// Keep the session immutable so re-detaching its id focuses this panel.
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
        // A resize floor prevents the window collapsing into a sliver.
        self.contentMinSize = NSSize(width: 420, height: 320)
        let autosaveKey = "DetachedChatPanel.\(sessionId)"
        self.setFrameAutosaveName(autosaveKey)
        self.setFrameUsingName(autosaveKey)
    }

    static func hasSavedFrame(sessionId: String) -> Bool {
        let key = "NSWindow Frame DetachedChatPanel.\(sessionId)"
        return UserDefaults.standard.string(forKey: key) != nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Controller

@MainActor
final class DetachedChatWindowController: NSObject, NSWindowDelegate {
    static let shared = DetachedChatWindowController()

    private var panels: [String: DetachedChatPanel] = [:]
    private weak var appModel: AppModel?
    private let defaults = UserDefaults.standard

    static let persistKey = "NativeAgent.detachedChatSessionIds"

    private override init() { super.init() }

    /// Inject AppModel because the singleton panel controller predates it.
    func attach(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - Appearance

    func applyAppearanceToOpenPanels(_ appearance: NSAppearance?) {
        for panel in panels.values where panel.appearance != appearance {
            panel.appearance = appearance
        }
    }

    func isDetached(_ sessionId: String) -> Bool {
        panels[sessionId] != nil
    }

    /// Clamp the proposed frame to a visible screen so a drop cannot strand the panel offscreen.
    private static func clampFrameToScreen(_ frame: NSRect, near point: NSPoint) -> NSRect {
        DetachedChatFramePlacement.place(
            frame,
            near: point,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallbackFrame: NSScreen.main?.visibleFrame
        )
    }

    func open(sessionId: String, origin: NSPoint? = nil) {
        if let existing = panels[sessionId] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard let appModel else {
            ModuleLog.app("[DetachedChatPanel] open(%@) before attach(appModel:) — skipping", sessionId)
            return
        }
        // Wait for the session load before pruning deleted ids so restoration cannot mistake unread state for absence.
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
            // Screen coordinates start bottom-left; subtract height to place the panel's top-left at the drop and clamp it onscreen.
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

        // Center only unsaved windows so relaunch preserves the person's chosen placement.
        if origin == nil, !DetachedChatPanel.hasSavedFrame(sessionId: sessionId) {
            panel.center()
        }

        panels[sessionId] = panel

        // Pin before persisting: a crash may leave a recoverable pin, never an unpinned detached panel.
        appModel.pinChatSessionForDetachedWindow(sessionId)
        addToPersist(sessionId)
        panel.makeKeyAndOrderFront(nil)
    }

    func updateTitle(sessionId: String, title: String) {
        guard !title.isEmpty, let panel = panels[sessionId], panel.title != title else { return }
        panel.title = title
    }

    func close(sessionId: String) {
        panels[sessionId]?.close()
    }

    func focus(sessionId: String) {
        panels[sessionId]?.makeKeyAndOrderFront(nil)
    }

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
        // Keep the pin after closing so the session remains reachable from the strip.
    }
}
