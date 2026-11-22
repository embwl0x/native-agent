import AppKit
import SwiftUI
import NativeAgentShared

// Blueprint: | `ShellTabs.swift` | Shell page/tab components: shared scroll gutter and tabbed page layout |

extension View {
    /// Reserve the same scroller width even when content fits so controls and rows share one right edge.
    func pageScrollColumn() -> some View {
        modifier(PageScrollColumn())
    }
}

/// Inset controls above scrolling rows by the scroller width so their trailing edges align.
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
            Task { @MainActor in ShellScrollGutter.shared.width = ShellScrollGutter.current() }
        }
    }

    private static func current() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }
}

/// Use scroller width, never overflow; rewrapping would feed back into an overflow measurement.
private struct PageScrollColumn: ViewModifier {
    func body(content: Content) -> some View {
        content.contentMargins(.trailing, ShellScrollGutter.shared.width, for: .scrollContent)
    }
}



/// Persist stable keys independently of user-facing tab words.
struct ShellTab<Key: Hashable>: Identifiable {
    let key: Key
    let title: String
    /// The segment's accessibility identifier, where one already names the page the tab selects.
    var identifier: String? = nil
    /// Something waits on the person here, the mark the rail's Desk row carries too.
    var needsYou = false
    var id: Key { key }
}

struct ShellTabs<Key: Hashable>: View {
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key

    var body: some View {
        HStack(spacing: 0) {
            Picker("Sections", selection: $selection) {
                ForEach(tabs) { tab in
                    if let identifier = tab.identifier {
                        word(tab).accessibilityIdentifier(identifier).tag(tab.key)
                    } else {
                        word(tab).tag(tab.key)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Sections")
    }

    /// The one accent's dot marks a tab where something waits on the person, as it marks the rail row.
    private func word(_ tab: ShellTab<Key>) -> Text {
        guard tab.needsYou else { return Text(tab.title) }
        return Text("\(tab.title) \(Text("●").foregroundStyle(NativeAgentShell.needsYou))")
            .accessibilityLabel("\(tab.title), waiting for you")
    }
}

/// Key content by selection so tab changes replace the entire page coherently.
struct ShellTabbedPage<Key: Hashable, Content: View>: View {
    @Environment(AppModel.self) private var appModel
    let title: String
    var subtitlePage: SidebarItem? = nil
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key
    @ViewBuilder let content: (Key) -> Content
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.quietRailTab) private var quietRailTab

    var body: some View {
        // Screenshots use their requested or default tab without changing the user's mounted selection.
        let shown = quietOffscreenRead
            ? (tabs.first { ($0.key as? String) == quietRailTab } ?? tabs.first)?.key ?? selection
            : selection
        ShellPageFrame(
            title: title,
            subtitle: subtitlePage.flatMap { ShellPageSubtitle.line($0, appModel) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ShellTabs(tabs: tabs, selection: quietOffscreenRead ? .constant(shown) : $selection)
                content(shown)
                    .id(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .aliveTopDissolve(18)
            }
        }
        .modifier(FaceObservation(demand: subtitlePage.flatMap(SidebarItem.doorPage).map { .key(.page($0)) }))
    }
}

private let aliveTopClearBand: CGFloat = 8

extension View {
    /// Use static safe-area geometry to keep scrolling responsive; safeAreaBar can block the main thread.
    /// Fade over the header gap and clear its first points so clipped partial glyphs stay invisible.
    /// Keep the fade within the gap so resting content retains full opacity.
    func aliveTopDissolve(_ gap: CGFloat) -> some View {
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
    }
}

enum ShellPageSubtitle {
    @MainActor static func line(_ page: SidebarItem, _ appModel: AppModel) -> String? {
        SidebarItem.doorPage(page).flatMap {
            appModel.face.slot(.page($0)).value(as: PartFaceSnapshot.self)?.face?.line
        }
    }
}
