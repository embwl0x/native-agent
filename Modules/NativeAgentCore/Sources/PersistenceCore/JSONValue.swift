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
    /// Transform string leaves without changing keys or non-string values.
    func mapStrings(_ transform: (String) -> String) -> JSONValue {
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
        let sanitized = stripNonFiniteTokens(data)
        let raw = try JSONSerialization.jsonObject(
            with: sanitized, options: [.fragmentsAllowed]
        )
        return convert(raw)
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
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let nullBytes: [UInt8] = [0x6E, 0x75, 0x6C, 0x6C] // "null"
        var inString = false
        var escape = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                out.append(b)
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
                out.append(b)
                i += 1
                continue
            }
            // 'N' — try NaN
            if b == 0x4E && matchesAscii(bytes, i, "NaN") {
                out.append(contentsOf: nullBytes)
                i += 3
                continue
            }
            // 'I' — try Infinity
            if b == 0x49 && matchesAscii(bytes, i, "Infinity") {
                out.append(contentsOf: nullBytes)
                i += 8
                continue
            }
            // '-Infinity'
            if b == 0x2D && i + 1 < bytes.count && bytes[i + 1] == 0x49
                && matchesAscii(bytes, i + 1, "Infinity") {
                out.append(contentsOf: nullBytes)
                i += 9
                continue
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    private static func matchesAscii(_ bytes: [UInt8], _ i: Int, _ token: String) -> Bool {
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
                return .int(n.int64Value)
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
                Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
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
