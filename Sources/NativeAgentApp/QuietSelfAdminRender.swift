import Connectors
import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import AppKit
import ChatOrchestration
import Foundation
import EngineRuntime
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
import ToolRegistry
import TrustCenter
import TrustPersistence

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
            case .bots: BotsShelfView()
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
        return await RuntimeReadProjection.quietPageContext(
            await pageProjection(for: page, appModel: appModel), pageID: page.id,
            model: appModel.chatModel, providerID: appModel.chatProvider,
            dataRoot: dataRoot(appModel), providers: appModel.engine.providers)
    }

    private static func proposalLine(_ proposal: ProposalRecord) -> String {
        proposal.content
    }

    /// The page, in the words of the records it draws from.
    static func pageProjection(for page: QuietPage, appModel: AppModel) async -> [JSONValue] {
        if let content = RuntimeReadProjection.quietVirtualPage(
            page.value) { return content }
        if let service = RuntimeReadProjection.quietServicePages[page.id] {
            return await RuntimeReadProjection.quietService(
                page.value, service,
                dataRoot: dataRoot(appModel), platform: AppConnectorStatusPlatform(),
                statusText: connectorStatusText, osAccess: macOSAccess)
        }
        switch page.item {
        case .chat: return await chatProjection(appModel: appModel)
        case .bots: return await RuntimeReadProjection.quietBots(dataRoot: dataRoot(appModel)) {
            BotState(record: $0, running: $1, queued: $2).word
        }
        case .activity: return await todayProjection(appModel: appModel)
        case .providers: return await providersProjection(appModel: appModel)
        case .trust: return RuntimeReadProjection.quietTrust(trust: appModel.engine.trust, dataRoot: dataRoot(appModel),
            presetTitle: { TrustPolicyPreset.matching(policy: $0, accessMode: $1)?.title ?? "custom" }) { policy, mode in
            TrustGuardrailSummary.rows(policy: policy, accessMode: mode).map { "\($0.title): \($0.value). \($0.detail)" }
        }
        case .memories: return RuntimeReadProjection.quietMemories(appModel.engine.memory,
            keptLine: MemoriesPageContent.keptLine(appModel.engine.memory.memories.count), graphEntityCount: appModel.graphEntities.count)
        case .desk: return await RuntimeReadProjection.quietDesk(desk: appModel.engine.desk)
        case .inboxPolicy: return RuntimeReadProjection.quietNotifications(appModel.engine.inbox)
        case .diagnostics: return await diagnosticsProjection(appModel: appModel)
        case .tools: return toolsProjection(appModel: appModel)
        case .capabilities: return RuntimeReadProjection.quietCapabilities(trust: appModel.engine.trust, approvals: appModel.engine.approvals,
            workflowCount: appModel.workflows.count, mcpServerCount: appModel.mcpServers.count, actionCount: appModel.nativeActions.count)
        case .connectors where page.tab == "iphone": return await RuntimeReadProjection.quietPairing(appModel.engine.sync, dataRoot: dataRoot(appModel))
        case .connectors where page.tab == "agents": return RuntimeReadProjection.quietAgents(dataRoot: dataRoot(appModel))
        case .connectors: return await RuntimeReadProjection.quietConnectors(
            dataRoot: dataRoot(appModel), platform: AppConnectorStatusPlatform(), workspaceCount: appModel.workspaces.count,
            telegramConfigured: appModel.engine.telegram.status?.tokenConfigured == true, statusText: connectorStatusText)
        case .telegram: return RuntimeReadProjection.quietTelegram(appModel.engine.telegram)
        case .mcp: return RuntimeReadProjection.quietMCP(servers: appModel.mcpServers, consents: appModel.mcpConsent)
        case .macIntegration: return await RuntimeReadProjection.quietMacIntegration(
            dataRoot: dataRoot(appModel), platform: AppConnectorStatusPlatform(), workspaceCount: appModel.workspaces.count,
            telegramConfigured: appModel.engine.telegram.status?.tokenConfigured == true,
            statusText: connectorStatusText, osAccess: macOSAccess)
        case .personality: return await RuntimeReadProjection.quietPersonality(name: appModel.personality?.name,
            currentPersona: appModel.chatPersona, documents: appModel.personalityDocs, dataRootOverride: appModel.dataRootOverride)
        case .settings: return RuntimeReadProjection.quietSettings(agentName: appModel.agentDisplayName, providerID: appModel.chatProvider,
            model: appModel.chatModel, fileAccess: appModel.chatFileAccess, status: appModel.statusForAgent)
        default: return []
        }
    }

    private static func dataRoot(_ appModel: AppModel) -> URL {
        appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    private static let section = RuntimeReadProjection.quietPageSection

    private static let countLine = RuntimeReadProjection.quietCountLine

    // MARK: Chat

    /// Project the transcript's cards and collapsed folds, which the offscreen
    /// accessibility tree cannot expose, together with the mounted composer.
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
            MoodTintProjection.line(),
        ])]

        // Read the same mounted draft and pane that composer verbs change.
        let composer = await QuietComposerCommands.state(appModel: appModel)
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

        // The shared collapse keeps the text read and the rendered card count aligned.
        let collapsed = InlineInteractionResolver.collapsedCards(
            await InlineInteractionResolver.interactionsByRow(
                sessionID: sessionID, dataRoot: root
            )
        )
        sections += await RuntimeReadProjection.quietChatCards(collapsed, dataRoot: root)
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
        // The page's blocks (ui/layout.json, today): the waiting card, then
        // the queues its links open, in the order the window shows them.
        var queues: [JSONValue] = []
        switch await appModel.engine.cognitionView.pendingProposals() {
        case .available(let pending):
            queues.append(section("Proposed views", pending.standingViews.isEmpty ? ["None."]
                : pending.standingViews.map { "\($0.id): \($0.title)" }))
        case .unavailable(let reason): queues.append(section("Proposed views", [reason]))
        }
        if !pending.isEmpty {
            queues.append(section("Approvals", pending.prefix(12).map { "\($0.title) — \($0.action), risk \($0.risk)" }))
        }
        if !waitingNotes.isEmpty {
            queues.append(section("Notes", waitingNotes.prefix(12).map { "\($0.severity): \($0.title) — \($0.summary)" }))
        }
        if !proposals.isEmpty {
            queues.append(section("Memories waiting", proposals.prefix(12).map(proposalLine)))
        }
        // The rest of the page from the readers it draws with (TodayView).
        let (snapshot, collaboration, _) = await WorkOverviewRead.readLanes(appModel.engine, fetchDiary: { await appModel.fetchDreamDiary(limit: 1) }, publishWorkStatus: { await appModel.publishWorkStatus() })
        let earlier = WorkOverviewRead.earlierNotes(appModel.engine.inbox.items)
        func rows(_ heading: String, _ rows: [TodayRow]) -> [JSONValue] {
            rows.isEmpty ? [] : [section(heading, rows.map { [$0.time, $0.title, $0.line].filter { !$0.isEmpty }.joined(separator: " · ") })]
        }
        let blocks: [String: [JSONValue]] = [
            "waiting": [section("Waiting on you", waiting)],
            "earlier": TodayView.earlierNotesLine(earlier).map { [section("Earlier", [$0] + earlier.map { $0.title + ($0.count > 1 ? " ×\($0.count)" : "") })] } ?? [],
            "did": rows("What I did today", WorkOverviewRead.didTodayRows(snapshot, collaboration, inbox: appModel.engine.inbox.items, sessions: appModel.engine.transcripts.sessions, surfaces: WorkOverviewRead.conversationSurfaces(appModel.engine.transcripts.sessions), activeSessionID: appModel.activeChatSessionId, messages: appModel.chatMessages, parseTimestamp: UserDisplayFormatters.parseISOTimestamp)),
            "ahead": rows("Ahead", WorkOverviewRead.aheadRows(snapshot)),
            "queues": queues,
        ]
        return SurfaceLayoutStore.layout(dataRoot: dataRoot(appModel)).shown("today", profile: SimpleViewMode.advanced).flatMap { blocks[$0.name] ?? [] }
    }

    // MARK: Providers

    /// The three groups, each with the model its whole group runs on, and the
    /// accounts that are connected. User, 2026-09-13: every surface in a group
    /// runs on the group's model, so the projection reads the group's rows.
    private static func providersProjection(appModel: AppModel) async -> [JSONValue] {
        let outcome = await appModel.engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause)
        guard case .loaded(let snapshot) = outcome else {
            if case .failed(let reason) = outcome {
                return [section("Providers", ["Providers could not be read: \(reason)"])]
            }
            return [section("Providers", ["Providers could not be read."])]
        }
        return RuntimeReadProjection.quietProviders(routing: snapshot.routing, providers: snapshot.providers) { info in
            ProvidersFacade.accountStatusLine(state: info.auth_status.state,
                detail: info.auth_status.detail, failedTest: snapshot.failedTests[info.provider_id])
        }
    }


    // MARK: The rest

    private static func diagnosticsProjection(appModel: AppModel) async -> [JSONValue] {
        let runtime = appModel.engine.doctor.health?.ok == true ? "online" : "not reachable"
        var head = ["Runtime: \(runtime)"]
        head.append("Status line: \(appModel.statusForAgent)")
        head.append(countLine(appModel.runs.count, "run recorded", "runs recorded"))
        var sections = [section("Diagnostics", head)]
        do {
            let tools = try await appModel.engine.tools.listAuthored()
            for (title, targets) in [("Tool ids for tool.restore", tools.filter { ["archived", "quarantined"].contains($0.status) }),
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
                    + [run.durationSeconds.map(CompactDurationFormatter.string), run.model].compactMap { $0 }
                        .filter { !$0.isEmpty })
                    .joined(separator: " · ") + ": " + RunPreviewPresentation.preview(for: run).text
            }))
        }
        return sections
    }

    private static func toolsProjection(appModel: AppModel) -> [JSONValue] {
        let tools = appModel.engine.tools
        let state = ChatToolCatalogPresentation.catalogState(catalog: tools.catalog,
            authored: tools.authored,
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
                sections += ChatToolCatalogPresentation.buckets(for: catalog, authored: tools.authored).map { bucket in
                    section(bucket.title, bucket.tools.map {
                        "\($0.name): \(ChatToolCatalogPresentation.toolStatusBadge(for: $0, in: catalog).title) · \($0.description)"
                    })
                }
                sections.append(section("Mac access", [catalog.builderModeDetail]
                    + catalog.builderAvailable + catalog.macAppAvailable))
            }
        }
        if !tools.authored.isEmpty {
            sections.append(.object(["heading": .string("Tools I wrote"),
                                     "tools": .array(tools.authored.map(ToolRegistryActions.read))]))
        }
        return sections
    }


    private static func connectorStatusText(_ connector: ConnectorRecord) -> String {
        ConnectorsView.statusText(for: connector, uiState: ConnectorUIState.resolve(connector))
    }

    private static func macOSAccess(_ mac: String) -> String {
        switch mac {
        case MacIntegrationID.contacts: MacContactsExecutor.currentAuthorizationStatus()
        case MacIntegrationID.calendar: LocalPIMConnectorActions.currentCalendarAuthorizationStatus()
        case MacIntegrationID.reminders: LocalPIMConnectorActions.currentReminderAuthorizationStatus()
        default: "unverified"
        }
    }

    /// The Agents tab's rows, as its own reload builds them.

}

@MainActor
final class QuietSelfAdmin {
    static let shared = QuietSelfAdmin()

    /// The live composer's own two objects. Both are view-local `@State` on
    /// `ChatView` — the draft so a keystroke invalidates the composer alone,
    /// the card state because the card DRAWS in the chat column — so neither
    /// is reachable from `AppModel`. The chat page registers them while it is
    /// mounted; weak, because the view owns them and a closed window must not
    /// be kept alive by this. Nil simply means no composer is on screen, and
    /// the composer verbs say so rather than inventing one.
    private weak var draft: ChatComposerDraft?
    private weak var cards: ComposerShellState?

    private init() {}

    func attach(composerDraft: ChatComposerDraft, cards: ComposerShellState) {
        draft = composerDraft
        self.cards = cards
    }

    func detachComposer(draft candidate: ChatComposerDraft) {
        guard draft === candidate else { return }
        draft = nil
        cards = nil
    }

    var composerDraft: ChatComposerDraft? { draft }
    var composerCards: ComposerShellState? { cards }

}

// MARK: - Pages

/// The rail route for a page from the shared catalog.
struct QuietPage: Sendable, Equatable {
    let value: QuietToolPage
    var id: String { value.id }
    var title: String { value.title }
    var summary: String { value.summary }
    var item: SidebarItem {
        switch id {
        case "chat", "simple", "simple_settings_menu": .chat
        case "today": .activity
        case "memories": .memories
        case "desk": .desk
        case "notifications": .inboxPolicy
        case "bots": .bots
        case "personality": .personality
        case "providers": .providers
        case "trust", "files", "shell", "browser", "mac": .trust
        case "connectors", "pairing", "agents", "github", "slack", "notion", "x", "markets": .connectors
        case "telegram": .telegram
        case "mcp", "web": .mcp
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
        case "github", "slack", "notion", "x", "markets": "connectors"
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
        QuietToolPage.page(named: raw).map(QuietPage.init)
    }
}

@MainActor struct AppQuietToolPresentation: QuietToolPresentationPort {
    /// The page index as the window shows it: a page whose rail row or place
    /// the layout hides (ui/layout.json) leaves it, and still reads by name.
    var pages: [QuietToolPage] {
        let appModel = NativeAgentAppCoordinator.shared.appModel
        return RuntimeReadProjection.quietPages(
            dataRoot: appModel?.dataRootOverride ?? PersistenceCore.defaultDataRoot(), profile: SimpleViewMode.current)
    }
    var currentPage: QuietToolPage? { NativeAgentAppCoordinator.shared.currentPage.map(\.value) }
    func page(named raw: String) -> QuietToolPage? { QuietToolPage.page(named: raw) }
    /// `app {page: "context", item: session_id}`: the composer's context
    /// receipt for a conversation, read from the turn traces by the same code
    /// the popover uses, line for line — the popover need not be open.
    /// Defaults to the conversation on screen.
    @MainActor
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = NativeAgentAppCoordinator.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.contextReceiptRead(input: input, activeSessionID: appModel.activeChatSessionId) { sessionID in
            let state = await ContextReceiptProjection.read(sessionId: sessionID, selectedModel: appModel.chatModel)
            return ComposerContextReceiptPresentation.lines(state)
        }
    }

    /// `app {page: "agent_view", item: room}`: one Agent-view tab's
    /// text, from the pane's own render (read-only: nothing marked seen or
    /// written, no tool run); no room lists the tabs. Defaults to the
    /// conversation on screen, as the pane does.
    @MainActor
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = NativeAgentAppCoordinator.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.agentViewRead(input: input, rooms: AgentScreenView.tabs,
                                                   activeSessionID: appModel.activeChatSessionId) { room, scope in
            await HerScreenPreview.paneText(room,
                root: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(), scope: scope)
        }
    }

    // MARK: - page.screenshot

    @MainActor
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue {
        let requested = Self.text(input["page"])
        guard let page = QuietPages.page(named: requested)
                ?? QuietPages.drawOnly.first(where: { $0.id == requested.lowercased() }) else {
            return AppToolExecutor.unknownPageFailure(requested, pages: QuietPages.ids)
        }
        // A tab by the key page.show takes (`QuietComposerCommands.tabs`), on
        // this page's own rail page. Without one the page's default tab draws.
        let tabKey = Self.text(input["tab"]).lowercased()
        let railPage = SidebarItem.shellHome(for: page.item)?.parent ?? page.item
        var tab: String?
        if !tabKey.isEmpty {
            guard let home = QuietComposerCommands.tabs[tabKey], home.page == railPage else {
                let keys = QuietComposerCommands.tabs.filter { $0.value.page == railPage }.keys.sorted()
                return AppToolExecutor.failure("unknown_tab", "This page has no tab called that.",
                                               extra: ["requested": .string(tabKey), "tabs": .array(keys.map { .string($0) })])
            }
            tab = home.tab
        }
        guard let appModel = NativeAgentAppCoordinator.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        var size = QuietSelfAdminRender.defaultSize
        switch input["height"] {
        case .int(let value)?: size.height = CGFloat(value)
        case .double(let value)?: size.height = CGFloat(value)
        case .string(let value)?: size.height = Double(value).map { CGFloat($0) } ?? size.height
        default: break
        }
        size.height = min(max(size.height, 400), 2400)
        guard let rendered = await QuietSelfAdminRender.pageImagePNG(for: page, tab: tab, appModel: appModel, size: size) else {
            return AppToolExecutor.failure("render_failed", "The page could not be drawn offscreen.")
        }
        return AppToolExecutor.pageScreenshotResult(
            page: page.value, tabKey: tabKey,
            dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(), rendered: rendered)
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
