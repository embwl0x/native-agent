import Foundation
import CoreFoundation
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#endif
import SwiftUI
// Blueprint: | `BoardDocument.swift` | A board kept as a `.board` Make piece: one JSON document of elements, read, changed and written whole |

/// A board kept as a `.board` file, a Make piece like a table: `{"board": 1, "elements": [...]}`. Each element is an object with a unique
/// string `id` and a `type`: `shape` (x, y, w, h, text, color, kind rounded|pill|rect, size), `text` (x, y, text, size
/// title|large|body|small, optional w), `container` (a section: x, y, w, h, text as its title, color), `arrow` (from, to element ids,
/// optional label, fromSide and toSide left|right|top|bottom) and `stroke` (x, y, points [x0, y0, x1, y1, …] from x and y, color,
/// width). Colours are green, yellow, purple, blue, peach, white and ink. Every element keeps every field as written, the ones this
/// reader does not know included, so a change by hand rewrites only the fields it changed.
public struct BoardDocument: Sendable, Equatable {
    /// The Desk's standing board in the Make store.
    public static let tableRef = "table"
    /// The file type a board is kept as.
    public static let type = "board"
    public static func isBoard(type: String) -> Bool { type.lowercased() == Self.type }

    public struct Element: Sendable, Equatable {
        public var fields: [String: PartFace.Value]
        public init(_ fields: [String: PartFace.Value]) { self.fields = fields }

        public var id: String { fields["id"]?.stringValue ?? "" }
        public var type: String { fields["type"]?.stringValue ?? "" }
        public func string(_ key: String) -> String? { fields[key]?.stringValue }
        public func number(_ key: String) -> Double? { fields[key]?.doubleValue }
        public var numbers: [Double] {
            guard case .array(let values)? = fields["points"] else { return [] }
            return values.compactMap(\.doubleValue)
        }
        /// A position or size is written as a whole number: a drag lands on points, never on fractions of one.
        public mutating func set(_ key: String, _ value: Double) { fields[key] = .int(Int64(value.rounded())) }
    }

    /// The document's own fields besides its elements (`board` and any other), kept as written.
    public var fields: [String: PartFace.Value]
    public var elements: [Element]

    public struct Unreadable: LocalizedError, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public init(elements: [Element] = []) {
        fields = ["board": .int(1)]
        self.elements = elements
    }

    public init(_ text: String) throws {
        let value: PartFace.Value
        do { value = try JSONDecoder().decode(PartFace.Value.self, from: Data(text.utf8)) }
        catch { throw Unreadable(message: "It is not JSON.") }
        guard case .object(var top) = value, top["board"] == .int(1) else {
            throw Unreadable(message: "A board is a JSON object whose \"board\" is 1.")
        }
        guard case .array(let listed)? = top.removeValue(forKey: "elements") else {
            throw Unreadable(message: "A board holds its elements as an \"elements\" array.")
        }
        var seen = Set<String>()
        elements = try listed.enumerated().map { index, value in
            guard case .object(let fields) = value, case .string(let id)? = fields["id"], !id.isEmpty, case .string(_)? = fields["type"] else {
                throw Unreadable(message: "Element \(index + 1) is not an object with a string id and type.")
            }
            guard seen.insert(id).inserted else { throw Unreadable(message: "Two elements share the id \(id).") }
            return Element(fields)
        }
        fields = top
    }

    /// The whole document as a board file holds it: pretty-printed, keys sorted, elements in their order.
    public var text: String {
        var top = fields
        top["elements"] = .array(elements.map { .object($0.fields) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(PartFace.Value.object(top)), let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }

    public func element(_ id: String) -> Element? { elements.first { $0.id == id } }

    // Each change below says whether it changed anything: a change made on a version where its element is gone changes nothing.

    @discardableResult public mutating func move(_ ids: [String], dx: Double, dy: Double) -> Bool {
        guard dx.rounded() != 0 || dy.rounded() != 0 else { return false }
        var moved = false
        for index in elements.indices where ids.contains(elements[index].id) {
            guard let x = elements[index].number("x"), let y = elements[index].number("y") else { continue }
            elements[index].set("x", x + dx)
            elements[index].set("y", y + dy)
            moved = true
        }
        return moved
    }

    @discardableResult public mutating func resize(_ id: String, w: Double, h: Double) -> Bool {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return false }
        let before = (elements[index].number("w"), elements[index].number("h"))
        elements[index].set("w", w)
        elements[index].set("h", h)
        return before != (elements[index].number("w"), elements[index].number("h"))
    }

    @discardableResult public mutating func setText(_ id: String, _ text: String) -> Bool {
        guard let index = elements.firstIndex(where: { $0.id == id }), elements[index].string("text") != text else { return false }
        elements[index].fields["text"] = .string(text)
        return true
    }

    /// An id for an element the person adds by hand: unique, so no version laid meanwhile by anyone else can hold it, and what the person
    /// chose or is writing on stays theirs however their change is laid.
    public static func mintID() -> String { "p" + UUID().uuidString.lowercased() }

    /// The next free id: `e` and twelve lowercase hexadecimal digits from a fresh UUID.
    public var nextID: String {
        while true {
            let id = "e" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            if element(id) == nil { return id }
        }
    }

    /// Lays a new element under the id it carries while that id is free, else under the next free one, and returns the id it got.
    @discardableResult public mutating func add(_ fields: [String: PartFace.Value]) -> String {
        var fields = fields
        let asked = fields["id"]?.stringValue ?? ""
        let id = asked.isEmpty || element(asked) != nil ? nextID : asked
        fields["id"] = .string(id)
        elements.append(Element(fields))
        return id
    }

    /// Takes an element off the board, and every arrow that starts or ends at it.
    @discardableResult public mutating func remove(_ id: String) -> Bool {
        let before = elements.count
        elements.removeAll { $0.id == id || ($0.type == "arrow" && ($0.string("from") == id || $0.string("to") == id)) }
        return elements.count != before
    }
}

#if os(macOS)
extension BoardGeometry {
    public static var macTextScale: CGFloat {
        min(max(NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize / 13, 0.85), 2)
    }
}
#endif

extension BoardDocument.Element {
    var boardStrokeWidth: CGFloat { CGFloat(number("width") ?? 3) }

    func boardFrame(table: Bool, title: String?, textScale: CGFloat) -> CGRect? {
        guard let x = number("x"), let y = number("y"), x.isFinite, y.isFinite else { return nil }
        switch type {
        case "shape", "container":
            let width = CGFloat(number("w") ?? 160)
            var height = CGFloat(number("h") ?? 80)
            guard width.isFinite, height.isFinite else { return nil }
            if table, type == "shape" {
                if let title {
                    let measured = Self.measured(AttributedString(title), width: max(1, width - 24),
                        font: boardFont(table: true, heading: true, textScale: textScale))
                    height = max(height, ceil(measured.height) + Self.boardCardTitlePadding(textScale: textScale))
                } else { height = boardNoteHeight(words: string("text") ?? "", textScale: textScale) }
            }
            return CGRect(x: x, y: y, width: width, height: height)
        case "text":
            let width = CGFloat(number("w") ?? 640)
            guard width.isFinite else { return nil }
            let words = Self.boardWords(string("text") ?? "")
            let measured = Self.measured(words.characters.isEmpty ? AttributedString(" ") : words,
                width: max(1, width), font: boardFont(textScale: textScale))
            return CGRect(x: x, y: y, width: max(ceil(measured.width), 24), height: ceil(measured.height))
        default: return nil
        }
    }

    func boardPoints(table: Bool, textScale: CGFloat) -> CGFloat {
        let size: CGFloat = switch string("size") ?? "" {
        case "title": 28
        case "large": 20
        case "small": 12
        default: type == "container" ? 15 : 14
        }
        return (table ? max(22, size) : size) * textScale
    }

    private func boardWeight() -> Font.Weight {
        switch string("size") ?? "" {
        case "title": .semibold
        case "large": .medium
        default: type == "container" ? .semibold : .regular
        }
    }

    nonisolated(unsafe) private static let measuredHeights = NSCache<NSString, NSNumber>()

    private func boardNoteHeight(words: String, textScale: CGFloat) -> CGFloat {
        let font = boardFont(table: true, textScale: textScale), width = max(1, CGFloat(number("w") ?? 160) - 24)
        let key = "\(width)|\(CTFontGetSize(font))|\(boardWeightValue)|\(words)" as NSString
        let needed: CGFloat
        if let known = unsafe Self.measuredHeights.object(forKey: key) { needed = CGFloat(known.doubleValue) } else {
            needed = Self.measured(Self.boardWords(words), width: width, font: font).height
            unsafe Self.measuredHeights.setObject(NSNumber(value: Double(needed)), forKey: key)
        }
        return ceil(max(CGFloat(number("h") ?? 80), needed + 16))
    }

    private var boardWeightValue: Double {
        switch boardWeight() {
        case .semibold: 0.3
        case .medium: 0.23
        default: 0
        }
    }

    static func boardCardTitlePadding(textScale: CGFloat) -> CGFloat { 22 * textScale + 22 }

    func boardFont(table: Bool = false, heading: Bool = false, textScale: CGFloat) -> CTFont {
        let font = CTFont(.system, size: boardPoints(table: table, textScale: textScale))
        return Self.styledFont(font, weight: heading ? 0.23 : boardWeightValue)
    }

    public func boardEditorFont(table: Bool, textScale: CGFloat, zoom: CGFloat) -> Font {
        let font = boardFont(table: table, textScale: textScale)
        return Font(CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * zoom, nil, nil))
    }

    private static func styledFont(_ font: CTFont, weight: Double, italic: Bool = false) -> CTFont {
        guard weight != 0 || italic else { return font }
        var traits = [kCTFontWeightTrait as String: weight]
        if italic { traits[kCTFontSlantTrait as String] = 0.2 }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font),
            [kCTFontTraitsAttribute as String: traits] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    private static func inlineFont(_ font: CTFont, _ intent: InlinePresentationIntent) -> CTFont {
        let base = intent.contains(.code) ? CTFont(.userFixedPitch, size: CTFontGetSize(font)) : font
        if intent.contains(.emphasized) || intent.contains(.stronglyEmphasized) {
            let weight = intent.contains(.stronglyEmphasized) ? 0.4 :
                ((CTFontCopyTraits(base) as NSDictionary)[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
            return styledFont(base, weight: weight, italic: intent.contains(.emphasized))
        }
        return base
    }

    private static func measured(_ words: AttributedString, width: CGFloat, font: CTFont) -> CGSize {
        let attributed = NSMutableAttributedString(string: "")
        for run in words.runs {
            let face = inlineFont(font, run.inlinePresentationIntent ?? [])
            attributed.append(NSAttributedString(string: String(words[run.range].characters),
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face]))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    }

    static func boardWords(_ text: String, font: CTFont? = nil) -> AttributedString {
        var words = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? .init(text)
        if let font { for run in words.runs {
            words[run.range].swiftUI.font = Font(inlineFont(font, run.inlinePresentationIntent ?? []))
        } }
        return words
    }
}
