import Foundation
// Blueprint: | `BoardDocument.swift` | A board kept as a `.board` Make piece: one JSON document of elements, read, changed and written whole |

/// A board kept as a `.board` file, a Make piece like a table: `{"board": 1, "elements": [...]}`. Each element is an object with a unique
/// string `id` and a `type`: `shape` (x, y, w, h, text, color, kind rounded|pill|rect, size), `text` (x, y, text, size
/// title|large|body|small, optional w), `container` (a section: x, y, w, h, text as its title, color), `arrow` (from, to element ids,
/// optional label, fromSide and toSide left|right|top|bottom) and `stroke` (x, y, points [x0, y0, x1, y1, …] from x and y, color,
/// width). Colours are green, yellow, purple, blue, peach, white and ink. Every element keeps every field as written, the ones this
/// reader does not know included, so a change by hand rewrites only the fields it changed.
public struct BoardDocument: Sendable, Equatable {
    /// The file type a board is kept as.
    public static let type = "board"
    public static func isBoard(type: String) -> Bool { type.lowercased() == Self.type }

    public struct Element: Sendable, Equatable {
        public var fields: [String: PartFace.Value]
        public init(_ fields: [String: PartFace.Value]) { self.fields = fields }

        public var id: String { fields["id"]?.stringValue ?? "" }
        public var type: String { fields["type"]?.stringValue ?? "" }
        public func string(_ key: String) -> String? { fields[key]?.stringValue }
        public func number(_ key: String) -> Double? {
            switch fields[key] {
            case .int(let value)?: Double(value)
            case .double(let value)?: value
            default: nil
            }
        }
        public var numbers: [Double] {
            guard case .array(let values)? = fields["points"] else { return [] }
            return values.compactMap { value in
                switch value {
                case .int(let number): Double(number)
                case .double(let number): number
                default: nil
                }
            }
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
    public static func mintID() -> String { "p" + UUID().uuidString.lowercased().prefix(8) }

    /// The next free id: `e` and a number past every such id on the board.
    public var nextID: String {
        let taken = elements.compactMap { element -> Int? in
            element.id.hasPrefix("e") ? Int(element.id.dropFirst()) : nil
        }.max() ?? 0
        return "e\(taken + 1)"
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
