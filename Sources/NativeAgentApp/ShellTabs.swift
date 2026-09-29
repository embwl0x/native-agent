import SwiftUI

extension View {
    /// Page actions stay inside the content pane, so changing sidebar pages
    /// never adds or removes a window toolbar.
    func pageActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        safeAreaInset(edge: .top, spacing: 12) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                actions()
            }
            .buttonStyle(.bordered)
            .padding(.vertical, 4)
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

    var body: some View {
        ShellPageFrame(title: title, subtitle: subtitle, showsBack: false, alive: alive) {
            VStack(alignment: .leading, spacing: 0) {
                ShellTabs(tabs: tabs, selection: $selection)
                    .padding(.bottom, alive ? 0 : 18)
                content(selection)
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .aliveTopDissolve(alive ? 18 : 0)
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
