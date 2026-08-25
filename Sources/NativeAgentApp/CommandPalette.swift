import SwiftUI
import AppKit
import NativeAgentShared

// PATCH-2026-06-06: command-palette — Cmd+K modal that lets the user jump to any
// sidebar tab, any chat session, or any well-known recent action without
// touching the mouse. ContentView owns the sheet binding and the sidebar
// selection (@SceneStorage("selection")); the palette commits a navigation
// through NativeAgentAppCoordinator for navigation, and by calling AppModel
// directly only for the selected chat-session or explicit refresh action.

/// A single match row in the command palette.
struct PaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind

    enum Kind: Hashable {
        case tab(SidebarItem)
        case chatSession(String)         // chat session id
        case recentAction(String)        // recent-action id
    }
}

enum CommandPaletteRecentAction: String, CaseIterable, Sendable {
    case openSkills = "open_skills"
    case openTools = "open_tools"
    case newChat = "new_chat"
    case refreshActivity = "refresh_activity"
    case reloadAll = "reload_all"
    case openDoctor = "open_doctor"

    static func visible(showDeveloperSurfaces: Bool) -> [Self] {
        allCases.filter { showDeveloperSurfaces || !$0.isDeveloperOnly }
    }

    var isDeveloperOnly: Bool { self == .openDoctor }

    var presentation: (title: String, subtitle: String, systemImage: String) {
        switch self {
        case .openSkills:
            ("Skills", "Skills & Tools", "puzzlepiece.extension")
        case .openTools:
            ("Tools", "Skills & Tools", "wrench.and.screwdriver")
        case .newChat:
            ("New chat session", "Start a fresh chat", "plus.bubble")
        case .refreshActivity:
            ("Refresh Activity", "Reload approvals, Inbox, and proposals", "arrow.clockwise")
        case .reloadAll:
            ("Reload all", "Full refreshAll() pass", "arrow.triangle.2.circlepath")
        case .openDoctor:
            ("Open Doctor", "Diagnostics surface", "stethoscope")
        }
    }
}

/// The visible, deterministic projection behind Cmd+K. Keeping this separate
/// from the sheet lets every presentation state use the same exact pool and
/// ranking rules the user interacts with.
enum CommandPalettePresentation {
    static func filteredItems(pool: [PaletteItem], query: String) -> [PaletteItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else {
            return Array(pool.filter {
                if case .tab(let item) = $0.kind { return SidebarItem.primaryItems.contains(item) }
                return false
            }.prefix(8))
        }

        let scored: [(PaletteItem, Int, Int)] = pool.enumerated().compactMap { index, item in
            let title = item.title.lowercased()
            let subtitle = (item.subtitle ?? "").lowercased()
            if title == cleanQuery { return (item, 0, index) }
            if title.hasPrefix(cleanQuery) { return (item, 1, index) }
            if subtitle.hasPrefix(cleanQuery) { return (item, 2, index) }
            if title.contains(cleanQuery) { return (item, 3, index) }
            if subtitle.contains(cleanQuery) { return (item, 4, index) }
            return nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.0)
    }

    static func itemPool(
        sessions: [ChatSession],
        showDeveloperSurfaces: Bool
    ) -> [PaletteItem] {
        let tabCases: [SidebarItem] =
            SidebarItem.primaryItems
            + SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: showDeveloperSurfaces)
            + [.telegram]
        let tabs = tabCases.map { item in
            PaletteItem(
                id: "tab.\(item.rawValue)",
                title: item.displayName,
                subtitle: item == .telegram ? "Settings" : (item.isAdvanced ? "Advanced" : "Primary"),
                systemImage: item.systemImage,
                kind: .tab(item)
            )
        }
        let chats = visibleSessions(sessions).map { session in
            let title = session.displayTitle.isEmpty ? "Untitled chat" : session.displayTitle
            let preview = session.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PaletteItem(
                id: "chat.\(session.id)",
                title: title,
                subtitle: (preview?.isEmpty == false) ? preview : "Chat session",
                systemImage: "bubble.left.and.bubble.right",
                kind: .chatSession(session.id)
            )
        }
        return tabs + chats + CommandPaletteRecentAction.visible(
            showDeveloperSurfaces: showDeveloperSurfaces
        ).map { action in
            let presentation = action.presentation
            return PaletteItem(
                id: "action.\(action.rawValue)",
                title: presentation.title,
                subtitle: presentation.subtitle,
                systemImage: presentation.systemImage,
                kind: .recentAction(action.rawValue)
            )
        }
    }

    static func visibleSessions(_ sessions: [ChatSession]) -> [ChatSession] {
        let ordered = sessions
            .filter { $0.archived != true }
            .sorted {
                let lhsRecency = $0.updatedAt ?? $0.createdAt
                let rhsRecency = $1.updatedAt ?? $1.createdAt
                if lhsRecency != rhsRecency { return lhsRecency > rhsRecency }
                return $0.id < $1.id
            }
        var ids = Set<String>()
        return ordered.filter { ids.insert($0.id).inserted }.prefix(50).map { $0 }
    }
}

/// Cmd+K command palette. Presented as a sheet from ContentView.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var appModel
    // B2.2: keep the gate real — a stranger must not be able to Cmd+K straight
    // to a developer surface (Turn Inspector, MCP, …). Off → those rows are not
    // in the pool at all, matching the hidden sidebar disclosure.
    @AppStorage("showDeveloperSurfaces") private var showDeveloperSurfaces = false
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var selection: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to anything…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { commitCurrent() }
                    .onChange(of: query) { _, _ in
                        // Reset highlight whenever the query changes so the
                        // top match is always the default.
                        selection = 0
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        // Re-focus the field; the cleared button disappears
                        // and the responder would otherwise drift.
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
            .background(.regularMaterial)

            Divider()

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
                                // Row identity must be the ITEM id, never the index:
                                // an explicit .id(index) collides across filter
                                // changes (old row 0 vs new row 0), and LazyVStack
                                // then reuses the dead subtree — stale title AND
                                // stale tap closure (observed: "trust" rendering the
                                // old Chat row, tap navigating to Chat).
                                paletteRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selection = index
                                        commit(item)
                                    }
                                    .onContinuousHover { phase in
                                        // A filtered row can materialize beneath a
                                        // stationary pointer while the user types.
                                        // Treat only real pointer movement as hover
                                        // navigation so Return still opens the top
                                        // keyboard match.
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
                        withAnimation(.linear(duration: 0.08)) {
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
                Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
        .frame(width: 560)
        .background(KeyCatcher(
            onMoveUp: { moveSelection(-1) },
            onMoveDown: { moveSelection(1) },
            onEscape: { isPresented = false }
        ))
        .onAppear {
            selection = 0
            // SwiftUI sheet presentation animation can swallow a synchronous
            // @FocusState assignment on first present, leaving the palette
            // open but un-typeable. Defer one run-loop tick so the responder
            // chain lands after the window is on screen.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                fieldFocused = true
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func paletteRow(item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 22)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer()
            kindBadge(kind: item.kind, isSelected: isSelected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    @ViewBuilder
    private func kindBadge(kind: PaletteItem.Kind, isSelected: Bool) -> some View {
        let label: String = {
            switch kind {
            case .tab: return "Tab"
            case .chatSession: return "Chat"
            case .recentAction: return "Action"
            }
        }()
        Text(label)
            .font(.caption2)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12))
            )
    }

    @ViewBuilder
    private func paletteHint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Filtering / ranking

    private func filteredItems() -> [PaletteItem] {
        CommandPalettePresentation.filteredItems(pool: itemPool(), query: query)
    }

    private func itemPool() -> [PaletteItem] {
        CommandPalettePresentation.itemPool(
            sessions: appModel.chatSessions,
            showDeveloperSurfaces: showDeveloperSurfaces
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
        let items = filteredItems()
        guard !items.isEmpty else { return }
        let idx = max(0, min(selection, items.count - 1))
        commit(items[idx])
    }

    private func commit(_ item: PaletteItem) {
        switch item.kind {
        case .tab(let s):
            if s == .skills {
                NativeAgentAppCoordinator.shared.request(.skillsTools(.skills))
            } else {
                NativeAgentAppCoordinator.shared.request(.sidebar(s.normalized))
            }
        case .chatSession(let sid):
            if let session = appModel.chatSessions.first(where: { $0.id == sid }) {
                Task { await appModel.selectChatSession(session) }
            }
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        case .recentAction(let id):
            handleRecentAction(id)
        }
        isPresented = false
    }

    private func handleRecentAction(_ id: String) {
        guard let action = CommandPaletteRecentAction(rawValue: id) else { return }
        switch action {
        case .openSkills:
            NativeAgentAppCoordinator.shared.request(.skillsTools(.skills))
        case .openTools:
            NativeAgentAppCoordinator.shared.request(.skillsTools(.tools))
        case .newChat:
            Task { await appModel.newChatSession() }
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        case .refreshActivity:
            Task { await appModel.refreshForSidebarItem(.activity) }
            NativeAgentAppCoordinator.shared.request(.sidebar(.activity))
        case .openDoctor:
            NativeAgentAppCoordinator.shared.request(.sidebar(.diagnostics))
        case .reloadAll:
            Task { await appModel.refreshAll() }
        }
    }

}

/// True when a key event carries no USER-HELD modifiers — Cmd/Opt/Shift/Ctrl
/// combos must pass through to the field for text navigation. Arrow keys
/// always carry `.function` and `.numericPad` by hardware convention (Escape
/// carries `.function` on many keyboards), so those two flags are ignored;
/// comparing the raw device-independent mask against "empty" rejects every
/// arrow press ever made.
func commandPaletteIsBareKeyEvent(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection(.deviceIndependentFlagsMask)
        .subtracting([.function, .numericPad])
        .isEmpty
}

/// The executable contract for the palette's AppKit key monitor. Keeping the
/// routing and monitor lifecycle here prevents a local event hook from either
/// consuming keys belonging to another window or lingering after its view is
/// removed.
enum CommandPaletteKeyCatcherMonitor {
    enum KeyAction: Equatable {
        case passThrough
        case moveUp
        case moveDown
        case dismiss
    }

    enum LifecycleAction: Equatable {
        case none
        case install
        case uninstall
    }

    static func lifecycleAction(
        isAttachedToWindow: Bool,
        hasMonitor: Bool
    ) -> LifecycleAction {
        switch (isAttachedToWindow, hasMonitor) {
        case (true, false): return .install
        case (false, true): return .uninstall
        default: return .none
        }
    }

    static func action(
        eventBelongsToPaletteWindow: Bool,
        paletteWindowIsKey: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> KeyAction {
        guard eventBelongsToPaletteWindow,
              paletteWindowIsKey,
              commandPaletteIsBareKeyEvent(modifierFlags) else {
            return .passThrough
        }
        switch keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 53: return .dismiss
        default: return .passThrough
        }
    }
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
// SwiftUI doesn't surface up/down arrow events from a focused TextField, so
// we use an NSViewRepresentable that observes local key events while the
// view is in the window.

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
        // Deterministic teardown — don't rely on viewDidMoveToWindow(nil)
        // or deinit timing to drop the global key monitor.
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
        switch CommandPaletteKeyCatcherMonitor.lifecycleAction(
            isAttachedToWindow: window != nil,
            hasMonitor: monitor != nil
        ) {
        case .install:
            install()
        case .uninstall:
            uninstall()
        case .none:
            break
        }
    }

    func dismantle() {
        uninstall()
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Scope strictly to the palette's own window so we never swallow
            // arrows/escape in another NativeAgent window (or after the sheet
            // has visually dismissed but a stray monitor is still alive).
            let paletteWindow = self.window
            switch CommandPaletteKeyCatcherMonitor.action(
                eventBelongsToPaletteWindow: event.window === paletteWindow,
                paletteWindowIsKey: paletteWindow?.isKeyWindow == true,
                modifierFlags: event.modifierFlags,
                keyCode: event.keyCode
            ) {
            case .moveUp:
                self.onMoveUp?()
                return nil
            case .moveDown:
                self.onMoveDown?()
                return nil
            case .dismiss:
                self.onEscape?()
                return nil
            case .passThrough:
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

    // Note: no deinit fallback — Swift 6 forbids touching the non-Sendable
    // monitor handle from a nonisolated deinit. The two deterministic
    // teardown paths (dismantleNSView from NSViewRepresentable and
    // viewDidMoveToWindow(nil)) both run on the main thread and call
    // uninstall() directly, so we never rely on deinit to drop the monitor.
}
