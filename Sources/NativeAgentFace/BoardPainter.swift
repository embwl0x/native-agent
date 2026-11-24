import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `BoardPainter.swift` | `BoardPalette`, `BoardPainter`: the board's quiet colours and its painting in board points |

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
                let detail = [facts["state"]?.stringValue, facts["what"]?.stringValue].compactMap { $0 }
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
        var dots = Path()
        var x = camera.offset.x.truncatingRemainder(dividingBy: step)
        if x < 0 { x += step }
        while x < size.width {
            var y = camera.offset.y.truncatingRemainder(dividingBy: step)
            if y < 0 { y += step }
            while y < size.height {
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                y += step
            }
            x += step
        }
        context.fill(dots, with: .color(dot))
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
            // The Desk number is how the person and she both name the card.
            let caption = [facts["alias"]?.stringValue, facts["state"]?.stringValue, facts["what"]?.stringValue].compactMap { $0 }
                .joined(separator: " · ")
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
