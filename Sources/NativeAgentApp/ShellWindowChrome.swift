import AppKit
import SwiftUI

// Blueprint: | `ShellWindowChrome.swift` | `ShellWindowChrome` and `ShellFrame`: native window/titlebar integration, split shell layout and explicit keyboard target order |

/// A transparent title bar lets the shell run edge to edge beneath the traffic lights.
struct ShellWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: view.window) }
    }

    static func apply(to window: NSWindow?) {
        guard let window else { return }
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

/// The shell lays the rail and the content side by side itself, so no system
/// pane draws corners.
struct ShellFrame<Sidebar: View, Detail: View>: View {
    @State private var keyboardOrder = ShellKeyboardOrder()
    /// The haze is drawn only without Reduce Transparency, and where it is
    /// drawn it replaces the warm lamp: the two mixed to olive-khaki.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar().focusSection()
            detail().focusSection()
        }
        // One glass sheet and lamp span the transparent columns; only the rail floats above them.
        .background {
            ShellSheet().contentShape(Rectangle()).gesture(WindowDragGesture())
                // One haze sits over the sheet and beneath every column.
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
        // Other pages retain their native traversal through all page controls.
        // Without Keyboard navigation (System Settings > Keyboard) macOS keeps
        // buttons out of focus, so a hop to the rail or Send would land nowhere
        // and eat the Tab; the native loop keeps it.
        guard NSApp.isFullKeyboardAccessEnabled,
              order.contains(where: { $0.region == .composer }),
              let index = order.firstIndex(where: { $0.id == id }) else { return false }
        let current = order[index]
        if backwards || current.region == .rail || current.region == .send {
            enteredReceiptsFromComposer = false
        }
        let target: Destination
        // Leaving the draft goes straight to the newest visible Details.
        // Shift-Tab at the start of the rail returns directly to the draft.
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
            // Complete the forward circuit without returning to the draft
            // and entering the receipts again before reaching Send/the rail.
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
    /// Offered the draft's Tab before the window-wide order is. The composer's
    /// own settings words are a local ring inside the region, so Tab walks them
    /// before it leaves the composer at all.
    var tabInto: ((Bool) -> Bool)?
    var suggestionKey: ((UInt16) -> Bool)?
    var onPaste: (([NSItemProvider]) -> Void)?

    func body(content: Content) -> some View {
        Group {
            if region == .composer {
                content.background {
                    // A retained, hidden composer may still have a stale
                    // FocusState. It must not intercept another page's keys.
                    ComposerKeys(active: enabled && composerFocused, move: { backwards in
                        if tabInto?(backwards) == true { return true }
                        return order?.move(from: id, backwards: backwards) ?? false
                    }, suggestionKey: suggestionKey, onPaste: onPaste)
                }
            } else {
                content.focused($focused)
                    // The rail draws its own rounded ring in the haze's edge
                    // light instead of the square system one.
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
    /// Shift-Tab arrives as U+0019, not as `.tab` with Shift held, so a
    /// `keys: [.tab]` handler never saw it and Shift-Tab fell to the native
    /// loop: the rail's first word went to Send instead of back to the draft.
    static let backTab = KeyEquivalent("\u{19}")
}

extension View {
    /// A button or switch is a focus stop by itself while Keyboard navigation
    /// is on, and `.focusable()` over it adds a second, invisible stop: Tab
    /// off the last word, or through a pane, did nothing once. So it is added
    /// only when the system leaves buttons out; one stop either way.
    @MainActor @ViewBuilder
    func buttonFocusable() -> some View {
        if NSApp.isFullKeyboardAccessEnabled { self } else { focusable() }
    }

    /// `sortsLast`: a control pinned below a scrolling list (Simple's
    /// Settings) comes after every row, wherever the list is scrolled.
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

/// Places the lamp beneath content so cards and text remain above its light.
var shellLampUnderContent: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["SHELL_LAMP_UNDER"] == "1"
    #else
    return false
    #endif
}
