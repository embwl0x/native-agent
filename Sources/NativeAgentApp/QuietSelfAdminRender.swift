import AppKit
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// The page projection reads the same stores the pages read: the bots shelf's
// run queue (StandingBots) and the Providers group table (ProviderRouting).
import ProviderRouting
import StandingBots
import SwiftUI

/// Looking at a page without anyone else looking at it.
///
/// The page is built a SECOND time, offscreen, from the same live `AppModel`
/// the visible window is bound to. The window on screen is never read, never
/// touched, and never asked to change what it is showing — which is what makes
/// a read of Providers safe while the person is reading Chat.
///
/// The only AppKit window this file creates is an unordered, borderless host
/// used to give the hosting view a layout context so accessibility resolves.
/// It is never ordered front, never made key, never given a level, and is torn
/// down in the same call. `NSApp.activate`, `makeKeyAndOrderFront`, `orderFront`,
/// `NSWindow.level` and every synthesized-event API (`CGEvent`,
/// `CGWarpMouseCursorPosition`) appear nowhere in this file, in
/// `QuietSelfAdmin.swift`, in `QuietSelfAdminSettings.swift`, or in
/// `AppChatToolDispatcher+QuietSelfAdmin.swift` — that absence is the whole
/// guarantee, and a grep over those four files is how to check it.
/// True for the offscreen copy a quiet read mounts, false for the window the
/// person is looking at.
///
/// A read must not be a write. The pages carry lifecycle work — `.task` loads,
/// `onAppear` state writes — that is right for a page someone opened and wrong
/// for a page nobody opened: `TodayView` clearing the waiting-memories badge is
/// the one that gave this away. Pages honour the flag through `liveTask` /
/// `liveOnAppear`, which are `.task` / `.onAppear` that stay asleep for the
/// offscreen copy.
///
/// A read must also BE a read. Stopping every `.task` left the offscreen copy
/// with nothing on it — Providers came back as its own title on an empty field
/// — so a load that only fetches and assigns runs through `quietReadTask`
/// instead, which does run offscreen and is counted, and the render waits for
/// those loads and gives the host a layout and display pass before it draws.
private struct QuietOffscreenReadKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var quietOffscreenRead: Bool {
        get { self[QuietOffscreenReadKey.self] }
        set { self[QuietOffscreenReadKey.self] = newValue }
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
    /// `.task`, except that it does not run for the offscreen copy a quiet
    /// read mounts. Use it wherever appearing starts work or writes state.
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

    /// `.onAppear`, except that it does not run for a quiet read.
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
    /// Rows returned from one tree read. A page with more says so and truncates
    /// rather than handing the model a transcript-sized wall.
    static let maxTreeRows = 400

    // MARK: - The page, built offscreen

    @ViewBuilder
    static func pageView(for page: QuietPage, appModel: AppModel) -> some View {
        Group {
            switch page.item {
            case .chat: ChatView()
            case .activity: TodayView()
            case .memories: MemoriesRailPage()
            case .desk: DeskPageView()
            case .inboxPolicy: ShellRailPage(title: "Notifications") { InboxSettingsView() }
            case .bots: BotsShelfPreviewPage()
            case .personality: PersonalityRailPage()
            case .providers: ShellRailPage(title: "Providers", wide: true) { ProviderSettingsView() }
            case .trust: TrustRailPage()
            case .connectors: ConnectorsRailPage()
            case .capabilities: ShellRailPage(title: "Capabilities") { CapabilitiesView() }
            case .diagnostics: DiagnosticsRailPage()
            case .settings: SetupView()
            default: EmptyView()
            }
        }
        .environment(appModel)
        // Nobody opened this page. Lifecycle work stays asleep (`liveTask` /
        // `liveOnAppear`), so a read cannot change what the page reports.
        .environment(\.quietOffscreenRead, true)
        .frame(width: defaultSize.width, height: defaultSize.height)
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

    /// Longest a quiet read waits for a page's own read-only loads. A page
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
    /// then is the tree read and the bitmap taken. Before this, both were taken
    /// from a host that had never been through a display pass, which is why a
    /// screenshot came back as a title on an empty page.
    private static func withPreparedHost<T>(
        for page: QuietPage, appModel: AppModel, _ body: (NSHostingView<AnyView>) -> T
    ) async -> T {
        await loadPageData(for: page, appModel: appModel)

        let hosting = NSHostingView(rootView: AnyView(
            pageView(for: page, appModel: appModel)
                // A capture is one moment, so nothing is captured mid-animation.
                .transaction { $0.animation = nil }
        ))
        hosting.frame = CGRect(origin: .zero, size: defaultSize)

        // An unordered window. NSHostingView resolves accessibility and native
        // scroll geometry against a window; this one is created, used, and
        // released without ever being ordered in, made key, or given a level —
        // so it exists for AppKit and for nobody else.
        let host = NSWindow(
            contentRect: CGRect(origin: .zero, size: defaultSize),
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
        // so the tree and the bitmap are of a page that has actually drawn.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    // MARK: - Picture

    /// A PNG of the page, drawn by SwiftUI into a bitmap through the offscreen
    /// host. It does not read the screen, so it needs no screen-recording
    /// grant, works while the app is behind other apps, and cannot capture
    /// anything that is not ours.
    static func pageImagePNG(
        for page: QuietPage, appModel: AppModel
    ) async -> (data: Data, width: Int, height: Int)? {
        await withPreparedHost(for: page, appModel: appModel) { hosting in
            // 1x: a retina page doubles the bytes for detail a model does not read.
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(defaultSize.width), pixelsHigh: Int(defaultSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            bitmap.size = defaultSize
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return (data, bitmap.pixelsWide, bitmap.pixelsHigh)
        }
    }

    // MARK: - Words and state

    /// The page's accessibility tree — the same rows a screen reader would
    /// read, which is also the closest thing the app has to "what the page
    /// says". Read from the same prepared offscreen host the picture comes
    /// from, so the two describe one loaded page and nothing on screen moves.
    static func pageTree(
        for page: QuietPage, appModel: AppModel
    ) async -> (rows: [JSONValue], truncated: Bool) {
        await withPreparedHost(for: page, appModel: appModel) { hosting in
            var rows: [JSONValue] = []
            var truncated = false
            collect(element: hosting, depth: 0, rows: &rows, truncated: &truncated)
            return (rows, truncated)
        }
    }

    private static func collect(
        element: Any, depth: Int, rows: inout [JSONValue], truncated: inout Bool
    ) {
        guard !truncated else { return }
        guard rows.count < maxTreeRows else {
            truncated = true
            return
        }
        // `NSAccessibility` is the protocol every AppKit element answers —
        // real views and the synthetic elements SwiftUI builds alike.
        guard depth <= 24, let node = element as? NSAccessibilityProtocol else { return }

        let role = (node.accessibilityRole()?.rawValue).map(shortRole) ?? ""
        // SwiftUI answers in whichever of these four it happens to fill: a
        // shelf card puts its words in the label, a static text in the value,
        // an AppKit control in the title, and a decorated row only in the help.
        // Taking one of them and stopping was why the Bots page came back as
        // rows with a role and no words at all.
        let label = trimmed(node.accessibilityLabel())
        let title = trimmed(node.accessibilityTitle())
        let help = trimmed(node.accessibilityHelp())
        let value = describe(node.accessibilityValue())

        // A row with no role, no words and no value says nothing; the layout
        // containers SwiftUI builds are mostly these. Its children still count.
        if !(role.isEmpty && label.isEmpty && title.isEmpty && help.isEmpty && value.isEmpty) {
            var row: [String: JSONValue] = ["depth": .int(Int64(depth))]
            if !role.isEmpty { row["role"] = .string(role) }
            let words = [label, title, help].first { !$0.isEmpty } ?? ""
            if !words.isEmpty { row["label"] = .string(bounded(words)) }
            if !value.isEmpty { row["value"] = .string(bounded(value)) }
            // Only worth saying when it is false — everything else is enabled.
            if node.isAccessibilityEnabled() == false {
                row["enabled"] = .bool(false)
            }
            rows.append(.object(row))
        }

        let children = node.accessibilityChildren() ?? []
        guard children.isEmpty else {
            for child in children {
                collect(element: child, depth: depth + 1, rows: &rows, truncated: &truncated)
            }
            return
        }
        // A container that answers the accessibility protocol with no children
        // is not necessarily empty. The Bots shelf came back as one disabled
        // group and nothing else — no title, no cards, no run history — while
        // its real subviews held the whole page; a SwiftUI subtree that has not
        // been asked for by a screen reader can report itself that way offscreen.
        // Where the element IS a view, the view hierarchy is the ground truth,
        // so the walk keeps going down it rather than stopping at the group.
        if let view = element as? NSView {
            for subview in view.subviews {
                // A SwiftUI backing view is usually AX-ignored: asked directly
                // it answers with no role and no words — the eleven "unknown"
                // rows the Bots read came back with. Its unignored descendant
                // IS the element a screen reader would land on, so ask that.
                let reachable = NSAccessibility.unignoredDescendant(of: subview) ?? subview
                collect(element: reachable, depth: depth + 1, rows: &rows, truncated: &truncated)
            }
        }
    }

    /// Plain words over AX constants: "button", not "AXButton".
    private static func shortRole(_ raw: String) -> String {
        raw.hasPrefix("AX") ? String(raw.dropFirst(2)).lowercased() : raw.lowercased()
    }

    private static func trimmed(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let flag as Bool: return flag ? "on" : "off"
        case let number as NSNumber: return number.stringValue
        default: return ""
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

/// Agent, 2026-09-13: `app_page_read(page: bots)` came back as twelve elements,
/// ten of them role "unknown", with no label, value or text on any of them —
/// only the settings block had anything in it. Three passes at the offscreen
/// accessibility tree (unignored descendants, the view hierarchy under an
/// AX-silent group, four attributes instead of one) each moved it a little and
/// none of them made the page READABLE. A SwiftUI subtree nobody has asked for
/// with a screen reader does not have to publish its words, and no amount of
/// walking it changes that.
///
/// So the content half of a page read stops going through the tree. Every rail
/// page has a text PROJECTION built from the same records the page renders —
/// the store rows, the AppModel state, the derived lines the cards print —
/// emitted as `content`. The tree stays, as `elements`, for the rows that do
/// carry words; the projection is what the model reads.
///
/// The rules are the same as everywhere else in a quiet read: main actor, read
/// only, no store the page would not have read itself, and no write of any
/// kind. It runs AFTER `pageTree`, which has already awaited the page's own
/// loaders, so `AppModel` is as fresh as the copy that was just drawn.
extension QuietSelfAdminRender {
    /// One page read: the tree, and the words.
    static func pageRead(
        for page: QuietPage, appModel: AppModel
    ) async -> (rows: [JSONValue], truncated: Bool, content: [JSONValue]) {
        // The tree first: `withPreparedHost` inside it awaits the page's own
        // read-only loaders, so the projection below reads loaded state.
        let tree = await pageTree(for: page, appModel: appModel)
        let content = await pageProjection(for: page, appModel: appModel)
        return (tree.rows, tree.truncated, content)
    }

    /// One section of the projection: a heading and the lines under it.
    private static func section(_ heading: String, _ lines: [String]) -> JSONValue {
        .object([
            "heading": .string(heading),
            "lines": .array(lines.map { .string(bounded($0)) }),
        ])
    }

    private static func proposalLine(_ proposal: MemoryProposalRecord) -> String {
        let text = proposal.display_text ?? proposal.fact_text
        return text.isEmpty ? proposal.fact_text : text
    }

    private static func countLine(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }

    /// The page, in the words of the records it draws from.
    static func pageProjection(for page: QuietPage, appModel: AppModel) async -> [JSONValue] {
        switch page.item {
        case .chat: return await chatProjection(appModel: appModel)
        case .bots: return await botsProjection(appModel: appModel)
        case .activity: return todayProjection(appModel: appModel)
        case .providers: return await providersProjection(appModel: appModel)
        case .trust: return trustProjection(appModel: appModel)
        case .memories: return memoriesProjection(appModel: appModel)
        case .desk: return await deskProjection(appModel: appModel)
        case .inboxPolicy: return notificationsProjection(appModel: appModel)
        case .diagnostics: return diagnosticsProjection(appModel: appModel)
        case .capabilities: return capabilitiesProjection(appModel: appModel)
        case .connectors: return connectorsProjection(appModel: appModel)
        case .personality: return personalityProjection(appModel: appModel)
        case .settings: return settingsProjection(appModel: appModel)
        default: return []
        }
    }

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
        let messages = appModel.chatMessages(for: sessionID)
        let groups = MessageGrouper.groups(
            for: messages,
            sessionId: sessionID,
            structureVersion: appModel.chatMessagesStructureVersion
        )
        var sections: [JSONValue] = [section("Chat", [
            "Conversation: \(sessionID)",
            countLine(messages.count, "message", "messages") + " loaded.",
            // Mood in the tint: the level the glass is actually wearing, so it
            // can be read and driven headless.
            MoodTintProjection.line(),
        ])]

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
                + " in this conversation. interaction_act answers one by its id."]
        ))
        for pair in pairs {
            let descriptor = InlineInteractionResolver.descriptor(
                for: pair.interaction, dataRoot: root
            )
            let card = InlineCardProjection.model(
                pair.interaction, descriptor: descriptor,
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
            if let field = card.field {
                lines.append(
                    "Takes: \(field.label)\(field.isSecret ? " (secret — pass it as `value`)" : "")"
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
             active: (try? BotRunQueue(dataRoot: root).activeOrQueuedIDs()) ?? [])
        }.value
        guard let loaded else {
            return [section("Bots", ["The shelf could not be read."])]
        }
        var sections: [JSONValue] = []
        var header = [countLine(loaded.records.count, "bot", "bots") + " on the shelf."]
        if !unattended { header.append(BotsShelfUnattended.pageLine) }
        sections.append(section("Bots", header))
        for record in loaded.records {
            let state = BotState(record: record, running: loaded.active.contains(record.id))
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

    private static func todayProjection(appModel: AppModel) -> [JSONValue] {
        let pending = appModel.approvals.filter { $0.status.lowercased() == "pending" }
        let waitingNotes = appModel.inboxItems.filter { $0.status == "unread" }
        let proposals = appModel.memoryProposals
        var waiting: [String] = []
        waiting.append(countLine(pending.count, "approval waiting", "approvals waiting"))
        waiting.append(countLine(waitingNotes.count, "unread note", "unread notes"))
        waiting.append(countLine(proposals.count, "memory waiting to be reviewed", "memories waiting to be reviewed"))
        var sections = [section("Waiting on you", waiting)]
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
            let lines: [String] = group.members.map { member in
                let surface = member.surface
                let provider = snapshot.activeProviders[surface] ?? "same as Chat"
                guard let preference = snapshot.preferences[surface] else {
                    return "\(member.label): \(provider) · no model pinned"
                }
                let fast = preference.serviceTier == "priority" ? "Fast on" : "Fast off"
                let think = preference.reasoningEffort.isEmpty ? "no thinking level" : "Think \(preference.reasoningEffort)"
                return "\(member.label): \(provider) · \(preference.model) · \(think) · \(fast)"
            }
            sections.append(section(group.title, lines))
        }
        let accounts = snapshot.providers.map { info -> String in
            let mode = info.auth_mode.map { " via \($0)" } ?? ""
            return "\(info.display_name): \(info.auth_status.state) — \(info.auth_status.detail)\(mode)"
        }
        sections.append(section("Accounts", accounts.isEmpty ? ["No providers listed."] : accounts))
        return sections
    }

    // MARK: Trust

    private static func trustProjection(appModel: AppModel) -> [JSONValue] {
        guard let policy = appModel.trustPolicy else {
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
        return sections
    }

    // MARK: Memories

    private static func memoriesProjection(appModel: AppModel) -> [JSONValue] {
        let memories = appModel.memories
        var head = [MemoriesPageContent.keptLine(memories.count)]
        head.append(countLine(appModel.memoryProposals.count, "proposal waiting", "proposals waiting"))
        head.append(countLine(appModel.graphEntities.count, "thing in the graph", "things in the graph"))
        var sections = [section("Memories", head)]
        if !memories.isEmpty {
            sections.append(section("Kept", memories.prefix(20).map { record in
                let first = record.text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? record.text
                return "\(record.layer): \(first)"
            }))
        }
        if !appModel.memoryProposals.isEmpty {
            sections.append(section("Waiting", appModel.memoryProposals.prefix(12).map(proposalLine)))
        }
        return sections
    }

    // MARK: Desk

    /// The Desk loads its own board too (`refreshForSidebarItem(.desk)` is a
    /// no-op), so the projection takes the same read the page takes.
    private static func deskProjection(appModel: AppModel) async -> [JSONValue] {
        let root = dataRoot(appModel)
        let snapshot = await Task.detached(priority: .userInitiated) {
            await DeskPageSnapshot.load(root: root)
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
            countLine(active.count, "item in play", "items in play"),
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
        let items = appModel.inboxItems
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

    private static func diagnosticsProjection(appModel: AppModel) -> [JSONValue] {
        // The runtime line comes from the PROBE, like the status line does. A
        // failed read leaves `health` on its cached row; printing "online" off
        // that row under a "Health check failed" status is a claim about a
        // reading that never came back.
        let runtime: String
        if appModel.healthProbeFailed {
            runtime = "unknown (last check failed)"
        } else {
            runtime = appModel.health?.ok == true ? "online" : "not reachable"
        }
        var head = ["Runtime: \(runtime)"]
        head.append("Status line: \(appModel.statusText)")
        head.append(countLine(appModel.runs.count, "run recorded", "runs recorded"))
        var sections = [section("Diagnostics", head)]
        if !appModel.runs.isEmpty {
            sections.append(section("Runs", appModel.runs.prefix(15).map { "\($0.id) · \($0.status)" }))
        }
        return sections
    }

    private static func capabilitiesProjection(appModel: AppModel) -> [JSONValue] {
        [section("Capabilities", [
            countLine(appModel.capabilitySummary?.records.count ?? 0, "capability", "capabilities"),
            countLine(appModel.workflows.count, "workflow", "workflows"),
            countLine(appModel.mcpServers.count, "MCP server", "MCP servers"),
            countLine(appModel.nativeActions.count, "action", "actions"),
            countLine(appModel.approvals.filter { $0.status.lowercased() == "pending" }.count,
                      "approval waiting", "approvals waiting"),
        ])]
    }

    private static func connectorsProjection(appModel: AppModel) -> [JSONValue] {
        var sections = [section("Connectors", [
            countLine(appModel.connectors.count, "connector", "connectors"),
            countLine(appModel.workspaces.count, "workspace", "workspaces"),
            "Telegram: \(appModel.telegramStatus?.tokenConfigured == true ? "configured" : "not configured")",
        ])]
        if !appModel.connectors.isEmpty {
            sections.append(section("Connected", appModel.connectors.map {
                "\($0.name)\($0.kind.isEmpty ? "" : " (\($0.kind))"): \($0.enabled ? "on" : "off")"
            }))
        }
        return sections
    }

    private static func personalityProjection(appModel: AppModel) -> [JSONValue] {
        var head: [String] = []
        if let profile = appModel.personality { head.append("Name: \(profile.name)") }
        head.append(countLine(appModel.personalityDocs.count, "document", "documents"))
        var sections = [section("Personality", head)]
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
            "Status line: \(appModel.statusText)",
        ])]
    }
}
