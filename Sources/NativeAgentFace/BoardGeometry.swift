import CoreGraphics
import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `BoardGeometry.swift` | `BoardGeometry`: where each board element is, its measured frame and what is under a point |

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
        if let known = unsafe measuredHeights.object(forKey: key) { needed = CGFloat(known.doubleValue) } else {
            needed = NSAttributedString(Self.words(words, font: font)).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            unsafe measuredHeights.setObject(NSNumber(value: Double(needed)), forKey: key)
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
