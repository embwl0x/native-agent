import AppKit
import SwiftUI

extension View {
    /// Page actions stay inside the content pane, so changing sidebar pages
    /// never adds or removes a window toolbar. On a tabbed page they sit at
    /// the right end of the tab row (`ShellTabbedPage`); elsewhere, in a row
    /// of their own at the top of the page.
    func pageActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        modifier(PageActionsModifier(actions: actions()))
    }

    /// The page column's right edge, the same whether or not this page's
    /// scroll view is showing a scroller. With legacy scrollers (a mouse
    /// attached) the scroller takes its width out of the column only while
    /// the page overflows; a page that fits leaves the same room empty, so
    /// the controls above the scroll view (`ShellScrollGutter`) and the rows
    /// in it end at one x either way. Applies to the scroll views inside.
    func pageScrollColumn() -> some View {
        modifier(PageScrollColumn())
    }
}

/// The width a legacy scroller takes out of a page's scroll view; zero with
/// overlay scrollers. Controls drawn above a page's scroll view inset their
/// trailing edge by it so they end where the rows below end.
@MainActor @Observable
final class ShellScrollGutter {
    static let shared = ShellScrollGutter()
    private(set) var width: CGFloat = ShellScrollGutter.current()
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ShellScrollGutter.shared.width = ShellScrollGutter.current() }
        }
    }

    private static func current() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }
}

private struct PageScrollColumn: ViewModifier {
    @State private var overflows = false
    @State private var height: CGFloat = 0

    private struct Reading: Equatable {
        var containerHeight: CGFloat
        var overflows: Bool
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // Every scroll view inside reports here; only the page's own
            // (most of the page tall) decides. A chip row or a small inset
            // list must not.
            .onScrollGeometryChange(for: Reading.self) { geometry in
                Reading(containerHeight: geometry.containerSize.height,
                        overflows: geometry.contentSize.height > geometry.containerSize.height + 0.5)
            } action: { _, reading in
                guard reading.containerHeight >= height * 0.6 else { return }
                overflows = reading.overflows
            }
            .contentMargins(.trailing, overflows ? 0 : ShellScrollGutter.shared.width, for: .scrollContent)
    }
}

extension EnvironmentValues {
    /// Set by `ShellTabbedPage`: its tab row draws the page's actions.
    @Entry var shellTabRowHostsActions: Bool = false
}

/// The selected tab's actions, handed up to the tab row that draws them.
struct ShellPageActionsKey: PreferenceKey {
    static var defaultValue: AnyView? { nil }
    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        value = value ?? nextValue()
    }
}

private struct PageActionsModifier<Actions: View>: ViewModifier {
    let actions: Actions
    @Environment(\.shellTabRowHostsActions) private var tabRowHostsActions

    func body(content: Content) -> some View {
        if tabRowHostsActions {
            content.preference(key: ShellPageActionsKey.self, value: AnyView(actions))
        } else {
            content.safeAreaInset(edge: .top, spacing: 12) {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    actions
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 4)
                .padding(.trailing, ShellScrollGutter.shared.width)
            }
        }
    }
}

// User, 2026-09-04: the Advanced pages come out from behind Settings and onto
// the rail, and the ones that belong together become tabs on one page. The
// tab row is the rail's own idiom turned sideways: the rail's 14pt medium
// words, the selected one in the text colour with the rail's 2pt bar that
// travels, the rest secondary with a hover fade on the word. No segmented
// control, no second accent.

/// One tab: a stable key (persisted per page) and the word a person reads.
struct ShellTab<Key: Hashable>: Identifiable {
    let key: Key
    let title: String
    var id: Key { key }
}

/// The page's sections as the Mac's own segmented control (User 09-27: all
/// controls native; her colour arrives through the app tint).
struct ShellTabs<Key: Hashable>: View {
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key

    var body: some View {
        HStack(spacing: 0) {
            Picker("Sections", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(tab.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Sections")
    }
}

/// A rail page with tabs: the page frame's title, the tab row under it, then
/// the selected tab's content. Content is keyed by the selection so a tab
/// switch is a clean swap, never a half-updated page.
struct ShellTabbedPage<Key: Hashable, Content: View>: View {
    let title: String
    var subtitle: String?
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key
    /// The serif header; the tab content hands its line up (`alivePageLine`).
    var alive: Bool = false
    @ViewBuilder let content: (Key) -> Content
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.quietRailTab) private var quietRailTab
    @State private var tabRowHeight: CGFloat = 24

    var body: some View {
        // A screenshot's offscreen copy draws the tab it asked for, else the
        // first (default) tab — not the one User last left open, which is his.
        let shown = quietOffscreenRead
            ? (tabs.first { ($0.key as? String) == quietRailTab } ?? tabs.first)?.key ?? selection
            : selection
        ShellPageFrame(title: title, subtitle: subtitle, showsBack: false, alive: alive) {
            VStack(alignment: .leading, spacing: 0) {
                ShellTabs(tabs: tabs, selection: quietOffscreenRead ? .constant(shown) : $selection)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabRowHeight = $0 }
                    .padding(.bottom, alive ? 0 : 18)
                content(shown)
                    .id(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .aliveTopDissolve(alive ? 18 : 0)
                    .environment(\.shellTabRowHostsActions, true)
            }
            // The tab's actions (Refresh) at the right end of the tab row,
            // ending where the tab's rows end.
            .overlayPreferenceValue(ShellPageActionsKey.self, alignment: .topTrailing) { actions in
                if let actions {
                    HStack(spacing: 12) { actions }
                        .buttonStyle(.bordered)
                        .frame(height: tabRowHeight)
                        .padding(.trailing, ShellScrollGutter.shared.width)
                }
            }
        }
    }
}

private let aliveTopClearBand: CGFloat = 8

extension View {
    /// An alive page's gap under its pinned header or tab row, as a dissolve
    /// instead of a gap. The gap becomes safe area, so content still rests
    /// `gap` down but scrolls up into it, and a static alpha mask fades it
    /// out across the gap: the soft edge the chat header has
    /// (`roomTopChrome`), not a hard slice at the scroll view's edge.
    /// Static geometry, no `safeAreaBar` (it pinned the main thread).
    /// The first `aliveTopClearBand` points are fully clear, so a line cut
    /// at the edge shows no partial glyphs; the ramp fills the rest of the
    /// gap and ends where content rests. Chat's 24pt fade (`simpleTopFade`)
    /// runs over scrolled lines only; here the gap is the whole budget.
    @ViewBuilder
    func aliveTopDissolve(_ gap: CGFloat) -> some View {
        if gap > 0 {
            safeAreaPadding(.top, gap)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: min(aliveTopClearBand, gap))
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: max(gap - aliveTopClearBand, 0))
                        Color.black
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
        } else {
            self
        }
    }
}

/// A rail page without tabs: the frame and its title, nothing else added.
struct ShellRailPage<Content: View>: View {
    let title: String
    var subtitle: String?
    var wide: Bool = false
    /// The serif header; the content hands its line up (`alivePageLine`).
    var alive: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        ShellPageFrame(title: title, subtitle: subtitle, showsBack: false, wide: wide, alive: alive) { content }
    }
}
