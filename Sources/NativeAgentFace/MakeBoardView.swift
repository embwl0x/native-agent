import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `MakeBoardView.swift` | A Make board drawn as a native board; a change by hand is laid as the next version on the newest |

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
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietCaptureSession) private var capture
    @State private var arrival: BoardArrival?
    @State private var issue: String?
    private var key: FaceKey { .makePreview(reference: reference, version: version) }
    private var preview: MakePreviewFace? { appModel.face.slot(key).value(as: MakePreviewFace.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            if let capture {
                if let preview, let board = capture.held(preview)?.board {
                    MakeBoardView(reference: reference, arrival: BoardArrival(document: board, version: version), still: true)
                } else { FaceReadStatus(state: preview?.state) }
            } else if let arrival {
                MakeBoardView(reference: reference, arrival: arrival)
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
        .modifier(FaceObservation(demand: .key(key)))
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
    var offset: CGPoint
    var scale: CGFloat
    func view(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y) }
    func board(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale) }
    func view(_ rect: CGRect) -> CGRect {
        CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
    func zoomed(by factor: CGFloat, at point: CGPoint) -> BoardCamera {
        let scale = min(3, max(0.2, self.scale * factor)), ratio = scale / self.scale
        return BoardCamera(offset: CGPoint(x: point.x - (point.x - offset.x) * ratio, y: point.y - (point.y - offset.y) * ratio), scale: scale)
    }
}

/// What the person's hand holds between pressing and letting go: the board as it was drawn then, and what the drag does to it.
struct BoardHand {
    enum Kind { case move([String]), resize(String), join(String), pan(BoardCamera) }
    let kind: Kind
    let document: BoardDocument
    let camera: BoardCamera
    let start: CGPoint
    var now: CGPoint
    let seen: Int
    let under: String?
    var board: CGSize { CGSize(width: (now.x - start.x) / camera.scale, height: (now.y - start.y) / camera.scale) }
    var travelled: CGFloat { hypot(now.x - start.x, now.y - start.y) }
}

/// A board drawn as a board: sections, cards, words, pen lines and the arrows between them, on the page's own material. Drag a card to
/// move it (a section carries what lies in it), its corner to size it, its edge onto another card to join them with an arrow; double-click
/// to write on it, or on the empty board to add a card there; Delete takes the chosen one off; drag the empty board to look around and
/// pinch to zoom. Every change by hand is laid as the next version when the hand lets go.
struct MakeBoardView: View {
    let reference: String
    let arrival: BoardArrival
    /// A picture of the page: drawn as read, nothing to change.
    var still = false
    @Environment(AppModel.self) private var appModel
    @State private var hand: BoardHand?
    @State private var chosen: String?
    @State private var writing: String?
    @State private var camera: BoardCamera?
    @State private var zoomFrom: BoardCamera?
    @FocusState private var focused: Bool

    static let height: CGFloat = 560

    var body: some View {
        let state = MakeBoardState.of(reference)
        let older = !still && state.read > MakeBoardState.number(arrival.version)
        let changeable = !still && !older && state.latest != nil
        let base = changeable ? (state.current ?? arrival.document) : arrival.document
        VStack(alignment: .leading, spacing: 8) {
            if !still, let said = MakePieceWords.shared.said[reference] {
                Text(said).font(ShellType.label).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if older {
                Text("This is version \(arrival.version). Changes by hand go on the newest, version \(state.read).")
                    .font(ShellType.label).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let camera = self.camera ?? BoardGeometry.fit(base, in: geometry.size)
                let drawn = hand.map(Self.held) ?? base
                let mark = changeable ? chosen : nil
                let joining = hand.flatMap(Self.joining)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        BoardPainter.paint(&context, size: size, document: drawn, camera: camera, chosen: mark, joining: joining)
                    }
                    if let writing, let element = drawn.element(writing), let frame = BoardGeometry.frame(element) {
                        let shown = camera.view(frame).insetBy(dx: element.type == "shape" ? 6 * camera.scale : 0, dy: 0)
                        BoardWordsEditor(text: element.string("text") ?? "",
                                         font: BoardGeometry.font(element, scale: camera.scale)) { words in
                            self.writing = nil
                            focused = true
                            guard let words else { return }
                            state.change(BoardEdit { $0.setText(writing, words) }, seen: state.newer, appModel: appModel)
                        }
                        .frame(width: max(shown.width, 160), alignment: .leading)
                        .position(x: max(shown.width, 160) / 2 + shown.minX, y: shown.midY)
                    }
                    if changeable { controls(state, camera: camera, size: geometry.size) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if hand == nil { begin(at: value.startLocation, base, camera: camera, changeable: changeable, seen: state.newer) }
                        hand?.now = value.location
                        if let hand, case .pan(let from) = hand.kind {
                            self.camera = BoardCamera(offset: CGPoint(x: from.offset.x + hand.now.x - hand.start.x,
                                                                      y: from.offset.y + hand.now.y - hand.start.y), scale: from.scale)
                        }
                    }
                    .onEnded { value in
                        hand?.now = value.location
                        if let held = hand { end(held, state) }
                        hand = nil
                    })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                    guard changeable else { return }
                    write(at: tap.location, base, camera: camera, state)
                })
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let from = zoomFrom ?? camera
                        zoomFrom = from
                        self.camera = from.zoomed(by: value.magnification, at: value.startLocation)
                    }
                    .onEnded { _ in zoomFrom = nil })
                .onAppear { if self.camera == nil { self.camera = camera } }
            }
            .frame(height: Self.height)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous).strokeBorder(TodayPalette.cardStroke))
            .focusable(changeable)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard changeable, writing == nil, let gone = chosen else { return .ignored }
                chosen = nil
                state.change(BoardEdit { $0.remove(gone) }, seen: state.newer, appModel: appModel)
                return .handled
            }
            .onKeyPress(.escape) {
                guard chosen != nil else { return .ignored }
                chosen = nil
                return .handled
            }
            .help(changeable ? "Drag a card to move it, its corner to size it, or its edge onto another card to join them. Double-click to write." : "")
            if state.isSaving, !still { Text("Saving…").font(ShellType.label).foregroundStyle(.secondary) }
        }
        .onChange(of: arrival, initial: true) { _, now in if !still { state.arrive(now, appModel: appModel) } }
    }

    private func controls(_ state: MakeBoardState, camera: BoardCamera, size: CGSize) -> some View {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 10) {
            Menu {
                ForEach(BoardPalette.names, id: \.self) { name in
                    Button(name.prefix(1).uppercased() + name.dropFirst()) { addCard(name, at: camera.board(middle), state) }
                }
            } label: { Label("Add a card", systemImage: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { self.camera = camera.zoomed(by: 0.8, at: middle) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button("Fit") { self.camera = BoardGeometry.fit(state.current ?? arrival.document, in: size) }.help("Fit the whole board")
            Button { self.camera = camera.zoomed(by: 1.25, at: middle) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
        }
        .buttonStyle(.borderless)
        .font(ShellType.label)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The board with what the hand is doing to it drawn in place, made by the same change that is laid when it lets go.
    private static func held(_ hand: BoardHand) -> BoardDocument {
        var document = hand.document
        if let edit = edit(hand) { _ = edit.apply(&document) }
        return document
    }

    private static func joining(_ hand: BoardHand) -> (from: String, to: CGPoint)? {
        guard case .join(let from) = hand.kind else { return nil }
        return (from, hand.camera.board(hand.now))
    }

    private static func edit(_ hand: BoardHand) -> BoardEdit? {
        let moved = hand.board
        switch hand.kind {
        case .move(let ids):
            let dx = Double(moved.width), dy = Double(moved.height)
            return BoardEdit { $0.move(ids, dx: dx, dy: dy) }
        case .resize(let id):
            guard let element = hand.document.element(id), let w = element.number("w"), let h = element.number("h") else { return nil }
            let least: (w: Double, h: Double) = element.type == "container" ? (120, 80) : (48, 32)
            let width = max(least.w, w + Double(moved.width)), height = max(least.h, h + Double(moved.height))
            return BoardEdit { $0.resize(id, w: width, h: height) }
        case .join, .pan: return nil
        }
    }

    private func begin(at point: CGPoint, _ document: BoardDocument, camera: BoardCamera, changeable: Bool, seen: Int) {
        focused = true
        let spot = camera.board(point)
        let under = BoardGeometry.hit(document, at: spot, scale: camera.scale)
        var kind = BoardHand.Kind.pan(camera)
        if changeable {
            if let chosen, let element = document.element(chosen), BoardGeometry.resizable(element), let frame = BoardGeometry.frame(element),
               hypot(camera.view(frame).maxX - point.x, camera.view(frame).maxY - point.y) <= 9 {
                kind = .resize(chosen)
            } else if let under, under.type != "arrow", let frame = BoardGeometry.frame(under) {
                let rim = 8 / camera.scale
                if under.type == "shape", !frame.insetBy(dx: rim, dy: rim).contains(spot) { kind = .join(under.id) }
                else if under.type == "container" { kind = .move([under.id] + BoardGeometry.inside(frame, of: document, except: under.id)) }
                else { kind = .move([under.id]) }
            }
        }
        hand = BoardHand(kind: kind, document: document, camera: camera, start: point, now: point, seen: seen, under: under?.id)
    }

    private func end(_ hand: BoardHand, _ state: MakeBoardState) {
        // A press that hardly moved is a click: it chooses what is under it, or nothing.
        guard hand.travelled >= 3 else {
            chosen = hand.under
            return
        }
        if case .join(let from) = hand.kind {
            let spot = hand.camera.board(hand.now)
            guard let to = BoardGeometry.hit(hand.document, at: spot, scale: hand.camera.scale), to.id != from,
                  let start = hand.document.element(from).flatMap(BoardGeometry.frame), let finish = BoardGeometry.frame(to) else { return }
            let sides = BoardGeometry.sides(start, finish)
            let arrow: [String: PartFace.Value] = ["id": .string(BoardDocument.mintID()), "type": .string("arrow"), "from": .string(from), "to": .string(to.id),
                                                   "fromSide": .string(sides.from), "toSide": .string(sides.to)]
            state.change(BoardEdit { document in
                guard document.element(from) != nil, document.element(to.id) != nil else { return false }
                document.add(arrow)
                return true
            }, seen: hand.seen, appModel: appModel)
            return
        }
        guard let edit = Self.edit(hand) else { return }
        var probe = hand.document
        guard edit.apply(&probe) else { return }
        if case .move(let ids) = hand.kind { chosen = ids.first }
        state.change(edit, seen: hand.seen, appModel: appModel)
    }

    /// A double-click writes on what is under it; on the empty board it adds a card there to write on.
    private func write(at point: CGPoint, _ document: BoardDocument, camera: BoardCamera, _ state: MakeBoardState) {
        let spot = camera.board(point)
        if let under = BoardGeometry.hit(document, at: spot, scale: camera.scale), ["shape", "text", "container"].contains(under.type) {
            chosen = under.id
            writing = under.id
        } else { addCard("white", at: spot, state) }
    }

    private func addCard(_ color: String, at middle: CGPoint, _ state: MakeBoardState) {
        guard state.current != nil else { return }
        let id = BoardDocument.mintID()
        let card: [String: PartFace.Value] = ["id": .string(id), "type": .string("shape"), "kind": .string("rounded"), "size": .string("body"),
            "color": .string(color), "text": .string(""), "x": .int(Int64((middle.x - 90).rounded())), "y": .int(Int64((middle.y - 40).rounded())),
            "w": .int(180), "h": .int(80)]
        state.change(BoardEdit { document in
            document.add(card)
            return true
        }, seen: state.newer, appModel: appModel)
        chosen = id
        writing = id
    }
}

/// One element's words being written in place: Return keeps them, Escape leaves them as they were, and clicking away keeps them. It
/// settles once.
private struct BoardWordsEditor: View {
    let text: String
    let font: Font
    let end: (String?) -> Void
    @State private var draft = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onSubmit { settle(draft) }
            .onKeyPress(.escape) {
                settle(nil)
                return .handled
            }
            .onExitCommand { settle(nil) }
            .onChange(of: focused) { _, now in if !now { settle(draft) } }
            .onAppear {
                draft = text
                DispatchQueue.main.async { focused = true }
            }
    }

    private func settle(_ words: String?) {
        guard !ended else { return }
        ended = true
        end(words == text ? nil : words)
    }
}

/// Where each element is on the board and what is under a point. Cards, sections and pen lines carry their own frame; words are as large
/// as they are set.
enum BoardGeometry {
    static func frame(_ element: BoardDocument.Element) -> CGRect? {
        guard let x = element.number("x"), let y = element.number("y") else { return nil }
        switch element.type {
        case "shape", "container":
            return CGRect(x: x, y: y, width: element.number("w") ?? 160, height: element.number("h") ?? 80)
        case "text":
            let words = plain(element.string("text") ?? "")
            let measured = ((words.isEmpty ? " " : words) as NSString).boundingRect(
                with: CGSize(width: element.number("w") ?? 640, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: nsFont(element)])
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
    static func hit(_ document: BoardDocument, at point: CGPoint, scale: CGFloat) -> BoardDocument.Element? {
        let ordered = order(document).reversed()
        if let found = ordered.first(where: { element in
            guard element.type != "arrow", let frame = frame(element) else { return false }
            let slack = element.type == "stroke" ? 6 / scale : 0
            return frame.insetBy(dx: -slack, dy: -slack).contains(point)
        }) { return found }
        return ordered.first { element in
            guard let line = arrowLine(element, in: document) else { return false }
            return distance(point, from: line.start, to: line.end) <= 6 / scale
        }
    }

    /// Where an arrow runs: from the side of the element it leaves to the side of the one it reaches.
    static func arrowLine(_ element: BoardDocument.Element, in document: BoardDocument) -> (start: CGPoint, end: CGPoint)? {
        guard element.type == "arrow", let from = element.string("from").flatMap(document.element).flatMap(frame),
              let to = element.string("to").flatMap(document.element).flatMap(frame) else { return nil }
        let facing = sides(from, to)
        return (point(from, side: element.string("fromSide") ?? facing.from), point(to, side: element.string("toSide") ?? facing.to))
    }

    static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    /// What lies in a section: every element but arrows whose middle is inside its frame.
    static func inside(_ frame: CGRect, of document: BoardDocument, except id: String) -> [String] {
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

    /// The whole board in view, at most at its own size, with a margin.
    static func fit(_ document: BoardDocument, in size: CGSize) -> BoardCamera {
        let frames = document.elements.compactMap(frame)
        guard let first = frames.first, size.width > 1, size.height > 1 else { return BoardCamera(offset: CGPoint(x: 24, y: 24), scale: 1) }
        let whole = frames.dropFirst().reduce(first) { $0.union($1) }
        let margin: CGFloat = 32
        let scale = max(0.2, min(1, (size.width - margin * 2) / max(whole.width, 1), (size.height - margin * 2) / max(whole.height, 1)))
        return BoardCamera(offset: CGPoint(x: (size.width - whole.width * scale) / 2 - whole.minX * scale, y: margin - whole.minY * scale),
                           scale: scale)
    }

    static func points(_ element: BoardDocument.Element) -> CGFloat {
        switch element.string("size") ?? "" {
        case "title": 28
        case "large": 20
        case "small": 12
        default: element.type == "container" ? 15 : 14
        }
    }

    static func weight(_ element: BoardDocument.Element) -> Font.Weight {
        switch element.string("size") ?? "" {
        case "title": .semibold
        case "large": .medium
        default: element.type == "container" ? .semibold : .regular
        }
    }

    static func font(_ element: BoardDocument.Element, scale: CGFloat = 1) -> Font {
        .system(size: points(element) * scale, weight: weight(element))
    }

    static func nsFont(_ element: BoardDocument.Element) -> NSFont {
        let thickness: NSFont.Weight = switch weight(element) {
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        return .systemFont(ofSize: points(element), weight: thickness)
    }

    /// Words as written, their inline Markdown read: **bold**, *italic*, `code`, links.
    static func words(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
    static func words(_ name: String?) -> Color { name == "ink" ? dynamic(light: 0xF6F3EE, dark: 0x1C1D20) : .primary }

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
                      joining: (from: String, to: CGPoint)?) {
        grid(&context, size: size, camera: camera)
        var board = context
        board.translateBy(x: camera.offset.x, y: camera.offset.y)
        board.scaleBy(x: camera.scale, y: camera.scale)
        let frames = Dictionary(document.elements.compactMap { element in BoardGeometry.frame(element).map { (element.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        for element in BoardGeometry.order(document) {
            switch element.type {
            case "container": container(&board, element, frames[element.id])
            case "arrow": arrow(&board, element, document, chosen: element.id == chosen)
            case "shape": card(&board, element, frames[element.id])
            case "text": words(&board, element, frames[element.id])
            case "stroke": stroke(&board, element)
            default: break
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
                let handle = CGRect(x: frame.maxX - side / 2, y: frame.maxY - side / 2, width: side, height: side)
                board.fill(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(TodayPalette.cardFill))
                board.stroke(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(.primary.opacity(0.7)), lineWidth: 1 / camera.scale)
            }
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

    private static func card(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?) {
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
        let text = Text(BoardGeometry.words(element.string("text") ?? "")).font(BoardGeometry.font(element))
            .foregroundStyle(BoardPalette.words(color))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: inset.size)
        var inside = context
        inside.clip(to: shape)
        inside.draw(resolved, in: CGRect(x: inset.minX, y: inset.midY - min(measured.height, inset.height) / 2, width: inset.width,
                                         height: min(measured.height, inset.height)))
    }

    private static func words(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?) {
        guard let frame else { return }
        let text = Text(BoardGeometry.words(element.string("text") ?? "")).font(BoardGeometry.font(element))
            .foregroundStyle(element.string("size") == "small" ? Color.secondary : Color.primary)
        context.draw(text, in: frame)
    }

    private static func stroke(_ context: inout GraphicsContext, _ element: BoardDocument.Element) {
        guard let x = element.number("x"), let y = element.number("y") else { return }
        let points = element.numbers
        guard points.count >= 4 else { return }
        var path = Path()
        path.move(to: CGPoint(x: x + points[0], y: y + points[1]))
        for index in stride(from: 2, to: points.count - 1, by: 2) { path.addLine(to: CGPoint(x: x + points[index], y: y + points[index + 1])) }
        context.stroke(path, with: .color(BoardPalette.line(element.string("color"))),
                       style: StrokeStyle(lineWidth: element.number("width") ?? 3, lineCap: .round, lineJoin: .round))
    }

    private static func arrow(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ document: BoardDocument, chosen: Bool) {
        guard let run = BoardGeometry.arrowLine(element, in: document) else { return }
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
