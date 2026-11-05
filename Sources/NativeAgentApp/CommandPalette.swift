import AppToolRuntime
import ChatSessionWork
import NativeAgentCore
import SwiftUI
import AppKit
import NativeAgentShared
import PersistenceCore
import Desk
import StandingBots
import DreamREMCycle
import MemoryV2
// Blueprint: | `CommandPalette.swift` | Mounted command search, navigation and window-scoped key interception; actions remain with canonical owners |

/// Share the palette across pages; Desk injects its own scope instead of maintaining a second implementation.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    var desk: DeskPaletteScope? = nil

    @State private var query: String = ""
    @State private var selection: Int = 0
    @State private var preparedPool: [PaletteItem] = []
    /// Read settings controls once per opening so the palette uses one catalog snapshot.
    @State private var settingThings: [PaletteItem] = []
    @State private var settingsFailure: String?
    @State private var messageHits: [PaletteItem] = []
    /// Bind hits to their exact query so stale results cannot answer newer text.
    @State private var messageHitsQuery = ""
    @State private var messagesIndexed = false
    @State private var indexRevision: UInt64 = 0
    private struct IndexRequest: Equatable {
        var sessions: [ChatSession]
        var revision: UInt64
    }
    private var indexRequest: IndexRequest {
        IndexRequest(sessions: appModel.engine.transcripts.sessions,
                     revision: appModel.engine.transcripts.structureVersion)
    }
    /// Retain unreadable-conversation evidence so missing rows cannot imply a complete search.
    @State private var unreadChats = 0
    @State private var indexRead = LatestRead()
    @State private var matchesRead = LatestRead()
    @State private var hitsRead = LatestRead()
    private struct MatchRequest: Equatable, Sendable {
        let pool: [PaletteItem]
        let query: String
        let confirmed: [PaletteItem]
        let rail: [SidebarItem]
    }
    @State private var matchedRequest: MatchRequest?
    @State private var matches: [PaletteItem] = []
    @State private var pendingCommit = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SurfaceLayoutContent(appModel.engine.layout.availability) { _ in
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(desk == nil ? "Jump to anything…" : "Find anything — or type close, defer or note", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { commitCurrent() }
                    .onChange(of: query) { _, _ in
                        // Reset highlight on query changes so Return selects the top current match.
                        selection = 0
                        pendingCommit = false
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        // Refocus after clearing because the disappearing button would otherwise leave the responder adrift.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            fieldFocused = true
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if let desk, let verb = DeskPaletteQuery.parse(query).verb {
                Text(DeskPalettePresentation.bannerText(
                    for: verb, target: deskTarget(desk), query: DeskPaletteQuery.parse(query).query))
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
            }

            if let error = settingsFailure ?? appModel.engine.transcripts.savedSearchError ?? appModel.engine.cognitionView.diaryError
                ?? appModel.engine.desk.board.deskError {
                Text(error).font(ShellType.label).foregroundStyle(NativeAgentShell.trouble)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            let items = filteredItems()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                // Preserve stable IDs so filtering cannot redirect row content or actions.
                                paletteRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selection = index
                                        commit(item)
                                    }
                                    .onContinuousHover { phase in
                                        // Only real pointer movement changes hover selection; a new row under a stationary pointer must not steal
                                        // Return from the keyboard match.
                                        if commandPaletteShouldAdoptHover(
                                            phase.isActive,
                                            eventType: NSApp.currentEvent?.type
                                        ) {
                                            selection = index
                                        }
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, new in
                        guard new >= 0, new < items.count else { return }
                        withAnimation(NativeAgentMotion.quick) {
                            proxy.scrollTo(items[new].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                paletteHint(symbol: "arrow.up.arrow.down", label: "Navigate")
                paletteHint(symbol: "return", label: "Open")
                paletteHint(symbol: "escape", label: "Close")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")"
                     + (unreadChats > 0 ? " · \(unreadChats) chat\(unreadChats == 1 ? "" : "s") could not be searched" : ""))
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .houseSheet()
        .background(KeyCatcher(
            onMoveUp: { moveSelection(-1) },
            onMoveDown: { moveSelection(1) },
            onEscape: { isPresented = false }
        ))
        .onAppear {
            selection = 0
            // Defer focus one run-loop tick because SwiftUI sheet animation can swallow a synchronous FocusState assignment.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                fieldFocused = true
            }
        }
        .task {
            do { settingThings = try CommandPalettePresentation.settingItems(appModel: appModel) }
            catch { settingsFailure = "Settings could not be read: " + error.localizedDescription + ". Repair the reported source and reopen search." }
            preparePool()
            _ = await appModel.engine.desk.loadBoard()
            await appModel.engine.cognitionView.refreshDiary()
        }
        .onChange(of: appModel.engine.layout.availability) { _, _ in preparePool() }
        .onChange(of: appModel.engine.transcripts.sessions) { _, _ in preparePool() }
        .onChange(of: appModel.engine.desk.board.items) { _, _ in preparePool() }
        .onChange(of: appModel.engine.cognitionView.diary) { _, _ in preparePool() }
        .onChange(of: appModel.engine.transcripts.savedBotReplies.map(\.0)) { _, _ in preparePool() }
        .onChange(of: appModel.engine.transcripts.savedMemories) { _, _ in preparePool() }
        .task {
            await appModel.engine.transcripts.observeSavedSearch(bots: appModel.engine.bots, memory: appModel.engine.memory)
        }
        .task(id: indexRequest) {
            let transcripts = appModel.engine.transcripts
            let sessions = CommandPalettePresentation.visibleSessions(transcripts.sessions)
                .map { (id: $0.id, stamp: CommandPaletteMessageIndex.stamp($0)
                        + "|\(transcripts.structureVersion(for: $0.id))") }
            _ = await indexRead.read({ await transcripts.messageIndex.refresh(sessions, transcripts: transcripts) }, publish: { unread in
                unreadChats = unread
                messagesIndexed = true
                indexRevision &+= 1
            })
            guard !Task.isCancelled else { return }
            try? await transcripts.openingLines.prepare(transcripts.sessions)
        }
        .task(id: matchRequest) {
            guard let request = matchRequest else { return }
            _ = await matchesRead.read({
            await Task.detached(priority: .userInitiated) {
                CommandPalettePresentation.filteredItems(pool: request.pool, query: request.query,
                                                         confirmed: request.confirmed, rail: request.rail)
            }.value
            }, publish: { result in
            matches = result
            matchedRequest = request
            if pendingCommit { pendingCommit = false; commitCurrent() }
            })
        }
        // Debounce full-text search until typing pauses to avoid redundant reads.
        .task(id: "\(messagesIndexed) \(indexRevision) \(query)") {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard messagesIndexed, text.count >= 3 else { hitsRead.write { messageHits = [] }; return }
            _ = await hitsRead.read({
            try? await Task.sleep(for: .milliseconds(150))
            let hits = await appModel.engine.transcripts.messageIndex.search(text)
            let sessions = appModel.engine.transcripts.sessions
            return hits.compactMap { hit -> PaletteItem? in
                guard let session = sessions.first(where: { $0.id == hit.sessionID }) else { return nil }
                return PaletteItem(id: "message.\(hit.sessionID)", title: ChatShellConversationRow.title(for: session),
                                   subtitle: hit.snippet, systemImage: "text.bubble", kind: .chatSession(hit.sessionID))
            }
            }, publish: { hits in
                messageHitsQuery = text
                messageHits = hits
            })
        }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func paletteRow(item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 22)
                .foregroundStyle(NativeAgentShell.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(ShellType.labelMedium)
                    .foregroundStyle(NativeAgentShell.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(kindLabel(item))
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                .fill(isSelected ? NativeAgentShell.softFill : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    private func kindLabel(_ item: PaletteItem) -> String {
        switch item.kind {
        case .tab: return "Page"
        case .railTab: return "Tab"
        case .setting: return "Setting"
        case .chatSession: return "Chat"
        case .recentAction: return "Action"
        case .deskItem(let handle):
            return handle == desk?.selectedHandle ? "Selected" : "Desk"
        case .saved(let destination):
            switch destination {
            case .botReply: return "Bot"
            case .dream: return "Dream"
            case .memory: return "Memory"
            }
        }
    }

    @ViewBuilder
    private func paletteHint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(ShellType.caption)
        .foregroundStyle(NativeAgentShell.secondary)
    }

    // MARK: - Filtering / ranking

    private func filteredItems() -> [PaletteItem] {
        let general = matchedRequest == matchRequest ? matches : []
        guard let desk else {
            return general
        }
        let parsed = DeskPaletteQuery.parse(query)
        // Restrict verbs to applicable rows; an empty query opens on Desk's own rows.
        let rows = deskMatches(desk, parsed).map(PaletteItem.init(desk:))
        if parsed.verb != nil || parsed.query.isEmpty { return rows }
        // Rank Desk's rows first while retaining saved entries so summaries remain searchable.
        let shown = Set(rows.map(\.id))
        return rows + general
            .filter { !shown.contains($0.id) }
    }

    private func preparePool() {
        preparedPool = CommandPalettePresentation.itemPool(
            layout: appModel.engine.layout.availability,
            sessions: appModel.engine.transcripts.sessions,
            settings: settingThings,
            saved: CommandPaletteSavedThings.shared(engine: appModel.engine)
        )
    }

    private var matchRequest: MatchRequest? {
        return MatchRequest(pool: preparedPool, query: query,
                     confirmed: messageHitsQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) ? messageHits : [],
                     rail: CommandPalettePresentation.railItems(appModel.engine.layout.availability))
    }

    private func deskMatches(_ desk: DeskPaletteScope, _ parsed: DeskPaletteQuery) -> [DeskPaletteRow] {
        DeskFuzzy.filter(desk.rows, query: parsed.query)
    }

    /// A bare verb targets the selected Desk row; additional query text targets the highlighted match.
    private func deskTarget(_ desk: DeskPaletteScope) -> DeskPaletteRow? {
        let parsed = DeskPaletteQuery.parse(query)
        return DeskPalettePresentation.target(
            rows: desk.rows,
            matches: deskMatches(desk, parsed),
            selectedHandle: desk.selectedHandle,
            parsed: parsed,
            highlighted: selection
        )
    }

    // MARK: - Commit / navigation

    private func moveSelection(_ delta: Int) {
        let items = filteredItems()
        guard !items.isEmpty else { return }
        let next = (selection + delta).clamped(to: 0...(items.count - 1))
        selection = next
    }

    private func commitCurrent() {
        // Require a named Desk target before dismissal so the person can correct an incomplete query.
        if let desk, DeskPaletteQuery.parse(query).verb != nil {
            guard let target = deskTarget(desk) else { return }
            commit(PaletteItem(desk: target))
            return
        }
        let items = filteredItems()
        if items.isEmpty, matchedRequest != matchRequest { pendingCommit = true; return }
        guard !items.isEmpty else { return }
        let idx = max(0, min(selection, items.count - 1))
        commit(items[idx])
    }

    private func commit(_ item: PaletteItem) {
        if let desk, case .deskItem(let handle) = item.kind,
           desk.rows.contains(where: { $0.handle == handle }) {
            isPresented = false
            if let verb = DeskPaletteQuery.parse(query).verb {
                desk.onCommand(verb, handle)
            } else {
                desk.onSelect(handle)
            }
            return
        }
        switch item.kind {
        case .tab(let s):
            ApplicationLifetime.shared.request(.sidebar(s.normalized))
        case .railTab(let page, let key):
            // Choose the control's tab after routing because the route itself opens the page's first tab.
            SettingsLink.open(page, tab: key)
        case .setting(let pageID, let tab):
            if let page = QuietPages.page(named: pageID) {
                let home = SidebarItem.shellHome(for: page.item)
                SettingsLink.open(home?.parent ?? page.item, tab: tab ?? page.tab ?? home?.tab)
            }
        case .chatSession(let sid):
            if let session = appModel.engine.transcripts.sessions.first(where: { $0.id == sid }) {
                Task { await appModel.selectChatSession(session) }
            }
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case .recentAction(let id):
            handleRecentAction(id)
        case .deskItem(let handle):
            // Use the notification's exact handle so navigation reveals and opens the intended row.
            ApplicationLifetime.shared.request(.sidebar(.desk))
            appModel.pendingDeskHandle = handle
        case .saved(let destination):
            ApplicationLifetime.shared.request(.savedThing(destination))
        }
        isPresented = false
    }

    private func handleRecentAction(_ id: String) {
        guard let action = CommandPaletteRecentAction(rawValue: id) else { return }
        switch action {
        case .newChat:
            Task { await appModel.newChatSession() }
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case .refreshActivity:
            Task { await appModel.refreshForSidebarItem(.activity) }
            ApplicationLifetime.shared.request(.sidebar(.activity))
        case .reloadAll:
            Task { await appModel.refreshAll() }
        }
    }

}

/// Ignore hardware arrow/escape flags while preserving all user-held modifiers.
func commandPaletteIsBareKeyEvent(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.function, .numericPad])
        .isEmpty
}

@MainActor
func commandPaletteShouldAdoptHover(
    _ hovering: Bool,
    eventType: NSEvent.EventType?
) -> Bool {
    guard hovering else { return false }
    switch eventType {
    case .mouseMoved, .leftMouseDragged:
        return true
    default:
        return false
    }
}

private extension HoverPhase {
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Arrow / escape key catcher
// Observe local keys because SwiftUI does not surface focused TextField arrow events.

private struct KeyCatcher: NSViewRepresentable {
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onMoveUp = onMoveUp
        nsView.onMoveDown = onMoveDown
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: KeyCatcherView, coordinator: ()) {
        // Tear down deterministically; window removal or deinit timing cannot reliably release the global key monitor.
        nsView.dismantle()
    }
}

final class KeyCatcherView: NSView {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onEscape: (() -> Void)?

    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            install()
        } else {
            uninstall()
        }
    }

    func dismantle() {
        uninstall()
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Scope interception to the palette's window so a lingering monitor cannot swallow another window's keys.
            let paletteWindow = self.window
            guard event.window === paletteWindow,
                  paletteWindow?.isKeyWindow == true,
                  commandPaletteIsBareKeyEvent(event.modifierFlags) else { return event }
            switch event.keyCode {
            case 126:
                self.onMoveUp?()
                return nil
            case 125:
                self.onMoveDown?()
                return nil
            case 53:
                self.onEscape?()
                return nil
            default:
                return event
            }
        }
    }

    private func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    // Keep monitor teardown on the main actor through both window removal and dismantle.
}
