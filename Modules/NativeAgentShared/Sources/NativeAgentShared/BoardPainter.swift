import CoreGraphics
import CoreText
import Foundation
import SwiftUI
// Blueprint: | `BoardPainter.swift` | Shared SwiftUI painting of a board in board points, using a host palette |

public struct BoardSliceView: View {
    let document: BoardDocument
    let cards: [String: PartFace.Value]
    let ids: [String]?
    let textScale: CGFloat
    let palette: BoardPainter.Palette
    let open: @MainActor () -> Void

    public init(document: BoardDocument, cards: [String: PartFace.Value], ids: [String]?,
                textScale: CGFloat, palette: BoardPainter.Palette, open: @escaping @MainActor () -> Void) {
        self.document = document; self.cards = cards; self.ids = ids
        self.textScale = textScale; self.palette = palette; self.open = open
    }

    public var body: some View {
        let geometry = BoardGeometry(cards: cards, textScale: textScale)
        let slice = geometry.slice(document, ids: ids)
        if slice.elements.isEmpty {
            Text(ids == nil ? "The table is empty." : "No matching elements are on the table.").foregroundStyle(.secondary)
        } else {
            Button(action: open) {
                Canvas { context, size in
                    BoardPainter.paint(&context, palette: palette, size: size, document: slice,
                        camera: geometry.fit(slice, in: size, minimumScale: 0), chosen: nil,
                        joining: nil, cards: cards, textScale: textScale, table: true)
                }
                .frame(height: 220)
                .background(palette.cardFill, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the table at this slice")
            .accessibilityValue(Text(slice.elements.prefix(12).map { element in
                if case .object(let facts)? = cards[element.id], let title = facts["title"]?.stringValue {
                    return PartFace.oneLine(title, limit: 80)
                }
                return PartFace.oneLine(element.string("text") ?? element.type, limit: 80)
            }.joined(separator: ", ")))
        }
    }
}

/// Paints a board in view space, transformed into board points: a quiet dot grid, sections, arrows, then cards, words and pen lines.
public enum BoardPainter {
    public struct Palette {
        let fill: (String?) -> Color
        let words: (String?, Bool) -> Color
        let line: (String?) -> Color
        let cardFill: Color
        let cardStroke: Color
        let caption: Font

        public init(fill: @escaping (String?) -> Color, words: @escaping (String?, Bool) -> Color,
                    line: @escaping (String?) -> Color, cardFill: Color, cardStroke: Color, caption: Font) {
            self.fill = fill
            self.words = words
            self.line = line
            self.cardFill = cardFill
            self.cardStroke = cardStroke
            self.caption = caption
        }
    }

    public static func paint(_ context: inout GraphicsContext, palette: Palette, size: CGSize, document: BoardDocument, camera: BoardCamera, chosen: String?,
                      joining: (from: String, to: CGPoint)?, cards: [String: PartFace.Value], textScale: CGFloat, table: Bool = false,
                      hovered: String? = nil, dot: CGPoint? = nil, writing: String? = nil) {
        grid(&context, size: size, camera: camera)
        var board = context
        board.translateBy(x: camera.offset.x, y: camera.offset.y)
        board.scaleBy(x: camera.scale, y: camera.scale)
        let geometry = BoardGeometry(cards: table ? cards : nil, textScale: textScale)
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
            case "container": container(&board, element, frames[element.id], textScale: textScale, palette: palette)
            case "arrow": arrow(&board, element, document, geometry: geometry, chosen: element.id == chosen, palette: palette)
            case "shape": card(&board, element, frames[element.id], facts: table ? facts : [:], table: table, textScale: textScale, palette: palette)
            case "text": words(&board, element, frames[element.id], textScale: textScale)
            case "stroke": stroke(&board, element, palette: palette)
            default: break
            }
            if (!table || element.id == hovered || element.id == chosen), let by = facts["by"]?.stringValue {
                let frame = frames[element.id] ?? geometry.arrowLine(element, in: document).map {
                    CGRect(x: ($0.start.x + $0.end.x) / 2, y: ($0.start.y + $0.end.y) / 2, width: 160, height: 0)
                }
                if let frame {
                    let words = by + (facts["changedBy"]?.stringValue.map { " · changed by " + $0 } ?? "")
                    board.draw(Text(words).font(.system(size: 10 * textScale)).foregroundStyle(.secondary),
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
                    board.fill(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(palette.cardFill))
                    board.stroke(Path(roundedRect: handle, cornerRadius: 2 / camera.scale), with: .color(.primary.opacity(0.7)), lineWidth: 1 / camera.scale)
                }
            }
        }
        if let dot {
            let circle = Path(ellipseIn: CGRect(x: dot.x - 5 / camera.scale, y: dot.y - 5 / camera.scale,
                                              width: 10 / camera.scale, height: 10 / camera.scale))
            board.fill(circle, with: .color(.primary))
            board.stroke(circle, with: .color(palette.cardFill), lineWidth: 2 / camera.scale)
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

    private static func container(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?,
                                  textScale: CGFloat, palette: Palette) {
        guard let frame else { return }
        let color = element.string("color")
        let shape = Path(roundedRect: frame, cornerRadius: 14, style: .continuous)
        context.fill(shape, with: .color(palette.fill(color).opacity(0.55)))
        context.stroke(shape, with: .color(palette.line(color).opacity(0.35)), lineWidth: 1)
        let title = Text(BoardDocument.Element.boardWords(element.string("text") ?? ""))
            .font(Font(element.boardFont(textScale: textScale))).foregroundStyle(.primary)
        context.draw(title, in: CGRect(x: frame.minX + 14, y: frame.minY + 10, width: max(frame.width - 28, 1), height: 22 * textScale))
    }

    private static func card(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?,
                             facts: [String: PartFace.Value], table: Bool, textScale: CGFloat, palette: Palette) {
        guard let frame else { return }
        let color = element.string("color")
        let radius: CGFloat = switch element.string("kind") ?? "" {
        case "pill": frame.height / 2
        case "rect": 3
        default: 10
        }
        let shape = Path(roundedRect: frame, cornerRadius: min(radius, frame.height / 2, frame.width / 2), style: .continuous)
        context.fill(shape, with: .color(palette.fill(color)))
        if let outline = element.string("stroke") {
            context.stroke(shape, with: .color(palette.line(outline)), lineWidth: 1.5)
        } else {
            context.stroke(shape, with: .color(palette.cardStroke), lineWidth: 1)
        }
        let inset = frame.insetBy(dx: 12, dy: 8)
        guard inset.width > 0, inset.height > 0 else { return }
        var inside = context
        inside.clip(to: shape)
        if let title = facts["title"]?.stringValue {
            // The Desk number is how the person and she both name the card.
            let caption = [facts["alias"]?.stringValue, facts["state"]?.stringValue, facts["what"]?.stringValue].compactMap { $0 }
                .joined(separator: " · ")
            let heading = inside.resolve(Text(title).font(Font(element.boardFont(table: true, heading: true, textScale: textScale)))
                .strikethrough(element.fields["crossed"] == .bool(true)).foregroundStyle(palette.words(color, true)))
            let captionHeight = 22 * textScale
            let height = min(heading.measure(in: inset.size).height, max(16, inset.height - captionHeight - 6))
            inside.draw(heading, in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: height))
            inside.draw(Text(caption).font(.system(size: 16 * textScale)).foregroundStyle(palette.words(color, true)),
                in: CGRect(x: inset.minX, y: inset.minY + height + 4, width: inset.width, height: captionHeight))
            return
        }
        let font = element.boardFont(table: table, textScale: textScale)
        let text = Text(BoardDocument.Element.boardWords(element.string("text") ?? "", font: table ? font : nil))
            .font(Font(font))
            .strikethrough(element.fields["crossed"] == .bool(true))
            .foregroundStyle(palette.words(color, table))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: inset.size)
        inside.draw(resolved, in: CGRect(x: inset.minX, y: table ? inset.minY : inset.midY - min(measured.height, inset.height) / 2, width: inset.width,
                                         height: min(measured.height, inset.height)))
    }

    private static func words(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ frame: CGRect?, textScale: CGFloat) {
        guard let frame else { return }
        let font = element.boardFont(textScale: textScale)
        let text = Text(BoardDocument.Element.boardWords(element.string("text") ?? "", font: font)).font(Font(font))
            .strikethrough(element.fields["crossed"] == .bool(true))
            .foregroundStyle(element.string("size") == "small" ? Color.secondary : Color.primary)
        context.draw(text, in: frame)
    }

    private static func stroke(_ context: inout GraphicsContext, _ element: BoardDocument.Element, palette: Palette) {
        guard let path = BoardGeometry.strokePath(element) else { return }
        context.stroke(path, with: .color(palette.line(element.string("color"))), style: BoardGeometry.strokeStyle(element))
    }

    private static func arrow(_ context: inout GraphicsContext, _ element: BoardDocument.Element, _ document: BoardDocument,
                              geometry: BoardGeometry, chosen: Bool, palette: Palette) {
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
        let resolved = context.resolve(Text(BoardDocument.Element.boardWords(label)).font(palette.caption).foregroundStyle(.secondary))
        let measured = resolved.measure(in: CGSize(width: 200, height: 60))
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let box = CGRect(x: middle.x - measured.width / 2, y: middle.y - measured.height / 2, width: measured.width, height: measured.height)
        context.fill(Path(roundedRect: box.insetBy(dx: -5, dy: -2), cornerRadius: 6), with: .color(palette.cardFill))
        context.draw(resolved, in: box)
    }
}
