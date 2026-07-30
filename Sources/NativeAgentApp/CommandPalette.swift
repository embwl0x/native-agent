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
        let pool = itemPool()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            // Empty query → top 8 primary sidebar items.
            return Array(pool.filter {
                if case .tab(let s) = $0.kind { return SidebarItem.primaryItems.contains(s) }
                return false
            }.prefix(8))
        }
        // Preserve original pool index as a stable tie-breaker so equal-score
        // matches don't reshuffle between keystrokes (Swift's sort is not
        // guaranteed stable). Tabs come first in the pool, so a tab title
        // match outranks a same-bucket chat-session or action title match.
        let scored: [(PaletteItem, Int, Int)] = pool.enumerated().compactMap { (idx, item) in
            let title = item.title.lowercased()
            let subtitle = (item.subtitle ?? "").lowercased()
            if title == q { return (item, 0, idx) }
            if title.hasPrefix(q) { return (item, 1, idx) }
            if subtitle.hasPrefix(q) { return (item, 2, idx) }
            if title.contains(q) { return (item, 3, idx) }
            if subtitle.contains(q) { return (item, 4, idx) }
            return nil
        }
        let result = scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.0)
        return result
    }

    private func itemPool() -> [PaletteItem] {
        var pool: [PaletteItem] = []

        // All sidebar tabs (primary + advanced + the routed-only .telegram
        // child surface so it stays discoverable via Cmd+K). Legacy aliases
        // are skipped — they route through `.normalized` already.
        let tabCases: [SidebarItem] =
            SidebarItem.primaryItems
            + SidebarItem.visibleAdvancedItems(developerSurfacesEnabled: showDeveloperSurfaces)
            + [.telegram]
        for s in tabCases {
            pool.append(
                PaletteItem(
                    id: "tab.\(s.rawValue)",
                    title: s.displayName,
                    subtitle: s == .telegram ? "Settings" : (s.isAdvanced ? "Advanced" : "Primary"),
                    systemImage: s.systemImage,
                    kind: .tab(s)
                )
            )
        }

        // All chat sessions (non-archived first, capped at 50).
        let liveSessions = appModel.chatSessions.filter { $0.archived != true }
        for session in liveSessions.prefix(50) {
            let title = session.displayTitle.isEmpty ? "Untitled chat" : session.displayTitle
            let preview = session.lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            pool.append(
                PaletteItem(
                    id: "chat.\(session.id)",
                    title: title,
                    subtitle: (preview?.isEmpty == false) ? preview : "Chat session",
                    systemImage: "bubble.left.and.bubble.right",
                    kind: .chatSession(session.id)
                )
            )
        }

        // Recent / well-known actions. Each id is wired in handleRecentAction.
        var actions: [(String, String, String, String)] = [
            ("open_skills", "Skills", "Skills & Tools", "puzzlepiece.extension"),
            ("open_tools", "Tools", "Skills & Tools", "wrench.and.screwdriver"),
            ("new_chat", "New chat session", "Start a fresh chat", "plus.bubble"),
            ("refresh_activity", "Refresh Activity", "Reload approvals, Inbox, and proposals", "arrow.clockwise"),
            ("reload_all", "Reload all", "Full refreshAll() pass", "arrow.triangle.2.circlepath"),
        ]
        // B2.2 review fix (gpt-5.5 BLOCKING): discoverable actions that jump
        // to a developer-gated surface hide with the gate — same contract as
        // the tab pool above. Explicit deep links still resolve.
        if showDeveloperSurfaces {
            actions.append(("open_doctor", "Open Doctor", "Diagnostics surface", "stethoscope"))
        }
        for (id, title, subtitle, image) in actions {
            pool.append(
                PaletteItem(
                    id: "action.\(id)",
                    title: title,
                    subtitle: subtitle,
                    systemImage: image,
                    kind: .recentAction(id)
                )
            )
        }
        return pool
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
        switch id {
        case "open_skills":
            NativeAgentAppCoordinator.shared.request(.skillsTools(.skills))
        case "open_tools":
            NativeAgentAppCoordinator.shared.request(.skillsTools(.tools))
        case "new_chat":
            Task { await appModel.newChatSession() }
            NativeAgentAppCoordinator.shared.request(.sidebar(.chat))
        case "refresh_activity":
            Task { await appModel.refreshForSidebarItem(.activity) }
            NativeAgentAppCoordinator.shared.request(.sidebar(.activity))
        case "open_doctor":
            NativeAgentAppCoordinator.shared.request(.sidebar(.diagnostics))
        case "reload_all":
            Task { await appModel.refreshAll() }
        default:
            break
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
            // Scope strictly to the palette's own window so we never swallow
            // arrows/escape in another NativeAgent window (or after the sheet
            // has visually dismissed but a stray monitor is still alive).
            guard let paletteWindow = self.window,
                  event.window === paletteWindow,
                  paletteWindow.isKeyWindow else {
                return event
            }
            // Only intercept BARE arrows / escape — no user-held modifiers — so
            // Cmd+Arrow / Shift+Arrow / etc. inside the search field still do
            // their normal text-nav job. See commandPaletteIsBareKeyEvent for
            // the .function/.numericPad hardware-flag trap.
            guard commandPaletteIsBareKeyEvent(event.modifierFlags) else { return event }
            switch event.keyCode {
            case 126: // up arrow
                self.onMoveUp?()
                return nil
            case 125: // down arrow
                self.onMoveDown?()
                return nil
            case 53:  // escape
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

    // Note: no deinit fallback — Swift 6 forbids touching the non-Sendable
    // monitor handle from a nonisolated deinit. The two deterministic
    // teardown paths (dismantleNSView from NSViewRepresentable and
    // viewDidMoveToWindow(nil)) both run on the main thread and call
    // uninstall() directly, so we never rely on deinit to drop the monitor.
}
