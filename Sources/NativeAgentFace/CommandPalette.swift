import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `CommandPalette.swift` | Finished global and Desk search results; mounted keyboard navigation |

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isPresented: Bool
    var desk: DeskPaletteScope? = nil
    @State private var viewID = UUID()
    @State private var query = ""
    @State private var selection: String?
    @State private var issue: String?
    @State private var pendingCommitQuery: String?
    @FocusState private var fieldFocused: Bool
    private struct Reading: Equatable {
        let query: String
        let rows: [PartFace.Row]
        let commands: [DeskCommandRequest]
        let selectedHandle: String?
        let state: FaceReadState?
        let targets: [String: FacePaletteTarget]
    }

    private var palette: PaletteFace? {
        appModel.face.slot(.palette(viewID)).value(as: PaletteFace.self)
    }
    private var deskPalette: DeskPaletteFace? {
        appModel.face.slot(.deskPalette(viewID)).value(as: DeskPaletteFace.self)
    }
    private var rows: [PartFace.Row] {
        if desk != nil {
            guard let value = deskPalette, value.query == query else { return [] }
            return value.rows
        }
        guard let value = palette, value.query == query else { return [] }
        return value.ranks.flatMap { $0 }
    }
    private var readState: FaceReadState? {
        if desk != nil {
            guard let value = deskPalette, value.query == query else { return .waiting(on: "Desk search") }
            return value.state
        }
        guard let value = palette, value.query == query else { return .waiting(on: "search") }
        return value.state
    }
    private var commands: [DeskCommandRequest] {
        guard let value = deskPalette, value.query == query else { return [] }
        return value.commands
    }
    var body: some View {
        let shown = Reading(query: query, rows: rows, commands: commands, selectedHandle: deskPalette?.selectedHandle,
            state: readState, targets: palette?.query == query ? palette?.targets ?? [:] : [:])
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(desk == nil ? "Jump to anything…" : "Find anything — or type close, defer or note", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($fieldFocused)
                    .onSubmit {
                        if shown.state == .ready { commitCurrent(shown) }
                        else { pendingCommitQuery = query }
                    }
                if !query.isEmpty {
                    Button { query = ""; fieldFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear")
                }
            }.padding(14)
            Divider()
            if desk != nil, let command = shown.commands.first {
                Text(commandBanner(command.command, from: shown)).font(ShellType.label).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            FaceReadStatus(state: shown.state).padding(.horizontal, 14)
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled).padding(14) }
            if desk == nil, palette?.query == shown.query, let failures = palette?.sourceFailures {
                ForEach(failures.keys.sorted(), id: \.self) { source in
                    if let failure = failures[source] { Text(failure.localizedDescription).foregroundStyle(.red).padding(.horizontal, 14) }
                }
            }
            if shown.rows.isEmpty, shown.state == .ready {
                Text("No matches in available sources").foregroundStyle(.secondary).padding(36)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.rows, id: \.id) { row in
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(ShellType.labelMedium).lineLimit(1)
                                    if let detail = row.detail { Text(detail).font(ShellType.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer()
                                if let state = row.value { Text(state).font(ShellType.caption).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selection == row.id ? NativeAgentShell.softFill : Color.clear)
                            .contentShape(Rectangle()).id(row.id)
                            .onTapGesture { selection = row.id; commit(row, from: shown) }
                            .onContinuousHover { phase in
                                if commandPaletteShouldAdoptHover(phase.isActive, eventType: NSApp.currentEvent?.type) { selection = row.id }
                            }
                        }
                    }
                }.frame(maxHeight: 360)
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(NativeAgentMotion.quick) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Divider()
            HStack {
                Text("↑↓ Navigate   ↩ Open   Esc Close")
                Spacer()
                Text("\(shown.rows.count) results")
            }.font(ShellType.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(width: 560).houseSheet()
        .background(KeyCatcher(onMoveUp: { move(-1, in: shown.rows) }, onMoveDown: { move(1, in: shown.rows) }, onEscape: { isPresented = false }))
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selection = nil; issue = nil; pendingCommitQuery = nil }
        .onChange(of: shown) { _, value in
            if pendingCommitQuery == value.query, value.state == .ready {
                pendingCommitQuery = nil
                commitCurrent(value)
            }
        }
        .modifier(FaceObservation(demand: desk == nil
            ? .palette(view: viewID, query: query) : .deskPalette(view: viewID, query: query)))
    }

    private func move(_ delta: Int, in rows: [PartFace.Row]) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection }
        let next = min(max((current ?? (delta > 0 ? -1 : 1)) + delta, 0), rows.count - 1)
        selection = rows[next].id
    }

    private func verbOnly(_ shown: Reading) -> Bool {
        guard let command = shown.commands.first else { return false }
        return shown.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == command.command
    }

    private func commitCurrent(_ shown: Reading) {
        guard shown.state == .ready, shown.query == query else { issue = "Read the current search before choosing a result."; return }
        if desk != nil, verbOnly(shown) {
            guard let handle = shown.selectedHandle, let row = shown.rows.first(where: { $0.id == handle }) else {
                issue = "Select the Desk item before submitting this command."
                return
            }
            commit(row, from: shown)
            return
        }
        if let row = shown.rows.first(where: { $0.id == selection }) ?? shown.rows.first { commit(row, from: shown) }
    }

    private func commit(_ row: PartFace.Row, from shown: Reading) {
        guard shown.state == .ready, shown.query == query else { issue = "Read the current search before choosing a result."; return }
        if let desk {
            if let command = shown.commands.first(where: { $0.handle == row.id }) {
                desk.onCommand(command)
            } else {
                desk.onSelect(row.id)
            }
            isPresented = false
            return
        }
        Task {
            do {
                guard let target = shown.targets[row.id] else {
                    throw PartCallError(code: "palette_destination_missing", message: "This search row has no supplied destination.")
                }
                try await open(target)
                isPresented = false
            } catch { issue = error.localizedDescription }
        }
    }

    private func open(_ target: FacePaletteTarget) async throws {
        switch target {
        case .page(let raw):
            guard let page = SidebarItem(rawValue: raw) else { throw missingPage(raw) }
            ApplicationLifetime.shared.request(.sidebar(page))
        case .tab(let raw, let tab):
            guard let page = SidebarItem(rawValue: raw) else { throw missingPage(raw) }
            try await SettingsLink.openChecked(page, tab: tab, appModel: appModel)
        case .setting(let raw, let tab):
            guard let page = QuietPages.page(named: raw) else { throw missingPage(raw) }
            let home = SidebarItem.shellHome(for: page.item)
            try await SettingsLink.openChecked(home?.parent ?? page.item, tab: tab ?? home?.tab, appModel: appModel)
        case .conversation(let id):
            try await MacFaceLinks.follow(.init(page: "chat", item: nil, session: id, message: nil), appModel: appModel)
        case .newConversation:
            let selection = UUID()
            appModel.chatSelectionGeneration = selection
            let session = try appModel.acceptedConversation(try await appModel.chatAct(.createConversation))
            guard appModel.chatSelectionGeneration == selection else {
                throw WireFailure(code: "palette_selection_changed", message: "The new conversation was created; your newer selection is preserved.",
                    cause: nil, effects: .known)
            }
            appModel.commitChatSessionSelection(session)
            ApplicationLifetime.shared.request(.sidebar(.chat))
        case .refresh(let scope):
            try FaceWindowReply.check(await appModel.client.act(.refresh(scope)))
            if scope == .panel(SidebarItem.activity.rawValue) { ApplicationLifetime.shared.request(.sidebar(.activity)) }
        case .desk(let handle):
            try FaceWindowReply.check(await appModel.client.act(.deskCommand(.init(command: "open", handle: handle, arguments: [:]))))
            ApplicationLifetime.shared.request(.sidebar(.desk))
        case .memory(let id): ApplicationLifetime.shared.request(.savedThing(.memory(id)))
        case .dream(let date): ApplicationLifetime.shared.request(.savedThing(.dream(date)))
        case .helperResult(let bot, let entry): ApplicationLifetime.shared.request(.savedThing(.botReply(botID: bot, entryID: entry)))
        }
    }

    private func missingPage(_ name: String) -> PartCallError {
        .init(code: "palette_page_unavailable", message: "This search destination is absent from the window: " + name)
    }

    private func commandBanner(_ command: String, from shown: Reading) -> String {
        let target: PartFace.Row?
        if verbOnly(shown) { target = shown.rows.first { $0.id == shown.selectedHandle } }
        else { target = shown.rows.first { $0.id == selection } ?? shown.rows.first }
        guard let target else { return "Select the Desk item before submitting this command, or type part of its title." }
        switch command {
        case "close": return "Enter closes “" + target.title + "”."
        case "defer": return "Enter selects “" + target.title + "” and opens its park choices."
        case "note": return "Enter selects “" + target.title + "” and opens the note editor."
        default: return "This command is not recognized."
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
