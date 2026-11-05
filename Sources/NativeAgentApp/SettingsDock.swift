import AppKit
import CoreGraphics
import MacIntegration
import SwiftUI

// Blueprint: | `SettingsDock.swift` | `SettingsDock`: helper card docked beside System Settings with the app icon to drag into the list; closes on grant, Settings quit or Close |

/// Stay non-activating so System Settings keeps focus; clicks reach the card without taking it.
private final class SettingsDockPanel: NSPanel {
    init(content: NSView) {
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

/// A card beside System Settings for the panes only a hand in Settings can finish: the person drags the app's icon into the list.
/// One card at a time. It closes when the grant lands, when Settings quits (or never starts), on Close, and with the app.
@MainActor
final class SettingsDock {
    static let shared = SettingsDock()

    /// Panes where the app's row may be missing and the person adds it by hand.
    static let capabilities: Set<SystemPermissionCapability> = [.accessibility, .fullDiskAccess, .screenRecording, .inputMonitoring]
    private static let settingsBundleID = "com.apple.systempreferences"
    /// Settings posts no window-moved signal to an app without Accessibility, so the frame is read once a second while the card is up.
    private static let frameInterval: Duration = .seconds(1)
    /// The pane's open call has handed off to macOS; Settings must be running within this or there is nothing to dock beside.
    private static let launchGrace: Duration = .seconds(15)
    private static let width: CGFloat = 360
    private static let gap: CGFloat = 8
    private static let screenInset: CGFloat = 24

    private var panel: SettingsDockPanel?
    private var capability: SystemPermissionCapability?
    /// A grant already on when the card opens is not a landing; only an off-to-on change closes the card.
    private var grantedAtOpen = false
    private var sawSettings = false
    private var launchDeadline = ContinuousClock.now
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var follow: Task<Void, Never>?

    func show(for capability: SystemPermissionCapability) {
        guard Self.capabilities.contains(capability) else { return }
        close()
        let granted = SystemPermissionPreflight.status(capability) == .granted
        self.capability = capability
        grantedAtOpen = granted
        sawSettings = false
        launchDeadline = ContinuousClock.now + Self.launchGrace
        let card = SettingsDockCard(line: Self.line(capability, granted: granted)) { [weak self] in self?.close() }
        let panel = SettingsDockPanel(content: NSHostingView(rootView: card))
        self.panel = panel
        place(panel, settings: Self.settingsFrame())
        panel.orderFrontRegardless()

        // The same wakes GrantWatch takes (app activation, in-process grant changes, Settings quitting) plus Settings launching.
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didBecomeActiveNotification, on: .default)
        observe(SystemPermissionPreflight.permissionDidChange, on: .default)
        observe(NSWorkspace.didLaunchApplicationNotification, on: workspace)
        observe(NSWorkspace.didTerminateApplicationNotification, on: workspace)
        follow = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.frameInterval) } catch { return }
                self?.refresh()
            }
        }
    }

    func close() {
        follow?.cancel()
        follow = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        panel?.orderOut(nil)
        panel = nil
        capability = nil
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append((center, token))
    }

    /// Every wake re-reads the live state: Settings running, the grant, and where Settings sits.
    private func refresh() {
        guard let capability, let panel else { return }
        let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).filter { !$0.isTerminated }
        if !settings.isEmpty { sawSettings = true }
        if settings.isEmpty, sawSettings || ContinuousClock.now >= launchDeadline {
            close()
            return
        }
        if !grantedAtOpen, SystemPermissionPreflight.status(capability) == .granted {
            close()
            return
        }
        place(panel, settings: Self.settingsFrame())
    }

    // MARK: Words

    private static func line(_ capability: SystemPermissionCapability, granted: Bool) -> AttributedString {
        let name = capability.displayName
        let text: String
        if granted {
            text = "NativeAgent is already on in \(name). If it is missing from the list, drag this icon in."
        } else if capability == .fullDiskAccess {
            text = "Drag this icon into the \(name) list, then turn it on."
        } else {
            text = "Turn NativeAgent on in \(name). If it is not listed, drag this icon into the list."
        }
        var words = AttributedString(text)
        // The one accent marks what the person is being waited on for.
        if !granted, let range = words.range(of: name) { words[range].foregroundColor = NativeAgentShell.needsYou }
        return words
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
    let line: AttributedString
    let close: @MainActor () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(alignment: .top, spacing: 14) {
            AppIconDragSource().frame(width: 52, height: 52)
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
    func makeNSView(context: Context) -> AppIconDragNSView { AppIconDragNSView(frame: .zero) }
    func updateNSView(_ nsView: AppIconDragNSView, context: Context) {}
}

private final class AppIconDragNSView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var pressStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
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
