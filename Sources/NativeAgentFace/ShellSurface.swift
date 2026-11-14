import SwiftUI
import NativeAgentShared

// Blueprint: | `ShellSurface.swift` | `ShellSurface`: the window's five places; `ShellSurfaceTabs`: a place's tabs; `ShellPlacePage`: tabs over the page, the ask bar under it |

/// One of the window's places: Advanced's rail draws all five, Simple's sidebar all but Diagnostics. A surface is a fixed grouping of the pages
/// the layout's `rail` block shows in the window's view, in that block's order; the pages, their ids and the layout stay as they are, and a
/// surface showing more than one page shows them as tabs.
enum ShellSurface: String, CaseIterable, Identifiable, Sendable {
    case chat, desk, agent, control, diagnostics

    var id: String { rawValue }

    /// The surface a page belongs to. A tab item (Knowledge graph, Dreams, Cognition, Inspector) belongs with the page that holds it
    /// (`SidebarItem.shellHome`).
    init(_ item: SidebarItem) {
        switch item {
        case .chat: self = .chat
        case .desk, .activity, .inboxPolicy, .bots: self = .desk
        case .memories, .knowledge, .personality, .dreams, .capabilities, .ownPage: self = .agent
        case .trust, .providers, .connectors, .settings: self = .control
        case .diagnostics, .cognition, .inspector: self = .diagnostics
        }
    }

    /// The page the surface opens on the first time it is chosen in a window.
    var firstPage: SidebarItem {
        switch self {
        case .chat: .chat
        case .desk: .desk
        case .agent: .memories
        case .control: .trust
        case .diagnostics: .diagnostics
        }
    }

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

    /// The surface a rail word names. The rail's fixed words win: a surface's id, or the word drawn for a place other than the agent's. The
    /// agent's name as it is now names the agent's place only when no fixed place has that word.
    @MainActor static func named(_ word: String, appModel: AppModel) -> ShellSurface? {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        func names(_ fixed: String) -> Bool { fixed.caseInsensitiveCompare(word) == .orderedSame }
        if let fixed = allCases.first(where: { names($0.rawValue) || ($0 != .agent && names($0.title(appModel))) }) { return fixed }
        return names(ShellSurface.agent.title(appModel)) ? .agent : nil
    }

    /// The place's word. The agent's place carries the name the shell writes everywhere else (`agentDisplayName`); while
    /// that name is unread or unreadable the place is called Agent.
    @MainActor func title(_ appModel: AppModel) -> String {
        switch self {
        case .chat: return "Chat"
        case .desk: return "Desk"
        case .agent:
            let name = appModel.agentDisplayName
            return name.isEmpty ? "Agent" : name
        case .control: return "Control"
        case .diagnostics: return "Diagnostics"
        }
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
    private let own: [QuietPage]
    private let catalog: PartFaceCatalog?

    init(_ appModel: AppModel, pages: [ShellRailRow]) {
        own = QuietPages.own(appModel, ids: Set(pages.compactMap { row -> String? in if case .page(let id) = row { id } else { nil } }))
        catalog = appModel.face.slot(PageFaceKey.catalog).value(as: PartFaceCatalog.self)
    }

    func title(_ row: ShellRailRow) -> String {
        switch row {
        case .item(let item): return item.shellRailTitle
        case .page(let page):
            if let title = own.first(where: { $0.id == page })?.title { return title }
            if catalog?.failure != nil { return "\(page) · unavailable" }
            if catalog == nil { return "\(page) · waiting" }
            return "\(page) · unclaimed"
        // The divider is no page and names none.
        case .divider: return ""
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
