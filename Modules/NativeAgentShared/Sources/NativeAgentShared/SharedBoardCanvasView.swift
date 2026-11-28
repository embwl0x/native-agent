import CoreGraphics
import Darwin
import Foundation
import SwiftUI
// Blueprint: | `SharedBoardCanvasView.swift` | Shared board gestures, field edits, spatial accessibility and keyboard navigation |

public extension KeyEquivalent {
    static let backTab = KeyEquivalent("\u{19}")
}

#if os(macOS)
public struct BoardCanvasDrawing: PreferenceKey {
    public static var defaultValue: BoardDocument? { nil }
    public static func reduce(value: inout BoardDocument?, nextValue: () -> BoardDocument?) { value = nextValue() ?? value }
}
#endif

public struct BoardEdit {
    public let apply: (inout BoardDocument) -> Bool

    public init(_ apply: @escaping (inout BoardDocument) -> Bool) { self.apply = apply }
}

public struct TableElementEdit: Sendable {
    public enum Verb: String, Sendable {
        case put = "table.put", cross = "table.cross", remove = "table.remove"
    }

    public let verb: Verb
    public let id: String
    public let fields: [String: PartFace.Value]

    public init(_ verb: Verb, _ id: String, _ fields: [String: PartFace.Value] = [:]) {
        self.verb = verb
        self.id = id
        self.fields = fields
    }

    public var arguments: [String: PartFace.Value] {
        fields.merging(["id": .string(id)]) { _, id in id }
    }
}

public enum TableBoardTool: String, CaseIterable {
    case select = "Select", note = "Note", card = "Card", pen = "Pen", connect = "Connect"

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .note: "note.text"
        case .card: "rectangle.on.rectangle"
        case .pen: "pencil.tip"
        case .connect: "arrow.up.right"
        }
    }
}

public struct SharedBoardCanvasView: View {
    let document: BoardDocument
    let cards: [String: PartFace.Value]
    let geometry: BoardGeometry
    let palette: BoardPainter.Palette
    let table: Bool
    let changeable: Bool
    let behind: Bool
    let seen: Int
    let camera: BoardCamera
    let size: CGSize
    let placementSize: CGSize
    let writing: String?
    let focus: FocusState<Bool>.Binding
    let edit: @MainActor ([TableElementEdit]) -> Void
    let save: @MainActor (BoardEdit, Int) -> Void
    let open: @MainActor (BoardDocument.Element) -> Void
    let writeNote: @MainActor (BoardDocument.Element) -> Void
    let canOpen: @MainActor (BoardDocument.Element) -> Bool
    let pointAt: @MainActor (Bool, Bool) -> Void
    let hidden: Set<String>
    let locked: Set<String>
    @Binding var cameraOverride: BoardCamera?
    @Binding var tool: TableBoardTool
    @Binding var chosen: String?
    @Binding var connectFrom: String?
    @Binding var failed: Set<String>
    @State private var hover: CGPoint?
    @State private var hand: Hand?
    @State private var pointer: SpatialEventCollection.Event.ID?
    @State private var zoomFrom: BoardCamera?
    @State private var leavingElements = false

    public init(document: BoardDocument, cards: [String: PartFace.Value], geometry: BoardGeometry, palette: BoardPainter.Palette,
                table: Bool, changeable: Bool, behind: Bool = false, seen: Int = 0, camera: BoardCamera, size: CGSize, placementSize: CGSize,
                cameraOverride: Binding<BoardCamera?>, tool: Binding<TableBoardTool>, chosen: Binding<String?>,
                connectFrom: Binding<String?>, writing: String? = nil, focus: FocusState<Bool>.Binding,
                failed: Binding<Set<String>> = .constant([]), hidden: Set<String> = [], locked: Set<String> = [],
                edit: @escaping @MainActor ([TableElementEdit]) -> Void,
                save: @escaping @MainActor (BoardEdit, Int) -> Void = { _, _ in },
                canOpen: @escaping @MainActor (BoardDocument.Element) -> Bool,
                open: @escaping @MainActor (BoardDocument.Element) -> Void, writeNote: @escaping @MainActor (BoardDocument.Element) -> Void,
                pointAt: @escaping @MainActor (Bool, Bool) -> Void = { _, _ in }) {
        self.document = document
        self.cards = cards
        self.geometry = geometry
        self.palette = palette
        self.table = table
        self.changeable = changeable
        self.behind = behind
        self.seen = seen
        self.camera = camera
        self.size = size
        self.placementSize = placementSize
        _cameraOverride = cameraOverride
        _tool = tool
        _chosen = chosen
        _connectFrom = connectFrom
        self.writing = writing
        self.focus = focus
        _failed = failed
        self.hidden = hidden
        self.locked = locked
        self.edit = edit
        self.save = save
        self.canOpen = canOpen
        self.open = open
        self.writeNote = writeNote
        self.pointAt = pointAt
    }

    private struct Hand {
        enum Kind { case move([String]), resize(String, CGPoint), join(String), pan, draw(String) }
        let kind: Kind
        let document: BoardDocument
        let camera: BoardCamera
        let geometry: BoardGeometry
        let start: CGPoint
        var now: CGPoint
        var points: [CGPoint] = []
        let editable: Bool
        let seen: Int
        let under: String?
        var delta: CGSize { CGSize(width: (now.x - start.x) / camera.scale, height: (now.y - start.y) / camera.scale) }
        var travelled: CGFloat {
            if let first = points.first {
                return points.reduce(0) { max($0, hypot($1.x - first.x, $1.y - first.y) * camera.scale) }
            }
            return hypot(now.x - start.x, now.y - start.y)
        }

        func holds(_ id: String) -> Bool {
            switch kind {
            case .move(let ids): ids.contains(id)
            case .resize(let held, _), .join(let held): held == id
            case .pan, .draw: false
            }
        }
    }

    public var body: some View {
        let picture = drawing
        let hovered = hover.flatMap { geometry.hit(picture, at: camera.board($0), scale: camera.scale) }
        let dot = joinDot(in: picture, at: hover)
        let joining = hand.flatMap { hand -> (from: String, to: CGPoint)? in
            guard case .join(let from) = hand.kind else { return nil }
            return (from, hand.camera.board(hand.now))
        }
        let mark = connectFrom ?? chosen
        let reading = table ? geometry.spatialOrder(document) : []
        Canvas { context, size in
            BoardPainter.paint(&context, palette: palette, size: size, document: picture, camera: camera, chosen: mark,
                joining: joining, cards: cards, textScale: geometry.textScale, table: table,
                hovered: hovered?.id, dot: dot, writing: writing)
        }
        .contentShape(Rectangle())
        .gesture(SpatialEventGesture()
            .onChanged { receive($0) }
            .onEnded {
                receive($0, ending: true)
                hand = nil
                pointer = nil
            })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            guard changeable, tool == .select else { return }
            let spot = camera.board(tap.location)
            if let element = geometry.hit(document, at: spot, scale: camera.scale) {
                if element.id != writing, !locked.contains(element.id), canOpen(element) { activate(element) }
            } else { addNote(at: tap.location, camera: camera) }
        })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                hand = nil
                let from = zoomFrom ?? camera
                zoomFrom = from
                cameraOverride = from.zoomed(by: value.magnification, at: value.startLocation)
            }
            .onEnded { _ in zoomFrom = nil })
        .onContinuousHover { phase in
            guard table, changeable else { return }
            switch phase {
            case .active(let point):
                let onDot = dot.map { distance(camera.view($0), point) <= 9 } ?? false
                if !onDot { hover = point }
                pointAt(onDot, true)
            case .ended:
                hover = nil
                pointAt(false, false)
            }
        }
        .focusable(changeable || focus.wrappedValue)
        .focused(focus)
        .focusEffectDisabled()
        .onChange(of: focus.wrappedValue) { _, _ in leavingElements = false }
        .onKeyPress(keys: [.tab, .backTab, .leftArrow, .rightArrow, .upArrow, .downArrow, .return, .delete, .deleteForward, .escape, "0"]) {
            key($0, order: reading)
        }
        .accessibilityChildren {
            ZStack(alignment: .topLeading) {
                ForEach(reading) { entry in
                    accessibilityElement(entry, reading: reading)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .onChange(of: tool) { _, next in
            if next != .connect { connectFrom = nil }
        }
        .onChange(of: changeable) { _, enabled in
            if !enabled { hover = nil; pointAt(false, false) }
        }
        .onChange(of: changeable || behind) { _, enabled in
            if !enabled { hand = nil }
        }
        .onChange(of: failed) { _, ids in
            guard !ids.isEmpty else { return }
            if let hand, ids.contains(where: hand.holds) { self.hand = nil }
            failed = []
        }
        #if os(macOS)
        .preference(key: BoardCanvasDrawing.self, value: table && changeable ? picture : nil)
        #endif
    }

    private var drawing: BoardDocument {
        guard let hand else { return document }
        var picture = document
        if let stroke = stroke(hand) {
            _ = picture.add(stroke.arguments)
        } else if let change = movement(hand) {
            if table {
                for put in placement(hand, change) where !hidden.contains(put.id) {
                    if let index = picture.elements.firstIndex(where: { $0.id == put.id }) {
                        picture.elements[index].fields.merge(put.fields) { _, new in new }
                    }
                }
            } else {
                picture = hand.document
                _ = change.apply(&picture)
            }
        }
        return picture
    }

    private func receive(_ events: SpatialEventCollection, ending: Bool = false) {
        if events.filter({ $0.phase == .active }).count > 1 {
            pointer = pointer ?? events.first(where: { $0.phase == .active })?.id
            hand = nil
            return
        }
        if pointer == nil, !ending, zoomFrom == nil, let event = events.first(where: {
            guard $0.phase == .active else { return false }
            #if os(iOS)
            if $0.kind == .pencil { return true }
            #endif
            return $0.kind == .pointer || $0.kind == .touch
        }) {
            pointer = event.id
            begin(at: event.location)
        }
        guard let pointer, let event = events[pointer] else { return }
        if event.phase == .cancelled {
            hand = nil
            self.pointer = nil
            return
        }
        guard var hand else {
            if event.phase == .ended { self.pointer = nil }
            return
        }
        hand.now = event.location
        if case .draw = hand.kind, let last = hand.points.last {
            let point = hand.camera.board(hand.now)
            if distance(point, last) >= 2 { hand.points.append(point) }
        } else if case .pan = hand.kind, tool == .select, hand.travelled >= 3 {
            cameraOverride = BoardCamera(offset: CGPoint(x: hand.camera.offset.x + hand.now.x - hand.start.x,
                y: hand.camera.offset.y + hand.now.y - hand.start.y), scale: hand.camera.scale)
        }
        if event.phase == .ended || hand.points.count == 500 {
            self.hand = nil
            if event.phase == .ended { self.pointer = nil }
            end(hand)
        } else if !ending { self.hand = hand }
    }

    private func begin(at point: CGPoint) {
        let spot = camera.board(point)
        if table, let writing, document.element(writing).flatMap(geometry.frame)?.contains(spot) == true { return }
        if cameraOverride == nil { cameraOverride = camera }
        leavingElements = false
        if changeable { focus.wrappedValue = true }
        let under = geometry.hit(document, at: spot, scale: camera.scale)
        var kind = Hand.Kind.pan
        var points: [CGPoint] = []
        if changeable, table, tool == .pen {
            kind = .draw(BoardDocument.mintID())
            points = [spot]
        } else if changeable, tool == .select {
            if let chosen, !locked.contains(chosen), let element = document.element(chosen), BoardGeometry.resizable(element), let frame = geometry.frame(element),
               let corner = (table ? BoardGeometry.corners : [CGPoint(x: 1, y: 1)]).first(where: {
                   distance(camera.view(CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)), point) <= 9
               }) {
                kind = .resize(chosen, corner)
            } else if let hover, let dot = joinDot(in: document, at: hover), distance(camera.view(dot), point) <= 9,
                      let source = geometry.hit(document, at: camera.board(hover), scale: camera.scale) {
                kind = .join(source.id)
            } else if let under, under.type != "arrow", let frame = geometry.frame(under) {
                let rim = 8 / camera.scale
                if !table, under.type == "shape", !frame.insetBy(dx: rim, dy: rim).contains(spot) { kind = .join(under.id) }
                else {
                    let ids = carried(by: under, frame: frame)
                    if locked.isDisjoint(with: ids) { kind = .move(ids) }
                }
            }
        }
        hand = Hand(kind: kind, document: document, camera: camera, geometry: geometry, start: point,
                    now: point, points: points, editable: changeable, seen: seen, under: under?.id)
    }

    private func end(_ hand: Hand) {
        guard hand.editable, changeable || behind else { return }
        if hand.travelled < 3 {
            guard changeable else { return }
            switch tool {
            case .note:
                tool = .select
                addNote(at: hand.now, camera: hand.camera)
            case .connect:
                guard let target = hand.under.flatMap(document.element), !locked.contains(target.id), target.type == "shape" else { connectFrom = nil; return }
                if let from = connectFrom, from != target.id {
                    join(from, at: hand.camera.board(hand.now), in: document, camera: hand.camera, seen: hand.seen)
                    tool = .select
                    connectFrom = nil
                } else { connectFrom = target.id; chosen = target.id }
            default: chosen = hand.under
            }
            return
        }
        cameraOverride = cameraOverride ?? hand.camera
        if let stroke = stroke(hand) {
            edit([stroke])
        } else if case .join(let from) = hand.kind {
            join(from, at: hand.camera.board(hand.now), in: table ? document : hand.document, camera: hand.camera, seen: hand.seen)
        } else if let change = movement(hand) {
            if case .move(let ids) = hand.kind { chosen = ids.first }
            if table { edit(placement(hand, change).filter { !hidden.contains($0.id) }) }
            else {
                var probe = hand.document
                if change.apply(&probe) { save(change, hand.seen) }
            }
        }
    }

    private func carried(by element: BoardDocument.Element, frame: CGRect) -> [String] {
        element.type == "container" ? [element.id] + geometry.inside(frame, of: document, except: element.id) : [element.id]
    }

    private func movement(_ hand: Hand) -> BoardEdit? {
        let dx = Double(hand.delta.width), dy = Double(hand.delta.height)
        switch hand.kind {
        case .move(let ids):
            return BoardEdit { $0.move(ids, dx: dx, dy: dy) }
        case .resize(let id, let corner):
            guard let element = hand.document.element(id), element.number("w") != nil, element.number("h") != nil,
                  let frame = hand.geometry.frame(element) else { return nil }
            let w = Double(frame.width), h = Double(frame.height)
            let least: (w: Double, h: Double) = element.type == "container" ? (120, 80) : (48, 32)
            let width = max(least.w, w + dx * (corner.x == 0 ? -1 : 1))
            let height = max(least.h, h + dy * (corner.y == 0 ? -1 : 1))
            return BoardEdit { document in
                let sized = document.resize(id, w: width, h: height)
                let shifted = document.move([id], dx: corner.x == 0 ? w - width : 0, dy: corner.y == 0 ? h - height : 0)
                return sized || shifted
            }
        case .join, .pan, .draw: return nil
        }
    }

    private func placement(_ hand: Hand, _ change: BoardEdit) -> [TableElementEdit] {
        switch hand.kind {
        case .move(let ids): return placements(ids, keys: ["x", "y"], from: hand.document, change)
        case .resize(let id, _): return placements([id], keys: ["x", "y", "w", "h"], from: hand.document, change)
        case .join, .pan, .draw: return []
        }
    }

    private func placements(_ ids: [String], keys: Set<String>, from original: BoardDocument, _ change: BoardEdit) -> [TableElementEdit] {
        var result = original
        guard change.apply(&result) else { return [] }
        return ids.compactMap { id in
            guard let element = result.element(id), element != original.element(id) else { return nil }
            return TableElementEdit(.put, id, element.fields.filter { keys.contains($0.key) })
        }
    }

    private func stroke(_ hand: Hand) -> TableElementEdit? {
        guard case .draw(let id) = hand.kind, let first = hand.points.first else { return nil }
        return TableElementEdit(.put, id, [
            "type": .string("stroke"), "x": .int(Int64(first.x.rounded())), "y": .int(Int64(first.y.rounded())),
            "points": .array(hand.points.flatMap { [.int(Int64(($0.x - first.x).rounded())), .int(Int64(($0.y - first.y).rounded()))] }),
            "color": .string("ink"), "width": .int(2)
        ])
    }

    private func joinDot(in picture: BoardDocument, at hover: CGPoint?) -> CGPoint? {
        guard table, changeable, tool == .select, let hover else { return nil }
        let spot = camera.board(hover)
        return geometry.hit(picture, at: spot, scale: camera.scale).flatMap { geometry.joinDot($0, at: spot) }
    }

    private func join(_ from: String, at point: CGPoint, in picture: BoardDocument, camera: BoardCamera, seen: Int) {
        guard let to = geometry.hit(picture, at: point, scale: camera.scale), to.id != from, !table || to.type == "shape",
              !locked.contains(from), !locked.contains(to.id),
              let start = picture.element(from).flatMap(geometry.frame), let finish = geometry.frame(to) else { return }
        let sides = BoardGeometry.sides(start, finish)
        let arrow = TableElementEdit(.put, BoardDocument.mintID(), ["type": .string("arrow"), "from": .string(from),
            "to": .string(to.id), "fromSide": .string(sides.from), "toSide": .string(sides.to)])
        if table { edit([arrow]) }
        else {
            save(BoardEdit { document in
                guard document.element(from) != nil, document.element(to.id) != nil else { return false }
                document.add(arrow.arguments)
                return true
            }, seen)
        }
    }

    public static func note(color: String, at middle: CGPoint, in document: BoardDocument, geometry: BoardGeometry,
                            visible: CGRect? = nil) -> BoardDocument.Element {
        let size = visible == nil ? CGSize(width: 180, height: 80) : CGSize(width: 200, height: 110)
        let origin = visible.map { geometry.landing(size, at: middle, in: $0, document) }
            ?? CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
        return BoardDocument.Element(["id": .string(BoardDocument.mintID()), "type": .string("shape"), "kind": .string("rounded"),
            "size": .string("body"), "color": .string(color), "text": .string(""), "x": .int(Int64(origin.x.rounded())),
            "y": .int(Int64(origin.y.rounded())), "w": .int(Int64(size.width)), "h": .int(Int64(size.height))])
    }

    public static func linkedCard(_ choice: [String: PartFace.Value], camera: BoardCamera, size: CGSize,
                                  document: BoardDocument, geometry: BoardGeometry) -> TableElementEdit? {
        let key = choice["item"] == nil ? "piece" : "item"
        guard let pointer = choice[key], pointer.stringValue != nil else { return nil }
        let center = camera.board(CGPoint(x: size.width / 2, y: size.height / 2))
        let origin = geometry.landing(CGSize(width: 260, height: 120), at: center,
            in: camera.board(CGRect(origin: .zero, size: size)), document)
        return TableElementEdit(.put, BoardDocument.mintID(), ["type": .string("shape"), key: pointer,
            "x": .int(Int64(origin.x.rounded())), "y": .int(Int64(origin.y.rounded())), "w": .int(260), "h": .int(120)])
    }

    private func addNote(at point: CGPoint, camera: BoardCamera) {
        cameraOverride = camera
        let note = Self.note(color: "white", at: camera.board(point), in: document, geometry: geometry,
            visible: table ? camera.board(CGRect(origin: .zero, size: placementSize)) : nil)
        chosen = note.id
        writeNote(note)
    }

    private func activate(_ element: BoardDocument.Element) {
        chosen = element.id
        open(element)
    }

    private func remove(_ id: String) {
        chosen = nil
        if connectFrom == id { connectFrom = nil }
        if table { edit([TableElementEdit(.remove, id)]) }
        else { save(BoardEdit { $0.remove(id) }, seen) }
    }

    private func key(_ press: KeyPress, order: [BoardGeometry.SpatialEntry]) -> KeyPress.Result {
        guard changeable, writing == nil else { return .ignored }
        if press.key == .escape {
            guard chosen != nil || tool != .select || hand != nil || (table && !leavingElements) else { return .ignored }
            chosen = nil
            connectFrom = nil
            tool = .select
            hand = nil
            leavingElements = true
            return .handled
        }
        if press.key == .tab || press.key == .backTab, table, !leavingElements, !order.isEmpty, press.modifiers.subtracting(.shift).isEmpty {
            let backwards = press.key == .backTab || press.modifiers.contains(.shift)
            let index = order.firstIndex { $0.id == chosen }
            let next = index.map { ($0 + (backwards ? order.count - 1 : 1)) % order.count }
                ?? (backwards ? order.count - 1 : 0)
            let entry = order[next]
            chosen = entry.id
            let frame = entry.frame
            if !CGRect(origin: .zero, size: size).contains(camera.view(frame)) {
                cameraOverride = BoardCamera(offset: CGPoint(x: size.width / 2 - frame.midX * camera.scale,
                    y: size.height / 2 - frame.midY * camera.scale), scale: camera.scale)
            }
            return .handled
        }
        if press.key == "0", press.modifiers == .command {
            cameraOverride = nil
            return .handled
        }
        guard let element = chosen.flatMap(document.element), !locked.contains(element.id) else { return .ignored }
        if press.key == .delete || press.key == .deleteForward { remove(element.id); return .handled }
        if press.key == .return, canOpen(element) { activate(element); return .handled }
        guard table, press.modifiers.subtracting(.shift).isEmpty, let frame = geometry.frame(element) else { return .ignored }
        let step: Double = press.modifiers.contains(.shift) ? 24 : 8
        let dx: Double, dy: Double
        switch press.key {
        case .leftArrow: (dx, dy) = (-step, 0)
        case .rightArrow: (dx, dy) = (step, 0)
        case .upArrow: (dx, dy) = (0, -step)
        case .downArrow: (dx, dy) = (0, step)
        default: return .ignored
        }
        cameraOverride = camera
        let ids = carried(by: element, frame: frame)
        edit(placements(ids, keys: ["x", "y"], from: document, BoardEdit { $0.move(ids, dx: dx, dy: dy) }))
        return .handled
    }

    private func accessibilityElement(_ entry: BoardGeometry.SpatialEntry, reading: [BoardGeometry.SpatialEntry]) -> some View {
        let element = entry.element
        let shown = camera.view(entry.frame)
        return Rectangle()
            .frame(width: max(12, shown.width), height: max(12, shown.height))
            .position(x: shown.midX, y: shown.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(geometry.spokenTitle(element, in: document)))
            .accessibilityValue(Text(geometry.spokenPosition(element, frame: entry.frame, in: document, reading: reading)))
            .accessibilitySortPriority(Double(reading.count - entry.rank))
            .accessibilityAddTraits(chosen == element.id ? .isSelected : [])
            .accessibilityActions {
                if changeable, !locked.contains(element.id) {
                    if canOpen(element) { Button("Open") { activate(element) } }
                    Button("Cross off") { edit([TableElementEdit(.cross, element.id)]) }
                    Button("Remove") { remove(element.id) }
                }
            }
    }

    private func distance(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
        hypot(left.x - right.x, left.y - right.y)
    }
}
