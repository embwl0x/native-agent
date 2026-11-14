import AppKit
import SwiftUI

// Blueprint: | `ShellWindowChrome.swift` | `ShellWindowChrome`, `ShellFrame`, `WindowFrame`: chrome, kept frames, split layout, keyboard order |

@MainActor
private protocol ShellWindowSizing: AnyObject {
    var sizingOptions: NSHostingSizingOptions { get set }
}

extension NSHostingView: ShellWindowSizing {}

/// Let the shell extend beneath the traffic lights without opaque title chrome.
struct ShellWindowChrome: NSViewRepresentable {
    static let minimumSize = NSSize(width: 1040, height: 680)

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: view) }
    }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Wait for attachment so the hosting ancestors exist when sizing is configured.
            DispatchQueue.main.async { [weak self] in
                if let self { ShellWindowChrome.apply(to: self) }
            }
        }
    }

    static func apply(to view: NSView) {
        guard let window = view.window else { return }
        // The main window has a fixed floor; editing content must not measure its tree to derive another one.
        var ancestor = view.superview
        while let current = ancestor {
            if let host = current as? any ShellWindowSizing, !host.sizingOptions.isEmpty {
                host.sizingOptions = []
            }
            ancestor = current.superview
        }
        if window.contentMinSize != minimumSize { window.contentMinSize = minimumSize }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar?.isVisible = false
        // The glass sheet handles window dragging so text selection and controls win.
        window.isMovableByWindowBackground = false
    }
}


/// A window opens where the person left it. AppKit keeps its frame under one stable autosave name in this process's defaults; beside it are
/// kept what a frame cannot say: whether the window was zoomed, its unzoomed frame for the zoom button to return to, and full screen.
/// A frame that no longer fits any connected screen (a display since detached) comes back onto the nearest screen at the same size,
/// smaller only where that screen cannot hold it.
@MainActor
final class WindowFrame {
    private(set) weak var window: NSWindow?
    /// False when nothing was saved under the name: the window keeps its first placement.
    let restored: Bool
    private let name: String
    private var observers: [NSObjectProtocol] = []

    private var zoomedKey: String { name + ".zoomed" }
    private var unzoomedKey: String { name + ".unzoomed" }
    private var fullScreenKey: String { name + ".fullScreen" }

    /// `formerName` is read once, when nothing is saved under `name` yet, so a frame saved under an earlier name still opens.
    init(_ window: NSWindow, name: String, formerName: String? = nil) {
        self.window = window
        self.name = name
        let defaults = UserDefaults.standard
        if let formerName, defaults.string(forKey: "NSWindow Frame " + name) == nil,
           let former = defaults.string(forKey: "NSWindow Frame " + formerName) {
            defaults.set(former, forKey: "NSWindow Frame " + name)
        }
        // AppKit gives a name to one window at a time, and a closed window of the same scene can still hold it.
        for other in NSApp.windows where other !== window && other.frameAutosaveName == name { other.setFrameAutosaveName("") }
        restored = window.setFrameUsingName(name)
        // Taking the name applies the saved frame again, so every correction below comes after it and is saved over it.
        window.setFrameAutosaveName(name)
        if restored {
            let zoomed = defaults.bool(forKey: zoomedKey)
            let unzoomed = zoomed ? defaults.string(forKey: unzoomedKey) : nil
            // Zooming from the unzoomed frame lets AppKit remember it again, so the zoom button returns to the person's size.
            if let unzoomed { window.setFrame(from: unzoomed) }
            let fitted = Self.onScreen(window.frame, screens: NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) })
            if fitted != window.frame { window.setFrame(fitted, display: true) }
            if unzoomed != nil, !window.isZoomed { window.zoom(nil) }
            window.saveFrame(usingName: name)
        }
        let fullScreenKey = fullScreenKey
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                UserDefaults.standard.set(true, forKey: fullScreenKey)
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                UserDefaults.standard.set(false, forKey: fullScreenKey)
            },
        ] + [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { change in
            NotificationCenter.default.addObserver(forName: change, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recordZoom() }
            }
        }
        // A quit in full screen opens in full screen.
        if defaults.bool(forKey: fullScreenKey), !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Full screen is not zoom: its frame is the screen's, and leaving it returns to the frame already kept.
    private func recordZoom() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let zoomed = window.isZoomed
        UserDefaults.standard.set(zoomed, forKey: zoomedKey)
        if !zoomed { UserDefaults.standard.set(window.frameDescriptor, forKey: unzoomedKey) }
    }

    func end() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    /// The frame where it is when a screen holds it whole; otherwise moved onto the screen it overlaps most, or the nearest one.
    static func onScreen(_ frame: NSRect, screens: [(frame: NSRect, visible: NSRect)]) -> NSRect {
        let usable = screens.filter { $0.visible.width > 1 && $0.visible.height > 1 }
        guard !usable.contains(where: { $0.frame.contains(frame) }) else { return frame }
        func overlap(_ screen: NSRect) -> CGFloat {
            let shared = frame.intersection(screen)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        func distance(_ screen: NSRect) -> CGFloat {
            let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
            let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        guard let target = usable.map(\.visible).min(by: { a, b in
            overlap(a) != overlap(b) ? overlap(a) > overlap(b) : distance(a) < distance(b)
        }) else { return frame }
        let size = NSSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        // Keep the top-left corner where it can stay, as the person placed it, then pull the whole frame inside the screen.
        let moved = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        return DetachedChatFramePlacement.clamp(moved, within: target)
    }
}

/// The main window's frame, zoom and full screen are the person's, kept across quits, restarts and installs of a new build.
struct MainWindowFrame: NSViewRepresentable {
    static let autosaveName = "NativeAgent.MainWindow"
    /// The name SwiftUI saved the frame under before the window kept its own: the scene id.
    private static let formerName = ApplicationLifetime.mainSceneID

    func makeNSView(context: Context) -> Keeper { Keeper() }
    func updateNSView(_ view: Keeper, context: Context) {}
    static func dismantleNSView(_ view: Keeper, coordinator: ()) { view.detach() }

    final class Keeper: NSView {
        private var kept: WindowFrame?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The scene places a new window at its default size; the person's frame replaces it once the window exists.
            DispatchQueue.main.async { [weak self] in self?.keep() }
        }

        private func keep() {
            guard let window, window !== kept?.window else { return }
            detach()
            kept = WindowFrame(window, name: MainWindowFrame.autosaveName, formerName: MainWindowFrame.formerName)
        }

        func detach() {
            kept?.end()
            kept = nil
        }
    }
}

/// Lay out columns directly so system panes cannot add separate corners.
struct ShellFrame<Sidebar: View, Detail: View>: View {
    @State private var keyboardOrder = ShellKeyboardOrder()
    /// Replace the warm lamp where haze draws; mixing them muddies the colour.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar().focusSection()
            detail().focusSection()
        }
        .background {
            ShellSheet().contentShape(Rectangle()).gesture(WindowDragGesture())
                .overlay { WindowHaze() }
                .overlay { if reduceTransparency && shellLampUnderContent { ShellLamp() } }
        }
        .overlay { if reduceTransparency && !shellLampUnderContent { ShellLamp() } }
        // One masked mood tint warms the sheet, rail and composer without tinting transcript prose.
        .moodTintWindow()
        // The window has no accent of its own: controls take the text colour in every place, as the settings pages already did, so the
        // system's accent never lands on the glass. A switch carries its own neutral; the one colour that means something is drawn where it means it.
        .tint(NativeAgentShell.text)
        .environment(\.shellKeyboardOrder, keyboardOrder)
    }
}

/// Explicit Tab destinations. Receipt positions are measured in the transcript;
/// only receipts intersecting its visible scroll region participate.
@MainActor
final class ShellKeyboardOrder {
    enum Region: Int { case rail, receipt, composer, send }
    struct Destination {
        var id: UUID
        var region: Region
        var y: CGFloat
        var focus: () -> Void
    }
    var destinations: [UUID: Destination] = [:]
    private var enteredReceiptsFromComposer = false

    var ordered: [Destination] {
        destinations.values.sorted {
            if $0.region != $1.region { return $0.region.rawValue < $1.region.rawValue }
            return $0.region == .receipt ? $0.y > $1.y : $0.y < $1.y
        }
    }

    @discardableResult
    func move(from id: UUID, backwards: Bool) -> Bool {
        let order = ordered
        // With Keyboard navigation off, native buttons cannot take focus; preserve the native loop.
        guard NSApp.isFullKeyboardAccessEnabled,
              order.contains(where: { $0.region == .composer }),
              let index = order.firstIndex(where: { $0.id == id }) else { return false }
        let current = order[index]
        if backwards || current.region == .rail || current.region == .send {
            enteredReceiptsFromComposer = false
        }
        let target: Destination
        if !backwards, current.region == .composer,
           let receipt = order.first(where: { $0.region == .receipt }) {
            enteredReceiptsFromComposer = true
            target = receipt
        } else if backwards, index == 0, current.region == .rail,
                  let composer = order.first(where: { $0.region == .composer }) {
            target = composer
        } else if !backwards, enteredReceiptsFromComposer, current.region == .receipt,
                  index + 1 < order.count, order[index + 1].region == .composer,
                  let send = order.first(where: { $0.region == .send }) {
            // Finish the circuit without re-entering receipts before Send and the rail.
            target = send
        } else if !backwards, enteredReceiptsFromComposer, current.region == .receipt,
                  index + 1 < order.count, order[index + 1].region == .composer,
                  let rail = order.first(where: { $0.region == .rail }) {
            target = rail
        } else {
            target = order[(index + (backwards ? order.count - 1 : 1)) % order.count]
        }
        if target.region != .receipt { enteredReceiptsFromComposer = false }
        target.focus()
        return true
    }
}

extension EnvironmentValues {
    @Entry var shellKeyboardOrder: ShellKeyboardOrder? = nil
}

private struct ShellKeyboardTarget: ViewModifier {
    @Environment(\.shellKeyboardOrder) private var order
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var id = UUID()
    @State private var y: CGFloat = 0
    @State private var visible = false
    let region: ShellKeyboardOrder.Region
    var sortsLast = false
    var composerFocused: Bool = false
    var focusComposer: (() -> Void)?
    /// Let local composer settings finish their focus ring before the window-wide order takes Tab.
    var tabInto: ((Bool) -> Bool)?
    var suggestionKey: ((UInt16) -> Bool)?
    var onPaste: (([NSItemProvider]) -> Void)?

    func body(content: Content) -> some View {
        Group {
            if region == .composer {
                content.background {
                    // A hidden composer may retain stale FocusState; it must not intercept another page's keys.
                    ComposerKeys(active: enabled && composerFocused, move: { backwards in
                        if tabInto?(backwards) == true { return true }
                        return order?.move(from: id, backwards: backwards) ?? false
                    }, suggestionKey: suggestionKey, onPaste: onPaste)
                }
            } else {
                content.focused($focused)
                    // Keep rail focus consistent with its rounded haze ring.
                    .focusEffectDisabled(region == .rail)
                    .overlay { if region == .rail, focused { ShellRailFocusRing() } }
                    .onKeyPress(keys: [.tab, .backTab]) { press in
                        guard !press.modifiers.contains(.option) else { return .ignored }
                        return order?.move(from: id, backwards: press.modifiers.contains(.shift)) == true
                            ? .handled : .ignored
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: {
            y = sortsLast ? .greatestFiniteMagnitude : $0
            register()
        }
        .onScrollVisibilityChange(threshold: 0.01) {
            visible = $0
            register()
        }
        .onAppear { register() }
        .onChange(of: enabled) { register() }
        .onDisappear { order?.destinations.removeValue(forKey: id) }
    }

    private func register() {
        guard enabled, region != .receipt || visible else {
            order?.destinations.removeValue(forKey: id)
            return
        }
        order?.destinations[id] = .init(id: id, region: region, y: y) {
            if let focusComposer { focusComposer() } else { focused = true }
        }
    }
}

extension KeyEquivalent {
    /// Shift-Tab arrives as U+0019, so a shifted .tab handler cannot intercept it.
    static let backTab = KeyEquivalent("\u{19}")
}

extension View {
    /// Native buttons already take focus with Keyboard navigation on; add focusable only when needed to avoid double stops.
    @MainActor @ViewBuilder
    func buttonFocusable() -> some View {
        if NSApp.isFullKeyboardAccessEnabled { self } else { focusable() }
    }

    /// Pinned controls must sort after every scrolling row regardless of scroll position.
    func shellKeyboardTarget(_ region: ShellKeyboardOrder.Region, sortsLast: Bool = false) -> some View {
        modifier(ShellKeyboardTarget(region: region, sortsLast: sortsLast))
    }

    func shellComposerKeyboardTarget(
        isFocused: Bool,
        focus: @escaping () -> Void,
        tabInto: ((Bool) -> Bool)? = nil,
        suggestionKey: ((UInt16) -> Bool)? = nil,
        onPaste: (([NSItemProvider]) -> Void)? = nil
    ) -> some View {
        modifier(ShellKeyboardTarget(
            region: .composer,
            composerFocused: isFocused,
            focusComposer: focus,
            tabInto: tabInto,
            suggestionKey: suggestionKey,
            onPaste: onPaste
        ))
    }
}

/// Put the lamp beneath content so its light cannot wash out cards or text.
var shellLampUnderContent: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["SHELL_LAMP_UNDER"] == "1"
    #else
    return false
    #endif
}
