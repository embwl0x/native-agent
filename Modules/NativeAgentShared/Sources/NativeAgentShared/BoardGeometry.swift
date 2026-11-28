import CoreGraphics
import Foundation
import SwiftUI
// Blueprint: | `BoardGeometry.swift` | Shared board frames, hit testing, spatial reading order, containment, anchors and camera transforms |

/// Where each element is on the board and what is under a point. Cards, sections and pen lines carry their own frame; words are as large
/// as they are set.
public struct BoardGeometry: Sendable {
    public enum Anchor: String, CaseIterable, Sendable { case beside, after, under, inside, cluster }

    private let cards: [String: PartFace.Value]?
    let textScale: CGFloat

    public init(cards: [String: PartFace.Value]? = nil, textScale: CGFloat) {
        self.cards = cards
        self.textScale = textScale
    }

    public func landing(_ size: CGSize, at wanted: CGPoint, in visible: CGRect, _ document: BoardDocument) -> CGPoint {
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
    public static let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
    public func joinDot(_ element: BoardDocument.Element, at point: CGPoint) -> CGPoint? {
        guard element.type == "shape", let frame = frame(element) else { return nil }
        let edges = [("left", abs(point.x - frame.minX)), ("right", abs(point.x - frame.maxX)),
                     ("top", abs(point.y - frame.minY)), ("bottom", abs(point.y - frame.maxY))]
        return edges.min { $0.1 < $1.1 }.map { Self.point(frame, side: $0.0) }
    }
    public func frame(_ element: BoardDocument.Element) -> CGRect? {
        if element.type == "stroke" {
            if let path = Self.strokePath(element) {
                return Self.strokeBounds(path, style: Self.strokeStyle(element))
            }
            let points = element.numbers
            guard (2...3).contains(points.count), let x = element.number("x"), let y = element.number("y"),
                  (x + points[0]).isFinite, (y + points[1]).isFinite else { return nil }
            return CGRect(x: x + points[0], y: y + points[1], width: 0, height: 0)
        }
        let title: String?
        if case .object(let facts)? = cards?[element.id] { title = facts["title"]?.stringValue }
        else { title = nil }
        return element.boardFrame(table: cards != nil, title: title, textScale: textScale)
    }

    public func tableBounds(_ element: BoardDocument.Element) -> CGRect? {
        guard let rect = frame(element)?.standardized else { return nil }
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        return rect
    }

    public func elementFrame(_ element: BoardDocument.Element, in document: BoardDocument) -> CGRect? {
        if let frame = tableBounds(element) { return frame }
        guard let line = arrowLine(element, in: document) else { return nil }
        return CGRect(x: min(line.start.x, line.end.x), y: min(line.start.y, line.end.y),
                      width: abs(line.start.x - line.end.x), height: abs(line.start.y - line.end.y))
    }

    struct SpatialEntry: Identifiable {
        let element: BoardDocument.Element
        let frame: CGRect
        let rank: Int
        var id: String { element.id }
    }

    func spatialOrder(_ document: BoardDocument) -> [SpatialEntry] {
        let frames = document.elements.compactMap { element in
            elementFrame(element, in: document).map { (element, $0) }
        }
        return frames.sorted { ($0.1.minY, $0.1.minX, $0.0.id) < ($1.1.minY, $1.1.minX, $1.0.id) }
            .enumerated().map { SpatialEntry(element: $0.element.0, frame: $0.element.1, rank: $0.offset) }
    }

    func spokenTitle(_ element: BoardDocument.Element, in document: BoardDocument) -> String {
        if element.type == "arrow" {
            if let label = element.string("label"), !label.isEmpty { return PartFace.oneLine(label, limit: 100) }
            if let from = element.string("from").flatMap(document.element), from.type != "arrow",
               let to = element.string("to").flatMap(document.element), to.type != "arrow" {
                return "Arrow from \(spokenTitle(from, in: document)) to \(spokenTitle(to, in: document))"
            }
            return "Arrow"
        }
        let words = cardFacts(element)["title"]?.stringValue ?? element.string("text")
        if let words, !words.isEmpty { return PartFace.oneLine(words, limit: 100) }
        switch element.type {
        case "shape": return "Card"
        case "container": return "Section"
        case "text": return "Text"
        case "stroke": return "Ink stroke"
        default: return "Table element"
        }
    }

    func spokenPosition(_ element: BoardDocument.Element, frame: CGRect,
                        in document: BoardDocument, reading: [SpatialEntry]) -> String {
        let facts = cardFacts(element)
        func rank(_ frame: CGRect, _ id: String) -> (CGFloat, String) { (frame.width * frame.height, id) }
        let container = reading.lazy.filter { $0.element.type == "container" && $0.id != element.id }
            .filter { Self.containsCenter(of: frame, in: $0.frame)
                && (element.type != "container" || rank(frame, element.id) < rank($0.frame, $0.id)) }
            .min { rank($0.frame, $0.id) < rank($1.frame, $1.id) }
        let neighbour = reading.lazy.filter {
            $0.id != element.id && ["shape", "text"].contains($0.element.type)
        }
            .filter { other in
                let candidate = other.frame
                return candidate.minY < frame.maxY && frame.minY < candidate.maxY
                    && (candidate.maxX <= frame.minX || frame.maxX <= candidate.minX)
            }
            .min { abs($0.frame.midX - frame.midX) < abs($1.frame.midX - frame.midX) }
        var words: [String] = []
        if facts["crossed"] == .bool(true) || element.fields["crossed"] == .bool(true) { words.append("Crossed off") }
        if let state = facts["state"]?.stringValue { words.append(state) }
        if let container { words.append("Inside \(spokenTitle(container.element, in: document))") }
        if let neighbour {
            let side = neighbour.frame.midX < frame.midX ? "Right of" : "Left of"
            words.append("\(side) \(spokenTitle(neighbour.element, in: document))")
        }
        if case .array(let peers)? = facts["peer_sources"] {
            let names = peers.compactMap(\.stringValue)
            if !names.isEmpty { words.append("Contact provenance: " + names.joined(separator: ", ")) }
        }
        return words.joined(separator: ". ")
    }

    public func cardFacts(_ element: BoardDocument.Element) -> [String: PartFace.Value] {
        if case .object(let facts)? = cards?[element.id] { return facts }
        return [:]
    }

    public func anchorLanding(_ anchor: Anchor, frame: CGRect, size: CGSize, gap: CGFloat,
                                     blockers: [CGRect], limit: CGFloat) -> CGPoint? {
        if anchor == .inside {
            let header = BoardDocument.Element.boardCardTitlePadding(textScale: textScale)
            return Self.insideLanding(frame, size: size, blockers: blockers, limit: limit, header: header)
        }
        let beside = anchor == .beside
        func along(_ rect: CGRect) -> CGRect {
            beside ? rect : CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
        }
        let origin = along(frame), alignedSize = along(CGRect(origin: .zero, size: size)).size
        let blockers = blockers.map(along).sorted { $0.minX < $1.minX }
        let leading = origin.maxX + gap
        guard abs(leading) <= limit, abs(origin.minY) <= limit else { return nil }
        let start = leading.rounded(.up), preferred = origin.minY.rounded(), step: CGFloat = 24
        let rows = Set([preferred] + blockers.flatMap {
            let before = ($0.minY - alignedSize.height).rounded(.down), after = $0.maxY.rounded(.up)
            return [preferred + ((before - preferred) / step).rounded(.down) * step,
                    preferred + ((after - preferred) / step).rounded(.up) * step]
        }).filter { abs($0) <= limit }.sorted { (abs($0 - preferred), -$0) < (abs($1 - preferred), -$1) }
        var nearest: (point: CGPoint, distance: CGFloat)?
        for row in rows {
            let offset = abs(row - preferred)
            if let nearest, offset >= nearest.distance { break }
            let x = Self.firstClearX(start, y: row, size: alignedSize, blockers: blockers, limit: limit, step: step)
            guard x <= limit else { continue }
            let distance = hypot(x - start, offset)
            if nearest.map({ distance < $0.distance }) ?? true { nearest = (CGPoint(x: x, y: row), distance) }
        }
        guard let point = nearest?.point else { return nil }
        return beside ? point : CGPoint(x: point.y, y: point.x)
    }

    private static func insideLanding(_ frame: CGRect, size: CGSize, blockers: [CGRect], limit: CGFloat, header: CGFloat) -> CGPoint? {
        let start = max(-limit, (frame.minX + 16).rounded(.up))
        let top = max(-limit, (frame.minY + header).rounded(.up))
        let right = min(limit, (frame.maxX - 16 - size.width).rounded(.down))
        let bottom = min(limit, (frame.maxY - 16 - size.height).rounded(.down))
        guard start <= right, top <= bottom else { return nil }
        // A neighbour keeps the same 16 points of air the container's own edge does.
        let blockers = blockers.filter { $0.width > 0 && $0.height > 0 }.map { $0.insetBy(dx: -16, dy: -16) }
            .filter { $0.minX < right + size.width && $0.maxX > start && $0.minY < bottom + size.height && $0.maxY > top }
            .sorted { $0.minX < $1.minX }
        let rows = Set([top] + blockers.map { $0.maxY.rounded(.up) }.filter { $0 <= bottom }).sorted()
        for row in rows {
            let x = firstClearX(start, y: row, size: size, blockers: blockers, limit: right, step: 1)
            if x <= right { return CGPoint(x: x, y: row) }
        }
        return nil
    }

    public func growingInside(_ frame: CGRect, size: CGSize, blockers: [CGRect], limit: CGFloat)
        -> (position: CGPoint, size: CGSize)? {
        let header = BoardDocument.Element.boardCardTitlePadding(textScale: textScale)
        let sizes = [CGSize(width: limit, height: frame.height), CGSize(width: frame.width, height: limit),
                     CGSize(width: limit, height: limit)]
        var best: (position: CGPoint, size: CGSize)?
        for sizeLimit in sizes {
            let expanded = CGRect(origin: frame.origin, size: sizeLimit)
            guard let position = Self.insideLanding(expanded, size: size, blockers: blockers, limit: limit, header: header) else { continue }
            let width = max(frame.width, (position.x + size.width + 16 - frame.minX).rounded(.up))
            let height = max(frame.height, (position.y + size.height + 16 - frame.minY).rounded(.up))
            guard width <= limit, height <= limit else { continue }
            if let best, best.size.width + best.size.height <= width + height { continue }
            best = (position, CGSize(width: width, height: height))
        }
        return best
    }

    private static func firstClearX(_ start: CGFloat, y: CGFloat, size: CGSize, blockers: [CGRect], limit: CGFloat, step: CGFloat) -> CGFloat {
        var x = start
        for blocker in blockers where blocker.minY < y + size.height && blocker.maxY > y && blocker.height > 0 {
            if blocker.minX >= x + size.width { break }
            if blocker.maxX > x, blocker.width > 0 {
                x = start + ((blocker.maxX.rounded(.up) - start) / step).rounded(.up) * step
            }
            if x > limit { break }
        }
        return x
    }

    public static func resizable(_ element: BoardDocument.Element) -> Bool { ["shape", "container"].contains(element.type) }

    /// The drawing order: sections under everything, then arrows, then the rest as the document lists them.
    public static func order(_ document: BoardDocument) -> [BoardDocument.Element] {
        document.elements.filter { $0.type == "container" } + document.elements.filter { $0.type == "arrow" }
            + document.elements.filter { $0.type != "container" && $0.type != "arrow" }
    }

    /// The topmost element under a board point; a pen line or an arrow is under a point a few view points from it.
    public func hit(_ document: BoardDocument, at point: CGPoint, scale: CGFloat) -> BoardDocument.Element? {
        let slack = 6 / scale
        return Self.order(document).reversed().first { element in
            switch element.type {
            case "arrow":
                guard let line = arrowLine(element, in: document) else { return false }
                return Self.distance(point, from: line.start, to: line.end) <= slack
            case "stroke":
                let style = Self.strokeStyle(element, slack: slack)
                if let path = Self.strokePath(element) {
                    guard Self.strokeBounds(path, style: style).contains(point) else { return false }
                    return path.strokedPath(style).contains(point)
                }
                let points = element.numbers
                guard let x = element.number("x"), let y = element.number("y"), points.count >= 2 else { return false }
                return hypot(point.x - x - points[0], point.y - y - points[1]) <= style.lineWidth / 2
            default:
                return frame(element)?.contains(point) == true
            }
        }
    }

    static func strokeStyle(_ element: BoardDocument.Element, slack: CGFloat = 0) -> StrokeStyle {
        StrokeStyle(lineWidth: max(0, element.boardStrokeWidth) + 2 * slack, lineCap: .round, lineJoin: .round)
    }

    private static func strokeBounds(_ path: Path, style: StrokeStyle) -> CGRect {
        let radius = style.lineWidth / 2
        return path.cgPath.boundingBoxOfPath.insetBy(dx: -radius, dy: -radius)
    }

    /// A pen line as drawn: a smooth curve through its points; two points are a straight line.
    static func strokePath(_ element: BoardDocument.Element) -> Path? {
        guard let x = element.number("x"), let y = element.number("y"), x.isFinite, y.isFinite else { return nil }
        let points = element.numbers
        guard points.count >= 4, element.boardStrokeWidth.isFinite,
              points.allSatisfy({ $0.isFinite && (x + $0).isFinite && (y + $0).isFinite }) else { return nil }
        var path = Path()
        path.move(to: CGPoint(x: x + points[0], y: y + points[1]))
        for index in stride(from: 2, to: points.count - 1, by: 2) {
            let previous = CGPoint(x: x + points[index - 2], y: y + points[index - 1])
            let next = CGPoint(x: x + points[index], y: y + points[index + 1])
            if points.count == 4 { path.addLine(to: next) }
            else { path.addQuadCurve(to: CGPoint(x: previous.x / 2 + next.x / 2, y: previous.y / 2 + next.y / 2), control: previous) }
        }
        if points.count > 4 { path.addLine(to: CGPoint(x: x + points[points.count - 2], y: y + points[points.count - 1])) }
        return path
    }

    /// Where an arrow runs: from the side of the element it leaves to the side of the one it reaches.
    public func arrowLine(_ element: BoardDocument.Element, in document: BoardDocument) -> (start: CGPoint, end: CGPoint)? {
        guard element.type == "arrow", let from = element.string("from").flatMap(document.element).flatMap(frame),
              let to = element.string("to").flatMap(document.element).flatMap(frame) else { return nil }
        let facing = Self.sides(from, to)
        return (Self.point(from, side: element.string("fromSide") ?? facing.from), Self.point(to, side: element.string("toSide") ?? facing.to))
    }

    private static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    /// What lies in a section: every element but arrows whose middle is inside its frame.
    public func inside(_ frame: CGRect, of document: BoardDocument, except id: String) -> [String] {
        document.elements.compactMap { element in
            guard element.id != id, element.type != "arrow", let own = self.frame(element),
                  Self.containsCenter(of: own, in: frame) else { return nil }
            return element.id
        }
    }

    static func containsCenter(of frame: CGRect, in container: CGRect) -> Bool {
        container.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    public func slice(_ document: BoardDocument, ids: [String]?) -> BoardDocument {
        guard let ids else { return document }
        let existing = Set(document.elements.map(\.id))
        let requested = existing.intersection(ids)
        var included = requested
        let regions = document.elements.filter { $0.type == "container" }
        for region in regions where requested.contains(region.id) {
            if let frame = frame(region) { included.formUnion(inside(frame, of: document, except: region.id)) }
        }
        let arrows = document.elements.filter { $0.type == "arrow" }
        for arrow in arrows where requested.contains(arrow.id) {
            if let from = arrow.string("from"), let to = arrow.string("to") {
                included.formUnion([from, to].filter(existing.contains))
            }
        }
        let centers = document.elements.filter { included.contains($0.id) && $0.type != "arrow" }
            .compactMap { frame($0).map { CGPoint(x: $0.midX, y: $0.midY) } }
        for region in regions where !included.contains(region.id) {
            if let frame = frame(region), centers.contains(where: frame.contains) {
                included.insert(region.id)
            }
        }
        for arrow in arrows {
            if let from = arrow.string("from"), let to = arrow.string("to"), included.contains(from), included.contains(to) {
                included.insert(arrow.id)
            }
        }
        var slice = document
        slice.elements.removeAll { !included.contains($0.id) }
        return slice
    }

    public static func point(_ frame: CGRect, side: String) -> CGPoint {
        switch side {
        case "left": CGPoint(x: frame.minX, y: frame.midY)
        case "right": CGPoint(x: frame.maxX, y: frame.midY)
        case "top": CGPoint(x: frame.midX, y: frame.minY)
        default: CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    /// The sides two frames face each other by, along the axis they are further apart on.
    public static func sides(_ from: CGRect, _ to: CGRect) -> (from: String, to: String) {
        let dx = to.midX - from.midX, dy = to.midY - from.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? ("right", "left") : ("left", "right") }
        return dy >= 0 ? ("bottom", "top") : ("top", "bottom")
    }

    /// The board fitted and centred in view, at most at its own size and never below 60%; content too large for that is centred on its
    /// newest element. An empty board is at its own size with its origin at the centre.
    public func fit(_ document: BoardDocument, in size: CGSize, minimumScale: CGFloat = 0.6) -> BoardCamera {
        let frames = document.elements.compactMap(tableBounds)
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let first = frames.first else { return BoardCamera(offset: middle, scale: 1) }
        let whole = frames.dropFirst().reduce(first) { $0.union($1) }
        let margin = min(32, max(0, min(size.width, size.height) / 4))
        let fit = min(1, (size.width - margin * 2) / max(whole.width, 1), (size.height - margin * 2) / max(whole.height, 1))
        let scale = max(0.000001, minimumScale, fit)
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
}

/// Where the board is looked at from: board points times `scale`, plus `offset`, are view points.
public struct BoardCamera: Equatable, Sendable {
    public init(offset: CGPoint, scale: CGFloat) {
        self.offset = offset
        self.scale = scale
    }
    public static let maximumScale: CGFloat = 2
    public var offset: CGPoint
    public var scale: CGFloat
    public func view(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y) }
    public func board(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale) }
    public func view(_ rect: CGRect) -> CGRect {
        CGRect(origin: view(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
    public func board(_ rect: CGRect) -> CGRect {
        CGRect(origin: board(rect.origin), size: CGSize(width: rect.width / scale, height: rect.height / scale))
    }
    public func zoomed(by factor: CGFloat, at point: CGPoint) -> BoardCamera {
        let scale = min(Self.maximumScale, max(0.25, self.scale * factor)), ratio = scale / self.scale
        return BoardCamera(offset: CGPoint(x: point.x - (point.x - offset.x) * ratio, y: point.y - (point.y - offset.y) * ratio), scale: scale)
    }
}
