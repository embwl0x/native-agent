import AppKit
import NativeAgentShared
import SwiftUI

// Blueprint: | `SettingsDock.swift` | Permission guidance from body slots, with the grant-holding body bundle as its drag source |

/// Stay non-activating so System Settings keeps focus; clicks reach the card without taking it.
private final class SettingsDockPanel: NSPanel {
    init(card: SettingsDockCard) {
        let content = NSHostingView(rootView: card)
        super.init(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Permission guidance draws the body's current grant; closing it never decides the grant.
@MainActor
final class SettingsDock {
    static let shared = SettingsDock()
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let gap: CGFloat = 8
    private static let screenInset: CGFloat = 24
    private var panel: SettingsDockPanel?
    private var capability: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func show(capability: String, bodyBundleURL: URL, appModel: AppModel) {
        close()
        self.capability = capability
        let slot = appModel.face.slot(.settings)
        let card = SettingsDockCard(slot: slot, capability: capability, bodyBundleURL: bodyBundleURL) { [weak self] in self?.close() }
        let panel = SettingsDockPanel(card: card)
        self.panel = panel
        place(panel, settings: Self.settingsFrame())
        panel.orderFrontRegardless()
        observe(NSApplication.didBecomeActiveNotification, center: .default)
        observe(NSWorkspace.didLaunchApplicationNotification, center: NSWorkspace.shared.notificationCenter)
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self, weak panel] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.settingsBundleID else { return }
            Task { @MainActor in
                guard let self, let panel, self.panel === panel else { return }
                self.close()
            }
        }
        observers.append((workspace, token))
    }

    func close(capability: String) {
        if self.capability == capability { close() }
    }
    func close() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        panel?.orderOut(nil)
        panel = nil
        capability = nil
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                self.place(panel, settings: Self.settingsFrame())
            }
        }
        observers.append((center, token))
    }

    // MARK: Placement

    /// Beside the Settings window: right of it, else left of it, else against the screen edge it sits near. With no readable frame,
    /// the top-right corner of the main screen.
    private func place(_ panel: NSPanel, settings: NSRect?) {
        let size = panel.frame.size
        guard let screen = Self.screen(containing: settings) else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - size.width - Self.screenInset, y: visible.maxY - size.height - Self.screenInset)
        if let settings {
            var x = settings.maxX + Self.gap
            if x + size.width > visible.maxX {
                x = settings.minX - Self.gap - size.width
                if x < visible.minX { x = visible.maxX - size.width - Self.gap }
            }
            let y = min(max(settings.maxY - size.height, visible.minY), visible.maxY - size.height)
            origin = NSPoint(x: x, y: y)
        }
        guard abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 else { return }
        panel.setFrameOrigin(origin)
    }

    private static func screen(containing frame: NSRect?) -> NSScreen? {
        guard let frame else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.max { lhs, rhs in
            area(lhs.frame.intersection(frame)) < area(rhs.frame.intersection(frame))
        } ?? NSScreen.main
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    /// The largest ordinary on-screen window of System Settings, in AppKit coordinates. Window bounds need no Screen Recording grant.
    /// Nil when Settings has no readable window (hidden, minimized, not yet drawn).
    private static func settingsFrame() -> NSRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).map { Int($0.processIdentifier) })
        guard !pids.isEmpty, let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let rects = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 300, rect.height >= 300 else { return nil }
            return rect
        }
        guard let best = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // Window server rects are top-left origin on the primary display; AppKit's are bottom-left.
        return NSRect(x: best.minX, y: primary.frame.height - best.maxY, width: best.width, height: best.height)
    }
}

// MARK: - Card

private struct SettingsDockCard: View {
    let slot: FaceSlot
    let capability: String
    let bodyBundleURL: URL
    let close: @MainActor () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let value = slot.select("permissions.dock:\(capability)", as: SettingsFace.self) { $0?.permissions.docks[capability] }
        var line = AttributedString(value?.line ?? "Reading the permission…")
        if let highlight = value?.highlight, let range = line.range(of: highlight) { line[range].foregroundColor = NativeAgentShell.needsYou }
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(alignment: .top, spacing: 14) {
            AppIconDragSource(bodyBundleURL: bodyBundleURL).frame(width: 52, height: 52)
            Text(line)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Close") { close() }
                .buttonStyle(.plain)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .padding(14)
        .frame(width: 360)
        .background { if reduceTransparency { shape.fill(TodayPalette.cardFill) } }
        .glassEffect(reduceTransparency ? .identity : .regular, in: shape)
        // A card in another app's window loses the glass rim, so the hairline stays.
        .overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1).allowsHitTesting(false) }
    }
}

/// The app's own icon; dragging it offers the app bundle as a file, which is what the Settings list accepts.
private struct AppIconDragSource: NSViewRepresentable {
    let bodyBundleURL: URL
    func makeNSView(context: Context) -> AppIconDragNSView { AppIconDragNSView(bodyBundleURL: bodyBundleURL) }
    func updateNSView(_ nsView: AppIconDragNSView, context: Context) {}
}

private final class AppIconDragNSView: NSView, NSDraggingSource {
    private let bodyBundleURL: URL
    private let icon: NSImage
    private var pressStart: NSPoint?

    init(bodyBundleURL: URL) {
        self.bodyBundleURL = bodyBundleURL
        self.icon = NSWorkspace.shared.icon(forFile: bodyBundleURL.path)
        super.init(frame: .zero)
        toolTip = "Drag into the list"
        setAccessibilityLabel("NativeAgent icon, drag into the list")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        pressStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        pressStart = nil
        let item = NSDraggingItem(pasteboardWriter: bodyBundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressStart = nil
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
