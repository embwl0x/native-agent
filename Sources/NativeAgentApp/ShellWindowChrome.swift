import AppKit
import SwiftUI

/// User, 2026-09-02: "that top corner looks bolted together." Two causes, one
/// fix each. The standard title bar was an opaque strip laid over glass
/// columns, so the rail and the room met it at a hard seam: in the new shell
/// the title bar is transparent and the content runs up under it, the
/// traffic lights float on the rail, the title goes (the rail already says
/// where you are) and the toolbar's leftover » goes with it. And on this
/// macOS the split view draws its sidebar as a floating rounded pane, so the
/// rail had corners top and bottom: the new shell no longer lives in a split
/// view at all (see ShellFrame). One surface, edge to edge.
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
        // 2026-09-08 (User): dragging to select text in the composer moved the
        // window. Background-drag is off; the glass sheet under the columns
        // carries the drag gesture instead, so any view that handles its own
        // mouse (text fields, buttons) wins and empty chrome still drags.
        window.isMovableByWindowBackground = false
    }
}

/// The classic shell keeps NavigationSplitView; the new shell lays the rail
/// and the content side by side itself, so no system pane draws corners.
struct ShellFrame<Sidebar: View, Detail: View>: View {
    @State private var keyboardOrder = ShellKeyboardOrder()
    var classic: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        Group {
            if classic {
                NavigationSplitView {
                    sidebar().focusSection()
                } detail: {
                    detail().focusSection()
                }
                    .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
            } else {
                HStack(spacing: 0) {
                    sidebar().focusSection()
                    detail().focusSection()
                }
                // User, 2026-09-03: one sheet of glass. Agent, same day: drawn ONCE,
                // here, under all three columns — per-column copies of the same
                // material still read as three plates. The columns are transparent
                // over it; the lamp is drawn once over all of them.
                .background {
                    ShellSheet().contentShape(Rectangle()).gesture(WindowDragGesture())
                        .overlay { if shellLampUnderContent { ShellLamp() } }
                }
                .overlay { if !shellLampUnderContent { ShellLamp() } }
            }
        }
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
        guard order.contains(where: { $0.region == .composer }),
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

private struct ShellKeyboardOrderKey: EnvironmentKey {
    static let defaultValue: ShellKeyboardOrder? = nil
}

extension EnvironmentValues {
    var shellKeyboardOrder: ShellKeyboardOrder? {
        get { self[ShellKeyboardOrderKey.self] }
        set { self[ShellKeyboardOrderKey.self] = newValue }
    }
}

private struct ShellKeyboardTarget: ViewModifier {
    @Environment(\.shellKeyboardOrder) private var order
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var id = UUID()
    @State private var y: CGFloat = 0
    @State private var visible = false
    let region: ShellKeyboardOrder.Region
    var composerFocused: Bool = false
    var focusComposer: (() -> Void)?

    func body(content: Content) -> some View {
        Group {
            if region == .composer {
                content.background {
                    ComposerTabKeyHandler(active: composerFocused) { backwards in
                        order?.move(from: id, backwards: backwards) ?? false
                    }
                }
            } else {
                content.focused($focused)
                    .onKeyPress(keys: [.tab]) { press in
                        guard !press.modifiers.contains(.option) else { return .ignored }
                        return order?.move(from: id, backwards: press.modifiers.contains(.shift)) == true
                            ? .handled : .ignored
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: {
            y = $0
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

extension View {
    func shellKeyboardTarget(_ region: ShellKeyboardOrder.Region) -> some View {
        modifier(ShellKeyboardTarget(region: region))
    }

    func shellComposerKeyboardTarget(isFocused: Bool, focus: @escaping () -> Void) -> some View {
        modifier(ShellKeyboardTarget(region: .composer, composerFocused: isFocused, focusComposer: focus))
    }
}

/// Review comparison (2026-09-10): the lamp drawn under page content so cards
/// and text sit above the light instead of being washed by it.
var shellLampUnderContent: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["SHELL_LAMP_UNDER"] == "1"
    #else
    return false
    #endif
}
