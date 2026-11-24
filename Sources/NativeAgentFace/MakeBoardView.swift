import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `MakeBoardView.swift` | A Make board drawn as a native board; a change by hand is laid as the next version on the newest |

extension EnvironmentValues {
    @Entry var boardFillsWindow = false
    @Entry var boardPage: String? = nil
}

/// One version of a board as read from Make.
struct BoardArrival: Equatable {
    let document: BoardDocument
    let version: String
}

/// A change the person made by hand. It is applied to the newest version known, so a version laid by someone else while the person was
/// changing the board is changed in turn, never written over. It says whether it changed anything: its card may be gone from that version.
struct BoardEdit {
    let apply: (inout BoardDocument) -> Bool
}

/// A board's state for its Make ref, shared by every drawing of it and outliving each one: the newest version read from Make, and the
/// person's changes on their way into the next version. Changes go to Make one save at a time; one made while a save runs waits for it
/// and goes onto the version that save laid. A save Make refuses because a newer version exists (`version_superseded`, nothing written)
/// waits for that version to be read and is made again on it; any other failure is said as it was said and never made again, since
/// it may have landed: what landed is drawn when it is read.
@MainActor @Observable final class MakeBoardState {
    private static var boards: [String: MakeBoardState] = [:]
    static func of(_ reference: String) -> MakeBoardState {
        if let held = boards[reference] { return held }
        let made = MakeBoardState(reference)
        boards[reference] = made
        return made
    }
    static func number(_ version: String) -> Int { Int(version) ?? 0 }

    let reference: String
    private(set) var latest: BoardArrival?
    /// The newest version read from Make. A drawing of an older one is a look back: it is drawn as it is, and changes go on the newest.
    private(set) var read = 0
    private(set) var isSaving = false
    /// How many versions arrived that no save from here laid: a change begun before one of them lands on a newer version than it was made on.
    private(set) var newer = 0
    private var laying: [BoardEdit] = []
    /// The version the save under way was made on. Once a newer version is read, that version holds the save's change or Make will
    /// refuse it, so the change is no longer drawn on top of it.
    private var layingOn: String?
    /// The version a save was refused on for a newer one: the change waits until a version past it is read.
    private var refusedOn: String?
    private var waiting: [BoardEdit] = []
    private var laid: Set<String> = []
    private var onNewer = false

    private init(_ reference: String) { self.reference = reference }

    /// The board as the person sees it: the newest version with every change of theirs not yet laid.
    var current: BoardDocument? {
        guard let latest else { return nil }
        var document = latest.document
        for edit in (latest.version == layingOn ? laying : []) + waiting { _ = edit.apply(&document) }
        return document
    }

    func arrive(_ arrival: BoardArrival, appModel: AppModel) {
        read = max(read, Self.number(arrival.version))
        if let latest, Self.number(arrival.version) < Self.number(latest.version) { return }
        if arrival.version != latest?.version, !laid.contains(arrival.version) { newer += 1 }
        latest = arrival
        lay(appModel)
    }

    /// `seen` is `newer` when the change began: a version that came since means the change lands on a version it was not made on.
    func change(_ edit: BoardEdit, seen: Int, appModel: AppModel) {
        if seen != newer { onNewer = true }
        waiting.append(edit)
        lay(appModel)
    }

    private func lay(_ appModel: AppModel) {
        guard !isSaving, !waiting.isEmpty, let base = latest, base.version != refusedOn else { return }
        refusedOn = nil
        var document = base.document
        var changed = false
        for edit in waiting {
            if edit.apply(&document) { changed = true }
        }
        let told = onNewer
        laying = waiting
        waiting = []
        onNewer = false
        guard changed else {
            laying = []
            MakePieceWords.shared.said[reference] = "What you changed is not on the newest version of this board any more, so nothing was saved."
            return
        }
        isSaving = true
        layingOn = base.version
        MakePieceWords.shared.said[reference] = nil
        Task {
            var words: String?
            do {
                let saved = try await MakePieceSave.save(appModel, reference: reference, version: base.version,
                                                         name: reference + "." + BoardDocument.type, content: document.text)
                laid.insert(saved.version)
                if Self.number(saved.version) > Self.number(latest?.version ?? "0") {
                    latest = BoardArrival(document: document, version: saved.version)
                }
                words = told ? "This board changed while you were changing it, so your change is saved on top of the newer version." : saved.words
            } catch let failure as WireFailure where failure.code == "version_superseded" {
                // Nothing was written: the same change goes onto the newer version, now if it is read, else when it is.
                waiting = laying + waiting
                onNewer = true
                if latest?.version == base.version { refusedOn = base.version }
                words = Self.number(latest?.version ?? "0") > Self.number(base.version) ? nil
                    : "This board changed while you were changing it. Your change goes onto the newer version once it is here."
            } catch { words = error.localizedDescription }
            laying = []
            layingOn = nil
            isSaving = false
            if let words { MakePieceWords.shared.said[reference] = words }
            // The Make pane follows the newest version after a save, as it does for a table.
            WorkPaneState.shared.selectedMakeVersions[reference] = nil
            lay(appModel)
        }
    }
}

/// A board piece on a page (the Desk), drawn across its versions: a new version replaces the one drawn only once it has been read, so a
/// card the person is holding stays in their hand and their change goes onto whatever arrived meanwhile.
struct PageMakeBoard: View {
    let reference: String
    let version: String
    var cards: [String: PartFace.Value] = [:]
    var choices: [[String: PartFace.Value]] = []
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietCaptureSession) private var capture
    @Environment(\.boardFillsWindow) private var fillsWindow
    @State private var arrival: BoardArrival?
    @State private var issue: String?
    init(reference: String, version: String, cards: [String: PartFace.Value] = [:], choices: [[String: PartFace.Value]] = []) {
        self.reference = reference; self.version = version; self.cards = cards; self.choices = choices
        let empty = reference == BoardDocument.tableRef && version == "0"
        _arrival = State(initialValue: empty ? BoardArrival(document: BoardDocument(), version: "0") : nil)
    }
    private var key: FaceKey { .makePreview(reference: reference, version: version) }
    private var preview: MakePreviewFace? { appModel.face.slot(key).value(as: MakePreviewFace.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if let capture {
                if let preview, let board = capture.held(preview)?.board {
                    MakeBoardView(reference: reference, arrival: BoardArrival(document: board, version: version), cards: cards, choices: choices, still: true)
                } else { FaceReadStatus(state: preview?.state) }
            } else if let arrival {
                MakeBoardView(reference: reference, arrival: arrival, cards: cards, choices: choices)
            } else if let state = preview?.state, state != .ready {
                FaceReadStatus(state: state)
            } else if issue == nil { Text("Reading the board…").foregroundStyle(.secondary) }
        }
        // Until the board is read it holds the room it will take, so what follows it on the page does not jump down when it arrives.
        .frame(minHeight: capture == nil && arrival == nil && !fillsWindow ? MakeBoardView.height : nil, alignment: .top)
        .task(id: preview) {
            guard capture == nil, let preview, preview.state == .ready, preview.reference == reference, preview.version == version,
                  let grant = preview.resources.first else { return }
            do {
                let read = try await BoardFile.read(grant)
                try Task.checkCancellation()
                arrival = BoardArrival(document: read, version: version)
                issue = nil
            } catch is CancellationError {
            } catch { issue = "I couldn't read this board: " + error.localizedDescription }
        }
        .modifier(FaceObservation(demand: reference == BoardDocument.tableRef && version == "0" ? nil : .key(key)))
        // Leaving the board lets go of what its last save said.
        .onDisappear { MakePieceWords.shared.said[reference] = nil }
    }
}

/// A board file is read off the main actor, and only within the words Make takes in hand.
enum BoardFile {
    static func read(_ grant: ResourceGrant) async throws -> BoardDocument {
        let opened = try await FaceResourceAccess.resolve(grant)
        defer { if opened.scoped { opened.url.stopAccessingSecurityScopedResource() } }
        return try await read(opened.url)
    }

    @concurrent static func read(_ file: URL) async throws -> BoardDocument {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
        guard size <= MakePreviewFace.wordsLimit else {
            throw BoardDocument.Unreadable(message: "It is over 2 MB, too large to draw here. The whole file is in Make.")
        }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return try BoardDocument(text)
    }
}

/// Where the board is looked at from: board points times `scale`, plus `offset`, are view points.
struct BoardCamera: Equatable {
    static let maximumScale: CGFloat = 2
    var offset: CGPoint
    var scale: CGFloat
    func view(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y) }
    func board(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale) }
    func view(_ rect: CGRect) -> CGRect {
        CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
    func board(_ rect: CGRect) -> CGRect {
        CGRect(origin: board(rect.origin), size: CGSize(width: rect.width / scale, height: rect.height / scale))
    }
    func zoomed(by factor: CGFloat, at point: CGPoint) -> BoardCamera {
        let scale = min(Self.maximumScale, max(0.25, self.scale * factor)), ratio = scale / self.scale
        return BoardCamera(offset: CGPoint(x: point.x - (point.x - offset.x) * ratio, y: point.y - (point.y - offset.y) * ratio), scale: scale)
    }
}

/// What the person's hand holds between pressing and letting go: the board as it was drawn then, and what the drag does to it.
struct BoardHand {
    enum Kind { case move([String]), resize(String, CGPoint), join(String), pan(BoardCamera), draw([CGPoint]) }
    var kind: Kind
    let document: BoardDocument
    let camera: BoardCamera
    let start: CGPoint
    var now: CGPoint
    let seen: Int
    let under: String?
    var board: CGSize { CGSize(width: (now.x - start.x) / camera.scale, height: (now.y - start.y) / camera.scale) }
    var travelled: CGFloat {
        if case .draw(let points) = kind {
            return points.reduce(CGFloat.zero) { max($0, hypot($1.x - points[0].x, $1.y - points[0].y) * camera.scale) }
        }
        return hypot(now.x - start.x, now.y - start.y)
    }
}

/// A board drawn as a board: sections, cards, words, pen lines and the arrows between them, on the page's own material. Drag a card to
/// move it (a section carries what lies in it), its corner to size it, its edge onto another card to join them with an arrow; double-click
/// to write on it, or on the empty board to add a card there; Delete takes the chosen one off; drag the empty board to look around and
/// pinch to zoom. Every change by hand is laid as the next version when the hand lets go. The Desk's standing table is worked with its
/// named tools (`TableBoardTools`) and the bar on the chosen element, and each gesture's end is one door call.
struct MakeBoardView: View {
    let reference: String
    let arrival: BoardArrival
    var cards: [String: PartFace.Value] = [:]
    var choices: [[String: PartFace.Value]] = []
    /// A picture of the page: drawn as read, nothing to change.
    var still = false
    @Environment(AppModel.self) private var appModel
    @Environment(\.boardFillsWindow) private var fillsWindow
    @Environment(\.boardPage) private var boardPage
    @State private var hand: BoardHand?
    @State private var tool: TableBoardTool = .select
    @State private var picking = false
    @State private var connectFrom: String?
    @State private var hover: CGPoint?
    @State private var barSize = CGSize(width: 360, height: 36)
    @State private var toolsHeight: CGFloat = 50
    @State private var deadPress = false
    @State private var chosen: String?
    @State private var writing: String?
    @State private var newNote: BoardDocument.Element?
    @State private var camera: BoardCamera?
    @State private var zoomFrom: BoardCamera?
    @State private var held: [String: Hold] = [:]
    @State private var chains: [String: Task<Void, Never>] = [:]
    @FocusState private var focused: Bool

    /// Fields held over the last read until the store's returned version arrives; nil fields hold a removal.
    private struct Hold {
        var fields: [String: PartFace.Value]?
        var calls = 0
        var until: Int?
        var added: Int?
        let generation = UUID()
    }

    static let height: CGFloat = 560
    static let pristineIdleInlineHeight: CGFloat = 220
    static let tableToolsInset: CGFloat = 10
    private var geometry: BoardGeometry { BoardGeometry(cards: reference == BoardDocument.tableRef ? cards : nil) }

    private func isPristineIdleInline(_ document: BoardDocument) -> Bool {
        !fillsWindow && reference == BoardDocument.tableRef && boardPage == "desk"
            && document.elements.isEmpty && newNote == nil && writing == nil
    }

    var body: some View {
        let state = MakeBoardState.of(reference)
        let still = self.still || (reference == BoardDocument.tableRef && boardPage != "desk")
        let older = !still && state.read > MakeBoardState.number(arrival.version)
        let changeable = !still && !older && state.latest != nil
        let base = reference == BoardDocument.tableRef ? picture : changeable ? (state.current ?? arrival.document) : arrival.document
        let pristine = isPristineIdleInline(base)
        VStack(alignment: .leading, spacing: 8) {
            if !still, let said = MakePieceWords.shared.said[reference] {
                Text(said).font(ShellType.label).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if older {
                Text("This is version \(arrival.version). Changes by hand go on the newest, version \(state.read).")
                    .font(ShellType.label).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let camera = self.camera ?? self.geometry.fit(base, in: geometry.size)
                let placementSize = pristine ? CGSize(width: geometry.size.width, height: Self.height) : geometry.size
                let drawn = reference == BoardDocument.tableRef ? base : hand.map(holding) ?? base
                let mark = !still && !older ? connectFrom ?? chosen : nil
                let joining = hand.flatMap(Self.joining)
                let hovered = hover.flatMap { self.geometry.hit(drawn, at: camera.board($0), scale: camera.scale)?.id }
                let dot = reference == BoardDocument.tableRef && tool == .select && changeable
                    ? hover.flatMap { point in drawn.element(hovered ?? "").flatMap { self.geometry.joinDot($0, at: camera.board(point)) } } : nil
                ZStack(alignment: .topLeading) {
                    if fillsWindow {
                        BoardScrollPan { delta in
                            self.camera = BoardCamera(offset: CGPoint(x: camera.offset.x + delta.width, y: camera.offset.y + delta.height),
                                                      scale: camera.scale)
                        }
                    }
                    Canvas { context, size in
                        var document = drawn
                        if let hand, let stroke = Self.stroke(hand) { document.add(stroke) }
                        BoardPainter.paint(&context, size: size, document: document, camera: camera, chosen: mark, joining: joining, cards: cards,
                                           table: reference == BoardDocument.tableRef, hovered: hovered, dot: dot, writing: writing)
                    }
                    if let writing, let element = drawn.element(writing), let frame = self.geometry.frame(element) {
                        let table = reference == BoardDocument.tableRef
                        let shown = table ? camera.view(frame) : camera.view(frame).insetBy(dx: element.type == "shape" ? 6 * camera.scale : 0, dy: 0)
                        BoardWordsEditor(text: element.string("text") ?? "",
                                         font: BoardGeometry.font(element, scale: camera.scale, table: table && element.type == "shape"), table: table,
                                         scale: camera.scale, keepOnEscape: newNote?.id == writing) { words in
                            self.writing = nil
                            focused = true
                            var fields: [String: PartFace.Value] = words.map { ["text": .string($0)] } ?? [:]
                            if table, element.type == "shape", let words {
                                fields["h"] = .int(Int64(BoardGeometry.noteHeight(element, words: words)))
                            }
                            if var note = newNote, note.id == writing {
                                newNote = nil
                                guard let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { chosen = nil; return }
                                note.fields.merge(fields) { _, new in new }
                                commit([(writing, note.fields)], BoardEdit { _ in false }, state.newer, state)
                                return
                            }
                            guard let words else { return }
                            commit([(writing, fields)], BoardEdit { $0.setText(writing, words) }, state.newer, state)
                        }
                        .foregroundStyle(reference == BoardDocument.tableRef ? BoardPalette.words(element.string("color"), table: true) : .primary)
                        .id(reference == BoardDocument.tableRef ? writing : "")
                        .frame(width: table ? shown.width : max(shown.width, 160), height: table ? shown.height : nil, alignment: .topLeading)
                        .position(x: (table ? shown.width : max(shown.width, 160)) / 2 + shown.minX, y: shown.midY)
                    }
                    if !still && !older, state.latest != nil {
                        if reference == BoardDocument.tableRef {
                            GlassEffectContainer(spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    tableControls(state, camera: camera, size: geometry.size, placementSize: placementSize, document: drawn)
                                }
                            }
                        } else { controls(state, camera: camera, size: geometry.size, changeable: changeable) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !deadPress else { return }
                        if hand == nil { begin(at: value.startLocation, base, camera: camera, changeable: changeable, seen: state.newer) }
                        advance(to: value.location, state)
                    }
                    .onEnded { value in
                        if let hand, case .draw = hand.kind { advance(to: value.location, state) }
                        else { hand?.now = value.location }
                        if let held = hand { end(held, state, size: placementSize) }
                        hand = nil
                        deadPress = false
                    })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                    guard changeable, reference != BoardDocument.tableRef || tool == .select else { return }
                    write(at: tap.location, base, camera: camera, size: placementSize, state)
                })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let from = zoomFrom ?? camera
                        zoomFrom = from
                        self.camera = from.zoomed(by: value.magnification, at: value.startLocation)
                    }
                    .onEnded { _ in zoomFrom = nil })
                .onContinuousHover { phase in
                    guard reference == BoardDocument.tableRef, changeable else { return }
                    switch phase {
                    case .active(let point):
                        let onDot = dot.map { hypot(camera.view($0).x - point.x, camera.view($0).y - point.y) <= 9 } ?? false
                        if !onDot { hover = point }
                        (onDot || tool == .connect ? NSCursor.crosshair : tool == .note ? .iBeam : tool == .pen ? .crosshair : .arrow).set()
                    case .ended: hover = nil; NSCursor.arrow.set()
                    }
                }
            }
            .frame(height: fillsWindow ? nil : pristine ? Self.pristineIdleInlineHeight : Self.height)
            .background(reference == BoardDocument.tableRef ? NativeAgentShell.list : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous).strokeBorder(TodayPalette.cardStroke))
            .focusable(!still && !older)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard changeable, writing == nil, let gone = chosen else { return .ignored }
                chosen = nil
                commit([(gone, nil)], BoardEdit { $0.remove(gone) }, state.newer, state)
                return .handled
            }
            .onKeyPress(.escape) {
                guard chosen != nil || (reference == BoardDocument.tableRef && tool != .select) else { return .ignored }
                tool = .select
                connectFrom = nil
                picking = false
                if reference == BoardDocument.tableRef, hand != nil { hand = nil; deadPress = true }
                chosen = nil
                return .handled
            }
            .help(reference == BoardDocument.tableRef ? "" : changeable
                  ? "Drag a card to move it, its corner to size it, or its edge onto another card to join them. Double-click to write." : "")
            if state.isSaving, !still { Text("Saving…").font(ShellType.label).foregroundStyle(.secondary) }
        }
        .onChange(of: arrival, initial: true) { _, now in
            readHolds(now.version)
            if !still { state.arrive(now, appModel: appModel) }
        }
        .onChange(of: held.mapValues { $0.calls == 0 ? $0.until ?? 0 : -1 }) { _, _ in
            readHolds(arrival.version)
        }
        .onChange(of: tool) { _, now in
            if now != .connect { connectFrom = nil }
            if now != .select, writing != nil { focused = true }
        }
        .onDisappear { if reference == BoardDocument.tableRef { NSCursor.arrow.set() } }
    }

    private func readHolds(_ version: String) {
        held = held.filter { $0.value.calls > 0 || ($0.value.until.map { $0 > MakeBoardState.number(version) } ?? false) }
    }

    private var picture: BoardDocument {
        var document = arrival.document
        var fields = held.mapValues(\.fields)
        if let hand { for (id, end) in placement(hand) where held[id].map({ $0.fields != nil }) ?? true {
            fields[id] = .some((fields[id] ?? nil).map { $0.merging(end ?? [:]) { _, new in new } } ?? end)
        } }
        for (id, end) in fields {
            guard let end else { _ = document.remove(id); continue }
            if let index = document.elements.firstIndex(where: { $0.id == id }) {
                document.elements[index].fields.merge(end) { _, new in new }
            } else if end["type"] != nil, held[id]?.added.map({ MakeBoardState.number(arrival.version) < $0 }) ?? true {
                document.elements.append(BoardDocument.Element(end.merging(["id": .string(id)]) { _, new in new }))
            }
        }
        if let newNote { document.elements.append(newNote) }
        return document
    }

    private func placement(_ hand: BoardHand) -> [(String, [String: PartFace.Value]?)] {
        // A gesture sends only what it changed: a move sends position, so a resize someone made meanwhile is kept.
        let ids: [String], keys: Set<String>
        switch hand.kind {
        case .move(let moved): ids = moved; keys = ["x", "y"]
        case .resize(let id, _): ids = [id]; keys = ["x", "y", "w", "h"]
        case .join, .pan, .draw: return []
        }
        let end = holding(hand)
        return ids.compactMap { id in end.element(id).map { (id, $0.fields.filter { keys.contains($0.key) }) } }
    }

    private func commit(_ end: [(String, [String: PartFace.Value]?)], _ edit: BoardEdit, _ seen: Int,
                        _ state: MakeBoardState, changed: Bool = true, action: String = "table.put") {
        guard reference == BoardDocument.tableRef else {
            if changed { state.change(edit, seen: seen, appModel: appModel) }
            return
        }
        for (id, fields) in end {
            var hold = held[id] ?? Hold(fields: fields)
            if hold.fields != nil { hold.fields = fields.map { hold.fields!.merging($0) { _, new in new } } }
            hold.calls += 1
            held[id] = hold
            let previous = chains[id], generation = hold.generation
            chains[id] = Task {
                await previous?.value
                guard held[id]?.generation == generation else { return }
                do {
                    let arguments = (fields ?? [:]).merging(["id": .string(id)]) { _, new in new }
                    if let version = try await tableCall(fields == nil ? "table.remove" : action, arguments) {
                        held[id]?.until = max(held[id]?.until ?? version, version)
                        if fields?["type"] != nil { held[id]?.added = version }
                    }
                    held[id]?.calls -= 1
                    if held[id]?.calls == 0 { chains[id] = nil }
                } catch {
                    held[id] = nil
                    chains[id] = nil
                    if let hand, placement(hand).contains(where: { $0.0 == id }) || Self.joining(hand)?.from == id {
                        self.hand = nil
                        deadPress = true
                    }
                    if writing == id { writing = nil }
                    if chosen == id { chosen = nil }
                    if connectFrom == id { connectFrom = nil }
                    MakePieceWords.shared.said[reference] = error.localizedDescription
                }
            }
        }
    }

    @discardableResult private func tableCall(_ action: String, _ arguments: [String: PartFace.Value]) async throws -> Int? {
        let value = try FaceWindowReply.value(await appModel.client.act(.deskCommand(.init(
            command: action, handle: action == "open_piece" ? arguments["ref"]?.stringValue : reference,
            arguments: action == "open_piece" ? [:] : arguments))))
        let outcome = try FaceActOutcome.reply(.result(value))
        if let failure = outcome.failure { throw failure }
        guard !outcome.unresolved else {
            throw PartCallError(code: "table_change_unconfirmed", message: "The table change is unconfirmed. Read the table before changing it again.")
        }
        MakePieceWords.shared.said[reference] = nil
        if case .int(let version)? = outcome.committed?.first?.value { return Int(version) }
        return nil
    }

    private func controls(_ state: MakeBoardState, camera: BoardCamera, size: CGSize, changeable: Bool) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 10) {
            if changeable {
                Menu {
                    ForEach(BoardPalette.names, id: \.self) { name in
                        Button(name.prefix(1).uppercased() + name.dropFirst()) { addCard(name, at: camera.board(middle), state) }
                    }
                } label: { Label("Add a card", systemImage: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Button { self.camera = camera.zoomed(by: 0.8, at: middle) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Text("\(Int((camera.scale * 100).rounded()))%")
            Button { self.camera = camera.zoomed(by: 1.25, at: middle) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button("Fit") { self.camera = nil }.help("Fit the board")
        }
        .buttonStyle(.borderless)
        .font(ShellType.label)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private func tableControls(
        _ state: MakeBoardState, camera: BoardCamera, size: CGSize, placementSize: CGSize, document: BoardDocument
    ) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        TableBoardTools(tool: $tool, picking: $picking, choices: choices, percent: Int((camera.scale * 100).rounded()), choose: { choice in
            self.camera = camera
            let field = choice["item"] == nil ? "piece" : "item"
            let placementMiddle = CGPoint(x: placementSize.width / 2, y: placementSize.height / 2)
            let origin = geometry.landing(CGSize(width: 260, height: 120), at: camera.board(placementMiddle),
                                               in: camera.board(CGRect(origin: .zero, size: placementSize)), document)
            let card: [String: PartFace.Value] = ["type": .string("shape"), field: choice[field]!,
                "x": .int(Int64(origin.x.rounded())), "y": .int(Int64(origin.y.rounded())), "w": .int(260), "h": .int(120)]
            let id = BoardDocument.mintID()
            commit([(id, card)], BoardEdit { _ in false }, state.newer, state)
            chosen = id; picking = false; tool = .select
        }, zoom: { self.camera = camera.zoomed(by: $0, at: middle) }, fit: { self.camera = nil }).padding(Self.tableToolsInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolsHeight = $0 }
        if let chosen, let element = document.element(chosen), writing == nil,
           let frame = geometry.frame(element) ?? geometry.arrowLine(element, in: document).map({
               CGRect(origin: $0.start, size: .zero).union(CGRect(origin: $0.end, size: .zero))
           }) {
            let shown = camera.view(frame)
            let x = min(max(shown.midX, barSize.width / 2 + 8), size.width - barSize.width / 2 - 8) - barSize.width / 2
            let above = CGRect(x: x, y: shown.minY - barSize.height - 8, width: barSize.width, height: barSize.height)
            let below = CGRect(x: x, y: shown.maxY + 8, width: barSize.width, height: barSize.height)
            let others = document.elements.filter { $0.id != chosen }.compactMap(geometry.frame).map { camera.view($0) }
            let place = [above, below].first { candidate in
                candidate.minY >= toolsHeight + 8 && candidate.maxY <= size.height - 8 && !others.contains { $0.intersects(candidate) }
            } ?? above
            elementTools(element, state).fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
                .position(x: place.midX, y: place.midY)
        }
    }

    private func elementTools(_ element: BoardDocument.Element, _ state: MakeBoardState) -> some View {
        let id = element.id
        let ref = element.string("piece").map { String($0.dropFirst("make:".count)) }
        let pointer = element.string("item") != nil || element.string("piece") != nil
        return TableElementTools(starting: connectFrom == id, connectable: element.type == "shape", colours: element.type == "shape" && !pointer,
                                 color: element.string("color"), recolor: { color in
            commit([(id, ["color": .string(color)])], BoardEdit { _ in false }, state.newer, state)
        }, cross: {
            commit([(id, [:])], BoardEdit { _ in false }, state.newer, state, action: "table.cross")
        }, connect: { tool = .connect; connectFrom = id }, remove: {
            chosen = nil
            commit([(id, nil)], BoardEdit { _ in false }, state.newer, state)
        }, open: ref.map { ref in { Task {
            do { try await tableCall("open_piece", ["ref": .string(ref)]) }
            catch { MakePieceWords.shared.said[reference] = error.localizedDescription }
        } } })
    }

    /// The board with what the hand is doing to it drawn in place, made by the same change that is laid when it lets go.
    private func holding(_ hand: BoardHand) -> BoardDocument {
        var document = hand.document
        if let edit = edit(hand) { _ = edit.apply(&document) }
        return document
    }

    private static func joining(_ hand: BoardHand) -> (from: String, to: CGPoint)? {
        guard case .join(let from) = hand.kind else { return nil }
        return (from, hand.camera.board(hand.now))
    }

    private func edit(_ hand: BoardHand) -> BoardEdit? {
        let moved = hand.board
        switch hand.kind {
        case .move(let ids):
            let dx = Double(moved.width), dy = Double(moved.height)
            return BoardEdit { $0.move(ids, dx: dx, dy: dy) }
        case .resize(let id, let corner):
            guard let element = hand.document.element(id), element.number("w") != nil, element.number("h") != nil,
                  let frame = geometry.frame(element) else { return nil }
            let w = Double(frame.width), h = Double(frame.height)
            let least: (w: Double, h: Double) = element.type == "container" ? (120, 80) : (48, 32)
            let width = max(least.w, w + Double(moved.width) * (corner.x == 0 ? -1 : 1))
            let height = max(least.h, h + Double(moved.height) * (corner.y == 0 ? -1 : 1))
            return BoardEdit { document in
                let sized = document.resize(id, w: width, h: height)
                let shifted = document.move([id], dx: corner.x == 0 ? w - width : 0, dy: corner.y == 0 ? h - height : 0)
                return sized || shifted
            }
        case .join, .pan, .draw: return nil
        }
    }

    private static func stroke(_ hand: BoardHand) -> [String: PartFace.Value]? {
        guard case .draw(let points) = hand.kind, let first = points.first else { return nil }
        return ["type": .string("stroke"), "x": .int(Int64(first.x.rounded())), "y": .int(Int64(first.y.rounded())),
                "points": .array(points.flatMap { [PartFace.Value.int(Int64(($0.x - first.x).rounded())),
                                                   .int(Int64(($0.y - first.y).rounded()))] }), "color": .string("ink"), "width": .int(2)]
    }

    private func advance(to point: CGPoint, _ state: MakeBoardState) {
        hand?.now = point
        if var hand, case .draw(var points) = hand.kind, let last = points.last {
            let spot = hand.camera.board(point)
            if hypot(spot.x - last.x, spot.y - last.y) >= 2 { points.append(spot) }
            hand.kind = .draw(points)
            self.hand = hand
            if points.count == 500 { end(hand, state); self.hand = nil; deadPress = true }
        } else if let hand, case .pan(let from) = hand.kind, reference != BoardDocument.tableRef || tool == .select {
            camera = BoardCamera(offset: CGPoint(x: from.offset.x + hand.now.x - hand.start.x,
                                                 y: from.offset.y + hand.now.y - hand.start.y), scale: from.scale)
        }
    }

    private func begin(at point: CGPoint, _ document: BoardDocument, camera: BoardCamera, changeable: Bool, seen: Int) {
        if reference == BoardDocument.tableRef, let writing,
           document.element(writing).flatMap(geometry.frame)?.contains(camera.board(point)) == true { deadPress = true; return }
        focused = true
        if self.camera == nil { self.camera = camera }
        let spot = camera.board(point)
        let under = geometry.hit(document, at: spot, scale: camera.scale)
        var kind = BoardHand.Kind.pan(camera)
        if changeable, reference == BoardDocument.tableRef, tool == .pen { kind = .draw([spot]) }
        else if changeable, reference != BoardDocument.tableRef || tool == .select {
            if let chosen, let element = document.element(chosen), BoardGeometry.resizable(element), let frame = geometry.frame(element),
               let corner = (reference == BoardDocument.tableRef ? BoardGeometry.corners : [CGPoint(x: 1, y: 1)]).first(where: {
                   hypot(camera.view(frame).minX + $0.x * frame.width * camera.scale - point.x,
                         camera.view(frame).minY + $0.y * frame.height * camera.scale - point.y) <= 9
               }) {
                kind = .resize(chosen, corner)
            } else if reference == BoardDocument.tableRef, let hover,
                      let source = geometry.hit(document, at: camera.board(hover), scale: camera.scale),
                      let dot = geometry.joinDot(source, at: camera.board(hover)),
                      hypot(camera.view(dot).x - point.x, camera.view(dot).y - point.y) <= 9 {
                kind = .join(source.id)
            } else if let under, under.type != "arrow", let frame = geometry.frame(under) {
                let rim = 8 / camera.scale
                if reference != BoardDocument.tableRef, under.type == "shape", !frame.insetBy(dx: rim, dy: rim).contains(spot) { kind = .join(under.id) }
                else if under.type == "container" { kind = .move([under.id] + geometry.inside(frame, of: document, except: under.id)) }
                else { kind = .move([under.id]) }
            }
        }
        hand = BoardHand(kind: kind, document: document, camera: camera, start: point, now: point, seen: seen, under: under?.id)
    }

    private func end(_ hand: BoardHand, _ state: MakeBoardState, size: CGSize = .zero) {
        // A press that hardly moved is a click: it chooses what is under it, or nothing.
        guard hand.travelled >= 3 else {
            if reference == BoardDocument.tableRef, tool == .note {
                addCard("white", at: hand.camera.board(hand.now), state, visible: hand.camera.board(CGRect(origin: .zero, size: size)))
                tool = .select
                return
            }
            if reference == BoardDocument.tableRef, tool == .connect {
                guard let target = hand.under.flatMap(picture.element), target.type == "shape" else { connectFrom = nil; return }
                if let from = connectFrom, from != target.id {
                    var join = hand
                    join.kind = .join(from)
                    joinCards(join, state)
                    tool = .select; connectFrom = nil
                } else { connectFrom = target.id; chosen = target.id }
                return
            }
            chosen = hand.under
            return
        }
        if let stroke = Self.stroke(hand) {
            commit([(BoardDocument.mintID(), stroke)], BoardEdit { _ in false }, hand.seen, state)
            return
        }
        if case .join = hand.kind {
            joinCards(hand, state)
            return
        }
        guard let edit = edit(hand) else { return }
        var probe = hand.document
        let changed = edit.apply(&probe)
        if case .move(let ids) = hand.kind { chosen = ids.first }
        commit(placement(hand), edit, hand.seen, state, changed: changed)
    }

    private func joinCards(_ hand: BoardHand, _ state: MakeBoardState) {
        if case .join(let from) = hand.kind {
            let spot = hand.camera.board(hand.now)
            let document = reference == BoardDocument.tableRef ? picture : hand.document
            guard let to = geometry.hit(document, at: spot, scale: hand.camera.scale), to.id != from,
                  reference != BoardDocument.tableRef || to.type == "shape",
                  let start = document.element(from).flatMap(geometry.frame), let finish = geometry.frame(to) else { return }
            let sides = BoardGeometry.sides(start, finish)
            let arrow: [String: PartFace.Value] = ["id": .string(BoardDocument.mintID()), "type": .string("arrow"), "from": .string(from), "to": .string(to.id),
                                                   "fromSide": .string(sides.from), "toSide": .string(sides.to)]
            commit([(arrow["id"]!.stringValue!, arrow)], BoardEdit { document in
                guard document.element(from) != nil, document.element(to.id) != nil else { return false }
                document.add(arrow)
                return true
            }, hand.seen, state)
            return
        }
    }

    /// A double-click writes on what is under it; on the empty board it adds a card there to write on.
    private func write(at point: CGPoint, _ document: BoardDocument, camera: BoardCamera, size: CGSize, _ state: MakeBoardState) {
        let spot = camera.board(point)
        if reference == BoardDocument.tableRef, let writing,
           document.element(writing).flatMap(geometry.frame)?.contains(spot) == true { return }
        if let under = geometry.hit(document, at: spot, scale: camera.scale) {
            guard ["shape", "text", "container"].contains(under.type),
                  reference != BoardDocument.tableRef || (under.string("item") == nil && under.string("piece") == nil) else { return }
            chosen = under.id
            writing = under.id
        } else { addCard("white", at: spot, state, visible: camera.board(CGRect(origin: .zero, size: size))) }
    }

    private func addCard(_ color: String, at middle: CGPoint, _ state: MakeBoardState, visible: CGRect? = nil) {
        guard state.current != nil else { return }
        let id = BoardDocument.mintID()
        let size = reference == BoardDocument.tableRef ? CGSize(width: 200, height: 110) : CGSize(width: 180, height: 80)
        let origin = reference == BoardDocument.tableRef && visible != nil
            ? geometry.landing(size, at: middle, in: visible!, picture) : CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
        let card: [String: PartFace.Value] = ["id": .string(id), "type": .string("shape"), "kind": .string("rounded"), "size": .string("body"),
            "color": .string(color), "text": .string(""), "x": .int(Int64(origin.x.rounded())), "y": .int(Int64(origin.y.rounded())),
            "w": .int(Int64(size.width)), "h": .int(Int64(size.height))]
        if reference == BoardDocument.tableRef { newNote = BoardDocument.Element(card) }
        else { commit([(id, card)], BoardEdit { document in
            document.add(card)
            return true
        }, state.newer, state) }
        chosen = id
        writing = id
    }
}

/// Receives board wheel movement while native click, drag and text editing keep the normal event route.
private struct BoardScrollPan: NSViewRepresentable {
    let pan: (CGSize) -> Void
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.pan = pan }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) { view.removeMonitor() }

    /// A transparent wheel receiver bounded by the board's visible rectangle.
    final class WheelView: NSView {
        var pan: ((CGSize) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, let content = window.contentView, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                var target = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
                while let view = target {
                    if view is NSTextView || view is NSTextField { return event }
                    target = view.superview
                }
                self.scrollWheel(with: event)
                return nil
            }
        }
        override func scrollWheel(with event: NSEvent) {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            pan?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

/// One element's words being written in place: Return keeps them, Escape leaves them as they were, and clicking away keeps them. It
/// settles once. On the Desk's table the editor fills the card, a click inside the card keeps writing, and Escape keeps a new note's words.
private struct BoardWordsEditor: View {
    let text: String
    let font: Font
    var table = false
    var scale: CGFloat = 1
    var keepOnEscape = false
    let end: (String?) -> Void
    @State private var draft = ""
    @State private var opening = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if table {
                TextEditor(text: $draft).textEditorStyle(.plain).scrollContentBackground(.hidden)
                    .onKeyPress(.return, phases: [.down, .repeat]) { key in
                        if key.modifiers.contains(.shift) { return .ignored }
                        settle(draft); return .handled
                    }
                    .padding(.horizontal, 12 * scale).padding(.vertical, 8 * scale)
            } else { TextField("", text: $draft, axis: .vertical).textFieldStyle(.plain) }
        }
            .font(font)
            .focused($focused)
            .frame(maxWidth: .infinity, maxHeight: table ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { if table { focused = true } })
            .onSubmit { settle(draft) }
            .onKeyPress(.escape) {
                settle(keepOnEscape ? draft : nil)
                return .handled
            }
            .onExitCommand { settle(keepOnEscape ? draft : nil) }
            .onChange(of: focused) { _, now in if !now { settle(draft) } }
            .onAppear {
                opening = text
                draft = opening
                DispatchQueue.main.async { focused = true }
            }
    }

    private func settle(_ words: String?) {
        guard !ended else { return }
        ended = true
        end(words == opening ? nil : words)
    }
}
