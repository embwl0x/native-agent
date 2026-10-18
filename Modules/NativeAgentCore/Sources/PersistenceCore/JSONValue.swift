import CryptoKit
import Foundation
import Darwin
import NativeAgentCore

// MARK: - JSONValue

/// Sendable, Equatable JSON ADT used at the persistence boundary.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    public struct SchemaProblem: Sendable {
        public let path: String
        public let keyword: String
        public let expected: String
    }

    public func validate(schema: JSONValue) throws {
        if let problem = schemaProblem(schema: schema) {
            throw PersistenceCoreError.ioFailure("JSON schema: \(problem.path.isEmpty ? "value" : problem.path) must be \(problem.expected)")
        }
    }

    /// Check the entire schema before matching values, including unused branches.
    /// Callers own error wording. Unknown keywords are ignored; enforced rules must be valid.
    public func schemaProblem(schema: JSONValue, path: String = "") -> SchemaProblem? {
        func number(_ value: JSONValue?) -> Double? {
            switch value { case .int(let n)?: Double(n); case .double(let n)?: n; default: nil }
        }
        func list(_ value: JSONValue) -> [JSONValue] { if case .array(let values) = value { values } else { [value] } }
        func schemaError(_ schema: JSONValue, _ at: String) -> SchemaProblem? {
            func bad(_ expected: String) -> SchemaProblem { .init(path: at, keyword: "schema", expected: expected) }
            if case .bool = schema { return nil }
            guard case .object(let rules) = schema else { return bad("an object or boolean schema") }
            for key in rules.keys.sorted() {
                let rule = rules[key]!
                switch key {
                case "type":
                    let types = list(rule)
                    guard !types.isEmpty, types.allSatisfy({
                        if case .string(let type) = $0 { return ["string", "boolean", "integer", "number", "object", "array", "null"].contains(type) }
                        return false
                    }) else { return bad("a known type or nonempty type array") }
                case "required", "enum", "allOf", "anyOf", "oneOf":
                    guard case .array(let values) = rule else { return bad("an array for \(key)") }
                    if key == "required", !values.allSatisfy({ if case .string = $0 { true } else { false } }) { return bad("string required names") }
                    if ["allOf", "anyOf", "oneOf"].contains(key) {
                        guard !values.isEmpty else { return bad("nonempty \(key)") }
                        for (index, child) in values.enumerated() {
                            if let error = schemaError(child, "\(at).\(key)[\(index)]") { return error }
                        }
                    }
                case "properties":
                    guard case .object(let properties) = rule else { return bad("an object for properties") }
                    for name in properties.keys.sorted() {
                        if let error = schemaError(properties[name]!, at + ".properties." + name) { return error }
                    }
                case "items", "additionalProperties", "not":
                    // Draft-07 tuple form: items is a list of schemas, one per position.
                    if key == "items", case .array(let positions) = rule {
                        for (index, child) in positions.enumerated() {
                            if let error = schemaError(child, "\(at).items[\(index)]") { return error }
                        }
                    } else if let error = schemaError(rule, at + "." + key) { return error }
                case "minItems", "maxItems", "minLength", "maxLength", "minProperties", "maxProperties":
                    guard let n = number(rule), n.isFinite, n >= 0, n.rounded() == n else { return bad("a nonnegative integer for \(key)") }
                case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf":
                    guard let n = number(rule), n.isFinite, key != "multipleOf" || n > 0 else { return bad("a valid numeric \(key)") }
                case "uniqueItems":
                    guard case .bool = rule else { return bad("a boolean for uniqueItems") }
                case "pattern":
                    guard case .string(let pattern) = rule, (try? NSRegularExpression(pattern: pattern)) != nil else { return bad("a valid regular expression") }
                default: break
                }
            }
            return nil
        }
        func check(_ value: JSONValue, _ schema: JSONValue, _ at: String) -> SchemaProblem? {
            func bad(_ key: String, _ expected: String, at child: String? = nil) -> SchemaProblem {
                .init(path: child ?? at, keyword: key, expected: expected)
            }
            func childPath(_ key: String) -> String { at.isEmpty ? key : at + "." + key }
            if case .bool(let allowed) = schema { return allowed ? nil : bad("false", "allowed by the schema") }
            guard case .object(let rules) = schema else { return nil } // Checked above.
            if case .array(let choices)? = rules["allOf"] {
                for choice in choices { if let problem = check(value, choice, at) { return problem } }
            }
            for key in ["anyOf", "oneOf"] {
                if case .array(let choices)? = rules[key] {
                    let problems = choices.compactMap { check(value, $0, at) }
                    if problems.count == choices.count { return bad(key, problems.map(\.expected).joined(separator: " or ")) }
                    if key == "oneOf", choices.count - problems.count != 1 { return bad(key, "exactly one accepted alternative") }
                }
            }
            if let child = rules["not"], check(value, child, at) == nil { return bad("not", "outside the forbidden combination") }
            if let fixed = rules["const"], fixed != value { return bad("const", "\(fixed)") }
            if case .array(let options)? = rules["enum"], !options.contains(value) {
                return bad("enum", options.map { if case .string(let text) = $0 { text } else { String(describing: $0) } }.joined(separator: " or "))
            }
            if let declared = rules["type"] {
                let types = list(declared)
                let matches = types.contains { type in
                    switch (type, value) {
                    case (.string("string"), .string), (.string("boolean"), .bool), (.string("integer"), .int),
                         (.string("number"), .int), (.string("number"), .double), (.string("object"), .object),
                         (.string("array"), .array), (.string("null"), .null): return true
                    case (.string("integer"), .double(let n)): return n.isFinite && n.rounded() == n
                    default: return false
                    }
                }
                if !matches { return bad("type", types.compactMap { if case .string(let text) = $0 { text } else { nil } }.joined(separator: " or ")) }
            }
            func bounds(_ count: Int, _ minimum: String, _ maximum: String, _ unit: String) -> SchemaProblem? {
                if let n = number(rules[minimum]), Double(count) < n { return bad(minimum, "at least \(Int64(exactly: n).map(String.init) ?? String(n)) \(unit)") }
                if let n = number(rules[maximum]), Double(count) > n { return bad(maximum, "at most \(Int64(exactly: n).map(String.init) ?? String(n)) \(unit)") }
                return nil
            }
            switch value {
            case .object(let object):
                if let problem = bounds(object.count, "minProperties", "maxProperties", "properties") { return problem }
                if case .array(let required)? = rules["required"] {
                    for case .string(let key) in required where object[key] == nil { return bad("required", "present", at: childPath(key)) }
                }
                let properties: [String: JSONValue] = if case .object(let fields)? = rules["properties"] { fields } else { [:] }
                for key in object.keys.sorted() {
                    if properties[key] == nil, rules["additionalProperties"] == .bool(false) { return bad("additionalProperties", "an accepted argument", at: childPath(key)) }
                    if let rule = properties[key] ?? rules["additionalProperties"], let problem = check(object[key]!, rule, childPath(key)) { return problem }
                }
            case .array(let items):
                if let problem = bounds(items.count, "minItems", "maxItems", "items") { return problem }
                if rules["uniqueItems"] == .bool(true), items.indices.contains(where: { items.prefix($0).contains(items[$0]) }) { return bad("uniqueItems", "unique items") }
                if case .array(let positions)? = rules["items"] {
                    for (index, item) in items.enumerated() where index < positions.count {
                        if let problem = check(item, positions[index], "\(at)[\(index)]") { return problem }
                    }
                } else if let rule = rules["items"] {
                    for (index, item) in items.enumerated() { if let problem = check(item, rule, "\(at)[\(index)]") { return problem } }
                }
            case .string(let text):
                if let problem = bounds(text.unicodeScalars.count, "minLength", "maxLength", "characters") { return problem }
                if case .string(let pattern)? = rules["pattern"], let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return bad("pattern", "matching \(pattern)") }
            case .int, .double:
                let n = number(value)!
                for (key, failed) in [("minimum", n < (number(rules["minimum"]) ?? -.infinity)),
                    ("maximum", n > (number(rules["maximum"]) ?? .infinity)),
                    ("exclusiveMinimum", n <= (number(rules["exclusiveMinimum"]) ?? -.infinity)),
                    ("exclusiveMaximum", n >= (number(rules["exclusiveMaximum"]) ?? .infinity))] where failed { return bad(key, "within \(key)") }
                if let step = number(rules["multipleOf"]), abs(n / step - (n / step).rounded()) > 1e-10 { return bad("multipleOf", "a multiple of \(step)") }
            default: break
            }
            return nil
        }
        return schemaError(schema, path) ?? check(self, schema, path)
    }

    /// An object's string fields by key; empty for anything that isn't an object.
    public var stringFields: [String: String] {
        guard case .object(let fields) = self else { return [:] }
        return fields.compactMapValues { value in
            guard case .string(let text) = value else { return nil }
            return text
        }
    }

    /// Convert using the default Codable wire format and the canonical JSON parser.
    public static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        try parse(JSONEncoder().encode(value))
    }

    /// Transform string leaves without changing keys or non-string values.
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

    /// Parse JSON bytes into a JSONValue. Distinguishes Int vs Double by
    /// inspecting the underlying CFNumber type (NSNumber from JSONSerialization).
    ///
    /// LOSSY: Python's `json.dumps` with default `allow_nan=True` emits the bare
    /// tokens `NaN`, `Infinity`, `-Infinity` (non-standard). Swift's
    /// JSONSerialization rejects those tokens. To stay readable across the wire
    /// we strip those tokens (when they appear as JSON values, not inside string
    /// literals) and replace them with `null` before parsing. So
    /// `Python NaN → Swift JSONValue.null` on read.
    public static func parse(_ data: Data) throws -> JSONValue {
        // JSONSerialization's tree is autoreleased, and a busy cooperative
        // thread may not drain its pool for seconds: at launch every parsed
        // feed and transcript stayed alive at once. Release it per parse.
        try autoreleasepool {
            let sanitized = stripNonFiniteTokens(data)
            let raw = try JSONSerialization.jsonObject(
                with: sanitized, options: [.fragmentsAllowed]
            )
            return convert(raw)
        }
    }

    /// Build a `JSONValue` from a Foundation `Any` leaf/container — the same
    /// shape `JSONSerialization.jsonObject` produces (NSNull / NSNumber /
    /// String / [Any] / [String: Any]). Uses the identical NSNumber
    /// bool-vs-int-vs-double disambiguation as `parse`, so a value built from
    /// an in-memory body round-trips byte-identically to one read off disk.
    /// Non-JSON Foundation types fall through to `.null` (unreachable for valid
    /// JSON output). Used to carry profile.json "extras" (unknown keys) through
    /// the persona normalize/write path losslessly.
    public init(fromFoundation any: Any) {
        self = JSONValue.convert(any)
    }

    /// Walk JSON bytes with a tiny string-aware lexer and replace bare
    /// `NaN` / `Infinity` / `-Infinity` value tokens with `null`. Tokens
    /// inside double-quoted strings (respecting `\"` escapes) are untouched.
    static func stripNonFiniteTokens(_ data: Data) -> Data {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var out = Data()
            let nullBytes: [UInt8] = [0x6E, 0x75, 0x6C, 0x6C] // "null"
            var inString = false
            var escape = false
            var i = 0, start = 0
            while i < bytes.count {
                let b = bytes[i]
                if inString {
                    if escape {
                        escape = false
                    } else if b == 0x5C { // backslash
                        escape = true
                    } else if b == 0x22 { // quote
                        inString = false
                    }
                    i += 1
                    continue
                }
                if b == 0x22 { // entering string
                    inString = true
                    i += 1
                    continue
                }
                let tokenLength: Int
                if b == 0x4E && matchesAscii(bytes, i, "NaN") {
                    tokenLength = 3
                } else if b == 0x49 && matchesAscii(bytes, i, "Infinity") {
                    tokenLength = 8
                } else if b == 0x2D && i + 1 < bytes.count && bytes[i + 1] == 0x49
                    && matchesAscii(bytes, i + 1, "Infinity") {
                    tokenLength = 9
                } else {
                    i += 1
                    continue
                }
                out.append(contentsOf: bytes[start..<i])
                out.append(contentsOf: nullBytes)
                i += tokenLength
                start = i
            }
            guard start > 0 else { return data }
            out.append(contentsOf: bytes[start..<bytes.count])
            return out
        }
    }

    private static func matchesAscii(_ bytes: UnsafeRawBufferPointer, _ i: Int, _ token: String) -> Bool {
        let t = Array(token.utf8)
        if i + t.count > bytes.count { return false }
        for j in 0..<t.count where bytes[i + j] != t[j] { return false }
        return true
    }

    private static func convert(_ any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // CFBooleanRef shows up as NSNumber, but objCType is "c". The reliable
            // disambiguator is comparing against kCFBooleanTrue/False.
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
        // Fallback — should be unreachable for valid JSON output.
        return .null
    }
}

extension JSONValue {
    /// Serialize to a UTF-8 string matching Python's `json.dumps(v, sort_keys=True,
    /// ensure_ascii=True)`. When `pretty` is true, matches `indent=2` formatting
    /// (separators default to `(',', ': ')` with indent); otherwise compact mode
    /// uses `(', ', ': ')`.
    public func serialize(pretty: Bool) throws -> String {
        var out = ""
        try encode(into: &out, pretty: pretty, indentLevel: 0, path: "")
        return out
    }

    /// UTF-8 byte form of `serialize`.
    public func serializedData(pretty: Bool) throws -> Data {
        try Data(serialize(pretty: pretty).utf8)
    }

    /// Serialize an object whose keys MUST be emitted in the given order (NOT
    /// sorted), byte-for-byte matching Python's `json.dumps(d)` with its DEFAULT
    /// arguments (`sort_keys=False`, `ensure_ascii=True`, compact separators
    /// `(', ', ': ')`). The plain `serialize`/`encode` path always sort_keys —
    /// correct for the `indent=2, sort_keys=True` writers (registry.json, persona
    /// docs, replay captures) but WRONG for any file the daemon writes with a
    /// bare `json.dumps(...)`, which preserves Python dict insertion order.
    ///
    /// The audit log (`mac_control_audit.jsonl`) is exactly that case: the
    /// daemon's `MacControl._append_audit` does `fh.write(json.dumps(receipt))`
    /// with NO sort_keys, so a row's keys land in `make_receipt(...)` insertion
    /// order. To be byte-equivalent the Swift mirror must reproduce that order,
    /// not the alphabetical sort. (Closes wave-32 W03's functional-but-not-
    /// byte-equivalent gap — CUTOVER §6.96.)
    ///
    /// Values are escaped identically to `serialize` (same `encodeString` ⇒ same
    /// `\uXXXX` / control-escape rules ⇒ same `ensure_ascii=True` output). Nested
    /// objects/arrays inside a value still go through the sort_keys `encode`
    /// path; pass only flat, pre-ordered top-level objects (the audit receipt is
    /// flat, so this is exact). The boolean/int/null/string atoms used by the
    /// receipt are reproduced exactly.
    public static func serializeOrderedObjectPython(_ pairs: [(String, JSONValue)]) throws -> String {
        if pairs.isEmpty { return "{}" }
        var out = "{"
        for (idx, pair) in pairs.enumerated() {
            if idx > 0 { out += ", " }
            JSONValue.encodeString(pair.0, into: &out)
            out += ": "
            try pair.1.encode(into: &out, pretty: false, indentLevel: 0, path: pair.0)
        }
        out += "}"
        return out
    }

    private func encode(into out: inout String, pretty: Bool, indentLevel: Int, path: String) throws {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if d.isNaN || d.isInfinite {
                throw PersistenceCoreError.nonFiniteFloat(d, path: path)
            }
            out += String(d)
        case .string(let s):
            JSONValue.encodeString(s, into: &out)
        case .array(let arr):
            if arr.isEmpty { out += "[]"; return }
            if pretty {
                let inner = String(repeating: " ", count: (indentLevel + 1) * 2)
                let close = String(repeating: " ", count: indentLevel * 2)
                out += "[\n"
                for (idx, v) in arr.enumerated() {
                    out += inner
                    try v.encode(into: &out, pretty: true, indentLevel: indentLevel + 1, path: "\(path)[\(idx)]")
                    if idx < arr.count - 1 { out += "," }
                    out += "\n"
                }
                out += close + "]"
            } else {
                out += "["
                for (idx, v) in arr.enumerated() {
                    if idx > 0 { out += ", " }
                    try v.encode(into: &out, pretty: false, indentLevel: 0, path: "\(path)[\(idx)]")
                }
                out += "]"
            }
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            // Sort keys by UTF-8 byte order to match Python's json.dumps(sort_keys=True)
            // (Python sorts by Unicode code point, which equals UTF-8 byte order).
            // Swift's default String.sorted() uses NFC + locale-aware comparison
            // which diverges from Python on non-ASCII keys.
            let keys = dict.keys.sorted { lhs, rhs in
                lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }
            if pretty {
                let inner = String(repeating: " ", count: (indentLevel + 1) * 2)
                let close = String(repeating: " ", count: indentLevel * 2)
                out += "{\n"
                for (idx, k) in keys.enumerated() {
                    out += inner
                    JSONValue.encodeString(k, into: &out)
                    out += ": "
                    let childPath = path.isEmpty ? k : "\(path).\(k)"
                    try dict[k]!.encode(into: &out, pretty: true, indentLevel: indentLevel + 1, path: childPath)
                    if idx < keys.count - 1 { out += "," }
                    out += "\n"
                }
                out += close + "}"
            } else {
                out += "{"
                for (idx, k) in keys.enumerated() {
                    if idx > 0 { out += ", " }
                    JSONValue.encodeString(k, into: &out)
                    out += ": "
                    let childPath = path.isEmpty ? k : "\(path).\(k)"
                    try dict[k]!.encode(into: &out, pretty: false, indentLevel: 0, path: childPath)
                }
                out += "}"
            }
        }
    }

    /// Match Python `json.encoder.py_encode_basestring_ascii`: shortest control
    /// escapes for \b \t \n \f \r, \" and \\ for quote/backslash, \u00XX for
    /// other C0 controls and DEL, \uXXXX for non-ASCII (surrogate pairs >0xFFFF).
    /// Forward slash is NOT escaped.
    package static func encodeString(_ s: String, into out: inout String) {
        // Do not derive reserve capacity from `out.count` here. String.count
        // walks the entire accumulated Unicode output, so doing it once per
        // JSON string makes a large projection quadratic. Swift's String
        // storage already grows amortized while we append.
        out.append("\"")
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            default:
                if v < 0x20 {
                    out += String(format: "\\u%04x", v)
                } else if v < 0x7F {
                    out.unicodeScalars.append(scalar)
                } else if v <= 0xFFFF {
                    out += String(format: "\\u%04x", v)
                } else {
                    // Surrogate pair
                    let adjusted = v - 0x10000
                    let hi = 0xD800 + (adjusted >> 10)
                    let lo = 0xDC00 + (adjusted & 0x3FF)
                    out += String(format: "\\u%04x\\u%04x", hi, lo)
                }
            }
        }
        out.append("\"")
    }
}

// MARK: - Codable

/// JSONValue ↔ Codable so it can ride inside other Codable wire structs.
/// Round-trip preserves shape; numeric tags follow the same Int vs Double
/// policy as `parse(_:)`.
///
/// IMPORTANT: This Codable conformance is for SHAPE-ONLY use (composing
/// JSONValue inside other Codable structs).
/// It does NOT produce bytes that match `serializedData(pretty:)`. Any
/// byte-sensitive write path (registry.json, persona docs, replay
/// captures) MUST use `serializedData(pretty:)` directly to match Python's
/// `json.dumps(indent=2, sort_keys=True)` output exactly. Treating Codable
/// output as canonical will break replay validators on downstream subsystems.
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

/// Checked reads of one stored JSON object row, for owners that hand out
/// typed records without a byte round trip: a required field must be present
/// with its type, an optional one may be absent or null, and a present field
/// of the wrong type makes the row malformed.
public struct JSONRow {
    public enum Malformed: Error, LocalizedError {
        case notAnObject
        case field(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject: return "row is not a JSON object"
            case .field(let key): return "row has no valid \(key)"
            }
        }
    }

    public let fields: [String: JSONValue]

    public init(_ value: JSONValue) throws {
        guard case .object(let fields) = value else { throw Malformed.notAnObject }
        self.fields = fields
    }

    public func string(_ key: String) throws -> String { try required(key, Self.string) }
    public func optionalString(_ key: String) throws -> String? { try optional(key, Self.string) }
    public func strings(_ key: String) throws -> [String] { try required(key, Self.strings) }
    public func array(_ key: String) throws -> [JSONValue] {
        try required(key) { if case .array(let values) = $0 { return values }; return nil }
    }
    public func optionalBool(_ key: String) throws -> Bool? {
        try optional(key) { if case .bool(let value) = $0 { return value }; return nil }
    }
    public func optionalInt(_ key: String) throws -> Int? {
        try optional(key) {
            switch $0 {
            case .int(let value): return Int(exactly: value)
            case .double(let value): return Int(exactly: value)
            default: return nil
            }
        }
    }
    /// Any value but null.
    public func optionalValue(_ key: String) -> JSONValue? {
        fields[key].flatMap { $0 == .null ? nil : $0 }
    }

    public func optional<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let raw = fields[key], raw != .null else { return nil }
        guard let value = read(raw) else { throw Malformed.field(key) }
        return value
    }

    private func required<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T {
        guard let value = try optional(key, read) else { throw Malformed.field(key) }
        return value
    }

    private static func string(_ value: JSONValue) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }

    private static func strings(_ value: JSONValue) -> [String]? {
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap(string)
        return strings.count == values.count ? strings : nil
    }
}

// MARK: - A store's document

extension JSONValue {
    public struct ShapeError: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// THE ONE SHAPE CHECK for a document a store reads or is handed: every
    /// field `T` has, and none it lacks, so a misspelt field never silently
    /// drops. The error names the field.
    public func decodedExactly<T: Codable>(as _: T.Type) throws -> T {
        let value: T
        do { value = try JSONDecoder().decode(T.self, from: serializedData(pretty: false)) }
        catch { throw ShapeError(description: Self.describe(error)) }
        if let stray = Self.unknownField(self, (try? JSONValue.fromEncodable(value)) ?? .null, value) {
            throw ShapeError(description: "it has no field \(stray)")
        }
        return value
    }

    /// The first field `given` names that the value it decoded to does not
    /// have: one the decoder skipped. A field is the value's when the value
    /// encodes it, or when it is one of the value's own optional properties
    /// left nil, so a null is checked by name like any other value
    /// (`colour: null` is refused; a nil optional's `null` is not).
    private static func unknownField(_ given: JSONValue, _ decoded: JSONValue, _ value: Any?, path: String = "") -> String? {
        switch (given, decoded) {
        case (.object(let fields), _):
            let known: [String: JSONValue] = if case .object(let known) = decoded { known } else { [:] }
            for (key, field) in fields.sorted(by: { $0.key < $1.key }) {
                let property = member(value, key)
                guard let match = known[key] ?? (field == .null && isNilOptional(property) ? .null : nil) else { return path + key }
                if let stray = unknownField(field, match, property, path: path + key + ".") { return stray }
            }
        case (.array(let items), .array(let known)):
            let elements = unwrapped(value) as? [Any]
            for (index, item) in items.enumerated() where index < known.count {
                let element = elements.flatMap { index < $0.count ? $0[index] : nil }
                if let stray = unknownField(item, known[index], element, path: String(path.dropLast()) + "[\(index)].") { return stray }
            }
        default: break
        }
        return nil
    }

    /// A decoded value's `key`: a dictionary's entry or a stored property, through any Optional.
    private static func member(_ value: Any?, _ key: String) -> Any? {
        guard let value = unwrapped(value) else { return nil }
        if let entries = value as? [String: Any] { return entries[key] }
        return Mirror(reflecting: value).children.first { $0.label == key }?.value
    }

    private static func unwrapped(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.flatMap { unwrapped($0.value) }
    }

    private static func isNilOptional(_ value: Any?) -> Bool {
        guard let value else { return false }
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// A decoding failure as the field it names, so the fix is plain.
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

    /// The first 8 bytes of the compact form's SHA-256, as hex.
    public var digest: String {
        SHA256.hash(data: (try? serializedData(pretty: false)) ?? Data()).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The dotted fields whose values differ, for a write's receipt.
    public static func differences(_ old: JSONValue, _ new: JSONValue, path: String = "") -> [String] {
        guard case .object(let before) = old, case .object(let after) = new else { return old == new ? [] : [String(path.dropLast())] }
        return Set(before.keys).union(after.keys).sorted().flatMap { differences(before[$0] ?? .null, after[$0] ?? .null, path: path + $0 + ".") }
    }
}
