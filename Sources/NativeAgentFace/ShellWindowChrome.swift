import AppKit
import SwiftUI

// Blueprint: | `ShellWindowChrome.swift` | `ShellWindowChrome`, `ShellFrame`: native chrome, split layout and keyboard order |

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
