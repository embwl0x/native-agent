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
    static let tableToolsInset: CGFloat = 10
    private var geometry: BoardGeometry { BoardGeometry(cards: reference == BoardDocument.tableRef ? cards : nil) }

    var body: some View {
        let state = MakeBoardState.of(reference)
        let still = self.still || (reference == BoardDocument.tableRef && boardPage != "desk")
        let older = !still && state.read > MakeBoardState.number(arrival.version)
        let changeable = !still && !older && state.latest != nil
        let base = reference == BoardDocument.tableRef ? picture : changeable ? (state.current ?? arrival.document) : arrival.document
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
                            tableControls(state, camera: camera, size: geometry.size, document: drawn)
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
                        if let held = hand { end(held, state, size: geometry.size) }
                        hand = nil
                        deadPress = false
                    })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                    guard changeable, reference != BoardDocument.tableRef || tool == .select else { return }
                    write(at: tap.location, base, camera: camera, size: geometry.size, state)
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
            .frame(height: fillsWindow ? nil : Self.height)
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
        let ids: [String]
        switch hand.kind {
        case .move(let moved): ids = moved
        case .resize(let id, _): ids = [id]
        case .join, .pan, .draw: return []
        }
        let end = holding(hand)
        return ids.compactMap { id in end.element(id).map { (id, $0.fields.filter { ["x", "y", "w", "h"].contains($0.key) }) } }
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

    @ViewBuilder private func tableControls(_ state: MakeBoardState, camera: BoardCamera, size: CGSize, document: BoardDocument) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        TableBoardTools(tool: $tool, picking: $picking, choices: choices, percent: Int((camera.scale * 100).rounded()), choose: { choice in
            self.camera = camera
            let field = choice["item"] == nil ? "piece" : "item"
            let origin = geometry.landing(CGSize(width: 260, height: 120), at: camera.board(middle),
                                               in: camera.board(CGRect(origin: .zero, size: size)), document)
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

/// Where each element is on the board and what is under a point. Cards, sections and pen lines carry their own frame; words are as large
/// as they are set.
struct BoardGeometry {
    var cards: [String: PartFace.Value]? = nil
    func landing(_ size: CGSize, at wanted: CGPoint, in visible: CGRect, _ document: BoardDocument) -> CGPoint {
        let start = CGPoint(x: (wanted.x - size.width / 2).rounded(), y: (wanted.y - size.height / 2).rounded())
        let frames = document.elements.compactMap(frame)
        if !frames.contains(where: { $0.intersects(CGRect(origin: start, size: size)) }) { return start }
        var outside: CGPoint?
        for radius in 0...min(Int(ceil(max(visible.width, visible.height) / 24)) + 1, 40) {
            let offsets = radius == 0 ? [CGPoint.zero] : (-radius...radius).flatMap { n in
                [CGPoint(x: CGFloat(n) * 24, y: CGFloat(radius) * 24), CGPoint(x: CGFloat(n) * 24, y: CGFloat(-radius) * 24),
                 CGPoint(x: CGFloat(radius) * 24, y: CGFloat(n) * 24), CGPoint(x: CGFloat(-radius) * 24, y: CGFloat(n) * 24)]
            }
            let free = offsets.sorted { hypot($0.x, $0.y) < hypot($1.x, $1.y) }.map { CGPoint(x: start.x + $0.x, y: start.y + $0.y) }
                .filter { origin in !frames.contains { $0.intersects(CGRect(origin: origin, size: size)) } }
            if let inside = free.first(where: { visible.contains(CGRect(origin: $0, size: size)) }) { return inside }
            if outside == nil { outside = free.first }
        }
        return outside ?? start
    }
    static let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
    func joinDot(_ element: BoardDocument.Element, at point: CGPoint) -> CGPoint? {
        guard element.type == "shape", let frame = frame(element) else { return nil }
        let edges = [("left", abs(point.x - frame.minX)), ("right", abs(point.x - frame.maxX)),
                     ("top", abs(point.y - frame.minY)), ("bottom", abs(point.y - frame.maxY))]
        return edges.min { $0.1 < $1.1 }.map { Self.point(frame, side: $0.0) }
    }
    func frame(_ element: BoardDocument.Element) -> CGRect? {
        guard let x = element.number("x"), let y = element.number("y") else { return nil }
        switch element.type {
        case "shape", "container":
            var height = CGFloat(element.number("h") ?? 80)
            if let cards, element.type == "shape" {
                if case .object(let facts)? = cards[element.id], let title = facts["title"]?.stringValue {
                    let width = max(1, CGFloat(element.number("w") ?? 160) - 24)
                    let measured = (title as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: NSFont.systemFont(ofSize: Self.points(element, table: true), weight: .medium)])
                    height = max(height, ceil(measured.height) + 44)
                } else { height = Self.noteHeight(element, words: element.string("text") ?? "") }
            }
            return CGRect(x: x, y: y, width: element.number("w") ?? 160, height: height)
        case "text":
            let words = Self.plain(element.string("text") ?? "")
            let measured = ((words.isEmpty ? " " : words) as NSString).boundingRect(
                with: CGSize(width: element.number("w") ?? 640, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.nsFont(element)])
            return CGRect(x: x, y: y, width: max(ceil(measured.width), 24), height: ceil(measured.height))
        case "stroke":
            let points = element.numbers
            guard points.count >= 2 else { return nil }
            let xs = stride(from: 0, to: points.count - 1, by: 2).map { points[$0] }
            let ys = stride(from: 1, to: points.count, by: 2).map { points[$0] }
            return CGRect(x: x + xs.min()!, y: y + ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        default: return nil
        }
    }

    static func resizable(_ element: BoardDocument.Element) -> Bool { ["shape", "container"].contains(element.type) }

    /// The drawing order: sections under everything, then arrows, then the rest as the document lists them.
    static func order(_ document: BoardDocument) -> [BoardDocument.Element] {
        document.elements.filter { $0.type == "container" } + document.elements.filter { $0.type == "arrow" }
            + document.elements.filter { $0.type != "container" && $0.type != "arrow" }
    }

    /// The topmost element under a board point; a pen line or an arrow is under a point a few view points from it.
    func hit(_ document: BoardDocument, at point: CGPoint, scale: CGFloat) -> BoardDocument.Element? {
        let slack = 6 / scale
        return Self.order(document).reversed().first { element in
            switch element.type {
            case "arrow":
                guard let line = arrowLine(element, in: document) else { return false }
                return Self.distance(point, from: line.start, to: line.end) <= slack
            case "stroke":
                let width = Self.strokeWidth(element) + 2 * slack
                guard frame(element)?.insetBy(dx: -width / 2, dy: -width / 2).contains(point) == true else { return false }
                if let path = Self.strokePath(element) {
                    return path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)).contains(point)
                }
                let points = element.numbers
                guard let x = element.number("x"), let y = element.number("y"), points.count >= 2 else { return false }
                return hypot(point.x - x - points[0], point.y - y - points[1]) <= width / 2
            default:
                return frame(element)?.contains(point) == true
            }
        }
    }

    static func strokeWidth(_ element: BoardDocument.Element) -> CGFloat { CGFloat(element.number("width") ?? 3) }

    /// A pen line as drawn: a smooth curve through its points; two points are a straight line.
    static func strokePath(_ element: BoardDocument.Element) -> Path? {
        guard let x = element.number("x"), let y = element.number("y") else { return nil }
        let points = element.numbers
        guard points.count >= 4 else { return nil }
        var path = Path()
        path.move(to: CGPoint(x: x + points[0], y: y + points[1]))
        for index in stride(from: 2, to: points.count - 1, by: 2) {
            let previous = CGPoint(x: x + points[index - 2], y: y + points[index - 1])
            let next = CGPoint(x: x + points[index], y: y + points[index + 1])
            if points.count == 4 { path.addLine(to: next) }
            else { path.addQuadCurve(to: CGPoint(x: (previous.x + next.x) / 2, y: (previous.y + next.y) / 2), control: previous) }
        }
        if points.count > 4 { path.addLine(to: CGPoint(x: x + points[points.count - 2], y: y + points[points.count - 1])) }
        return path
    }

    /// Where an arrow runs: from the side of the element it leaves to the side of the one it reaches.
    func arrowLine(_ element: BoardDocument.Element, in document: BoardDocument) -> (start: CGPoint, end: CGPoint)? {
        guard element.type == "arrow", let from = element.string("from").flatMap(document.element).flatMap(frame),
              let to = element.string("to").flatMap(document.element).flatMap(frame) else { return nil }
        let facing = Self.sides(from, to)
        return (Self.point(from, side: element.string("fromSide") ?? facing.from), Self.point(to, side: element.string("toSide") ?? facing.to))
    }

    static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    /// What lies in a section: every element but arrows whose middle is inside its frame.
    func inside(_ frame: CGRect, of document: BoardDocument, except id: String) -> [String] {
        document.elements.compactMap { element in
            guard element.id != id, element.type != "arrow", let own = self.frame(element),
                  frame.contains(CGPoint(x: own.midX, y: own.midY)) else { return nil }
            return element.id
        }
    }

    static func point(_ frame: CGRect, side: String) -> CGPoint {
        switch side {
        case "left": CGPoint(x: frame.minX, y: frame.midY)
        case "right": CGPoint(x: frame.maxX, y: frame.midY)
        case "top": CGPoint(x: frame.midX, y: frame.minY)
        default: CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    /// The sides two frames face each other by, along the axis they are further apart on.
    static func sides(_ from: CGRect, _ to: CGRect) -> (from: String, to: String) {
        let dx = to.midX - from.midX, dy = to.midY - from.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? ("right", "left") : ("left", "right") }
        return dy >= 0 ? ("bottom", "top") : ("top", "bottom")
    }

    /// The board fitted and centred in view, at most at its own size and never below 60%; content too large for that is centred on its
    /// newest element. An empty board is at its own size with its origin at the centre.
    func fit(_ document: BoardDocument, in size: CGSize) -> BoardCamera {
        let frames = document.elements.compactMap(frame)
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let first = frames.first else { return BoardCamera(offset: middle, scale: 1) }
        let whole = frames.dropFirst().reduce(first) { $0.union($1) }
        let margin: CGFloat = 32
        let fit = min(1, (size.width - margin * 2) / max(whole.width, 1), (size.height - margin * 2) / max(whole.height, 1))
        let scale = max(0.6, fit)
        let newest = document.elements.last.flatMap { element in
            frame(element) ?? arrowLine(element, in: document).map {
                CGRect(x: min($0.start.x, $0.end.x), y: min($0.start.y, $0.end.y),
                       width: abs($0.end.x - $0.start.x), height: abs($0.end.y - $0.start.y))
            }
        }
        let centered = whole.width * scale > size.width || whole.height * scale > size.height ? newest ?? whole : whole
        return BoardCamera(offset: CGPoint(x: middle.x - centered.midX * scale, y: middle.y - centered.midY * scale),
                           scale: scale)
    }

    static func points(_ element: BoardDocument.Element, table: Bool = false) -> CGFloat {
        let size: CGFloat = switch element.string("size") ?? "" {
        case "title": 28
        case "large": 20
        case "small": 12
        default: element.type == "container" ? 15 : 14
        }
        return table ? max(22, size) : size
    }

    static func weight(_ element: BoardDocument.Element) -> Font.Weight {
        switch element.string("size") ?? "" {
        case "title": .semibold
        case "large": .medium
        default: element.type == "container" ? .semibold : .regular
        }
    }

    static func font(_ element: BoardDocument.Element, scale: CGFloat = 1, table: Bool = false) -> Font {
        .system(size: points(element, table: table) * scale, weight: weight(element))
    }

    nonisolated(unsafe) private static let measuredHeights = NSCache<NSString, NSNumber>()

    static func noteHeight(_ element: BoardDocument.Element, words: String) -> CGFloat {
        let font = nsFont(element, table: true), width = max(1, CGFloat(element.number("w") ?? 160) - 24)
        let key = "\(width)|\(font.pointSize)|\(font.fontName)|\(words)" as NSString
        let needed: CGFloat
        if let known = measuredHeights.object(forKey: key) { needed = CGFloat(known.doubleValue) } else {
            needed = NSAttributedString(Self.words(words, font: font)).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            measuredHeights.setObject(NSNumber(value: Double(needed)), forKey: key)
        }
        return ceil(max(CGFloat(element.number("h") ?? 80), needed + 16))
    }

    static func nsFont(_ element: BoardDocument.Element, table: Bool = false) -> NSFont {
        let thickness: NSFont.Weight = switch weight(element) {
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        return .systemFont(ofSize: points(element, table: table), weight: thickness)
    }

    /// Words as written, their inline Markdown read: **bold**, *italic*, `code`, links.
    static func words(_ text: String, font: NSFont? = nil) -> AttributedString {
        var words = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? .init(text)
        if let font { for run in words.runs {
            let intent = run.inlinePresentationIntent ?? []
            var face = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            words[run.range].appKit.font = face
            words[run.range].swiftUI.font = Font(face)
        } }
        return words
    }

    static func plain(_ text: String) -> String { String(words(text).characters) }
}

/// The board's quiet colours: a card is content, a pale fill of its colour in light and a deep one in dark, its words in the ink that
/// reads on it; lines (pen strokes, a section's edge, a card's own outline) are the colour itself.
enum BoardPalette {
    static let names = ["white", "yellow", "green", "blue", "purple", "peach", "ink"]

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }

    static func fill(_ name: String?) -> Color {
        switch name ?? "" {
        case "green": dynamic(light: 0xE4F2E5, dark: 0x2F4033)
        case "yellow": dynamic(light: 0xFBF2D0, dark: 0x4A4228)
        case "purple": dynamic(light: 0xEEE6F7, dark: 0x3D3550)
        case "blue": dynamic(light: 0xE2ECF8, dark: 0x2D3A4C)
        case "peach": dynamic(light: 0xFCE7DA, dark: 0x4C382E)
        case "ink": dynamic(light: 0x2E3034, dark: 0xE6E3DE)
        default: TodayPalette.cardFill
        }
    }

    /// The words on a card of this colour.
    static func words(_ name: String?, table: Bool = false) -> Color {
        name == "ink" ? dynamic(light: 0xF6F3EE, dark: 0x1C1D20) : table ? dynamic(light: 0x1C1D20, dark: 0xF6F3EE) : .primary
    }

    static func line(_ name: String?) -> Color {
        switch name ?? "ink" {
        case "green": dynamic(light: 0x3E8E4E, dark: 0x7CC48A)
        case "yellow": dynamic(light: 0xA9841C, dark: 0xE0C25A)
        case "purple": dynamic(light: 0x7A5BB5, dark: 0xB49BE6)
        case "blue": dynamic(light: 0x3F6FB0, dark: 0x8DB2E8)
        case "peach", "terracotta": dynamic(light: 0xC46A3C, dark: 0xEDA27E)
        case "white": dynamic(light: 0x9A9A9A, dark: 0xD0D0D0)
        case "ink": .primary
        default: .secondary
        }
    }
}

/// Paints a board in view space, transformed into board points: a quiet dot grid, sections, arrows, then cards, words and pen lines.
enum BoardPainter {
    static func paint(_ context: inout GraphicsContext, size: CGSize, document: BoardDocument, camera: BoardCamera, chosen: String?,
                      joining: (from: String, to: CGPoint)?, cards: [String: PartFace.Value], table: Bool = false,
                      hovered: String? = nil, dot: CGPoint? = nil, writing: String? = nil) {
        grid(&context, size: size, camera: camera)
        var board = context
        board.translateBy(x: camera.offset.x, y: camera.offset.y)
        board.scaleBy(x: camera.scale, y: camera.scale)
        let geometry = BoardGeometry(cards: table ? cards : nil)
        let frames = Dictionary(document.elements.compactMap { element in geometry.frame(element).map { (element.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        for stored in BoardGeometry.order(document) {
            var element = stored
            let facts: [String: PartFace.Value]
            if case .object(let value)? = cards[element.id] { facts = value } else { facts = [:] }
            if !table, let title = facts["title"]?.stringValue {
                let detail = [facts["alias"]?.stringValue, facts["state"]?.stringValue, facts["what"]?.stringValue].compactMap { $0 }
                element.fields["text"] = .string(([title] + detail).joined(separator: "\n"))
            }
            if facts["crossed"] == .bool(true) { element.fields["crossed"] = .bool(true) }
            if table, element.id == writing { element.fields["text"] = .string("") }
            switch element.type {
            case "container": container(&board, element, frames[element.id])
            case "arrow": arrow(&board, element, document, geometry: geometry, chosen: element.id == chosen)
            case "shape": card(&board, element, frames[element.id], facts: table ? facts : [:], table: table)
            case "text": words(&board, element, frames[element.id])
            case "stroke": stroke(&board, element)
            default: break
            }
            if (!table || element.id == hovered || element.id == chosen), let by = facts["by"]?.stringValue {
                let frame = frames[element.id] ?? geometry.arrowLine(element, in: document).map {
                    CGRect(x: ($0.start.x + $0.end.x) / 2, y: ($0.start.y + $0.end.y) / 2, width: 160, height: 0)
                }
                if let frame {
                    let words = by + (facts["changedBy"]?.stringValue.map { " · changed by " + $0 } ?? "")
                    board.draw(Text(words).font(.system(size: 10)).foregroundStyle(.secondary),
                               at: CGPoint(x: frame.minX + 4, y: frame.maxY + 3), anchor: .topLeading)
                }
            }
        }
        if let joining, let start = frames[joining.from] {
            var path = Path()
            let side = BoardGeometry.sides(start, CGRect(origin: joining.to, size: .zero)).from
            path.move(to: BoardGeometry.point(start, side: side))
            path.addLine(to: joining.to)
            board.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5 / camera.scale, dash: [5 / camera.scale, 4 / camera.scale]))
        }
        if let chosen, let element = document.element(chosen), element.type != "arrow", let frame = frames[element.id] {
            let outline = frame.insetBy(dx: -4 / camera.scale, dy: -4 / camera.scale)
            board.stroke(Path(roundedRect: outline, cornerRadius: 6 / camera.scale), with: .color(.primary.opacity(0.5)), lineWidth: 1.5 / camera.scale)
            if BoardGeometry.resizable(element) {
                let side = 9 / camera.scale
                for corner in table ? BoardGeometry.corners : [CGPoint(x: 1, y: 1)] {
                    let handle = CGRect(x: frame.minX + corner.x * frame.width - side / 2,
                                        y: frame.minY + corner.y * frame.height - side / 2, width: side, height: side)
                    board.fill(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(TodayPalette.cardFill))
                    board.stroke(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(.primary.opacity(0.7)), lineWidth: 1 / camera.scale)
                }
            }
        }
        if let dot {
            let circle = Path(ellipseIn: CGRect(x: dot.x - 5 / camera.scale, y: dot.y - 5 / camera.scale,
                                              width: 10 / camera.scale, height: 10 / camera.scale))
            board.fill(circle, with: .color(.primary))
            board.stroke(circle, with: .color(TodayPalette.cardFill), lineWidth: 2 / camera.scale)
        }
    }

    private static func grid(_ context: inout GraphicsContext, size: CGSize, camera: BoardCamera) {
        var step = 24 * camera.scale
        while step < 12 { step *= 2 }
        let dot = Color.primary.opacity(0.07)
        var x = camera.offset.x.truncatingRemainder(dividingBy: step)
        if x < 0 { x += step }
        while x < size.width {
            var y = camera.offset.y.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y < size.height {
                context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(dot))
                y += step
            }
            x += step
        }
    }

    private static func container(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?) {
        guard let frame else { return }
        let color = element.string("color")
        let shape = Path(roundedRect: frame, cornerRadius: 14, style: .continuous)
        context.fill(shape, with: .color(BoardPalette.fill(color).opacity(0.55)))
        context.stroke(shape, with: .color(BoardPalette.line(color).opacity(0.35)), lineWidth: 1)
        let title = Text(BoardGeometry.words(element.string("text") ?? "")).font(BoardGeometry.font(element)).foregroundStyle(.primary)
        context.draw(title, in: CGRect(x: frame.minX + 14, y: frame.minY + 10, width: max(frame.width - 28, 1), height: 22))
    }

    private static func card(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?,
                             facts: [String: PartFace.Value], table: Bool) {
        guard let frame else { return }
        let color = element.string("color")
        let radius: CGFloat = switch element.string("kind") ?? "" {
        case "pill": frame.height / 2
        case "rect": 3
        default: 10
        }
        let shape = Path(roundedRect: frame, cornerRadius: min(radius, frame.height / 2, frame.width / 2), style: .continuous)
        context.fill(shape, with: .color(BoardPalette.fill(color)))
        if let outline = element.string("stroke") {
            context.stroke(shape, with: .color(BoardPalette.line(outline)), lineWidth: 1.5)
        } else {
            context.stroke(shape, with: .color(TodayPalette.cardStroke), lineWidth: 1)
        }
        let inset = frame.insetBy(dx: 12, dy: 8)
        guard inset.width > 0, inset.height > 0 else { return }
        var inside = context
        inside.clip(to: shape)
        if let title = facts["title"]?.stringValue {
            let caption = [facts["alias"]?.stringValue, facts["state"]?.stringValue, facts["what"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
            let heading = inside.resolve(Text(title).font(BoardGeometry.font(element, table: true).weight(.medium))
                .strikethrough(element.fields["crossed"] == .bool(true)).foregroundStyle(BoardPalette.words(color, table: true)))
            let height = min(heading.measure(in: inset.size).height, max(16, inset.height - 28))
            inside.draw(heading, in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: height))
            inside.draw(Text(caption).font(.system(size: 16)).foregroundStyle(BoardPalette.words(color, table: true)),
                in: CGRect(x: inset.minX, y: inset.minY + height + 4, width: inset.width, height: 22))
            return
        }
        let text = Text(BoardGeometry.words(element.string("text") ?? "", font: table ? BoardGeometry.nsFont(element, table: true) : nil))
            .font(BoardGeometry.font(element, table: table))
            .strikethrough(element.fields["crossed"] == .bool(true))
            .foregroundStyle(BoardPalette.words(color, table: table))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: inset.size)
        inside.draw(resolved, in: CGRect(x: inset.minX, y: table ? inset.minY : inset.midY - min(measured.height, inset.height) / 2, width: inset.width,
                                         height: min(measured.height, inset.height)))
    }

    private static func words(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?) {
        guard let frame else { return }
        let text = Text(BoardGeometry.words(element.string("text") ?? "")).font(BoardGeometry.font(element))
            .strikethrough(element.fields["crossed"] == .bool(true))
            .foregroundStyle(element.string("size") == "small" ? Color.secondary : Color.primary)
        context.draw(text, in: frame)
    }

    private static func stroke(_ context: inout GraphicsContext, _ element: BoardDocument.Element) {
        guard let path = BoardGeometry.strokePath(element) else { return }
        context.stroke(path, with: .color(BoardPalette.line(element.string("color"))),
                       style: StrokeStyle(lineWidth: BoardGeometry.strokeWidth(element), lineCap: .round, lineJoin: .round))
    }

    private static func arrow(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ document: BoardDocument,
                              geometry: BoardGeometry, chosen: Bool) {
        guard let run = geometry.arrowLine(element, in: document) else { return }
        let start = run.start, end = run.end
        let color = chosen ? Color.primary : Color.secondary
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: chosen ? 3 : 1.5)
        let angle = atan2(end.y - start.y, end.x - start.x), head: CGFloat = 9
        var tip = Path()
        tip.move(to: end)
        tip.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7), y: end.y - head * sin(angle - .pi / 7)))
        tip.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7), y: end.y - head * sin(angle + .pi / 7)))
        tip.closeSubpath()
        context.fill(tip, with: .color(color))
        guard let label = element.string("label"), !label.isEmpty else { return }
        let resolved = context.resolve(Text(BoardGeometry.words(label)).font(ShellType.caption).foregroundStyle(.secondary))
        let measured = resolved.measure(in: CGSize(width: 200, height: 60))
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let box = CGRect(x: middle.x - measured.width / 2, y: middle.y - measured.height / 2, width: measured.width, height: measured.height)
        context.fill(Path(roundedRect: box.insetBy(dx: -5, dy: -2), cornerRadius: 6), with: .color(TodayPalette.cardFill))
        context.draw(resolved, in: box)
    }
}
