import AppKit
import SwiftUI
import NativeAgentShared

// Blueprint: | `ShellTabs.swift` | Shell page/tab components: content-local action rows, shared scroll gutter and tabbed page layout |

extension View {
    /// Keep actions inside page content so navigation never adds or removes a window toolbar.
    func pageActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        modifier(PageActionsModifier(actions: actions()))
    }

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

extension EnvironmentValues {
    /// Let the tab row own actions so they are not drawn twice.
    @Entry var shellTabRowHostsActions: Bool = false
}

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
    var subtitle: String? = nil
    var subtitlePage: SidebarItem? = nil
    let tabs: [ShellTab<Key>]
    @Binding var selection: Key
    var alive: Bool = false
    @ViewBuilder let content: (Key) -> Content
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Environment(\.quietRailTab) private var quietRailTab
    @State private var tabRowHeight: CGFloat = 24

    var body: some View {
        // Screenshots use their requested or default tab without changing the user's mounted selection.
        let shown = quietOffscreenRead
            ? (tabs.first { ($0.key as? String) == quietRailTab } ?? tabs.first)?.key ?? selection
            : selection
        ShellPageFrame(
            title: title,
            subtitle: subtitlePage.flatMap { ShellPageSubtitle.line($0, appModel) } ?? subtitle,
            alive: alive
        ) {
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
            // Align tab actions to the rows' trailing edge.
            .overlayPreferenceValue(ShellPageActionsKey.self, alignment: .topTrailing) { actions in
                if let actions {
                    HStack(spacing: 12) { actions }
                        .buttonStyle(.bordered)
                        .frame(height: tabRowHeight)
                        .padding(.trailing, ShellScrollGutter.shared.width)
                }
            }
        }
        .quietReadTask(id: subtitlePage?.rawValue) {
            if let page=subtitlePage, ShellPageContent.doorPage(page) == nil {
                do { try FaceWindowReply.check(await appModel.client.act(.requestCopy(keys: ["page:" + page.rawValue]))) }
                catch { appModel.statusText = error.localizedDescription }
            }
        }
    }
}

private let aliveTopClearBand: CGFloat = 8

extension View {
    /// Use static safe-area geometry to keep scrolling responsive; safeAreaBar can block the main thread.
    /// Fade over the header gap and clear its first points so clipped partial glyphs stay invisible.
    /// Keep the fade within the gap so resting content retains full opacity.
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

/// A faced page's own line is its subtitle under the rail; other pages read their prepared caption.
enum ShellPageSubtitle {
    @MainActor static func line(_ page: SidebarItem, _ appModel: AppModel) -> String? {
        if let id = ShellPageContent.doorPage(page) {
            return appModel.face.slot(.page(id)).value(as: PartFaceSnapshot.self)?.face?.line
        }
        return appModel.face.slot(PageFaceKey.copy("page:" + page.rawValue)).value(as: PartFaceSnapshot.self)?.copyWords()
    }
}
