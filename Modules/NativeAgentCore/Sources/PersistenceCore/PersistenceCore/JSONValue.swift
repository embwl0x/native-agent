import CoreFoundation
import NativeAgentShared
import Foundation
// Blueprint: | `JSONValue.swift` | `JSONValue`, `decodeCompletion`, `fromEncodable`, `mapStrings`, `decodedExactly`, `digest`, `serializedSHA256`, `differences` |

// MARK: - JSONValue

public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Sorted object leaves and indexed array leaves; empty containers are leaves. False means the collected prefix is incomplete at the caller's bounds.
    @discardableResult
    package func leaves(prefix: String = "", into out: inout [(path: String, value: JSONValue)],
                        limit: Int, depthLimit: Int = .max, depth: Int = 0) -> Bool {
        guard out.count < limit, depth < depthLimit else { return false }
        switch self {
        case .object(let fields) where !fields.isEmpty:
            for (key, child) in fields.sorted(by: { $0.key < $1.key }) {
                guard child.leaves(prefix: prefix + "/" + Self.escapedPointerComponent(key), into: &out,
                                   limit: limit, depthLimit: depthLimit, depth: depth + 1) else { return false }
            }
        case .array(let values) where !values.isEmpty:
            for (index, child) in values.enumerated() {
                guard child.leaves(prefix: prefix + "/" + String(index), into: &out,
                                   limit: limit, depthLimit: depthLimit, depth: depth + 1) else { return false }
            }
        default: out.append((path: prefix, value: self))
        }
        return true
    }

    package static func escapedPointerComponent(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    package func replacing(at path: ArraySlice<String>, with leaf: JSONValue) -> JSONValue? {
        guard let head = path.first else { return leaf }
        switch self {
        case .object(var fields):
            guard let child = fields[head], let next = child.replacing(at: path.dropFirst(), with: leaf) else { return nil }
            fields[head] = next
            return .object(fields)
        case .array(var values):
            guard let index = Int(head), values.indices.contains(index),
                  let next = values[index].replacing(at: path.dropFirst(), with: leaf) else { return nil }
            values[index] = next
            return .array(values)
        default: return nil
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value): return !value.isEmpty
        case .array(let value): return !value.isEmpty
        case .object(let value): return !value.isEmpty
        }
    }

    public var stringFields: [String: String] {
        guard case .object(let fields) = self else { return [:] }
        return fields.compactMapValues { value in
            guard case .string(let text) = value else { return nil }
            return text
        }
    }

    public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(JSONEncoder().encode(value))
    }

    package func mapStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .string(let string):
            return .string(transform(string))
        case .array(let items):
            return .array(items.map { $0.mapStrings(transform) })
        case .object(let object):
            return .object(object.mapValues { $0.mapStrings(transform) })
        default:
            return self
        }
    }

    /// Decode the first balanced object/array candidate matching this job's type. Candidates may nest inside the other container kind, never their own. Quoted
    /// brackets and escapes are data.
    public static func decodeCompletion<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        var stack: [(start: String.Index, close: Character)] = []
        var spans: [Range<String.Index>] = []
        var inString = false
        var escaped = false
        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"", !stack.isEmpty {
                inString = true
            } else if c == "[" || c == "{" {
                stack.append((i, c == "[" ? "]" : "}"))
            } else if c == "]" || c == "}" {
                if let open = stack.last, open.close == c {
                    if !stack.dropLast().contains(where: { $0.close == c }) {
                        spans.append(open.start..<text.index(after: i))
                    }
                    stack.removeLast()
                } else { stack.removeAll() }
            }
        }
        var failure: Error = CocoaError(.coderInvalidValue)
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            do { return try JSONDecoder().decode(type, from: Data(text[span].utf8)) }
            catch { failure = error }
        }
        throw failure
    }

    public static func parse(_ data: Data) throws(CocoaError) -> JSONValue {
        let bytes = data.span
        let width: Int
        let bigEndian: Bool
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0 {
            (width, bigEndian) = (4, true)
        } else if bytes.count >= 4, bytes[2] == 0, bytes[3] == 0 {
            (width, bigEndian) = (4, false)
        } else if bytes.count >= 2, bytes[0] == 0 || (bytes[0] == 0xfe && bytes[1] == 0xff) {
            (width, bigEndian) = (2, true)
        } else if bytes.count >= 2, bytes[1] == 0 || (bytes[0] == 0xff && bytes[1] == 0xfe) {
            (width, bigEndian) = (2, false)
        } else {
            return try parseUTF8(data.bytes)
        }
        guard bytes.count.isMultiple(of: width) else { throw CocoaError(.propertyListReadCorrupt) }
        var utf8: [UInt8] = []
        var high: UInt32?
        for offset in stride(from: 0, to: bytes.count, by: width) {
            var code: UInt32 = 0
            for i in 0..<width {
                code = (code << 8) | UInt32(bytes[offset + (bigEndian ? i : width - i - 1)])
            }
            if width == 2, let previous = high {
                guard (0xdc00...0xdfff).contains(code) else { throw CocoaError(.propertyListReadCorrupt) }
                code = 0x10000 + ((previous - 0xd800) << 10) + (code - 0xdc00)
                high = nil
            } else if width == 2, (0xd800...0xdbff).contains(code) {
                high = code
                continue
            }
            guard let scalar = Unicode.Scalar(code) else { throw CocoaError(.propertyListReadCorrupt) }
            utf8.append(contentsOf: scalar.utf8)
        }
        guard high == nil else { throw CocoaError(.propertyListReadCorrupt) }
        return try parseUTF8(utf8.span.bytes)
    }

    package static func parseUTF8(_ bytes: RawSpan) throws(CocoaError) -> JSONValue {
        var reader = JSONByteReader()
        return try reader.document(bytes)
    }

    public init(fromFoundation any: Any) {
        self = JSONValue.convert(any)
    }

    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return values.map { $0.foundationObject }
        case .object(let values): return values.mapValues { $0.foundationObject }
        }
    }

    private static func convert(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // CFBoolean bridges as NSNumber with objCType c; compare the canonical Boolean objects to distinguish it.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            let cType = CFNumberGetType(n as CFNumber)
            switch cType {
            case .float32Type, .float64Type, .cgFloatType, .doubleType, .floatType:
                return .double(n.doubleValue)
            default:
                if let value = n as? Int64 { return .int(value) }
                return .double(n.doubleValue)
            }
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map(convert)) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = convert(v) }
            return .object(out)
        }
        return .null
    }
}

private struct JSONByteReader {
    var index = 0

    func byte(_ bytes: RawSpan) -> UInt8? {
        index < bytes.byteCount ? bytes[index] : nil
    }
    var invalid: CocoaError { CocoaError(.propertyListReadCorrupt) }

    func decodeUTF8(_ bytes: RawSpan) throws(CocoaError) -> String {
        let units = Span<UInt8>(viewing: bytes)
        guard let valid = try? UTF8Span(validating: units) else { throw invalid }
        return String(copying: valid)
    }

    mutating func take(_ bytes: RawSpan, _ expected: UInt8) -> Bool {
        guard byte(bytes) == expected else { return false }
        index += 1
        return true
    }

    mutating func space(_ bytes: RawSpan) {
        while let byte = byte(bytes), byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    mutating func document(_ bytes: RawSpan) throws(CocoaError) -> JSONValue {
        if take(bytes, 0xef) { guard take(bytes, 0xbb), take(bytes, 0xbf) else { throw invalid } }
        let result = try value(bytes, depth: 0)
        space(bytes)
        guard byte(bytes) == nil else { throw invalid }
        return result
    }

    mutating func value(_ bytes: RawSpan, depth: Int) throws(CocoaError) -> JSONValue {
        space(bytes)
        switch byte(bytes) {
        case 34: return .string(try string(bytes))
        case 110: return try literal(bytes, "null", value: .null)
        case 116: return try literal(bytes, "true", value: .bool(true))
        case 102: return try literal(bytes, "false", value: .bool(false))
        case 91:
            guard depth < 512 else { throw invalid }
            index += 1
            space(bytes)
            var values: [JSONValue] = []
            while !take(bytes, 93) {
                values.append(try value(bytes, depth: depth + 1))
                space(bytes)
                if take(bytes, 93) { break }
                guard take(bytes, 44) else { throw invalid }
                space(bytes)
            }
            return .array(values)
        case 123:
            guard depth < 512 else { throw invalid }
            index += 1
            space(bytes)
            var fields: [String: JSONValue] = [:]
            while !take(bytes, 125) {
                let key = try string(bytes)
                space(bytes)
                guard take(bytes, 58) else { throw invalid }
                fields[key] = try value(bytes, depth: depth + 1)
                space(bytes)
                if take(bytes, 125) { break }
                guard take(bytes, 44) else { throw invalid }
                space(bytes)
            }
            return .object(fields)
        default: return try number(bytes)
        }
    }

    mutating func literal(_ bytes: RawSpan, _ spelling: String, value: JSONValue) throws(CocoaError) -> JSONValue {
        for character in spelling.utf8 {
            guard take(bytes, character) else { throw invalid }
        }
        return value
    }

    mutating func digits(_ bytes: RawSpan) -> Bool {
        let start = index
        while let byte = byte(bytes), (48...57).contains(byte) { index += 1 }
        return index > start
    }

    mutating func number(_ bytes: RawSpan) throws(CocoaError) -> JSONValue {
        let start = index
        _ = take(bytes, 45)
        if !take(bytes, 48) { guard digits(bytes) else { throw invalid } }
        var integral = true
        if take(bytes, 46) {
            integral = false
            guard digits(bytes) else { throw invalid }
        }
        if take(bytes, 69) || take(bytes, 101) {
            integral = false
            if !take(bytes, 43) { _ = take(bytes, 45) }
            guard digits(bytes) else { throw invalid }
        }
        let token = try decodeUTF8(bytes.extracting(start..<index))
        if integral, let exact = Int64(token) { return .int(exact) }
        guard let number = Double(token), number.isFinite else { throw invalid }
        return .double(number)
    }

    mutating func hexQuad(_ bytes: RawSpan) throws(CocoaError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = byte(bytes) else { throw invalid }
            switch byte {
            case 48...57: value = value * 16 + UInt32(byte - 48)
            case 65...70: value = value * 16 + UInt32(byte - 55)
            case 97...102: value = value * 16 + UInt32(byte - 87)
            default: throw invalid
            }
            index += 1
        }
        return value
    }

    mutating func string(_ bytes: RawSpan) throws(CocoaError) -> String {
        guard take(bytes, 34) else { throw invalid }
        var result = ""
        while true {
            let start = index
            while let byte = byte(bytes), byte >= 32, byte != 34, byte != 92 { index += 1 }
            result += try decodeUTF8(bytes.extracting(start..<index))
            if take(bytes, 34) { return result }
            guard take(bytes, 92), let escaped = byte(bytes) else { throw invalid }
            index += 1
            switch escaped {
            case 34, 47, 92: result.unicodeScalars.append(Unicode.Scalar(escaped))
            case 98: result += "\u{8}"
            case 102: result += "\u{c}"
            case 110: result += "\n"
            case 114: result += "\r"
            case 116: result += "\t"
            case 117:
                var scalar = try hexQuad(bytes)
                if (0xd800...0xdbff).contains(scalar) {
                    guard take(bytes, 92), take(bytes, 117) else { throw invalid }
                    let low = try hexQuad(bytes)
                    guard (0xdc00...0xdfff).contains(low) else { throw invalid }
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00)
                }
                guard let decoded = Unicode.Scalar(scalar) else { throw invalid }
                result.unicodeScalars.append(decoded)
            default: throw invalid
            }
        }
    }
}

extension JSONValue {
    /// Serialize to a UTF-8 string matching Python's `json.dumps(v, sort_keys=True, ensure_ascii=True)`. When `pretty` is true, matches `indent=2` formatting
    /// (separators default to `(',', ': ')` with indent); otherwise compact mode uses `(', ', ': ')`.
    public func serialize(pretty: Bool) throws(PersistenceCoreError) -> String {
        try String(decoding: encodedBytes(pretty: pretty), as: UTF8.self)
    }

    public func serializedData(pretty: Bool) throws(PersistenceCoreError) -> Data {
        try Data(encodedBytes(pretty: pretty))
    }

    private func encodedBytes(pretty: Bool) throws(PersistenceCoreError) -> [UInt8] {
        var out: [UInt8] = []
        try encode(into: &out, pretty: pretty, indentLevel: 0, path: "")
        return out
    }

    /// Full SHA-256 hex of the native compact serialization.
    package func serializedSHA256() throws(PersistenceCoreError) -> String {
        SHA256Hex.of(try serializedData(pretty: false))
    }

    private func encode(into out: inout [UInt8], pretty: Bool, indentLevel: Int, path: String) throws(PersistenceCoreError) {
        switch self {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let b):
            out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i):
            out.append(contentsOf: String(i).utf8)
        case .double(let d):
            if d.isNaN || d.isInfinite {
                throw PersistenceCoreError.nonFiniteFloat(d, path: path)
            }
            out.append(contentsOf: String(d).utf8)
        case .string(let s):
            JSONValue.encodeString(s, into: &out)
        case .array(let arr):
            if arr.isEmpty { out.append(contentsOf: "[]".utf8); return }
            let inner = pretty ? String(repeating: " ", count: (indentLevel + 1) * 2) : ""
            out.append(contentsOf: (pretty ? "[\n" : "[").utf8)
            for (idx, v) in arr.enumerated() {
                if idx > 0 { out.append(contentsOf: (pretty ? ",\n" : ", ").utf8) }
                out.append(contentsOf: inner.utf8)
                try v.encode(into: &out, pretty: pretty, indentLevel: pretty ? indentLevel + 1 : 0, path: "\(path)[\(idx)]")
            }
            if pretty { out.append(contentsOf: ("\n" + String(repeating: " ", count: indentLevel * 2)).utf8) }
            out.append(93)
        case .object(let dict):
            if dict.isEmpty { out.append(contentsOf: "{}".utf8); return }
            // UTF-8 order matches Python's Unicode code-point key order; Swift's normalized comparison diverges for non-ASCII keys.
            let keys = dict.keys.sorted { lhs, rhs in
                lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }
            let inner = pretty ? String(repeating: " ", count: (indentLevel + 1) * 2) : ""
            out.append(contentsOf: (pretty ? "{\n" : "{").utf8)
            for (idx, k) in keys.enumerated() {
                if idx > 0 { out.append(contentsOf: (pretty ? ",\n" : ", ").utf8) }
                out.append(contentsOf: inner.utf8)
                JSONValue.encodeString(k, into: &out)
                out.append(contentsOf: ": ".utf8)
                let childPath = path.isEmpty ? k : "\(path).\(k)"
                try dict[k]!.encode(into: &out, pretty: pretty, indentLevel: pretty ? indentLevel + 1 : 0, path: childPath)
            }
            if pretty { out.append(contentsOf: ("\n" + String(repeating: " ", count: indentLevel * 2)).utf8) }
            out.append(125)
        }
    }

    package static func encodeString(_ s: String, into out: inout String) {
        var bytes: [UInt8] = []
        encodeString(s, into: &bytes)
        out += String(decoding: bytes, as: UTF8.self)
    }

    private static func encodeString(_ s: String, into out: inout [UInt8]) {
        let hex: InlineArray<16, UInt8> = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102]
        func escape(_ unit: UInt32, into out: inout [UInt8]) {
            out.append(contentsOf: [92, 117])
            for shift in stride(from: 12, through: 0, by: -4) {
                out.append(hex[Int(unit >> shift & 15)])
            }
        }

        out.append(34)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 34, 92: out.append(contentsOf: [92, UInt8(scalar.value)])
            case 8: out.append(contentsOf: [92, 98])
            case 9: out.append(contentsOf: [92, 116])
            case 10: out.append(contentsOf: [92, 110])
            case 12: out.append(contentsOf: [92, 102])
            case 13: out.append(contentsOf: [92, 114])
            case 32..<127: out.append(UInt8(scalar.value))
            case 0...0xffff: escape(scalar.value, into: &out)
            default:
                let offset = scalar.value - 0x10000
                escape(0xd800 + (offset >> 10), into: &out)
                escape(0xdc00 + (offset & 0x3ff), into: &out)
            }
        }
        out.append(34)
    }
}

// MARK: - Codable

/// Codable preserves shape, not canonical bytes; byte-sensitive writes must use serializedData to match Python exactly.
extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "JSONValue: no matching case"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - A store's document

extension JSONValue {
    public struct ShapeError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// Check every named field so misspellings cannot silently disappear during decoding.
    public func decodedExactly<T: Decodable>(as type: T.Type) throws(ShapeError) -> T {
        let reads = JSONKeyReads()
        let result: T
        do { result = try JSONValueDecoder(value: self, path: [], reads: reads).decode(type) }
        catch { throw ShapeError(description: Self.describe(error)) }
        if let path = reads.firstUnread { throw ShapeError(description: "it has no field \(path)") }
        return result
    }

    public static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context, _ key: CodingKey? = nil) -> String {
            (context.codingPath + (key.map { [$0] } ?? [])).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing " + path(context, key)
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return path(context) + " has the wrong type"
        case .dataCorrupted(let context): return context.codingPath.isEmpty ? "not JSON" : path(context) + ": " + context.debugDescription
        @unknown default: return error.localizedDescription
        }
    }

    public var digest: String {
        get throws {
            String(try serializedSHA256().prefix(16))
        }
    }

    public static func differences(_ old: JSONValue, _ new: JSONValue, path: String = "") -> [String] {
        guard case .object(let before) = old, case .object(let after) = new else { return old == new ? [] : [String(path.dropLast())] }
        return Set(before.keys).union(after.keys).sorted().flatMap { differences(before[$0] ?? .null, after[$0] ?? .null, path: path + $0 + ".") }
    }
}

private enum JSONField: CodingKey, Hashable, Comparable {
    case name(String), index(Int)

    init(stringValue: String) { self = .name(stringValue) }
    init(intValue: Int) { self = .index(intValue) }
    var stringValue: String {
        switch self {
        case .name(let key): key
        case .index(let index): "Index \(index)"
        }
    }
    var intValue: Int? {
        if case .index(let index) = self { index } else { nil }
    }
}

private final class JSONKeyReads {
    var remaining: [[JSONField]: Set<String>] = [:]

    var firstUnread: String? {
        let paths = remaining.compactMap { path, keys in keys.min().map { path + [.name($0)] } }
        guard let path = paths.min(by: { $0.lexicographicallyPrecedes($1) }) else { return nil }
        return path.enumerated().map { offset, component in
            switch component {
            case .name(let name): (offset == 0 ? "" : ".") + name
            case .index(let index): "[\(index)]"
            }
        }.joined()
    }
}

private struct JSONValueDecoder: Decoder, SingleValueDecodingContainer {
    let value: JSONValue
    let path: [JSONField]
    let reads: JSONKeyReads

    var codingPath: [any CodingKey] { path }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func child(_ field: JSONField, _ value: JSONValue) -> Self {
        Self(value: value, path: path + [field], reads: reads)
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Expected \(type)")
        return decodeNil() ? .valueNotFound(type, context) : .typeMismatch(type, context)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let fields) = value else { throw mismatch([String: JSONValue].self) }
        if reads.remaining[path] == nil { reads.remaining[path] = Set(fields.keys) }
        return KeyedDecodingContainer(JSONKeyedValues<Key>(decoder: self, fields: fields))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else { throw mismatch([JSONValue].self) }
        return JSONArrayValues(decoder: self, elements: elements)
    }

    func singleValueContainer() -> any SingleValueDecodingContainer { self }
    func decodeNil() -> Bool { if case .null = value { true } else { false } }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let flag) = value else { throw mismatch(type) }
        return flag
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let text) = value else { throw mismatch(type) }
        return text
    }

    private var invalidNumber: DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Unrepresentable JSON number"))
    }

    func decode(_ type: Double.Type) throws -> Double {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number):
            guard number.isFinite else { throw invalidNumber }
            return number
        default: throw mismatch(type)
        }
    }

    func decode(_ type: Float.Type) throws -> Float {
        switch value {
        case .int(let number): return Float(number)
        case .double(let number):
            guard let result = Float(String(number)), result.isFinite, result != 0 || number == 0 else { throw invalidNumber }
            return result
        default: throw mismatch(type)
        }
    }

    private func decimal() throws -> Decimal {
        switch value {
        case .int(let number): return Decimal(number)
        case .double(let number):
            guard number.isFinite, let result = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")),
                  !result.isNaN else { throw invalidNumber }
            return result
        default: throw mismatch(Decimal.self)
        }
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let number: T?
        switch value {
        case .int(let value): number = T(exactly: value)
        case .double(let value) where value.magnitude >= 0x1p53:
            number = try T(decimal().description)
        case .double(let value): number = T(exactly: value)
        default: throw mismatch(type)
        }
        guard let number else { throw invalidNumber }
        return number
    }
    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: Int128.Type) throws -> Int128 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }
    func decode(_ type: UInt128.Type) throws -> UInt128 { try integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            guard let data = Data(base64Encoded: try decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: self, debugDescription: "Encountered Data is not valid Base64.")
            }
            return data as! T
        }
        if type == URL.self {
            guard let url = URL(string: try decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: self, debugDescription: "Invalid URL string.")
            }
            return url as! T
        }
        if type == Decimal.self { return try decimal() as! T }
        return try T(from: self)
    }
}

private struct JSONKeyedValues<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONValueDecoder
    let fields: [String: JSONValue]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }

    private func consume(_ key: some CodingKey) -> JSONValue? {
        decoder.reads.remaining[decoder.path]?.remove(key.stringValue)
        return fields[key.stringValue]
    }

    private func child(_ key: Key) throws -> JSONValueDecoder {
        guard let value = consume(key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing \(key.stringValue)"))
        }
        return decoder.child(.name(key.stringValue), value)
    }

    func contains(_ key: Key) -> Bool { consume(key) != nil }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).decodeNil() }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let value = consume(key), value != .null else { return nil }
        return try decoder.child(.name(key.stringValue), value).decode(type)
    }
    func nestedContainer<K: CodingKey>(keyedBy type: K.Type, forKey key: Key) throws -> KeyedDecodingContainer<K> {
        try child(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() -> any Decoder { parent(JSONField.name("super")) }
    func superDecoder(forKey key: Key) -> any Decoder { parent(key) }
    private func parent(_ key: some CodingKey) -> JSONValueDecoder {
        decoder.child(.name(key.stringValue), consume(key) ?? .null)
    }
}

private struct JSONArrayValues: UnkeyedDecodingContainer {
    let decoder: JSONValueDecoder
    let elements: [JSONValue]
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex == elements.count }

    private func next() throws -> JSONValueDecoder {
        let index = JSONField.index(currentIndex)
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: codingPath + [index], debugDescription: "Unkeyed container is at end"))
        }
        return decoder.child(index, elements[currentIndex])
    }

    mutating func decodeNil() throws -> Bool {
        guard try next().decodeNil() else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let value = try next().decode(type)
        currentIndex += 1
        return value
    }

    mutating func nestedContainer<K: CodingKey>(keyedBy type: K.Type) throws -> KeyedDecodingContainer<K> {
        let container = try next().container(keyedBy: type)
        currentIndex += 1
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let container = try next().unkeyedContainer()
        currentIndex += 1
        return container
    }

    mutating func superDecoder() throws -> any Decoder {
        let child = try next()
        currentIndex += 1
        return child
    }
}
