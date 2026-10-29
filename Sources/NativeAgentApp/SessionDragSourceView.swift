// SwiftUI's `.onDrag` hides NSDraggingSource's
// `draggingSession(_:endedAt:operation:)` callback, so we can't detect
// "the user dropped this on empty desktop (no in-app target accepted)".
// This file adds an AppKit drag source that overlays the SwiftUI session
// row and writes the custom `com.nativeagent.chat-session` pasteboard type
// (declared in the app Info.plist), which the pinned-strip drop accepts.
//
// Click pass-through: the underlying NSView's `hitTest` returns nil, so
// taps and right-clicks reach the SwiftUI row beneath. Drag detection is
// done via an app-local NSEvent monitor that observes mouseDown/mouseDragged
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

// Blueprint: | `SessionDragSourceView.swift` | `SessionDragSource`: AppKit drag completion/desktop-detach bridge with pasteboard identity and monitor teardown |

enum SessionDragPresentation {
    static func shouldDetach(
        pressedMouseButtons: Int,
        screenPoint: NSPoint,
        visibleWindowFrames: [NSRect]
    ) -> Bool {
        guard pressedMouseButtons & 0x1 == 0 else { return false }
        // A release on a window edge is still an in-app drop, not a desktop
        // detach. The one-point margin avoids a flickering boundary decision.
        return !visibleWindowFrames.contains { $0.insetBy(dx: -1, dy: -1).contains(screenPoint) }
    }
}
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

    // Remove the row-local event monitor before SwiftUI recycles the view.
    static func dismantleNSView(_ nsView: SessionDragSourceNSView, coordinator: ()) {
        nsView.teardownMonitor()
    }
}

final class SessionDragSourceNSView: NSView, NSDraggingSource {
    var sessionId: String = ""
    var sessionTitle: String = ""

    // The non-Sendable event token must be readable by nonisolated deinit for cleanup.
    nonisolated(unsafe) private var eventMonitor: Any?
    private var pressStart: NSPoint?
    private var dragInFlight = false

    // Click/right-click pass-through: never claim hits. Drag is detected
    // via an app-local NSEvent monitor instead of mouseDown overrides.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        installMonitor()
    }

    deinit {
        // NSEvent monitor removal is main-actor-isolated indirectly via
        // NSEvent.removeMonitor, but it's safe to call here.
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    private func removeMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        pressStart = nil
    }

    /// Public teardown entry for `dismantleNSView` — deterministic monitor
    /// removal when SwiftUI tears the row out of the hierarchy.
    func teardownMonitor() { removeMonitor() }

    private func installMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                guard let win = self.window, event.window === win, !self.dragInFlight else { return event }
                let pointInView = self.convert(event.locationInWindow, from: nil)
                self.pressStart = self.bounds.contains(pointInView) ? event.locationInWindow : nil
            case .leftMouseDragged:
                guard let start = self.pressStart, !self.dragInFlight else { return event }
                let dx = event.locationInWindow.x - start.x
                let dy = event.locationInWindow.y - start.y
                if hypot(dx, dy) > 4 {
                    self.pressStart = nil
                    self.dragInFlight = true
                    self.beginDrag(with: event)
                    return nil
                }
            case .leftMouseUp:
                self.pressStart = nil
            default:
                break
            }
            return event
        }
    }

    private func beginDrag(with event: NSEvent) {
        let pbItem = NSPasteboardItem()
        let idData = Data(sessionId.utf8)
        // Use only the declared custom UTI; plain text creates unwanted Finder textClippings.
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
        // Detach only on release outside all app windows; drop operations cannot distinguish desktop drops from Esc.
        let visibleFrames = NSApp.windows.compactMap { window -> NSRect? in
            guard window.isVisible, window.frame.width > 1, window.frame.height > 1 else { return nil }
            return window.frame
        }
        guard SessionDragPresentation.shouldDetach(
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            screenPoint: screenPoint,
            visibleWindowFrames: visibleFrames
        ) else { return }
        let sid = sessionId
        Task { @MainActor in
            DetachedChatWindowController.shared.open(sessionId: sid, origin: screenPoint)
        }
    }

}
