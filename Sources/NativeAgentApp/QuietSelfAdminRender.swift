import Connectors
import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import AgentWorkspace
import ChatToolRuntime
import AppKit
import ChatTurnRuntime
import Foundation
import Dispatcher
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// Read the page owners directly so quiet projections cannot drift into another store.
import ProviderRouting
import StandingBots
import SwiftUI
import MacIntegration
import MemoryV2
import ToolRegistry
import ToolExecution
import TrustCenter
import TrustPersistence
// Blueprint: | `QuietSelfAdminRender.swift` | Quiet pages read engine.pages faces as text before page-specific projections; offscreen rendering |

extension EnvironmentValues {
    /// Screenshots suppress lifecycle writes while allowing read-only loads.
    @Entry var quietOffscreenRead: Bool = false

    /// A nil screenshot tab selects the page default without changing the mounted selection.
    @Entry var quietRailTab: String? = nil
}

private struct LiveTaskModifier<ID: Equatable>: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let id: ID
    let action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        content.task(id: id) {
            guard !quietOffscreenRead else { return }
            await action()
        }
    }
}

private struct LiveAppearModifier: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            guard !quietOffscreenRead else { return }
            action()
        }
    }
}

extension View {
    /// Suppress lifecycle work and writes for offscreen screenshots.
    func liveTask(
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(LiveTaskModifier(id: 0, action: action))
    }

    func liveTask<ID: Equatable>(
        id: ID,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(LiveTaskModifier(id: id, action: action))
    }

    /// Suppress appearance side effects for offscreen screenshots.
    func liveOnAppear(_ action: @escaping () -> Void) -> some View {
        modifier(LiveAppearModifier(action: action))
    }

    /// Count read-only loads so an offscreen capture can await its content.
    /// Writes, badge clears and permission requests belong on liveTask.
    /// Use live: false when an initial watcher event already loads the mounted page.
    func quietReadTask(
        live: Bool = true,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(QuietReadTaskModifier(id: 0, live: live, action: action))
    }

    func quietReadTask<ID: Equatable>(
        id: ID,
        live: Bool = true,
        @_inheritActorContext _ action: @escaping @Sendable () async -> Void
    ) -> some View {
        modifier(QuietReadTaskModifier(id: id, live: live, action: action))
    }
}

/// Count only offscreen loads; unrelated live refreshes must not hold a quiet read open.
@MainActor
enum QuietReadLoads {
    private(set) static var inFlight = 0

    static func begin() { inFlight += 1 }
    static func end() { inFlight = max(0, inFlight - 1) }
}

private struct QuietReadTaskModifier<ID: Equatable>: ViewModifier {
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    let id: ID
    let live: Bool
    let action: @Sendable () async -> Void

    func body(content: Content) -> some View {
        content.task(id: id) {
            guard quietOffscreenRead else {
                if live { await action() }
                return
            }
            QuietReadLoads.begin()
            await action()
            QuietReadLoads.end()
        }
    }
}

@MainActor
enum QuietSelfAdminRender {
    /// Preserve wide layouts while keeping a PNG within the eight-MiB tool-image ceiling.
    static let defaultSize = CGSize(width: 1280, height: 860)

    // MARK: - The page, built offscreen

    /// A nil tab draws the page default without changing the mounted tab.
    @ViewBuilder
    static func pageView(for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize) -> some View {
        // Render tab destinations inside their rail frame so screenshots match the visible page.
        let home = SidebarItem.shellHome(for: page.item)
        Group {
            if QuietPages.drawOnly.contains(page) {
                SimpleShellView()
                    .environment(\.simpleSettingsMenuDrawnOpen, page.id == "simple_settings_menu")
            } else if page.id == "inbox" {
                FacePageView(page: "inbox")
            } else {
            switch home?.parent ?? page.item {
            case .chat: ChatView()
            case .activity: TodayView()
            case .memories: FacePageView(page: "memories").modifier(MemoriesFaceNavigation())
            case .desk: FacePageView(page: "desk").modifier(DeskFaceEditors())
            case .inboxPolicy: ShellRailPage(title: "Notifications", alive: true) { InboxSettingsView() }
            case .bots: FacePageView(page: "bots", isReading: appModel.panelRefreshCounts[.bots, default: 0] > 0)
            case .personality: FacePageView(page: "personality").personalityDestinations()
            case .providers: FacePageView(page: "providers", isReading: appModel.panelRefreshCounts[.providers, default: 0] > 0)
            case .trust: FacePageView(page: "trust")
            case .connectors: ConnectorsRailPage()
            case .capabilities: CapabilitiesRailPage()
            case .diagnostics: DiagnosticsRailPage()
            case .settings: FacePageView(page: "settings")
            default: EmptyView()
            }
            }
        }
        .environment(\.quietRailTab, tab ?? page.tab ?? home?.tab)
        .environment(appModel)
        // A screenshot is a read, so lifecycle work must not change the state being captured.
        .environment(\.quietOffscreenRead, true)
        .frame(width: size.width, height: size.height)
        // Supply the same room colour as the onscreen ShellSheet.
        .background(NativeAgentShell.room.ignoresSafeArea())
    }

    // MARK: - Giving the offscreen copy its content

    /// Bound screenshot waiting; slow reads leave a partial page instead of holding the tool call.
    static let loadBudget: TimeInterval = 4

    /// Preload read-only page data; Today and Chat live sidebar loaders write shared state.
    private static func loadPageData(for page: QuietPage, appModel: AppModel) async {
        guard page.item != .chat, page.item != .activity, page.item.normalized != .memories, page.item != .bots else { return }
        _ = await appModel.refreshForSidebarItem(page.item)
    }

    /// Await shared data, mount for view reads, then await those reads before drawing.
    /// An unmounted host has never displayed and cannot provide populated page content.
    private static func withPreparedHost<T>(
        for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize,
        _ body: (NSHostingView<AnyView>) -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await loadPageData(for: page, appModel: appModel)
        let renderedTab = tab ?? page.tab ?? SidebarItem.shellHome(for: page.item)?.tab
        if page.item.normalized == .memories, renderedTab == "knowledge" {
            // Offscreen graph views suppress live loaders; capture the canonical snapshot before mounting the canvas.
            _ = try await appModel.engine.trust.load()
            await appModel.engine.memory.loadGraph()
            await appModel.engine.memory.refreshDiagnostics()
        }
        try Task.checkCancellation()

        let hosting = NSHostingView(rootView: AnyView(
            pageView(for: page, tab: tab, appModel: appModel, size: size)
                // A capture is one moment, so nothing is captured mid-animation.
                .transaction { $0.animation = nil }
                // Draw controls as active so on and off remain distinguishable in the screenshot.
                .environment(\.appearsActive, true)
        ))
        hosting.frame = CGRect(origin: .zero, size: size)

        // A never-ordered window gives native controls window geometry without taking focus.
        let host = QuietCaptureWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        host.isReleasedWhenClosed = false
        host.contentView = hosting
        defer {
            host.contentView = nil
            host.close()
        }

        hosting.layoutSubtreeIfNeeded()
        // SwiftUI starts view tasks on the first display pass; display once before waiting.
        if let warmUp = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: warmUp)
        }
        try await settle(hosting)
        try Task.checkCancellation()
        let result = body(hosting)
        try Task.checkCancellation()
        return result
    }

    /// Suspend so main-actor loads can run; require several idle turns because tasks may not have started.
    private static func settle(_ hosting: NSHostingView<AnyView>) async throws {
        let deadline = Date().addingTimeInterval(loadBudget)
        var idleTurns = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            hosting.layoutSubtreeIfNeeded()
            idleTurns = QuietReadLoads.inFlight == 0 ? idleTurns + 1 : 0
            if idleTurns >= 6 { break }
        }
        // Display once after loading so the bitmap includes the resulting state.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    /// Answer as key for control accents without ordering the window in or taking focus.
    private final class QuietCaptureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    // MARK: - Picture

    /// Offscreen rendering needs no screen grant and cannot capture another app.
    static func pageImagePNG(
        for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize
    ) async throws -> (data: Data, width: Int, height: Int)? {
        try Task.checkCancellation()
        guard size.width.isFinite, size.height.isFinite,
              let width = Int(exactly: size.width.rounded(.down)), width > 0,
              let height = Int(exactly: size.height.rounded(.down)), height > 0 else { return nil }
        return try await withPreparedHost(for: page, tab: tab, appModel: appModel, size: size) { hosting in
            // 1x: a retina page doubles the bytes for detail a model does not read.
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            bitmap.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
        }
    }

}

// MARK: - The page in words, from the page's own data

/// Reuse page records and formatters without creating another SwiftUI tree.
extension QuietSelfAdminRender {
    static func pageRead(for page: QuietPage, appModel: AppModel, turn: Turn? = nil) async -> [JSONValue] {
        await loadPageData(for: page, appModel: appModel)
        // Load only shared state not already supplied by rail or projection reads.
        if page.tab == "iphone" {
            appModel.engine.sync.observeStatus()
            await appModel.engine.sync.loadSecret(quiet: true)
        } else if page.item == .telegram {
            await appModel.refreshTelegram()
        }
        var projection = await pageProjection(for: page, appModel: appModel, turn: turn)
        if let failure = appModel.engine.layout.availability.failure {
            projection.insert(layoutIssue(failure), at: 0)
        }
        if appModel.engine.pages.snapshots[page.id] == nil {
            switch page.item.normalized {
            case .trust, .personality:
                let item=page.item.normalized
                let caption=await appModel.engine.transcripts.presentation.prepareSnapshot("page:"+item.rawValue,
                    input:.object(["kind":.string("page"),"page":.string(item.rawValue)]))
                if caption.status == .ready, let text=caption.face?.sections.first?.rows.first?.title {
                    projection.insert(section("About",[text]),at:0)
                } else { projection.insert(section("Page caption unavailable",[caption.error?.message ?? caption.status.rawValue]),at:0) }
            default: break
            }
        }
        return await RuntimeReadouts.quietPageContext(
            projection, pageID: page.id,
            model: appModel.chatModel, providerID: appModel.chatProvider,
            dataRoot: appModel.engine.dataRoot, providers: appModel.engine.providers, turn: turn)
    }

    static func pageProjection(for page: QuietPage, appModel: AppModel, turn: Turn?) async -> [JSONValue] {
        if page.id == "today" {
            await appModel.engine.today.refresh(appModel.engine, activeSessionID: appModel.activeChatSessionId)
        }
        await appModel.engine.pages.refresh(page: page.id)
        if let snapshot = appModel.engine.pages.snapshots[page.id] {
            guard snapshot.status == .ready, let face = snapshot.face else {
                return [section(page.title, [snapshot.error?.message ?? (page.title + " " + snapshot.status.rawValue + ".")])]
            }
            return face.text(door: true).components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { block in
                var lines = block.components(separatedBy: "\n")
                var heading = page.title
                if let first = lines.first, first == face.title || first.hasSuffix(":") {
                    heading = first.hasSuffix(":") ? String(first.dropLast()) : first
                    lines.removeFirst()
                }
                return section(heading, lines)
            }
        }
        if page.id == "inbox" { return [section(page.title, ["Inbox has not published a face."])] }
        if page.id == "today" { return [section(page.title, ["Today has not published a face."])] }
        if page.id == "trust" { return [section(page.title, ["Trust has not published a face."])] }
        if page.id == "personality" { return [section(page.title, ["Personality has not published a face."])] }
        if let content = RuntimeReadouts.quietVirtualPage(
            page.value, turn: turn) { return content }
        if let service = RuntimeReadouts.quietServicePages[page.id] {
            return await RuntimeReadouts.quietService(
                page.value, service,
                connectors: appModel.engine.connectors,
                macIntegration: appModel.engine.macIntegration, statusText: { $0.connectionStatusText }, turn: turn)
        }
        switch page.item {
        case .chat: return await chatProjection(appModel: appModel, turn: turn)
        case .inboxPolicy: return RuntimeReadouts.quietNotifications(appModel.engine.inbox)
        case .tools: return toolsProjection(appModel: appModel)
        case .connectors where page.tab == "iphone": return await RuntimeReadouts.quietPairing(appModel.engine.sync, dataRoot: appModel.engine.dataRoot)
        case .connectors where page.tab == "agents": return await RuntimeReadouts.quietAgents(appModel.engine.contacts)
        case .telegram: return RuntimeReadouts.quietTelegram(appModel.engine.telegram)
        case .macIntegration: return await RuntimeReadouts.quietMacIntegration(
            connectors: appModel.engine.connectors, macIntegration: appModel.engine.macIntegration,
            statusText: { $0.connectionStatusText }, turn: turn)
        default: return []
        }
    }

    private static let section = RuntimeReadouts.quietPageSection

    private static let countLine = RuntimeReadouts.quietCountLine

    // MARK: Chat

    /// Include transcript folds and cards that the offscreen accessibility tree cannot expose.
    private static func chatProjection(appModel: AppModel, turn: Turn?) async -> [JSONValue] {
        let sessionID = appModel.activeChatSessionId
        guard !sessionID.isEmpty else {
            return [section("Chat", ["No conversation is open.", MoodTintReadout.line()])]
        }
        let messages = appModel.engine.transcripts.messages(for: sessionID)
        await appModel.engine.transcripts.prepareGroups(for: sessionID)
        let groups = appModel.engine.transcripts.groups(for: sessionID)
        var sections: [JSONValue] = [section("Chat", [
            "Conversation: \(sessionID)",
            countLine(messages.count, "message", "messages") + " loaded.",
            MoodTintReadout.line(),
        ])]

        // Read mounted state so projections agree with composer verbs.
        let composer = await QuietComposerCommands.state(appModel: appModel, turn: turn)
        func line(_ label: String, _ key: String) -> String? {
            switch composer[key] {
            case .string(let value): return "\(label): \(value)"
            case .int(let value): return "\(label): \(value)"
            case .bool(let value): return "\(label): \(value ? "on" : "off")"
            default: return nil
            }
        }
        let shell = QuietSelfAdmin.shared.composerCards
        let paneRows: [String] = shell.map { live in
            live.activePane != nil
                ? [live.paneReadLine] + live.rows.map {
                    $0.isSelected ? "\($0.label) — selected" : $0.label
                }
                : []
        } ?? []
        sections.append(section("Composer", [
            line("Draft", "draft") ?? "Draft: (empty)",
            line("Model", "model_word") ?? "",
            line("Thinking", "think_word") ?? "",
            line("Trust", "trust_word") ?? "",
            line("Context used", "ring_percent").map { $0 + "%" } ?? "Context used: unknown",
            line("Context measurement", "context_measurement_source") ?? "Context measurement: unknown",
            line("Open pane", "open_card") ?? "",
            "The chat.* actions work this row in process.",
        ].filter { !$0.isEmpty } + paneRows))

        var foldLines: [String] = []
        for group in groups where group.isToolGroup {
            foldLines.append(await appModel.engine.transcripts.prepareToolFold(group.messages))
        }
        if !foldLines.isEmpty {
            sections.append(section("Tool folds", foldLines))
        }

        do {
            let read = try await appModel.engine.transcripts.loadTranscript(sessionId: sessionID)
            sections += RuntimeReadouts.quietChatCards(read)
        } catch {
            sections.append(RuntimeReadouts.quietPageIssue("Cards", reason: "chat_cards_unavailable",
                detail: error.localizedDescription,
                instruction: "Resolve the reported conversation read problem without deleting its history, then reload Chat.",
                next: ["page": .string("chat")], error: error))
        }
        return sections
    }



    private static func layoutIssue(_ failure: SurfaceLayoutFailure) -> JSONValue {
        RuntimeReadouts.quietPageIssue("Layout unavailable", reason: "invalid_file",
            detail: failure.localizedDescription, instruction: failure.instruction)
    }

    // MARK: The rest

    private static func toolsProjection(appModel: AppModel) -> [JSONValue] {
        let tools = appModel.engine.tools
        let state = ChatToolCatalogPresentation.catalogState(catalog: tools.catalog,
            authored: tools.authored,
            loadFailed: tools.catalogLoadError != nil, loadError: tools.catalogLoadError)
        var sections: [JSONValue] = []
        switch state {
        case .loading:
            sections.append(section("Tools", ["Loading the tools…"]))
        case .empty:
            sections.append(section("Tools", ["The tool list loaded, but there were no tools in it."]))
        case .unavailable:
            sections.append(RuntimeReadouts.quietPageIssue("Tools", reason: "tool_catalog_unavailable",
                detail: tools.catalogLoadError ?? "No tool catalog loaded. Use Refresh to load it.",
                instruction: "Resolve the reported catalog read problem, then read Tools to reload it.",
                next: ["page": .string("tools")]))
        case let .available(catalog, buckets), let .stale(catalog, buckets, _):
            if case .stale(_, _, let detail) = state {
                sections.append(RuntimeReadouts.quietPageIssue("Tools", reason: "tool_catalog_stale",
                    detail: detail ?? "The catalog could not refresh; these are the last loaded tools.",
                    instruction: "Resolve the reported catalog read problem, then read Tools to reload it.",
                    next: ["page": .string("tools")], status: "stale"))
            }
            sections += buckets.buckets.map { bucket in
                section(bucket.title, bucket.tools.map {
                    "\($0.name): \(catalog.status(for: $0).title) · \($0.description)"
                })
            }
            sections.append(section("Mac access", [catalog.builderModeDetail]
                + catalog.builderAvailable + catalog.macAppAvailable))
        }
        do {
            if case .object(let list) = try Parts(root: tools.dataRoot).list() {
                sections.append(.object(list.merging(["heading": .string("Abilities")]) { _, new in new }))
            }
        } catch { sections.append(RuntimeReadouts.quietPageIssue("Abilities", reason: "ability_list_unavailable",
            detail: error.localizedDescription, instruction: "Ask the person to repair the reported ability-store defect, then read Tools again.",
            next: ["page": .string("tools")])) }
        return sections
    }



}

@MainActor
final class QuietSelfAdmin {
    static let shared = QuietSelfAdmin()

    /// Drafts belong to AppModel by session, not to this projection.
    private weak var cards: ComposerShellState?

    private init() {}

    func attach(cards: ComposerShellState) {
        self.cards = cards
    }

    func detachComposer(cards candidate: ComposerShellState) {
        guard cards === candidate else { return }
        cards = nil
    }

    var composerCards: ComposerShellState? { cards }

}

// MARK: - Pages

struct QuietPage: Sendable, Equatable {
    let value: QuietToolPage
    var id: String { value.id }
    var title: String { value.title }
    var summary: String { value.summary }
    var item: SidebarItem {
        switch id {
        case "chat", "simple", "simple_settings_menu": .chat
        case "today", "inbox": .activity
        case "memories": .memories
        case "desk": .desk
        case "notifications": .inboxPolicy
        case "bots": .bots
        case "personality": .personality
        case "providers": .providers
        case "trust", "files", "shell", "web", "browser", "mac": .trust
        case "connectors", "pairing", "agents", "slack": .connectors
        case "telegram": .telegram
        case "mac_integration", "mail", "calendar", "reminders", "notes", "contacts", "messages", "music": .macIntegration
        case "capabilities": .capabilities
        case "diagnostics": .diagnostics
        case "skills": .skills
        case "tools": .tools
        case "settings": .settings
        default: preconditionFailure("The page has no rail route")
        }
    }
    var tab: String? {
        switch id {
        case "pairing": "iphone"
        case "agents": "agents"
        case "slack": "connectors"
        case "skills": "skills"
        case "tools": "tools"
        default: nil
        }
    }
}

enum QuietPages {
    static let all = QuietToolPage.all.map(QuietPage.init)
    static var ids: [String] { QuietToolPage.ids }
    static let drawOnly: [QuietPage] = [
        QuietPage(value: QuietToolPage(id: "simple", title: "Simple view",
                  summary: "The Simple shell: the sidebar with its pinned person row, and the chat.")),
        QuietPage(value: QuietToolPage(id: "simple_settings_menu", title: "Simple view settings menu",
                  summary: "The Simple shell with the person row's settings menu drawn open.")),
    ]
    static func page(named raw: String) -> QuietPage? {
        if AppDoorNames.resolve(raw) == "inbox" { return QuietPage(value: .inbox) }
        return QuietToolPage.page(named: raw).map(QuietPage.init)
    }
}

@MainActor struct AppQuietToolPresentation: QuietToolPresentationPort {
    /// Shipped pages exist independently of their presentation in the layout.
    var pages: [QuietToolPage] {
        get throws {
            guard ApplicationLifetime.shared.appModel != nil else {
                throw ToolFailureError("The app presentation has not attached.", effects: .none, code: "app_unattached")
            }
            return RuntimeReadouts.quietPages()
        }
    }
    var currentPage: QuietToolPage? { ApplicationLifetime.shared.currentPage.map(\.value) }
    var visiblePageInput: [String: JSONValue]? { ApplicationLifetime.shared.visiblePageInput }
    func page(named raw: String) -> QuietToolPage? { QuietPages.page(named: raw)?.value }
    /// Read a conversation's context receipt through the popover owner without requiring it to be open.
    /// With no session, use the conversation on screen.
    @MainActor
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.contextReceiptRead(input: input, activeSessionID: appModel.activeChatSessionId) { sessionID in
            let state = await ContextReceipts.read(sessionId: sessionID, selectedModel: appModel.chatModel, dataRoot: appModel.engine.dataRoot)
            return ComposerContextReceiptPresentation.lines(state)
        }
    }

    /// Read Agent-view text without marking seen, writing or running a tool.
    /// With no room, list tabs; with no session, use the conversation on screen.
    @MainActor
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        let layout = appModel.engine.layout.availability
        let result = await AppToolExecutor.agentViewRead(input: input, rooms: AgentScreenPreview.tabs(layout, profile: SimpleViewMode.agent),
                                                   activeSessionID: appModel.activeChatSessionId) { room, scope in
            await appModel.engine.turns.readAgentScreen(room: room, scope: scope)
        }
        if let failure = layout.failure, case .object(var fields) = result {
            fields["layout_issue"] = SurfaceLayoutStore.failureResult(failure)
            return .object(fields)
        }
        return result
    }

    // MARK: - page.screenshot

    @MainActor
    func pageScreenshot(input: [String: JSONValue], imageSink: LocalToolImage.Sink?) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        let requested = Self.text(input["page"])
        let resolved = AppDoorNames.resolve(requested)
        let target = resolved == "current" ? ApplicationLifetime.shared.currentPage
            : QuietPages.page(named: resolved) ?? QuietPages.drawOnly.first(where: { $0.id == resolved })
        guard let page = target else {
            return AppToolExecutor.failure(resolved == "current" ? "app_window_unavailable" : "unknown_page",
                resolved == "current" ? "No app window is showing a page right now; name the page instead of current." : "No page is called that.",
                extra: ["requested": .string(requested), "pages": .array(QuietPages.ids.map(JSONValue.string)),
                    "remedy": Repair.remedy(owner: "page.screenshot", nextCall: .object([
                        "tool": .string("app"), "input": .object([:])]), tap: nil,
                        instruction: "Read home, then choose a named page for page.screenshot.")])
        }
        // Reuse page.show tab keys so screenshots select the same rail tab.
        let tabKey = Self.text(input["tab"]).lowercased()
        let railPage = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
        var tab: String?
        if !tabKey.isEmpty {
            guard let home = QuietComposerCommands.tabs[tabKey], home.page == railPage else {
                let keys = QuietComposerCommands.tabs.filter { $0.value.page == railPage }.keys.sorted()
                return AppToolExecutor.failure("unknown_tab", "This page has no tab called that.",
                    extra: ["requested": .string(tabKey), "tabs": .array(keys.map { .string($0) }),
                        "remedy": Repair.remedy(owner: "page.screenshot", nextCall: .object([
                            "tool": .string("app"), "input": .object(["action": .string("page.screenshot"),
                                "args": .object(["page": .string(page.id)])])]), tap: nil,
                            instruction: "Omit tab for the page's default tab, or choose a key from tabs.")])
            }
            tab = home.tab
        }
        var size = QuietSelfAdminRender.defaultSize
        if let requestedHeight = input["height"] {
            let height: Double?
            switch requestedHeight {
            case .int(let value): height = Double(value)
            case .double(let value): height = value
            case .string(let value): height = Double(value)
            default: height = nil
            }
            guard let height, height.isFinite else {
                return AppToolExecutor.failure("invalid_height", "Screenshot height must be a finite number.")
            }
            size.height = min(max(CGFloat(height), 400), 2400)
        }
        let image: (data: Data, width: Int, height: Int)?
        do { image = try await QuietSelfAdminRender.pageImagePNG(for: page, tab: tab, appModel: appModel, size: size) }
        catch is CancellationError {
            return AppToolExecutor.failure("cancelled", "Page screenshot was cancelled; no image was produced.")
        } catch {
            return AppToolExecutor.failure("render_failed", error.localizedDescription)
        }
        guard let rendered = image else {
            return AppToolExecutor.failure("render_failed", "Offscreen bitmap allocation or PNG encoding failed.",
                extra: ["page": .string(page.id), "tab": .string(tabKey),
                    "remedy": Repair.remedy(owner: "page.screenshot", nextCall: .object([
                        "tool": .string("app"), "input": .object(["page": .string(page.id)])]), tap: nil,
                        instruction: "Inspect the page data through next_call to diagnose the render failure.")])
        }
        return AppToolExecutor.pageScreenshotResult(
            page: page.value, tabKey: tabKey,
            dataRoot: appModel.engine.dataRoot, rendered: rendered, imageSink: imageSink)
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
