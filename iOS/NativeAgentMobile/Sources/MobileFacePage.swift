import SwiftUI
import CoreGraphics
import Foundation
import NativeAgentShared
import Observation
// Blueprint: | `MobileFacePage.swift` | Phone page rows, shared Table canvas and sheet editor, signed document demands and retained action outcomes |

extension FaceActOutcome {
    /// Pre-dispatch refusals have no effects; a terminal response must carry its owner's effect evidence.
    static func phoneFailure(_ error: any Error) -> Self {
        guard let sync = error as? SyncError else { return .interrupted(error) }
        let effects: FaceEffects
        switch sync {
        case .notSetup, .notSigned, .busy, .sendFailed: effects = .none
        case .macRejected, .unsupported, .responseUnconfirmed, .persistence, .approvalRequired: return .interrupted(error)
        }
        return .init(failure: .init(code: "phone_action_refused", message: sync.localizedDescription, cause: nil, effects: effects), effects: effects)
    }
}

/// Where a link leads inside the page's own stack: another faced page, or a saved run's detail.
enum FaceDestination: Hashable {
    case page(String)
    case table([String]?)
    case run(String)
    case document(page: String, item: String)
    case item(page: String, item: String)

    /// The link's place in this stack, when the phone holds it.
    @MainActor init?(_ link: String) {
        guard case .page(let page, let item)? = FaceLink(link) else { return nil }
        let sync = iCloudSyncEngine.shared
        if page == "today", item == "inbox" || item == "approvals" {
            self = .page("inbox")
        } else if page == "diagnostics", item == nil {
            return nil
        } else if let item, page == "diagnostics", sync.runs.contains(where: { $0.id == item }) {
            self = .run(item)
        } else if let item, Self.isDocument(page: page, item: item, sync: sync) {
            self = .document(page: page, item: item)
        } else if let item, sync.faces[page] != nil {
            self = .item(page: page, item: item)
        } else if item == nil, sync.faces[page] != nil {
            self = .page(page)
        } else {
            return nil
        }
    }

    @MainActor private static func isDocument(page: String, item: String, sync: iCloudSyncEngine) -> Bool {
        if ["capabilities", "connectors", "diagnostics"].contains(page) { return true }
        if page == "memories", let target = MemoriesFaceTarget(row: item) {
            switch target {
            case .memory, .rejected: return true
            case .graph, .upkeep: return false
            }
        }
        return sync.faces[page]?.face?.sections.compactMap(\.block).contains { $0.key == item } == true
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .page(let page): MobileFacePage(page: page)
        case .table(let ids): MobileTablePage(ids: ids)
        case .run(let id):
            if let run = iCloudSyncEngine.shared.runs.first(where: { $0.id == id }) { RunDetailView(run: run) }
        case .document(let page, let item):
            MobileDocumentPage(identity: [page, item], subject: .pageItem(page: page, item: item), title: item)
        case .item(let page, let item): MobileDemandFacePage(page: page, item: item)
        }
    }
}

/// The shell's places for a face's links: Chat, Today and its queues, the Desk, a card, the browser. Answers the words for a place the
/// phone does not have.
struct FaceRouter {
    var follow: (String) -> String?
}

extension EnvironmentValues {
    @Entry var faceRouter = FaceRouter { _ in "This opens on your Mac." }
}

/// A faced page pushed on its own: its title and sentence in the phone's header, its face below.
struct MobileFacePage: View {
    let page: String
    /// A tab's root page draws the root header; a pushed one the pushed header.
    var style: AlivePageStyle = .pushed
    var openToday: (() -> Void)? = nil
    @State private var pushed: FaceDestination?
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        let face = sync.faces[page]?.face
        let title = openToday == nil ? (face?.title ?? QuietToolPage.page(named: page)?.title ?? page)
            : ShellSurface.desk.title(agentName: "", simple: true)
        AlivePage(title: title, line: face?.line, style: style) {
            if let openToday { Button("Today", systemImage: "sun.max", action: openToday) }
        } content: {
            MobileFaceRows(page: page) { pushed = $0 }
            if openToday != nil {
                Section {
                    NavigationLink("Helpers") { MobileFacePage(page: "bots") }
                }
            }
        }
        .navigationDestination(item: $pushed) { $0.view }
        .refreshable {
            _ = await sync.refreshSnapshotGroup(.faces)
            switch page {
            case "desk": _ = await sync.refreshSnapshotGroup(.desk)
            case "inbox", "today": _ = await sync.refreshSnapshotGroup(.activity)
            default: break
            }
        }
    }
}

/// The shared renderer holds pending work and failures beside the row; accepted work survives navigation.
struct MobileFaceRows: View {
    let page: String
    let push: (FaceDestination) -> Void
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page(page) }

    private var title: String { QuietToolPage.page(named: page)?.title ?? page }

    var body: some View {
        Group {
            if let snapshot = sync.faces[page] {
                FaceView(snapshot: snapshot, title: title, header: false, door: door, session: session, leaf: { leaf($0) }).id(page)
                    .onAppear { session.notice = { SystemToastCenter.shared.push(success: $0) } }
            } else {
                note(title + " has not arrived from your Mac yet.")
            }
        }
    }

    private func leaf(_ block: PartFace.Block) -> AnyView {
        if block.isTableSlice { return AnyView(MobileTableSlice(block: block, push: push)) }
        guard page == "desk", block.isStandingTable else {
            return AnyView(note(block.alt ?? PartFace.Block.updateNote))
        }
        return MobileDeskBoard.drawing(block, unavailable: "This table revision’s drawing is unavailable.") { document, table in
            MobileDeskBoard(document: document, table: table, push: push)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(AlivePalette.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ link: String) {
        if let destination = FaceDestination(link) { push(destination) }
        else if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page, open: open)
    }
}

private struct MobileTableSlice: View {
    let block: PartFace.Block
    let push: (FaceDestination) -> Void
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    var body: some View {
        MobileDeskBoard.drawing(MobileDeskBoard.standingTable, unavailable: block.alt ?? PartFace.Block.updateNote) { document, table in
            BoardSliceView(document: document, cards: table.cards ?? [:], ids: block.ids,
                           textScale: textScale, palette: MobileDeskBoard.palette(textScale: textScale)) {
                push(.table(block.ids))
            }
        }
    }
}

private struct MobileTablePage: View {
    let ids: [String]?
    @State private var overview = false
    @State private var pushed: FaceDestination?

    var body: some View {
        AlivePage(title: "The table") {
            MobileDeskBoard.drawing(MobileDeskBoard.standingTable, unavailable: "This table revision’s drawing is unavailable.") { document, table in
                MobileDeskBoard(document: document, table: table, focus: overview ? nil : ids) { pushed = $0 }
                if ids != nil, !overview { Button("Show the whole table") { overview = true } }
            }
        }
        .navigationDestination(item: $pushed) { $0.view }
    }
}

private struct MobileDeskBoard: View {
    let document: BoardDocument
    let table: PartFace.Block
    var focus: [String]? = nil
    let push: (FaceDestination) -> Void
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @State private var camera: BoardCamera?
    @State private var chosen: String?
    @State private var connectFrom: String?
    @State private var tool: TableBoardTool = .select
    @State private var viewer = UUID()
    @State private var showingNote = false
    @FocusState private var focused: Bool

    private struct Note {
        let id: String
        let opening: String
        let newFields: [String: PartFace.Value]?
        var draft: String
    }

    private struct PendingEdit {
        let messageID: String
        var answered: Bool
        let edit: TableElementEdit
        let revision: Int
        let crossing: BoardDocument.Element?
        let earlierIssues: [String]
        let unsent: [String]
        let earlierEffects: FaceEffects

        func matches(_ table: PartFace.Block) throws -> Bool {
            guard let text = table.text, let version = table.revision.flatMap(Int.init), version >= revision else { return false }
            let element = try BoardDocument(text).element(edit.id)
            switch edit.verb {
            case .put:
                guard version > revision, let element else { return false }
                return edit.fields.allSatisfy { element.fields[$0.key] == $0.value }
            case .remove: return version > revision && element == nil
            case .cross:
                guard let crossing, let element, crossing.string("item") == element.string("item") else { return false }
                if crossing.string("item") != nil {
                    guard case .object(let facts)? = table.cards?[edit.id] else { return false }
                    return element.fields["crossed"] != .bool(true) && facts["crossed"] == .bool(true)
                }
                return version > revision && (element.fields["crossed"] == .bool(true)) != (crossing.fields["crossed"] == .bool(true))
            }
        }
    }

    private static let noteKey = "[table-note]"
    private static let versionKey = "[table-version]"
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page("desk") }
    private var operations: [FacePageSession.Operation] {
        session.operations.values.filter { $0.item.section == "[table]" }.sorted { $0.item.row < $1.item.row }
    }
    private func pending(_ item: FaceItemID) -> PendingEdit? { session.drafts.value(item.row, seed: nil as PendingEdit?) }
    private var locked: Set<String> { Set(operations.compactMap { pending($0.item)?.edit.id }) }
    private var note: Note? {
        get { session.drafts.value(Self.noteKey, seed: nil as Note?) }
        nonmutating set {
            if let newValue { session.drafts.set(newValue, for: Self.noteKey) }
            else { session.drafts.clear(Self.noteKey) }
        }
    }

    private var cards: [String: PartFace.Value] { table.cards ?? [:] }
    private var geometry: BoardGeometry { BoardGeometry(cards: cards, textScale: textScale) }
    private var version: Int? { table.revision.flatMap(Int.init) }
    private var awaiting: Int { session.drafts.value(Self.versionKey, seed: -1) }
    private var sending: Bool { operations.contains { $0.outcome == nil } }
    private var changeable: Bool {
        version != nil && !sending && awaiting <= (version ?? -1) && !operations.contains { pending($0.item)?.answered == false }
    }

    static var standingTable: PartFace.Block? {
        iCloudSyncEngine.shared.faces["desk"]?.drawnFace?.sections.compactMap(\.block).first(where: \.isStandingTable)
    }

    static func drawing<Content: View>(_ table: PartFace.Block?, unavailable: String,
                                       @ViewBuilder content: (BoardDocument, PartFace.Block) -> Content) -> AnyView {
        func note(_ words: String) -> AnyView {
            AnyView(Text(words).font(.callout).foregroundStyle(AlivePalette.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true))
        }
        guard let table, let text = table.text else { return note(unavailable) }
        do { return AnyView(content(try BoardDocument(text), table)) }
        catch { return note("The table drawing could not be read: " + error.localizedDescription) }
    }

    static func palette(textScale: CGFloat) -> BoardPainter.Palette {
        BoardPainter.Palette(fill: { Self.ink($0).opacity(0.16) }, words: { _, _ in .primary },
            line: Self.ink, cardFill: AlivePalette.room, cardStroke: AlivePalette.divider, caption: .system(size: 11 * textScale))
    }

    var body: some View {
        let geometry = self.geometry
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { bounds in
                let size = bounds.size
                let target = geometry.slice(document, ids: focus)
                let camera = self.camera ?? geometry.fit(target, in: size, minimumScale: 0)
                ZStack(alignment: .topLeading) {
                    SharedBoardCanvasView(document: document, cards: cards, geometry: geometry,
                        palette: Self.palette(textScale: textScale), table: true, changeable: changeable && note == nil,
                        camera: camera, size: size, placementSize: size, cameraOverride: $camera,
                        tool: $tool, chosen: $chosen, connectFrom: $connectFrom, focus: $focused,
                        locked: locked, edit: commit, canOpen: canOpen, open: open, writeNote: { editNote($0, adding: true) })
                    tools(camera: camera, size: size, geometry: geometry).padding(8)
                    if let element = chosen.flatMap(document.element) {
                        elementActions(element)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(8)
                    }
                }
            }
            .frame(height: 340)
            .background(AlivePalette.room, in: RoundedRectangle(cornerRadius: AliveMetrics.cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: AliveMetrics.cardRadius))
            if note != nil { Button("Open note draft") { showingNote = true } }
            editStatus
        }
        .onAppear { session.attach(viewer) }
        .onDisappear { session.detach(viewer) }
        .onChange(of: focus) { _, _ in camera = nil }
        .onChange(of: version, initial: true) { _, version in
            if awaiting >= 0, let version, version >= awaiting { session.drafts.clear(Self.versionKey) }
            if let chosen, document.element(chosen) == nil, note == nil { self.chosen = nil }
            if let connectFrom, document.element(connectFrom) == nil { self.connectFrom = nil }
        }
        .onChange(of: note?.id) { _, id in
            if id == nil { showingNote = false }
        }
        .sheet(isPresented: $showingNote, onDismiss: { focused = true }) {
            if let note { noteEditor(note) }
        }
    }

    private func noteEditor(_ note: Note) -> some View {
        let draft = Binding(get: { self.note?.draft ?? note.draft }, set: { words in
            guard var current = self.note, current.id == note.id else { return }
            current.draft = words
            self.note = current
        })
        return NavigationStack {
            TextEditor(text: draft)
                .disabled(sending || locked.contains(note.id))
                .accessibilityLabel("Note text")
                .padding()
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading) {
                        if draft.wrappedValue.count > 2_000 {
                            Text("Table notes can have up to 2,000 characters.").font(.callout)
                        }
                        ForEach(operations.filter { $0.submission.value == note.id }, id: \.item) { editStatus($0) }
                    }
                    .padding(.horizontal)
                }
                .navigationTitle("Table note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.note = nil }.disabled(sending) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(note) }
                            .disabled(!changeable || locked.contains(note.id) || draft.wrappedValue == note.opening || draft.wrappedValue.count > 2_000
                                || (note.newFields != nil && draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
        }
    }

    @ViewBuilder private var editStatus: some View {
        ForEach(operations, id: \.item) { editStatus($0) }
        if awaiting > (version ?? -1) {
            Text("Waiting for the Mac’s table").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func editStatus(_ operation: FacePageSession.Operation) -> some View {
        if operation.outcome == nil || operation.checking {
            Button(operation.cancelling ? "Cancelling wait…" : "Cancel waiting") { session.cancel(operation.item) }
                .disabled(operation.cancelling)
        } else if operation.outcome?.unresolved == true, let pending = pending(operation.item) {
            Button(pending.answered ? "Check table" : "Resume waiting") {
                let session = self.session
                session.check(operation.item, door: ClosureFaceDoor(open: { _ in }) {
                    await Self.checkReply(pending, key: operation.item.row, in: session, noteID: $0.value)
                })
            }
            if pending.answered, let draft = pending.edit.fields["text"]?.stringValue {
                Text(draft).textSelection(.enabled)
            }
        }
        if let issue = operation.outcome?.failure?.message {
            Text(issue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func tools(camera: BoardCamera, size: CGSize, geometry: BoardGeometry) -> some View {
        HStack(spacing: 0) {
            ForEach([TableBoardTool.select, .note, .pen, .connect], id: \.self) { option in
                Button { tool = tool == option ? .select : option; focused = true } label: {
                    toolLabel(option.rawValue, systemImage: option.symbol)
                        .background(tool == option ? Color.primary.opacity(0.13) : .clear, in: Circle())
                }.disabled(!changeable || note != nil)
            }
            if let choices = table.choices, !choices.isEmpty {
                Menu {
                    ForEach(choices.indices, id: \.self) { index in
                        let choice = choices[index]
                        if let label = choice["label"]?.stringValue {
                            Button(label) {
                                guard let edit = SharedBoardCanvasView.linkedCard(choice, camera: camera, size: size,
                                                                                   document: document, geometry: geometry) else { return }
                                self.camera = camera
                                tool = .select
                                commit([edit])
                            }
                        }
                    }
                } label: { toolLabel("Card", systemImage: TableBoardTool.card.symbol) }
                    .disabled(!changeable || note != nil)
            }
            Button { self.camera = nil } label: { toolLabel("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
    }

    private func elementActions(_ element: BoardDocument.Element) -> some View {
        HStack(spacing: 0) {
            if canOpen(element) {
                Button { open(element) } label: { toolLabel("Open", systemImage: "arrow.up.forward.square") }
            }
            Button { commit([.init(.cross, element.id)]) } label: {
                toolLabel("Cross off", systemImage: "checkmark")
            }
            Button(role: .destructive) {
                chosen = nil
                if connectFrom == element.id { connectFrom = nil }
                commit([.init(.remove, element.id)])
            } label: { toolLabel("Remove", systemImage: "trash") }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .disabled(!changeable || note != nil || locked.contains(element.id))
    }

    private func toolLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).accessibilityLabel(Text(title))
    }

    private func canOpen(_ element: BoardDocument.Element) -> Bool {
        let facts = geometry.cardFacts(element)
        if facts["alias"]?.stringValue != nil { return true }
        return facts["title"] == nil && ["shape", "text", "container"].contains(element.type)
    }

    private func open(_ element: BoardDocument.Element) {
        if let item = geometry.cardFacts(element)["alias"]?.stringValue { push(.item(page: "desk", item: item)) }
        else { editNote(element, adding: false) }
    }

    private func editNote(_ element: BoardDocument.Element, adding: Bool) {
        guard note == nil, !locked.contains(element.id) else { return }
        let opening = element.string("text") ?? ""
        note = Note(id: element.id, opening: opening,
            newFields: adding ? element.fields.filter { $0.key != "id" } : nil, draft: opening)
        showingNote = true
    }

    private func save(_ note: Note) {
        guard let current = self.note, current.id == note.id else { return }
        var fields = note.newFields ?? [:]
        fields["text"] = .string(current.draft)
        commit([.init(.put, note.id, fields)], note: current)
    }

    private func commit(_ edits: [TableElementEdit]) { commit(edits, note: nil) }

    private func commit(_ edits: [TableElementEdit], note: Note?) {
        let ids = edits.map(\.id)
        guard changeable, let version, let first = edits.first, locked.isDisjoint(with: ids) else { return }
        let session = self.session
        let item = FaceItemID(section: "[table]", row: "[table-edit]" + ids.joined(separator: ","))
        let crossing = first.verb == .cross ? document.element(first.id) : nil
        let door = ClosureFaceDoor(open: { _ in }) { _ in
            await Self.send(edits, note: note, key: item.row, revision: version, crossing: crossing, in: session)
        }
        let action = first.verb.rawValue
        session.submit(item, row: item.row, action: action, value: note?.id,
                       call: .init(action, first.arguments), door: door)
    }

    private static func send(_ edits: [TableElementEdit], note: Note?, key: String, revision: Int, crossing: BoardDocument.Element?,
                             in session: FacePageSession) async -> FaceActOutcome {
        let sync = iCloudSyncEngine.shared
        var issues: [String] = []
        var effects: FaceEffects = .none
        for (index, edit) in edits.enumerated() {
            if Task.isCancelled {
                issues += unsentWords(edits[index...].map(\.id))
                break
            }
            var messageID: String?
            var answered = false
            do {
                let opening = note.flatMap { $0.newFields == nil ? $0.opening : nil }
                let id = try await sync.sendTableEdit(edit, openingText: opening) { messageID = $0 }
                messageID = id
                let response = try await sync.awaitResponse(msgId: id, expectedAction: edit.verb.rawValue)
                answered = true
                retainVersion(try sync.tableEditVersion(response), in: session)
                effects = .known
            } catch {
                let words = error is CancellationError ? "Stopped waiting for the Mac’s reply."
                    : TurnSecretRedactor.redactDisplayText(error.localizedDescription)
                if let refusal = error as? WireFailure, refusal.effects == .none {
                    issues.append("\(edit.id): \(words)")
                    continue
                }
                let unsent = edits.dropFirst(index + 1).map(\.id)
                if let messageID, (error as? WireFailure)?.effects != .known {
                    session.drafts.set(PendingEdit(messageID: messageID, answered: answered, edit: edit, revision: revision, crossing: crossing,
                        earlierIssues: issues, unsent: unsent, earlierEffects: effects), for: key)
                    if answered, note != nil { session.drafts.clear(noteKey) }
                    return outcome(issues + ["\(edit.id): \(words)"] + unsentWords(unsent), effects: .unknown)
                }
                issues += ["\(edit.id): \(words)"] + unsentWords(unsent)
                if (error as? WireFailure)?.effects == .known { effects = .known }
                break
            }
        }
        if issues.isEmpty, note != nil { session.drafts.clear(noteKey) }
        if effects == .known, !Task.isCancelled { _ = await sync.refreshFacesSnapshot() }
        return outcome(issues, effects: effects)
    }

    private static func checkReply(_ original: PendingEdit, key: String, in session: FacePageSession, noteID: String?) async -> FaceActOutcome {
        var pending = original
        let sync = iCloudSyncEngine.shared
        var issues = pending.earlierIssues
        var effects = pending.earlierEffects
        do {
            if !pending.answered {
                let response = try await sync.awaitResponse(msgId: pending.messageID, expectedAction: pending.edit.verb.rawValue)
                pending.answered = true
                session.drafts.set(pending, for: key)
                retainVersion(try sync.tableEditVersion(response), in: session)
            } else {
                guard await sync.refreshFacesSnapshot(), let table = standingTable, try pending.matches(table) else {
                    return outcome(issues + ["\(pending.edit.id): The committed table has not confirmed the requested change."]
                        + unsentWords(pending.unsent), effects: .unknown)
                }
                try await sync.retirePendingCloudKitAction(msgId: pending.messageID)
            }
            if let noteID, session.drafts.value(noteKey, seed: nil as Note?)?.id == noteID { session.drafts.clear(noteKey) }
            effects = .known
        } catch let refusal as WireFailure where refusal.effects != .unknown {
            issues.append("\(pending.edit.id): \(TurnSecretRedactor.redactDisplayText(refusal.message))")
            if refusal.effects == .known { effects = .known }
        } catch {
            let words = error is CancellationError ? "Stopped waiting for the Mac’s reply."
                : TurnSecretRedactor.redactDisplayText(error.localizedDescription)
            if pending.answered, let noteID,
               session.drafts.value(noteKey, seed: nil as Note?)?.id == noteID { session.drafts.clear(noteKey) }
            return outcome(issues + ["\(pending.edit.id): \(words)"] + unsentWords(pending.unsent), effects: .unknown)
        }
        if !original.answered, effects == .known, !Task.isCancelled { _ = await sync.refreshFacesSnapshot() }
        session.drafts.clear(key)
        let settled = outcome(issues + unsentWords(pending.unsent), effects: effects)
        return .init(failure: settled.failure, effects: effects, accepted: true)
    }

    private static func retainVersion(_ version: Int?, in session: FacePageSession) {
        guard let version, version > (standingTable?.revision.flatMap(Int.init) ?? -1),
              version > session.drafts.value(versionKey, seed: -1) else { return }
        session.drafts.set(version, for: versionKey)
    }

    private static func unsentWords(_ ids: [String]) -> [String] {
        ids.isEmpty ? [] : ["Not submitted: \(ids.joined(separator: ", "))."]
    }

    private static func outcome(_ issues: [String], effects: FaceEffects) -> FaceActOutcome {
        let failure = issues.isEmpty ? nil : WireFailure(code: "table_edit", message: issues.joined(separator: "\n"), cause: nil, effects: effects)
        return .init(failure: failure, effects: effects, accepted: failure == nil)
    }

    nonisolated private static func ink(_ color: String?) -> Color {
        switch color {
        case "green": .green
        case "yellow": .yellow
        case "purple": .purple
        case "blue": .blue
        case "peach", "terracotta": .orange
        case "white": .gray
        default: .primary
        }
    }
}

/// One row of a page's face standing alone: a matter's card in a conversation is its Inbox row. The same FaceView draws it and a tap
/// goes to the page's owner on the Mac, as on the page itself; every link goes to the shell's router.
struct MobileFaceRow: View {
    let page: String
    let row: PartFace.Row
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared
    private var session: FacePageSession { sync.pageSessions.page(page) }

    var body: some View {
        FaceView(face: PartFace(sections: [.init(id: row.id, style: .list, rows: [row])]), door: door, session: session)
            .id(page + "/" + row.id)
            .buttonStyle(.borderless).pickerStyle(.menu)
            .faceList(false)
            .phoneFaceStyle()
            .onAppear { session.notice = { SystemToastCenter.shared.push(success: $0) } }
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page, open: { link in
            if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
        })
    }
}

struct MobileDocumentPage<Identity: Hashable>: View {
    let identity: Identity
    let subject: DocumentSubject
    let title: String
    var body: some View {
        AlivePage(title: title, style: .pushed) {
            FaceDocumentReader(identity: identity, cancellationLabel: "Cancel waiting", waitingOn: "your Mac", presentation: { request in
                try await iCloudSyncEngine.shared.faceReadPresentation(.init(id: request.id, subject: subject, textOnly: true))
            })
        }
    }
}

@MainActor private enum MobileRemoteFaceDoor {
    static func make(page: String, open: @escaping (String) -> Void) -> ClosureFaceDoor {
        let sync = iCloudSyncEngine.shared
        return ClosureFaceDoor(open: open, cancellationLabel: "Cancel waiting", waitingOn: "your Mac", read: { request in
            try await sync.faceRead(.init(id: request.id, subject: .pageItem(page: page, item: request.key),
                                         expectedCall: request.expectedCall, textOnly: true))
        }, pageRead: { try await sync.faceReadFace(page: page, request: $0) }, releaseFace: { request in
            do { try await sync.releaseFaceRead(page: page, request: request) }
            catch { sync.syncError = "The Mac page demand could not be released: " + TurnSecretRedactor.redactDisplayText(error.localizedDescription) }
        }, scope: { item in make(page: page + "/" + item, open: open) },
           perform: { await sync.faceOutcome(page: page, submission: $0) })
    }
}

private struct MobileDemandFacePage: View {
    let page: String
    let item: String
    @State private var pushed: FaceDestination?
    @Environment(\.faceRouter) private var router
    private let sync = iCloudSyncEngine.shared

    var body: some View {
        AlivePage(title: item) {
            FaceItemView(item: item, door: door.scoped(to: item), reader: door, session: sync.pageSessions.page(page + "/" + item), leaf: { block in
                if block.isTableSlice { AnyView(MobileTableSlice(block: block) { pushed = $0 }) }
                else { AnyView(Text(block.alt ?? PartFace.Block.updateNote).foregroundStyle(.secondary)) }
            })
        }
        .navigationDestination(item: $pushed) { $0.view }
    }

    private var door: ClosureFaceDoor {
        MobileRemoteFaceDoor.make(page: page) { link in
            if let target = FaceDestination(link) { pushed = target }
            else if let words = router.follow(link) { SystemToastCenter.shared.push(info: words) }
        }
    }
}

/// A phone page reads its already received values through its own owner, independently of the Mac's action door.
@MainActor protocol MobileLocalFaceOwner {
    var waitingOn: String { get }
    func readFace(_ request: FaceReadRequest) async throws -> PartFace
    func readText(_ request: FaceReadRequest) async throws -> String
}

extension MobileLocalFaceOwner {
    func readText(_ request: FaceReadRequest) async throws -> String {
        throw PartCallError(code: "local_document_missing", message: "This local page has no document named \(request.key).")
    }
}

struct MobileLocalFaceRows: View {
    let face: PartFace
    let owner: any MobileLocalFaceOwner
    let session: FacePageSession
    var open: (String) -> Void = { _ in }

    var body: some View {
        FaceView(face: face, door: door, session: session)
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: open, waitingOn: owner.waitingOn,
                        read: { try await owner.readText($0) }, pageRead: { try await owner.readFace($0) }, perform: { _ in
            let failure = WireFailure(code: "local_page_read_only", message: "This page only reads this iPhone's received copy.",
                                      cause: nil, effects: .none)
            return FaceActOutcome(failure: failure, effects: .none)
        })
    }
}
