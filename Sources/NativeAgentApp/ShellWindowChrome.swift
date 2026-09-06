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
        window.isMovableByWindowBackground = true
    }
}

/// The classic shell keeps NavigationSplitView; the new shell lays the rail
/// and the content side by side itself, so no system pane draws corners.
struct ShellFrame<Sidebar: View, Detail: View>: View {
    var classic: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        if classic {
            NavigationSplitView(sidebar: sidebar, detail: detail)
        } else {
            HStack(spacing: 0) {
                sidebar()
                detail()
            }
            // User, 2026-09-03: one sheet of glass. Agent, same day: drawn ONCE,
            // here, under all three columns — per-column copies of the same
            // material still read as three plates. The columns are transparent
            // over it; the lamp is drawn once over all of them.
            .background { ShellSheet() }
            .overlay { ShellLamp() }
        }
    }
}
