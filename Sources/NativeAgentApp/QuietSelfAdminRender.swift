import Connectors
import BackgroundWork
import ApprovalTransactions
import AppToolRuntime
import AppKit
import ChatTurnRuntime
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
import ToolExecution
import TrustCenter
import TrustPersistence
// Blueprint: | `QuietSelfAdminRender.swift` | Quiet page assembly and app read/action host; Tools ability rows use Parts.list, including turn and senses; mounted presentation supplies the visible mode and Agent room for self-window reads, independently of Advanced sidebar `current` and its screenshot restriction; Today waiting uses `WorkOverviewRead`, helpers use the engine bot shelf, chat cards use the transcript owner's checked projection; page indexing/rendering receives live layout; context receipts read the engine data root |

extension EnvironmentValues {
    /// Screenshots suppress lifecycle writes while allowing read-only loads.
    @Entry var quietOffscreenRead: Bool = false

    /// The requested screenshot tab, or the page's default when nil.
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
        // A page that is a tab now (Mac integration, Telegram, iPhone,
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
            case .providers: ShellRailPage(title: "Providers", subtitlePage: .providers, alive: true) { ProviderSettingsView() }
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
        // ShellFrame owns the onscreen ground through ShellSheet; the
        // offscreen host supplies the same room color behind the page.
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
        guard size.width.isFinite, size.height.isFinite,
              let width = Int(exactly: size.width.rounded(.down)), width > 0,
              let height = Int(exactly: size.height.rounded(.down)), height > 0 else { return nil }
        return await withPreparedHost(for: page, tab: tab, appModel: appModel, size: size) { hosting in
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
        var projection=await pageProjection(for:page,appModel:appModel)
        switch page.item.normalized {
        case .providers, .bots, .trust, .connectors, .diagnostics, .personality:
            let item=page.item.normalized
            let caption=await appModel.engine.transcripts.presentation.prepareSnapshot("page:"+item.rawValue,
                input:.object(["kind":.string("page"),"page":.string(item.rawValue)]))
            if caption.status == .ready, let text=caption.face?.sections.first?.rows.first?.title {
                projection.insert(section("About",[text]),at:0)
            } else { projection.insert(section("Page caption unavailable",[caption.error?.message ?? caption.status.rawValue]),at:0) }
        default: break
        }
        return await RuntimeReadouts.quietPageContext(
            projection, pageID: page.id,
            model: appModel.chatModel, providerID: appModel.chatProvider,
            dataRoot: appModel.engine.dataRoot, providers: appModel.engine.providers)
    }

    /// The page, in the words of the records it draws from.
    static func pageProjection(for page: QuietPage, appModel: AppModel) async -> [JSONValue] {
        if let content = RuntimeReadouts.quietVirtualPage(
            page.value) { return content }
        if let service = RuntimeReadouts.quietServicePages[page.id] {
            return await RuntimeReadouts.quietService(
                page.value, service,
                connectors: appModel.engine.connectors,
                macIntegration: appModel.engine.macIntegration, statusText: connectorStatusText)
        }
        switch page.item {
        case .chat: return await chatProjection(appModel: appModel)
        case .bots: return await RuntimeReadouts.quietBots(engine: appModel.engine)
        case .activity: return await todayProjection(appModel: appModel)
        case .providers: return await providersProjection(appModel: appModel)
        case .trust: return RuntimeReadouts.quietTrust(trust: appModel.engine.trust, dataRoot: appModel.engine.dataRoot,
            presetTitle: { MobileTrustAction.Preset.matching(policy: $0, accessMode: $1)?.title ?? "custom" }) { policy, mode in
            TrustGuardrailSummary.rows(policy: policy, accessMode: mode).map { "\($0.title): \($0.value). \($0.detail)" }
        }
        case .memories: return RuntimeReadouts.quietMemories(appModel.engine.memory,
            keptLine: MemoriesPageContent.keptLine(appModel.engine.memory.memories.count), graphEntityCount: appModel.engine.memory.graphTotalEntities)
        case .desk: return await RuntimeReadouts.quietDesk(desk: appModel.engine.desk)
        case .inboxPolicy: return RuntimeReadouts.quietNotifications(appModel.engine.inbox)
        case .diagnostics: return await diagnosticsProjection(appModel: appModel)
        case .tools: return toolsProjection(appModel: appModel)
        case .capabilities: return RuntimeReadouts.quietCapabilities(trust: appModel.engine.trust, approvals: appModel.engine.approvals,
            workflowCount: appModel.engine.desk.workflows.count, actionCount: appModel.engine.tools.nativeActions.count)
        case .connectors where page.tab == "iphone": return await RuntimeReadouts.quietPairing(appModel.engine.sync, dataRoot: appModel.engine.dataRoot)
        case .connectors where page.tab == "agents": return await RuntimeReadouts.quietAgents(appModel.engine.contacts)
        case .connectors: return await RuntimeReadouts.quietConnectors(
            appModel.engine.connectors, workspaceCount: appModel.engine.connectors.workspaces.count,
            statusText: connectorStatusText)
        case .telegram: return RuntimeReadouts.quietTelegram(appModel.engine.telegram)
        case .macIntegration: return await RuntimeReadouts.quietMacIntegration(
            connectors: appModel.engine.connectors, macIntegration: appModel.engine.macIntegration,
            workspaceCount: appModel.engine.connectors.workspaces.count, statusText: connectorStatusText)
        case .personality: return await RuntimeReadouts.quietPersonality(appModel.engine.persona, currentPersona: appModel.chatPersona)
        case .settings: return RuntimeReadouts.quietSettings(agentName: appModel.agentDisplayName, providerID: appModel.chatProvider,
            model: appModel.chatModel, fileAccess: appModel.chatFileAccess, status: appModel.statusForAgent)
        default: return []
        }
    }

    private static let section = RuntimeReadouts.quietPageSection

    private static let countLine = RuntimeReadouts.quietCountLine

    // MARK: Chat

    /// Project the transcript's cards and collapsed folds, which the offscreen
    /// accessibility tree cannot expose, together with the mounted composer.
    private static func chatProjection(appModel: AppModel) async -> [JSONValue] {
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
            line("Open pane", "open_card") ?? "",
            "The chat.* actions work this row in process.",
        ].filter { !$0.isEmpty } + paneRows))

        // The folds, in transcript order, by the row the fold stands on.
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
                detail: error.localizedDescription, instruction: "Resolve the reported conversation read problem without deleting its history, then reload Chat.",
                next: ["page": .string("chat")], error: error))
        }
        return sections
    }


    // MARK: Today

    private static func todayProjection(appModel: AppModel) async -> [JSONValue] {
        let today = appModel.engine.today
        await appModel.publishWorkStatus()
        await today.refresh(appModel.engine, activeSessionID: appModel.activeChatSessionId)
        let pending = WaitingOnYou.approvals(appModel)
        let waitingNotes = appModel.engine.inbox.items.filter { $0.status == "unread" }
        var waiting: [String] = []
        if !pending.isEmpty { waiting.append(countLine(pending.count, "approval waiting", "approvals waiting")) }
        let deskCount = WaitingOnYou.onDesk(appModel)
        if deskCount > 0 { waiting.append(await today.prepareWaiting(appModel.engine, count: deskCount, split: WaitingOnYou.split(appModel))) }
        // The page's blocks (ui/layout.json, today): the waiting card, then
        // the queues its links open, in the order the window shows them.
        var queues: [JSONValue] = []
        if !pending.isEmpty {
            queues.append(section("Approvals", pending.prefix(12).map { "\($0.title) — \($0.action), risk \($0.risk)" }))
        }
        if !waitingNotes.isEmpty {
            queues.append(section("Notes", waitingNotes.prefix(12).map { "\($0.severity): \($0.title) — \($0.summary)" }))
        }
        let earlier = today.earlierNotes
        let snapshot = today.snapshot
        var unavailable: [String] = []
        if let error = snapshot.projectionError { unavailable.append(error) }
        if snapshot.memoryUnreadable { unavailable.append("Memory source unavailable.") }
        if today.dreamUnavailable { unavailable.append("Dream source unavailable.") }
        func rows(_ heading: String, _ rows: [TodayRow]) -> [JSONValue] {
            rows.isEmpty ? [] : [section(heading, rows.map { [$0.time, $0.title, $0.line].filter { !$0.isEmpty }.joined(separator: " · ") })]
        }
        let blocks: [String: [JSONValue]] = [
            "waiting": (appModel.engine.desk.ownerWaitingCount ?? 0) > 0 ? [section("Waiting on you", waiting)] : [],
            "earlier": TodayView.earlierNotesLine(earlier).map { [section("Earlier", [$0] + earlier.map { $0.title + ($0.count > 1 ? " ×\($0.count)" : "") })] } ?? [],
            "did": rows("What I did today", today.didRows),
            "ahead": rows("Ahead", snapshot.ahead),
            "queues": queues,
        ]
        return (unavailable.isEmpty ? [] : [section("Today unavailable", unavailable)])
            + appModel.engine.layout.layout.shown("today", profile: SimpleViewMode.advanced).flatMap { blocks[$0.name] ?? [] }
    }

    // MARK: Providers

    /// Each group's rows supply its shared model and connected accounts.
    private static func providersProjection(appModel: AppModel) async -> [JSONValue] {
        let outcome = await appModel.engine.providers.refreshSettings(refreshCatalog: false, cause: UserFacingError.cause)
        guard case .loaded(let snapshot) = outcome else {
            if case .failed(let reason) = outcome {
                return [RuntimeReadouts.quietPageIssue("Providers", reason: "providers_read_failed",
                    detail: reason, instruction: "Resolve the reported account or routing problem in Providers.", tap: "Providers")]
            }
            return [RuntimeReadouts.quietPageIssue("Providers", reason: "providers_not_loaded",
                detail: "Providers have not loaded.", instruction: "Read Providers to load accounts and routing.",
                next: ["page": .string("providers")], status: "not_loaded")]
        }
        return RuntimeReadouts.quietProviders(routing: snapshot.routing, providers: snapshot.providers)
    }


    // MARK: The rest

    private static func diagnosticsProjection(appModel: AppModel) async -> [JSONValue] {
        let runtime = appModel.engine.doctor.health.map { $0.ok ? "online" : "not reachable" } ?? "not loaded"
        var head = ["Runtime: \(runtime)"]
        head.append("Status line: \(appModel.statusForAgent)")
        head.append(countLine(appModel.engine.runs.rows.count, "run recorded", "runs recorded"))
        var sections = [section("Diagnostics", head)]
        if appModel.engine.doctor.health == nil {
            sections.append(RuntimeReadouts.quietPageIssue("Runtime health", reason: "runtime_health_not_loaded",
                detail: "No runtime health snapshot has loaded.", instruction: "Read Diagnostics to load runtime health.",
                next: ["page": .string("diagnostics")], status: "not_loaded"))
        }
        do {
            let tools = try await appModel.engine.tools.listAuthored()
            for (title, targets) in [("Abilities to read before restoring", tools.filter { $0.status == "disabled" }),
                                     ("Abilities to read before keeping", tools.filter { appModel.engine.tools.keepRefusal($0) == nil })] {
                sections.append(section(title, targets.isEmpty ? ["None."] : targets.map {
                    "\($0.id): \($0.name) · " + ($0.reviewedKeepDigest.map { "version \($0); read with ability.read before keeping this exact version" }
                        ?? "read with ability.read; only Markdown guidance restores without a version")
                }))
            }
        } catch { sections.append(RuntimeReadouts.quietPageIssue("Tool targets", reason: "tool_targets_unavailable",
            detail: error.localizedDescription, instruction: "Resolve the reported ability-store read problem before restoring an ability; inspect Tools for its current state.",
            next: ["page": .string("tools")], error: error)) }
        if !appModel.engine.runs.rows.isEmpty {
            // The Run history row's own words: kind, badge, when, how long,
            // model, and the error, output or prompt it previews.
            sections.append(section("Runs", appModel.engine.runs.rows.prefix(15).map { run in
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


    private static func connectorStatusText(_ connector: ConnectorRecord) -> String {
        ConnectorsView.statusText(for: connector, uiState: ConnectorUIState.resolve(connector))
    }

    /// The Agents tab's rows, as its own reload builds them.

}

@MainActor
final class QuietSelfAdmin {
    static let shared = QuietSelfAdmin()

    /// The mounted composer's shell; drafts belong to AppModel by session.
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
        QuietToolPage.page(named: raw).map(QuietPage.init)
    }
}

@MainActor struct AppQuietToolPresentation: QuietToolPresentationPort {
    /// The page index as the window shows it: a page whose rail row or place
    /// the layout hides (ui/layout.json) leaves it, and still reads by name.
    var pages: [QuietToolPage] {
        guard let appModel = ApplicationLifetime.shared.appModel else { return [] }
        return RuntimeReadouts.quietPages(
            layout: appModel.engine.layout.layout, profile: SimpleViewMode.current)
    }
    var currentPage: QuietToolPage? { ApplicationLifetime.shared.currentPage.map(\.value) }
    var visiblePageInput: [String: JSONValue]? { ApplicationLifetime.shared.visiblePageInput }
    func page(named raw: String) -> QuietToolPage? { QuietToolPage.page(named: raw) }
    /// `app {page: "context", item: session_id}`: the composer's context
    /// receipt for a conversation, read from the turn traces by the same code
    /// the popover uses, line for line — the popover need not be open.
    /// Defaults to the conversation on screen.
    @MainActor
    func contextReceiptRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.contextReceiptRead(input: input, activeSessionID: appModel.activeChatSessionId) { sessionID in
            let state = await ContextReceipts.read(sessionId: sessionID, selectedModel: appModel.chatModel, dataRoot: appModel.engine.dataRoot)
            return ComposerContextReceiptPresentation.lines(state)
        }
    }

    /// `app {page: "agent_view", item: room}`: one Agent-view tab's
    /// text, from the pane's own render (read-only: nothing marked seen or
    /// written, no tool run); no room lists the tabs. Defaults to the
    /// conversation on screen, as the pane does.
    @MainActor
    func agentViewRead(input: [String: JSONValue]) async -> JSONValue {
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
        return await AppToolExecutor.agentViewRead(input: input, rooms: HerScreenPreview.tabs(appModel.engine.layout.layout, profile: SimpleViewMode.agent),
                                                   activeSessionID: appModel.activeChatSessionId) { room, scope in
            await appModel.engine.turns.readAgentScreen(room: room, scope: scope)
        }
    }

    // MARK: - page.screenshot

    @MainActor
    func pageScreenshot(input: [String: JSONValue]) async -> JSONValue {
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
        // A tab by the key page.show takes (`QuietComposerCommands.tabs`), on
        // this page's own rail page. Without one the page's default tab draws.
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
        guard let appModel = ApplicationLifetime.shared.appModel else { return AppToolExecutor.unattachedFailure() }
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
        guard let rendered = await QuietSelfAdminRender.pageImagePNG(for: page, tab: tab, appModel: appModel, size: size) else {
            return AppToolExecutor.failure("render_failed", "Offscreen bitmap allocation or PNG encoding failed.",
                extra: ["page": .string(page.id), "tab": .string(tabKey),
                    "remedy": Repair.remedy(owner: "page.screenshot", nextCall: .object([
                        "tool": .string("app"), "input": .object(["page": .string(page.id)])]), tap: nil,
                        instruction: "Inspect the page data through next_call to diagnose the render failure.")])
        }
        return AppToolExecutor.pageScreenshotResult(
            page: page.value, tabKey: tabKey,
            dataRoot: appModel.engine.dataRoot, rendered: rendered)
    }

    private static func text(_ value: JSONValue?) -> String {
        guard case .string(let raw)? = value else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
