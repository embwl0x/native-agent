// detached-chat-windows Phase 1 W1.3 — drag-off-onto-desktop gesture.
//
// SwiftUI's `.onDrag` hides NSDraggingSource's
// `draggingSession(_:endedAt:operation:)` callback, so we can't detect
// "the user dropped this on empty desktop (no in-app target accepted)".
// This file adds an AppKit drag source that overlays the SwiftUI session
// row and writes the custom `com.nativeagent.chat-session` pasteboard type
// (declared in the app Info.plist), which the pinned-strip drop accepts.
//
// Click pass-through: the underlying NSView's `hitTest` returns nil, so
// taps and right-clicks reach the SwiftUI row beneath. Drag detection is
// done via app-local NSEvent monitors that observe mouseDown/mouseDragged
// regardless of hit-test, fire `beginDraggingSession` past a small
// threshold, and only consume the dragged event (clicks pass through
// untouched). On drag end, the detached panel opens IFF the left button is
// RELEASED and the drop point is OUTSIDE every app window. Point-based, not
// `operation`-based — with the custom-UTI-only payload Finder rejects the
// drop, so desktop drops and Esc-cancels both report an empty operation;
// the button state is what separates them (an Esc-cancel ends the session
// with the button still held). `pressedMouseButtons` is a process-global
// sample, not the ending event itself — a mistimed sample degrades to
// "no detach, drag again" or a rare stray panel, never a desktop file.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let sessionDragUTI = "com.nativeagent.chat-session"

struct SessionDragSource: NSViewRepresentable {
    let sessionId: String
    let sessionTitle: String

    func makeNSView(context: Context) -> SessionDragSourceNSView {
        let view = SessionDragSourceNSView()
        view.sessionId = sessionId
        view.sessionTitle = sessionTitle
        return view
    }

    func updateNSView(_ nsView: SessionDragSourceNSView, context: Context) {
        nsView.sessionId = sessionId
        nsView.sessionTitle = sessionTitle
    }

    // Deterministic teardown of the per-row NSEvent monitors. Without this,
    // cleanup relies on viewDidMoveToWindow(nil) + deinit — which DO fire,
    // but SwiftUI calls dismantleNSView at the exact moment the row leaves
    // the hierarchy, so removing the 3 app-local monitors here guarantees
    // they don't linger across a LazyVStack recycle. (gpt-5.5 review MEDIUM.)
    static func dismantleNSView(_ nsView: SessionDragSourceNSView, coordinator: ()) {
        nsView.teardownMonitors()
    }
}

final class SessionDragSourceNSView: NSView, NSDraggingSource {
    var sessionId: String = ""
    var sessionTitle: String = ""

    // nonisolated(unsafe): NSEvent monitor tokens are typed `Any?` and not
    // Sendable; deinit is nonisolated in Swift 6 strict-concurrency, so we
    // mark them unsafe-readable so cleanup can run on teardown.
    nonisolated(unsafe) private var mouseDownMonitor: Any?
    nonisolated(unsafe) private var mouseDraggedMonitor: Any?
    nonisolated(unsafe) private var mouseUpMonitor: Any?
    private var pressStart: NSPoint?
    private var dragInFlight = false

    // Click/right-click pass-through: never claim hits. Drag is detected
    // via app-local NSEvent monitors instead of mouseDown overrides.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitors()
        guard window != nil else { return }
        installMonitors()
    }

    deinit {
        // NSEvent monitor removal is main-actor-isolated indirectly via
        // NSEvent.removeMonitor, but it's safe to call here.
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDraggedMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
    }

    private func removeMonitors() {
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m); mouseDownMonitor = nil }
        if let m = mouseDraggedMonitor { NSEvent.removeMonitor(m); mouseDraggedMonitor = nil }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m); mouseUpMonitor = nil }
        pressStart = nil
    }

    /// Public teardown entry for `dismantleNSView` — deterministic monitor
    /// removal when SwiftUI tears the row out of the hierarchy.
    func teardownMonitors() { removeMonitors() }

    private func installMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let win = self.window, event.window === win, !self.dragInFlight else { return event }
            let pointInView = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(pointInView) {
                self.pressStart = event.locationInWindow
            } else {
                self.pressStart = nil
            }
            return event
        }
        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, let start = self.pressStart, !self.dragInFlight else { return event }
            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            if hypot(dx, dy) > 4 {
                self.pressStart = nil
                self.dragInFlight = true
                self.beginDrag(with: event)
                return nil
            }
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.pressStart = nil
            return event
        }
    }

    private func beginDrag(with event: NSEvent) {
        let pbItem = NSPasteboardItem()
        let idData = Data(sessionId.utf8)
        // Custom UTI ONLY — no plain-text. The 2026-06-08 live-verify that
        // forced a prefixed plain-text sibling ("SwiftUI's pinned-strip
        // .onDrop only matches the PLAIN-TEXT type from an AppKit
        // NSPasteboardItem") ran a month BEFORE the UTI was declared in
        // Info.plist (UTExportedTypeDeclarations, 767984ca 2026-07-10);
        // with the type declared, the custom-type drop matches (re-verified
        // live 2026-07-24). The plain-text was what Finder materialized as
        // a "nativeagent-chat-session-…" .textClipping on every desktop
        // drop — User's desktop-icons bug — so it must NOT come back as a
        // convenience payload.
        pbItem.setData(idData, forType: NSPasteboard.PasteboardType(sessionDragUTI))

        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let image = makeDragImage()
        let pointInView = convert(event.locationInWindow, from: nil)
        let imageOrigin = NSPoint(x: pointInView.x - image.size.width / 2,
                                  y: pointInView.y - image.size.height / 2)
        dragItem.setDraggingFrame(NSRect(origin: imageOrigin, size: image.size), contents: image)

        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        // Finder now REJECTS the drop (nothing it can read), which would
        // bounce the drag image back to the source — visually contradicting
        // the detached window that opens at the drop point. Suppress it.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private func makeDragImage() -> NSImage {
        let title = sessionTitle.isEmpty ? "Chat" : sessionTitle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let attr = NSAttributedString(string: title, attributes: attrs)
        let textSize = attr.size()
        let pad = NSSize(width: 16, height: 8)
        let size = NSSize(width: min(240, textSize.width + pad.width * 2),
                          height: textSize.height + pad.height * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let clip = size.width - pad.width * 2
        let drawRect = NSRect(x: pad.width,
                              y: (size.height - textSize.height) / 2,
                              width: clip,
                              height: textSize.height)
        attr.draw(with: drawRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        image.unlockFocus()
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragInFlight = false
        // Discriminate by drop POINT, not `operation` (2026-06-08 W1.3), and
        // by the mouse button for cancels (2026-07-24): with the plain-text
        // payload gone, Finder REJECTS desktop drops, so both a desktop drop
        // and an Esc-cancel report an empty operation — and with the
        // slide-back animation suppressed in beginDrag, both also end at the
        // cursor. What still separates them is the button: a real drop means
        // the user RELEASED; an Esc-cancel ends the session with the button
        // still held down.
        //   • drop on the pinned strip (in-app) → point INSIDE the main
        //     window → no detach; the strip's own .onDrop handles the pin.
        //   • Esc-cancel → left button still pressed → no detach.
        //   • genuine desktop drop → released, OUTSIDE all app windows →
        //     detach at the drop point.
        guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
        guard !Self.pointIsInsideAnyAppWindow(screenPoint) else { return }
        let sid = sessionId
        Task { @MainActor in
            DetachedChatWindowController.shared.open(sessionId: sid, origin: screenPoint)
        }
    }

    /// True if `screenPoint` (screen coords, bottom-left origin) falls
    /// inside any visible ordinary app window. Used to suppress the detach
    /// gesture for cancelled drags and in-app drops. The transient drag-
    /// feedback window is not an app window in `NSApp.windows`, so it
    /// doesn't interfere.
    @MainActor
    private static func pointIsInsideAnyAppWindow(_ screenPoint: NSPoint) -> Bool {
        for window in NSApp.windows where window.isVisible {
            // Skip off-screen / zero-size utility windows.
            guard window.frame.width > 1, window.frame.height > 1 else { continue }
            if window.frame.contains(screenPoint) { return true }
        }
        return false
    }
}
