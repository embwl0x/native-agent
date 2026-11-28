import SwiftUI
import NativeAgentShared

// Blueprint: | `ShellSurface.swift` | Mac place layout and last tab; `ShellSurfaceTabs` and `ShellPlacePage` draw the tabs, page and ask bar |

extension ShellSurface {
    /// The surfaces, in rail order, each with the pages the layout shows of it in the view `profile` names; a surface with none is absent.
    static func shown(_ layout: SurfaceLayoutAvailability, profile: String) -> [ShellSurfacePages] {
        let rows = SidebarItem.railRows(layout, profile: profile)
        return allCases.compactMap { surface in
            let pages = surface.pages(rows)
            return pages.isEmpty ? nil : ShellSurfacePages(surface: surface, pages: pages)
        }
    }

    /// The surface's pages among the layout's rail rows, in their order.
    func pages(_ rows: [ShellRailRow]) -> [ShellRailRow] {
        rows.filter { $0.surface == self }
    }

    /// The page choosing the surface shows: the one last shown in it during this run of the window, else its first page, else the
    /// first page it shows. Nil only when it shows no page, and then no row is drawn for it.
    func opening(_ pages: [ShellRailRow], last: ShellRailRow?) -> ShellRailRow? {
        if let last, pages.contains(last) { return last }
        if pages.contains(.item(firstPage)) { return .item(firstPage) }
        return pages.first
    }

    @MainActor static func named(_ word: String, appModel: AppModel) -> ShellSurface? {
        named(word, agentName: appModel.agentDisplayName)
    }
}

/// A place the window draws and the pages the layout shows of it.
struct ShellSurfacePages: Identifiable {
    let surface: ShellSurface
    let pages: [ShellRailRow]
    var id: ShellSurface { surface }
}

extension ShellRailRow {
    /// The surface the row's page belongs to; a page of the agent's own belongs to the agent's place, the divider to none.
    var surface: ShellSurface? {
        switch self {
        case .item(let item): ShellSurface(item)
        case .page: .agent
        case .divider: nil
        }
    }

    /// The accessibility identifier of the control that selects this page.
    var identifier: String? {
        switch self {
        case .item(let item): "sidebar.item.\(item.rawValue)"
        case .page(let page): "sidebar.page.\(page)"
        case .divider: nil
        }
    }
}

/// The words a page is named by in the rail and its surface's tabs: an app page by its rail title, a page of the agent's own by its
/// face's title, or by its id with why it has none.
@MainActor struct ShellPageWords {
    private let titles: [String: String]
    private let catalog: PartFaceCatalog?

    init(_ appModel: AppModel, pages: [ShellRailRow]) {
        titles = Dictionary(uniqueKeysWithValues: pages.compactMap { row -> (String, String)? in
            guard case .page(let id) = row,
                  let title = appModel.face.slot(.pageTitle(id)).value(as: PageTitleFace.self)?.title,
                  !title.isEmpty else { return nil }
            return (id, title)
        })
        catalog = appModel.face.slot(PageFaceKey.catalog).value(as: PartFaceCatalog.self)
    }

    func title(_ row: ShellRailRow) -> String {
        switch row {
        case .item(let item): return item.shellRailTitle
        case .page(let page):
            if catalog?.claims[page] != nil { return titles[page] ?? page }
            if catalog?.failure != nil { return "\(page) · unavailable" }
            if catalog == nil { return "\(page) · waiting" }
            return "\(page) · unclaimed"
        // The divider is no page and names none.
        case .divider: return ""
        }
    }
}

/// Each mounted label holds its small title slot independently of the page's content reader.
struct ShellPageWordObservation: ViewModifier {
    let pages: [ShellRailRow]
    func body(content: Content) -> some View {
        content.background {
            ForEach(pages.compactMap { row -> String? in if case .page(let id) = row { id } else { nil } }, id: \.self) { id in
                Color.clear.frame(width: 0, height: 0)
                    .modifier(FaceObservation(demand: .key(.pageTitle(id))))
            }
        }
    }
}

extension AppModel {
    /// Whether something waits on the person: nil while the waiting count is unread or unavailable. The Desk place's row and the Today
    /// tab carry it.
    var waitingOnPerson: Bool? {
        countPart("deskWaiting.presence") { face in
            guard let count = face?.deskWaiting, count.isAvailable, let value = count.value else { return nil }
            return value > 0
        }
    }
}

/// The selected surface's pages as tabs across the top of the page area, in the layout's order for the window's view, in the control
/// Diagnostics' own tabs use. A surface showing one page draws none. A page with tabs of its own keeps them inside the page, below these.
struct ShellSurfaceTabs: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.layoutProfile) private var layoutProfile
    let surface: ShellSurface
    /// The page the window shows.
    let shown: ShellRailRow
    let select: (ShellRailRow) -> Void

    var body: some View {
        if let layout = appModel.shellLayout {
            let pages = surface.pages(SidebarItem.railRows(layout, profile: layoutProfile))
            if pages.count > 1 {
                let words = ShellPageWords(appModel, pages: pages)
                // Only a surface holding Today reads the waiting count.
                let waiting = pages.contains(.item(.activity)) && appModel.waitingOnPerson == true
                ShellTabs(tabs: pages.map { page in
                    ShellTab(key: page, title: words.title(page), identifier: page.identifier,
                             needsYou: waiting && page == .item(.activity))
                }, selection: Binding(get: { shown }, set: { select($0) }))
                .modifier(ShellPageWordObservation(pages: pages))
                .padding(.top, NativeAgentSpacing.md)
                .padding(.horizontal, NativeAgentSpacing.pageInset)
                .frame(maxWidth: TodayMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The page area of every place but Chat, the same in Simple and Advanced: the page's stale notice, its place's tabs, the page and the ask
/// bar under it. Chat draws nothing here; the view that keeps Chat mounted shows it.
struct ShellPlacePage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    /// The page the window shows.
    let shown: ShellRailRow
    let select: (ShellRailRow) -> Void

    private var item: SidebarItem {
        if case .item(let item) = shown { item } else { .ownPage }
    }
    private var ownPage: String? {
        if case .page(let id) = shown { id } else { nil }
    }
    /// One identity per page shown, so two pages of the agent's own never share a page's state.
    private var identity: String { ownPage.map { SurfaceLayout.pagePrefix + $0 } ?? item.rawValue }

    var body: some View {
        let showingChat = shown == .item(.chat)
        // The tabs sit over the page column only, so mounted Chat keeps its frame.
        VStack(spacing: 0) {
            if !showingChat {
                if let notice = appModel.panelStaleNotice(for: item) {
                    StalePanelNotice(text: notice)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if let surface = shown.surface {
                    ShellSurfaceTabs(surface: surface, shown: shown, select: select)
                }
            }
            ZStack {
                if !showingChat {
                    // Every page but Chat draws through the one page map.
                    ShellPageContent(item: item, ownPage: ownPage)
                        // Give each page distinct identity so navigation cannot reuse another page's state.
                        .id(identity)
                        .transition(NativeAgentMotion.fadeIn)
                }
            }
            // Replace pages atomically to avoid superimposed translucent text; local controls own their animations.
            .animation(nil, value: identity)
            // Chat's composer is its bar; every other page has this one below it, never over it. A picture of a page is the page, so an
            // offscreen read draws no bar and no unsent words.
            if !showingChat, !quietOffscreenRead {
                ShellAskBar(page: identity)
                    .padding(.horizontal, NativeAgentSpacing.pageInset)
                    .padding(.vertical, NativeAgentSpacing.sm)
                    .frame(maxWidth: TodayMetrics.contentWidth)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
