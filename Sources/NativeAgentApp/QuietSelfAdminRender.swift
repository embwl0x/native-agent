import AppToolRuntime
import AppKit
import ChatOrchestration
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Desk
// The page projection reads the same stores the pages read: the bots shelf's
// run queue (StandingBots) and the Providers group table (ProviderRouting).
import ProviderRouting
import StandingBots
import SwiftUI
import MacIntegration
import MemoryV2
import Studio
import ToolRegistry
import PersonaEngine

/// Only screenshots mount an offscreen copy of a page. Text reads load owner
/// state directly. The screenshot's unordered host never touches the visible
/// window; this flag suppresses lifecycle writes while allowing read-only
/// `quietReadTask` loads to finish before capture.
private struct QuietOffscreenReadKey: EnvironmentKey {
    static let defaultValue = false
}

/// The tab a screenshot asked for. A tabbed page's offscreen copy draws it, or
/// its first (default) tab when nil — never the tab User last left open.
private struct QuietRailTabKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var quietOffscreenRead: Bool {
        get { self[QuietOffscreenReadKey.self] }
        set { self[QuietOffscreenReadKey.self] = newValue }
    }

    var quietRailTab: String? {
        get { self[QuietRailTabKey.self] }
        set { self[QuietRailTabKey.self] = newValue }
    }
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
    /// `.task`, except that it does not run for an offscreen screenshot.
    /// Use it wherever appearing starts work or writes state.
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

    /// `.onAppear`, except that it does not run for an offscreen screenshot.
    func liveOnAppear(_ action: @escaping () -> Void) -> some View {
        modifier(LiveAppearModifier(action: action))
    }

    /// A page load that ONLY READS.
    ///
    /// `liveTask` keeps a quiet read from writing anything; on its own it also
    /// left the offscreen copy with no content, which is not a read of the page
    /// at all — `app_page_screenshot(page: providers)` came back as the word
    /// "Providers" on an empty field. A load that fetches and assigns to the
    /// page's own state is not the lifecycle work `liveTask` exists to stop, so
    /// it runs for the offscreen copy too, and is COUNTED
    /// (`QuietReadLoads`) so the renderer can wait for it before it draws.
    ///
    /// Only for work that reads. Anything that writes a file, clears a badge,
    /// or asks macOS for a permission stays on `liveTask`.
    ///
    /// `live: false` is for a page whose visible copy already loads by another
    /// route — a file watcher that emits an initial event — so the page the
    /// person opened does not load twice.
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

/// How many read-only loads the offscreen copy still has in flight.
///
/// Only the offscreen copy counts. A refresh running on the page the person is
/// looking at is none of a quiet read's business, and counting it would make a
/// quiet read wait on a poll that never ends.
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
    /// Big enough that a page's real layout (two columns, a wide table) is what
    /// gets measured, small enough that one PNG stays well inside the eight-MiB
    /// tool-image ceiling.
    static let defaultSize = CGSize(width: 1280, height: 860)

    // MARK: - The page, built offscreen

    /// `tab` is a tab key of the page's rail page (`ShellTabbedPage`); nil
    /// draws the page's own tab, or the rail page's default.
    @ViewBuilder
    static func pageView(for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize) -> some View {
        // A page that is a tab now (Mac integration, Telegram, MCP, iPhone,
        // Agents) is drawn on its rail page with that tab open, as the
        // window shows it: frame, title and tab row included.
        let home = SidebarItem.shellHome(for: page.item)
        Group {
            if QuietPages.drawOnly.contains(page) {
                SimpleShellView()
                    .environment(\.simpleSettingsMenuDrawnOpen, page.id == "simple_settings_menu")
            } else {
            switch home?.parent ?? page.item {
            case .chat: ChatView()
            case .activity: TodayView()
            case .memories: MemoriesRailPage()
            case .desk: DeskPageView()
            case .inboxPolicy: ShellRailPage(title: "Notifications", alive: true) { InboxSettingsView() }
            case .bots: BotsShelfPreviewPage()
            case .personality: PersonalityRailPage()
            case .providers: ShellRailPage(title: "Providers", subtitle: SidebarItem.providers.shellPageSubtitle, alive: true) { ProviderSettingsView() }
            case .trust: TrustRailPage()
            case .connectors: ConnectorsRailPage()
            case .capabilities: CapabilitiesRailPage()
            case .diagnostics: DiagnosticsRailPage()
            case .settings: SetupView()
            default: EmptyView()
            }
            }
        }
        .environment(\.quietRailTab, tab ?? page.tab ?? home?.tab)
        .environment(appModel)
        // Nobody opened this page. Lifecycle work stays asleep (`liveTask` /
        // `liveOnAppear`), so a read cannot change what the page reports.
        .environment(\.quietOffscreenRead, true)
        .frame(width: size.width, height: size.height)
        // The room, drawn HERE and nowhere else in a quiet read.
        //
        // On the glass the ground is the window's job (`ShellFrame` draws
        // `ShellSheet`; `ShellRoomBackdrop` is deliberately `Color.clear` so a
        // page never draws a second plate). The offscreen host has no
        // ShellFrame, so the page had NO ground: every material resolved
        // against nothing and the Providers title came back all but invisible
        // on the capture while reading fine on screen. An opaque room ground
        // behind the copy is the same colour the sheet resolves to, and it is
        // behind the page, so nothing the page draws moves.
        .background(NativeAgentShell.room.ignoresSafeArea())
    }

    // MARK: - Giving the offscreen copy its content

    /// Longest a screenshot waits for a page's own read-only loads. A page
    /// whose fetches are slower than this is drawn as far as it got, which is
    /// still the page, rather than holding the tool call open.
    static let loadBudget: TimeInterval = 4

    /// The data the page draws from, loaded before the copy is even built.
    ///
    /// This is the rail's own loader — the call `TodayView` and the Connectors
    /// tab make when a person opens the page — and it only fetches and
    /// assigns: no file is written and no badge is cleared. Chat is the
    /// exception and is deliberately absent: its branch runs `loadChatState`,
    /// which writes shared session state, and a read must not do that.
    private static func loadPageData(for page: QuietPage, appModel: AppModel) async {
        guard page.item != .chat else { return }
        _ = await appModel.refreshForSidebarItem(page.item)
    }

    /// Mount the page offscreen, let it load, and lay it out — then draw.
    ///
    /// The order is the whole fix. The data the page reads from `AppModel` is
    /// loaded first and awaited; the copy is then mounted in an unordered host
    /// so its own read-only loads (`quietReadTask`) start; the run loop is
    /// given turns until those loads finish or the budget runs out; and only
    /// then is the bitmap taken. Previously the capture came from a host
    /// that had never been through a display pass, which is why a
    /// screenshot came back as a title on an empty page.
    private static func withPreparedHost<T>(
        for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize,
        _ body: (NSHostingView<AnyView>) -> T
    ) async -> T {
        await loadPageData(for: page, appModel: appModel)

        let hosting = NSHostingView(rootView: AnyView(
            pageView(for: page, tab: tab, appModel: appModel, size: size)
                // A capture is one moment, so nothing is captured mid-animation.
                .transaction { $0.animation = nil }
                // Drawn as the front window would be: an inactive switch is a
                // grey track, so on and off read alike in the picture.
                .environment(\.appearsActive, true)
        ))
        hosting.frame = CGRect(origin: .zero, size: size)

        // An unordered window. NSHostingView resolves accessibility and native
        // scroll geometry against a window; this one is created, used, and
        // released without ever being ordered in, made key, or given a level —
        // so it exists for AppKit and for nobody else.
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
        // SwiftUI starts a view's `.task` work on its first display pass, so
        // one has to happen before there is anything to wait for.
        if let warmUp = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: warmUp)
        }
        await settle(hosting)
        return body(hosting)
    }

    /// Turn the run loop until the page's read-only loads are done.
    ///
    /// Suspending (rather than nesting a run loop) is what lets those loads —
    /// which are main-actor async work — actually run. `idleTurns` guards the
    /// start: the counter reads zero for the first turns simply because the
    /// tasks have not begun yet, so a run of clear turns is what counts as
    /// finished, never the first reading.
    private static func settle(_ hosting: NSHostingView<AnyView>) async {
        let deadline = Date().addingTimeInterval(loadBudget)
        var idleTurns = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            hosting.layoutSubtreeIfNeeded()
            idleTurns = QuietReadLoads.inFlight == 0 ? idleTurns + 1 : 0
            if idleTurns >= 6 { break }
        }
        // The loads landed; give their state one more layout and display pass
        // so the bitmap is of a page that has actually drawn.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    /// Native controls draw their accent only in the key window. This one is
    /// never ordered in or made key; it only answers as if it were, so a
    /// capture shows an on switch as on. Nothing takes focus.
    private final class QuietCaptureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    // MARK: - Picture

    /// A PNG of the page, drawn by SwiftUI into a bitmap through the offscreen
    /// host. It does not read the screen, so it needs no screen-recording
    /// grant, works while the app is behind other apps, and cannot capture
    /// anything that is not ours.
    static func pageImagePNG(
        for page: QuietPage, tab: String? = nil, appModel: AppModel, size: CGSize = defaultSize
    ) async -> (data: Data, width: Int, height: Int)? {
        await withPreparedHost(for: page, tab: tab, appModel: appModel, size: size) { hosting in
            // 1x: a retina page doubles the bytes for detail a model does not read.
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            bitmap.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
        }
    }

    private static func bounded(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > 200 else { return collapsed }
        return String(collapsed.prefix(199)) + "\u{2026}"
    }
}

// MARK: - The page in words, from the page's own data

/// The same records and formatters the pages draw, without creating a second
/// SwiftUI tree.
extension QuietSelfAdminRender {
    static func pageRead(for page: QuietPage, appModel: AppModel) async -> [JSONValue] {
        await loadPageData(for: page, appModel: appModel)
        // These page tasks load shared owner state in addition to the rail's
        // refresh. Other view tasks only populate local presentation state or
        // repeat reads the rail/projection already performs.
        if page.tab == "iphone" {
            appModel.engine.sync.observeStatus()
            await appModel.engine.sync.loadSecret(quiet: true)
        } else if page.item == .telegram {
            await appModel.refreshTelegram()
        }
        var content = await pageProjection(for: page, appModel: appModel)
        if ["settings", "providers"].contains(page.id) {
            let turn = ChatTurnRuntimeContext.current
            let context = ChatSessionAutocompactionConfig.productionDefault().contextWindowReadout(
                forModel: turn?.model ?? appModel.chatModel, providerID: turn?.providerID ?? appModel.chatProvider,
                dataRoot: dataRoot(appModel))
            if case .string(let summary)? = context["summary"] { content.append(section("Context window", [summary])) }
        }
        let surfaces: [String] = switch page.id {
        case "chat": ["chat", "compaction"]
        case "memories": ["memory"]
        case "desk": ["desk", "workshop", "swarms"]
        case "diagnostics": ["diagnostics", "cognition_reflection", "training"]
        case "settings": ["dream", "rem", "self_improvement", "studio_wander", "heartbeat", "autonomy"]
        case "pairing": ["ios"]
        case "telegram": ["telegram"]
        case "slack": ["slack"]
        default: []
        }
        if !surfaces.isEmpty {
            do {
                let routing = try await appModel.engine.providers.routing.checkedRoutingSnapshotReadOnly()
                let members = ProviderSurfaceGroups.all.flatMap(\.members).filter { surfaces.contains($0.surface) }
                content.append(section("Models", modelLines(members, routing: routing)))
            } catch { content.append(section("Models", ["Models could not be read: \(error.localizedDescription)"])) }
        }
        return content
    }

    /// One section of the projection: a heading and the lines under it.
    private static func section(_ heading: String, _ lines: [String]) -> JSONValue {
        .object([
            "heading": .string(heading),
            "lines": .array(lines.map { .string(bounded($0)) }),
        ])
    }

    private static func proposalLine(_ proposal: ProposalRecord) -> String {
        proposal.content
    }

    private static func countLine(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }

    /// The page, in the words of the records it draws from.
    static func pageProjection(for page: QuietPage, appModel: AppModel) async -> [JSONValue] {
        if let read = virtualPageReads[page.id] {
            let registered = AppActions.on(page: page.id).filter { $0.page == page.id }.map(\.id)
            return [section(page.title, [page.summary, read,
                "This version covers this page's guidance and registered actions, not a file, command, tab, URL or screen."]),
                section("Registered actions", registered)]
        }
        if let service = servicePages[page.id] { return await serviceProjection(page, service, appModel: appModel) }
        switch page.item {
        case .chat: return await chatProjection(appModel: appModel)
        case .bots: return await botsProjection(appModel: appModel)
        case .activity: return await todayProjection(appModel: appModel)
        case .providers: return await providersProjection(appModel: appModel)
        case .trust: return trustProjection(appModel: appModel)
        case .memories: return memoriesProjection(appModel: appModel)
        case .desk: return await deskProjection(appModel: appModel)
        case .inboxPolicy: return notificationsProjection(appModel: appModel)
        case .diagnostics: return await diagnosticsProjection(appModel: appModel)
        case .tools: return toolsProjection(appModel: appModel)
        case .capabilities: return capabilitiesProjection(appModel: appModel)
        case .connectors where page.tab == "iphone": return pairingProjection(appModel: appModel)
        case .connectors where page.tab == "agents": return agentsProjection(appModel: appModel)
        case .connectors: return connectorsProjection(appModel: appModel)
        case .telegram: return telegramProjection(appModel: appModel)
        case .mcp: return mcpProjection(appModel: appModel)
        case .macIntegration:
            return [section("Mac Integration", [
                "Each app's access is a setting below (off, read, write, read_write). Under Full Mac an app "
                + "left untouched is allowed anyway; one set off here stays off.",
            ])]
        case .personality: return await personalityProjection(appModel: appModel)
        case .settings: return settingsProjection(appModel: appModel)
        default: return []
        }
    }

    private static let virtualPageReads = [
        "files": "Read a folder with files.list {path}; read a file with files.read {path}. File and folder results carry their own versions and next arguments.",
        "shell": "Read repository state with git.status {path}. Run commands with shell.run; a page read runs no command.",
        "web": "Read a URL with web.read {url}; discover web.search with find. A page read fetches no URL and performs no search.",
        "browser": "Read current browser state with browser.status, then read a tab with the browser or Chrome actions. A page read opens no tab.",
        "mac": "Read the current screen with mac.look, or a document with mac.read. A page read captures no screen and moves no control.",
        "markets": "Market research uses native routes. Read market.status for configured data sources; use market.watchlists, market.quote or market.tradingview for their results.",
    ]

    private static func dataRoot(_ appModel: AppModel) -> URL {
        appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    // MARK: Chat

    /// The two things on the chat page that the accessibility tree cannot
    /// say, said here instead.
    ///
    /// Both are deliberate AX silences. An inline card renders OFFSCREEN (the
    /// transcript scrolls, and the quiet copy is never scrolled), and the
    /// collapsed tool fold is `.accessibilityElement(children: .contain)` — a
    /// single element wearing one label. Fighting either from the tree side is
    /// a losing game and always was; the projection reads the same two records
    /// the views read, so what Agent reads is what the person sees.
    ///
    ///  * Every inline card in the open conversation, exactly as
    ///    `InlineCardProjection` hands it to the card view — title, why, the
    ///    scope lines, both action labels, state, and the interaction id that
    ///    `interaction_act` takes.
    ///  * Every collapsed tool fold, by the same `ChatShellToolSummary`
    ///    headline `ShellToolRow` prints when it is closed.
    private static func chatProjection(appModel: AppModel) async -> [JSONValue] {
        let sessionID = appModel.activeChatSessionId
        guard !sessionID.isEmpty else {
            return [section("Chat", ["No conversation is open.", MoodTintProjection.line()])]
        }
        let root = dataRoot(appModel)
        let messages = appModel.engine.transcripts.messages(for: sessionID)
        let groups = MessageGrouper.groups(
            for: messages,
            sessionId: sessionID,
            structureVersion: appModel.engine.transcripts.structureVersion
        )
        var sections: [JSONValue] = [section("Chat", [
            "Conversation: \(sessionID)",
            countLine(messages.count, "message", "messages") + " loaded.",
            // Mood in the tint: the level the glass is actually wearing, so it
            // can be read and driven headless.
            MoodTintProjection.line(),
        ])]

        // The composer, from the SAME live objects the verbs write, so a
        // set_draft or a set_model is on this page the moment it lands rather
        // than at the next thing that happens to reload.
        let composer = await QuietComposerVerbs.state(appModel: appModel)
        func line(_ label: String, _ key: String) -> String? {
            switch composer[key] {
            case .string(let value): return "\(label): \(value)"
            case .int(let value): return "\(label): \(value)"
            case .bool(let value): return "\(label): \(value ? "on" : "off")"
            default: return nil
            }
        }
        // ONE section. The shell is one surface with one active pane, so the
        // open pane and the rows it is showing belong under the same heading
        // as the words they were opened from — never a second "Composer".
        let shell = QuietSelfAdmin.shared.composerCards
        let paneRows: [String] = shell.map { live in
            live.activePane.isOpen
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
            line("Open pane", "open_card") ?? "",
            "The chat.* actions work this row in process.",
        ].filter { !$0.isEmpty } + paneRows))

        // The folds, in transcript order, by the row the fold stands on.
        var foldLines: [String] = []
        for group in groups where group.isToolGroup {
            // Same three-way rule the glass uses: a raised card is a question,
            // not a failure, pending or answered (2026-09-14).
            let statuses = group.messages.map {
                ChatShellToolSummary.status(
                    kind: $0.metadata?.kind,
                    ok: $0.metadata?.ok,
                    resultSummary: $0.metadata?.resultSummary,
                    resultStatus: $0.metadata?.resultStatus,
                    interactionState: $0.metadata?.interactionState
                )
            }
            foldLines.append(
                ChatShellToolSummary.headline(
                    count: group.messages.count,
                    failed: statuses.filter { $0 == .failed }.count,
                    needsYou: statuses.filter { $0 == .needsYou }.count
                )
            )
        }
        if !foldLines.isEmpty {
            sections.append(section("Tool folds", foldLines))
        }

        // The cards. Read from the transcript, not from the binding: the quiet
        // copy has no binding of its own, and the transcript is the authority
        // the binding itself reads.
        // Through the SAME two read-side collapses the chat binding applies, so
        // a card that went quiet on the glass reads as quiet here too, and a
        // run of identical answered asks is one counted line in both places.
        // ONE FUNCTION WITH THE GLASS. The collapse and the count come out of
        // the same call the chat binding makes, so a card that went quiet on
        // the glass reads as quiet here, a run of identical answered asks is
        // one counted line in both places, and the HEADING here cannot drift
        // from the lines beneath it.
        let collapsed = InlineInteractionChatBinding.collapsedCards(
            await InlineInteractionResolver.interactionsByRow(
                sessionID: sessionID, dataRoot: root
            )
        )
        let pairs = collapsed.pairs
        guard !pairs.isEmpty else { return sections }
        sections.append(section(
            "Cards",
            [collapsed.heading
                + " in this conversation. card.answer answers one by its id."]
        ))
        for pair in pairs {
            let descriptor = InlineInteractionResolver.descriptor(
                for: pair.interaction, dataRoot: root
            )
            // The same live read as the glass: done elsewhere reads as done.
            let card = InlineCardProjection.model(
                await InlineInteractionResolver.liveProjection(pair.interaction, dataRoot: root),
                descriptor: descriptor,
                repeatCount: collapsed.counts[pair.interaction.id] ?? 1
            )
            // The glass does not draw a settled card as a card. It draws ONE
            // line — the receipt, the refusal, or "Asked earlier" — and only a
            // card still waiting on the person carries the reason, the scope
            // lines and the two buttons. A projection that gave every row the
            // full body told Agent there were six live questions in a
            // conversation that shows one (Agent, 2026-09-13). The interaction
            // id stays on every line: a quiet card is still addressable.
            switch card.state {
            case .superseded:
                // "Asked earlier" is the superseded line and ONLY the
                // superseded line: a newer identical ask took this one's
                // place, so there is nothing to answer here.
                sections.append(section(card.title, [
                    // Every other branch leads with the state; this one read as
                    // a bare "Asked earlier." with nothing saying what state
                    // that is (Agent, 2026-09-14).
                    "State: " + card.state.rawValue,
                    "Asked earlier — a newer copy of this ask took its place.",
                    "Interaction id: \(card.id)",
                    "On message: \(pair.rowID)",
                ]))
                continue
            case .unknown:
                // Terminal, but not because anybody answered it: this build
                // has no control for the thing. Say that, with the reason the
                // glass shows, instead of "asked earlier".
                var lines: [String] = ["State: unknown"]
                if let outcome = card.outcome { lines.append(outcome) }
                if let meta = card.outcomeMeta { lines.append(meta) }
                lines.append("Interaction id: \(card.id)")
                lines.append("On message: \(pair.rowID)")
                sections.append(section(card.title, lines))
                continue
            case .declined, .settled:
                var receipt: [String] = ["State: \(card.state.rawValue)"]
                if let outcome = card.outcome { receipt.append(outcome) }
                if let meta = card.outcomeMeta { receipt.append(meta) }
                receipt.append("Interaction id: \(card.id)")
                receipt.append("On message: \(pair.rowID)")
                sections.append(section(card.title, receipt))
                continue
            case .pending, .running, .failed:
                // A failure settled NOTHING — on the glass it keeps its card,
                // its explanation, its field and its "Try again" — so it is
                // projected with those too, not as a receipt.
                break
            }
            var lines: [String] = ["State: \(card.state.rawValue)"]
            if !card.why.isEmpty { lines.append("Why: \(card.why)") }
            lines.append(contentsOf: card.scopeLines)
            if card.state == .failed && !card.canRetry {
                // The one failure with nothing to offer: no control on this
                // build, so naming buttons that are not drawn would be a lie.
                lines.append("There is no control for this on this build, so it can't be answered here.")
            } else {
                lines.append("Do: \(card.state == .failed ? "Try again" : card.primaryLabel)")
                // Joined mid-sentence after a dash, so it takes the same
                // lowercased lead the settled decline line takes — "Not now —
                // Without Notion…" read as a new sentence beside "Not now —
                // without Notion…" (Agent, 2026-09-14).
                lines.append(
                    "Or: \(card.secondaryLabel) — "
                        + InlineInteraction.lowercasedLead(
                            card.consequence.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                )
            }
            if let note = card.persistenceNote { lines.append(note) }
            if let signIn = card.signInLabel { lines.append("Offers: \(signIn)") }
            for field in card.fields {
                lines.append(
                    "Takes: \(field.label)\(field.isSecret ? " (secret — the person types it into the card, never into chat)" : "")"
                )
            }
            for choice in card.choices {
                lines.append("Choice \(choice.id): \(choice.title)"
                    + (choice.note.map { " — \($0)" } ?? ""))
            }
            if let outcome = card.outcome { lines.append("Outcome: \(outcome)") }
            if let meta = card.outcomeMeta { lines.append(meta) }
            lines.append("Interaction id: \(card.id)")
            lines.append("On message: \(pair.rowID)")
            sections.append(section(card.title, lines))
        }
        return sections
    }

    // MARK: Bots

    /// Every bot on the shelf, by the same lines its card prints.
    ///
    /// The shelf is not in `AppModel` — `refreshForSidebarItem(.bots)` is a
    /// deliberate no-op and `BotsShelfView` loads its own `@State` — so this
    /// takes the view's own loader, `BotsShelfView.readRecords`, off the main
    /// actor exactly as `readShelfOnce` does. Read-only: the definition store,
    /// the shelf, the scheduler's dates and misses, the event log, the queue.
    private static func botsProjection(appModel: AppModel) async -> [JSONValue] {
        let root = dataRoot(appModel)
        let unattended = await BackgroundLoopsAssembly.unattendedWorkAllowed(dataRoot: root)
        let loaded = try? await Task.detached(priority: .userInitiated) {
            (records: try BotsShelfView.readRecords(root: root, unattended: unattended),
             runs: try BotRunQueue(dataRoot: root).activeAndQueuedIDs())
        }.value
        guard let loaded else {
            return [section("Helpers", ["The shelf could not be read."])]
        }
        var sections: [JSONValue] = []
        var header = [countLine(loaded.records.count, "helper", "helpers") + " on the shelf."]
        if !unattended { header.append(BotsShelfUnattended.pageLine) }
        sections.append(section("Helpers", header))
        for record in loaded.records {
            let state = BotState(record: record, running: loaded.runs.active.contains(record.id),
                                 queued: loaded.runs.queued.contains(record.id))
            var lines: [String] = ["State: \(state.word)"]
            let brief = record.definition.brief
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            if let brief { lines.append("Brief: \(brief)") }
            // "Sep 10 at 1:47 AM · Reply saved: …" — the dated first line of
            // what it last said, exactly as the card prints it.
            lines.append("Latest: \(record.lastOutcomeLine)")
            lines.append("Schedule: \(record.scheduleLine)")
            lines.append("Timing: \(record.timingLine)")
            lines.append("Runs on: \(record.choiceLine)")
            if let missed = record.missedLine { lines.append(missed) }
            if let wake = record.wakeLine { lines.append(wake) }
            if record.unread > 0 { lines.append(countLine(record.unread, "unread reply", "unread replies")) }
            lines.append(countLine(record.entries.count, "run recorded", "runs recorded"))
            sections.append(section(record.definition.name, lines))
        }
        return sections
    }

    // MARK: Today

    private static func todayProjection(appModel: AppModel) async -> [JSONValue] {
        let pending = appModel.engine.approvals.records.filter { $0.status.lowercased() == "pending" }
        let waitingNotes = appModel.engine.inbox.items.filter { $0.status == "unread" }
        let proposals = appModel.engine.memory.proposals
        var waiting: [String] = []
        waiting.append(countLine(pending.count, "approval waiting", "approvals waiting"))
        waiting.append(countLine(waitingNotes.count, "unread note", "unread notes"))
        waiting.append(countLine(proposals.count, "memory waiting to be reviewed", "memories waiting to be reviewed"))
        var sections = [section("Waiting on you", waiting)]
        switch await appModel.engine.cognitionView.pendingProposals() {
        case .available(let pending):
            sections.append(section("Proposed views", pending.standingViews.isEmpty ? ["None."]
                : pending.standingViews.map { "\($0.id): \($0.title)" }))
        case .unavailable(let reason): sections.append(section("Proposed views", [reason]))
        }
        if !pending.isEmpty {
            sections.append(section("Approvals", pending.prefix(12).map { "\($0.title) — \($0.action), risk \($0.risk)" }))
        }
        if !waitingNotes.isEmpty {
            sections.append(section("Notes", waitingNotes.prefix(12).map { "\($0.severity): \($0.title) — \($0.summary)" }))
        }
        if !proposals.isEmpty {
            sections.append(section("Memories waiting", proposals.prefix(12).map(proposalLine)))
        }
        return sections
    }

    // MARK: Providers

    private static func modelLines(_ members: [ProviderSurfaceMember], routing: ProviderRoutingSnapshot) -> [String] {
        members.map { member in
            if let issue = routing.unusablePickNotice(for: member.surface) { return "\(member.label): \(issue)" }
            let provider = routing.activeProviders[member.surface] ?? "same as Chat"
            guard let preference = routing.preferences[member.surface] else {
                return "\(member.label): \(provider) · no model pinned"
            }
            let fast = preference.serviceTier == "priority" ? "Fast on" : "Fast off"
            let think = preference.reasoningEffort.isEmpty ? "no thinking level" : "Think \(preference.reasoningEffort)"
            return "\(member.label): \(provider) · \(preference.model) · \(think) · \(fast)"
        }
    }

    /// The three groups, each with the model its whole group runs on, and the
    /// accounts that are connected. User, 2026-09-13: every surface in a group
    /// runs on the group's model, so the projection reads the group's rows.
    private static func providersProjection(appModel: AppModel) async -> [JSONValue] {
        let outcome = await ProviderSettingsRefreshAction.perform(appModel: appModel, refreshCatalog: false)
        guard case .loaded(let snapshot) = outcome else {
            if case .failed(let reason) = outcome {
                return [section("Providers", ["Providers could not be read: \(reason)"])]
            }
            return [section("Providers", ["Providers could not be read."])]
        }
        var sections: [JSONValue] = []
        for group in ProviderSurfaceGroups.all {
            sections.append(section(group.title, modelLines(group.members, routing: snapshot.routing)))
        }
        let accounts = snapshot.providers.map { info -> String in
            let mode = info.auth_mode.map { " via \($0)" } ?? ""
            let line = ProviderAccountStateLinePresentation.pageLine(state: info.auth_status.state,
                detail: info.auth_status.detail, failedTest: snapshot.failedTests[info.provider_id])
            return "\(info.display_name): \(line)\(mode)"
        }
        sections.append(section("Accounts", accounts.isEmpty ? ["No providers listed."] : accounts))
        return sections
    }

    // MARK: Trust

    private static func trustProjection(appModel: AppModel) -> [JSONValue] {
        guard let policy = appModel.engine.trust.policy else {
            return [section("Trust", ["No Trust policy has loaded."])]
        }
        let mode = AppModel.agentAccessMode(from: policy)
        let preset = TrustCenterPolicyStatusPresentation.preset(policy: policy, accessMode: mode)
        var head = ["Preset: \(preset?.title ?? "custom")", "Agent access: \(mode)"]
        head.append("Mac control: \(policy.macControlPolicy?.enabled == true ? "on" : "off")")
        var sections = [section("Trust", head)]
        let rows = TrustGuardrailSummary.rows(policy: policy, accessMode: mode)
        if !rows.isEmpty {
            sections.append(section("Guardrails", rows.map { "\($0.title): \($0.value). \($0.detail)" }))
        }
        sections.append(section("Backup ids for backup.restore", appModel.engine.trust.backups.isEmpty ? ["None."]
            : appModel.engine.trust.backups.map { "\($0.id): \($0.createdAt) · \($0.reason)" }))
        return sections
    }

    // MARK: Memories

    private static func memoriesProjection(appModel: AppModel) -> [JSONValue] {
        let memories = appModel.engine.memory.memories
        var head = [MemoriesPageContent.keptLine(memories.count)]
        head.append(countLine(appModel.engine.memory.proposals.count, "proposal waiting", "proposals waiting"))
        head.append(countLine(appModel.graphEntities.count, "thing in the graph", "things in the graph"))
        head.append(contentsOf: MemoryStatusProjection.afterTurnRecovery(dataRoot: PersistenceCore.defaultDataRoot()).lines)
        var sections = [section("Memories", head)]
        if !memories.isEmpty {
            sections.append(section("Kept", memories.prefix(20).map { record in
                let first = record.text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? record.text
                return "\(record.layer ?? ""): \(first)"
            }))
        }
        if !appModel.engine.memory.proposals.isEmpty {
            sections.append(section("Waiting", appModel.engine.memory.proposals.prefix(12).map(proposalLine)))
        }
        return sections
    }

    // MARK: Desk

    /// The Desk loads its own board too (`refreshForSidebarItem(.desk)` is a
    /// no-op), so the projection takes the same read the page takes.
    private static func deskProjection(appModel: AppModel) async -> [JSONValue] {
        let desk = appModel.engine.desk
        let snapshot = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(desk: desk)
        }.value
        guard snapshot.loaded else {
            return [section("Desk", [snapshot.deskUnavailable ?? "The board could not be read."])]
        }
        let items = snapshot.items
        let waiting = DeskPageContent.waitingOnOwner(items)
        let blocked = DeskPageContent.blocked(items)
        let active = DeskPageContent.active(items)
        // `stuckReason` answers "why is this stuck" and always answers; asking
        // it about a row that is not stuck would print a blocked line over a
        // healthy item. Only the two stuck lanes ask.
        func rows(_ list: [DeskItem], stuck: Bool = false) -> [String] {
            list.prefix(20).map { item in
                let line = "\(item.alias) \(DeskPageContent.title(item)) [\(item.project)]"
                guard stuck else { return line }
                let reason = DeskPageContent.stuckReason(item)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return reason.isEmpty ? line : "\(line) — \(reason)"
            }
        }
        var sections = [section("Desk", [
            countLine(active.count, "open item, including parts; MY QUEUE separate", "open items, including parts; MY QUEUE separate"),
            countLine(waiting.count, "item waiting on you", "items waiting on you"),
            countLine(blocked.count, "item blocked", "items blocked"),
        ])]
        if !waiting.isEmpty { sections.append(section("Waiting on you", rows(waiting, stuck: true))) }
        if !blocked.isEmpty { sections.append(section("Blocked", rows(blocked, stuck: true))) }
        if !active.isEmpty { sections.append(section("In play", rows(active))) }
        return sections
    }

    // MARK: Notifications

    private static func notificationsProjection(appModel: AppModel) -> [JSONValue] {
        let items = appModel.engine.inbox.items
        var sections = [section("Notifications", [
            countLine(items.count, "item in the inbox", "items in the inbox"),
            countLine(items.filter { $0.status == "unread" }.count, "unread", "unread"),
        ])]
        if !items.isEmpty {
            sections.append(section("Recent", items.prefix(15).map {
                "\($0.created_at) · \($0.severity) · \($0.source): \($0.title) — \($0.summary)"
            }))
        }
        return sections
    }

    // MARK: The rest

    private static func diagnosticsProjection(appModel: AppModel) async -> [JSONValue] {
        // The runtime line comes from the PROBE, like the status line does. A
        // failed read leaves `health` on its cached row; printing "online" off
        // that row under a "Health check failed" status is a claim about a
        // reading that never came back.
        let runtime: String
        if appModel.engine.doctor.healthProbeFailed {
            runtime = "unknown (last check failed)"
        } else {
            runtime = appModel.engine.doctor.health?.ok == true ? "online" : "not reachable"
        }
        var head = ["Runtime: \(runtime)"]
        head.append("Status line: \(appModel.statusForAgent)")
        head.append(countLine(appModel.runs.count, "run recorded", "runs recorded"))
        var sections = [section("Diagnostics", head)]
        do {
            let tools = try await appModel.engine.tools.listAuthored()
            for (title, targets) in [("Tool ids for tool.restore", tools.filter { $0.status == "archived" }),
                                     ("Tool ids for tool.approve", tools.filter { ToolApprovalEligibility.refusal(for: $0) == nil })] {
                sections.append(section(title, targets.isEmpty ? ["None."] : targets.map { "\($0.id): \($0.name)" }))
            }
        } catch { sections.append(section("Tool targets", ["Unavailable: \(error.localizedDescription)"])) }
        if !appModel.runs.isEmpty {
            // The Run history row's own words: kind, badge, when, how long,
            // model, and the error, output or prompt it previews.
            sections.append(section("Runs", appModel.runs.prefix(15).map { run in
                ([run.id, RunKindVocabulary.displayName(run.kind, on: .mac),
                  RunStatusBadgePresentation.badge(for: run.status).label,
                  RunDetailPresentation.createdAtText(for: run)]
                    + [run.durationSeconds.map(UserDisplayFormatters.humanizeDuration), run.model].compactMap { $0 }
                        .filter { !$0.isEmpty })
                    .joined(separator: " · ") + ": " + RunPreviewPresentation.preview(for: run).text
            }))
        }
        return sections
    }

    private static func toolsProjection(appModel: AppModel) -> [JSONValue] {
        let tools = appModel.engine.tools
        let state = ChatToolCatalogPresentation.catalogState(catalog: tools.catalog,
            loadFailed: tools.catalogLoadError != nil, loadError: tools.catalogLoadError)
        var sections: [JSONValue] = []
        switch ToolsCatalogSurfacePresentation.state(for: state) {
        case .loading(let detail), .empty(let detail), .unavailable(let detail):
            sections.append(section("Tools", [detail.detail]))
        case .catalog:
            if let catalog = tools.catalog {
                if case .stale(_, _, let detail) = state {
                    sections.append(section("Tools", [detail ?? "The tool list is stale. Press Refresh to try again."]))
                }
                sections += ChatToolCatalogPresentation.buckets(for: catalog).map { bucket in
                    section(bucket.title, bucket.tools.map {
                        "\($0.name): \(ChatToolCatalogPresentation.toolStatusBadge(for: $0, in: catalog).title) · \($0.description)"
                    })
                }
                sections.append(section("Mac access", [catalog.builderModeDetail]
                    + catalog.builderAvailable + catalog.macAppAvailable))
            }
        }
        if !tools.authored.isEmpty {
            sections.append(section("Tools I wrote", tools.authored.map {
                "\($0.name): \(AuthoredToolPresentation.statusBadge(for: $0).title) · \($0.description)"
            }))
        }
        return sections
    }

    private static func capabilitiesProjection(appModel: AppModel) -> [JSONValue] {
        [section("Capabilities", [
            countLine(appModel.engine.trust.capabilitySummary?.records.count ?? 0, "capability", "capabilities"),
            countLine(appModel.workflows.count, "workflow", "workflows"),
            countLine(appModel.mcpServers.count, "MCP server", "MCP servers"),
            countLine(appModel.nativeActions.count, "action", "actions"),
            countLine(appModel.engine.approvals.records.filter { $0.status.lowercased() == "pending" }.count,
                      "approval waiting", "approvals waiting"),
        ])]
    }

    private static func connectorsProjection(appModel: AppModel) -> [JSONValue] {
        var sections = [section("Connectors", [
            countLine(appModel.connectors.count, "connector", "connectors"),
            countLine(appModel.workspaces.count, "workspace", "workspaces"),
            "Telegram: \(appModel.engine.telegram.status?.tokenConfigured == true ? "configured" : "not configured")",
        ])]
        sections.append(section("Connector ids", appModel.connectors.isEmpty ? ["None."] : appModel.connectors.map {
            "\($0.id): \($0.name)\($0.kind.isEmpty ? "" : " (\($0.kind))"): \($0.enabled ? "on" : "off")"
        }))
        return sections
    }

    private static func telegramProjection(appModel: AppModel) -> [JSONValue] {
        guard let status = appModel.engine.telegram.status else {
            return [section("Telegram", ["Telegram's status has not loaded."])]
        }
        var lines = [
            "Telegram: \(status.enabled ? "on" : "off") · bot token \(status.tokenConfigured ? "saved" : "not saved")",
            "Only answers when mentioned in a group: \(status.requireMention ? "yes" : "no")",
            countLine(status.allowedChatIds.count, "allowed chat", "allowed chats")
                + ", " + countLine(status.allowedUserIds.count, "allowed user", "allowed users"),
            "Model: \(status.model ?? "same as Chat") · Think \(status.reasoningEffort ?? "default")",
        ]
        if let at = status.lastReplyAt { lines.append("Last reply: \(at)") }
        if let error = status.lastError, !error.isEmpty { lines.append("Last error: \(error)") }
        return [section("Telegram", lines)]
    }

    private static func mcpProjection(appModel: AppModel) -> [JSONValue] {
        var sections = [section("MCP", [
            countLine(appModel.mcpServers.count, "server", "servers"),
            countLine(appModel.mcpConsent.count, "consent", "consents"),
        ])]
        if !appModel.mcpServers.isEmpty {
            sections.append(section("Servers", appModel.mcpServers.map {
                "\($0.name) [\($0.id)]: \($0.status ?? $0.healthStatus ?? "status unknown") · \($0.toolCount ?? 0) tools"
            }))
        }
        if !appModel.mcpConsent.isEmpty {
            sections.append(section("Consents", appModel.mcpConsent.prefix(30).map {
                "\($0.toolName ?? "a tool") on \($0.serverId ?? "a server"): \($0.status ?? "unknown") (\($0.risk ?? "risk unknown"))"
            }))
        }
        return sections
    }

    private static func pairingProjection(appModel: AppModel) -> [JSONValue] {
        let sync = appModel.engine.sync
        var head = ["iCloud: \(sync.status)"]
        if let error = sync.pairingError { head.append("Problem: \(error)") }
        let phones = sync.phones.filter { $0.status != .removed }
        head.append(countLine(phones.count, "phone", "phones"))
        var sections = [section("iPhone pairing", head)]
        if !phones.isEmpty {
            sections.append(section("Phones", phones.map { "\($0.id): \($0.status.rawValue)" }))
        }
        return sections
    }

    /// A Mac app's or connector's page: the Mac app whose access it shows,
    /// and the connectors behind its actions.
    static let servicePages: [String: (mac: String?, connectors: [String])] = [
        "mail": (MacIntegrationID.mail, ["local_mail", "gmail", "agentmail"]),
        "calendar": (MacIntegrationID.calendar, ["local_calendar", "google_calendar"]),
        "reminders": (MacIntegrationID.reminders, ["local_reminders"]),
        "notes": (MacIntegrationID.notes, []), "contacts": (MacIntegrationID.contacts, []),
        "messages": (MacIntegrationID.messages, []), "music": (MacIntegrationID.music, []),
        "github": (nil, ["github"]), "slack": (nil, ["slack"]), "notion": (nil, ["notion"]), "x": (nil, ["x"]),
    ]

    private static func serviceProjection(_ page: QuietPage, _ service: (mac: String?, connectors: [String]),
                                          appModel: AppModel) async -> [JSONValue] {
        var lines: [String] = []
        if let mac = service.mac {
            let store = MacIntegrationPermissionStore.shared
            let admitted = await appModel.fullMacYoloAuthorityAdmitted(tool: "mac_integration",
                surface: ChatToolSessionContext.envelope?.surface ?? "chat")
            let storedRead = await store.allows(mac, mode: .read), storedWrite = await store.allows(mac, mode: .write)
            let read = await store.allows(mac, mode: .read, fullMacAdmitted: admitted)
            let write = await store.allows(mac, mode: .write, fullMacAdmitted: admitted)
            let access = read && write ? "read and write" : read ? "read" : write ? "write" : "off"
            let stored = storedRead && storedWrite ? "read and write" : storedRead ? "read" : storedWrite ? "write" : "off"
            lines.append("\(MacIntegrationID.displayName(for: mac)) effective permission: \(access); stored permission: \(stored) "
                + "(Full Mac \(admitted ? "admitted" : "not admitted"); macOS permissions still apply; "
                + "setting trust.mac_integration_\(mac), on mac_integration)")
        }
        for connector in appModel.connectors where service.connectors.contains(connector.id) {
            lines.append("\(connector.name.isEmpty ? connector.id : connector.name): \(connector.enabled ? "on" : "off")"
                + (connector.authState.map { " · \($0)" } ?? ""))
        }
        if lines.isEmpty { lines.append("\(page.title) is not set up in Connectors.") }
        return [section(page.title, lines)]
    }

    /// The Agents tab's rows, as its own reload builds them.
    private static func agentsProjection(appModel: AppModel) -> [JSONValue] {
        let root = dataRoot(appModel)
        let dispatcher = SwiftToolDispatcher(dataRoot: root, allowProcessGlobalTools: false)
        let usable = Set(["codex", "claude", "omp"].filter { dispatcher.builtInAgentLaneUsable($0) })
        guard let peers = try? AgentPeerStore(dataRoot: root).list() else {
            return [section("Agents", ["Contacts and trusted switches could not be read."])]
        }
        let rows = AgentContactRow.rows(peers: peers, candidates: [], usable: usable, dataRoot: root)
        var sections = [section("Agents", [countLine(rows.count, "contact", "contacts")])]
        if !rows.isEmpty {
            sections.append(section("Contacts", rows.map { "\($0.displayName): \($0.pillWord)" }))
        }
        if !peers.isEmpty {
            sections.append(section("Trusted switches", peers.map { "\($0.name): trusted \($0.elevationAllowed ? "on" : "off")" }))
        }
        return sections
    }

    private static func personalityProjection(appModel: AppModel) async -> [JSONValue] {
        var head: [String] = []
        if let profile = appModel.personality { head.append("Name: \(profile.name)") }
        head.append("Current persona name: \(appModel.chatPersona).")
        head.append(countLine(appModel.personalityDocs.count, "document", "documents"))
        var sections = [section("Personality", head)]
        do {
            let persona = appModel.dataRootOverride.map(SwiftNativePersonaEngine.isolated(dataRoot:)) ?? SwiftNativePersonaEngine()
            let names = try PersonaCompiler.customPersonaNames(root: await persona.personaRoot)
            sections.append(section("Custom names for persona.set", names.isEmpty ? ["None."] : names))
        } catch { sections.append(section("Custom personas", ["Unavailable: \(error.localizedDescription)"])) }
        do {
            let consults = try await SwiftNativeStudioStore(dataRoot: dataRoot(appModel)).listConsults()
            sections.append(section("Consult ids for studio.consult_read", consults.isEmpty ? ["None."]
                : consults.map { "\($0.id): \($0.question) · \($0.descriptionOnly ? "description only" : "has artifacts")" }))
        } catch { sections.append(section("Consults", ["Unavailable: \(error.localizedDescription)"])) }
        if !appModel.personalityDocs.isEmpty {
            sections.append(section("Documents", appModel.personalityDocs.map { doc in
                let first = doc.content.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                return "\(doc.title): \(first)"
            }))
        }
        return sections
    }

    private static func settingsProjection(appModel: AppModel) -> [JSONValue] {
        [section("Settings", [
            "Agent name: \(appModel.agentDisplayName)",
            "Chat runs on: \(appModel.chatProvider) · \(appModel.chatModel)",
            "File access: \(appModel.chatFileAccess)",
            "Status line: \(appModel.statusForAgent)",
        ])]
    }
}
