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
    private static func encodeString(_ s: String, into out: inout String) {
        out.reserveCapacity(out.count + s.utf8.count + 2)
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

// MARK: - Errors

/// Errors raised by the persistence layer.
public enum PersistenceCoreError: Error, Equatable {
    case nonFiniteFloat(Double, path: String)
    case ioFailure(String)
}

// MARK: - Protocol

/// Atomic JSON / JSONL file IO using the stable NativeAgent file shapes.
public protocol PersistenceCoreProtocol: Sendable {
    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue
    func writeJSON(_ value: JSONValue, to path: URL) async throws
    func appendJSONL(_ record: JSONValue, to path: URL) async throws
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue]
    func readJSONL(_ path: URL) async throws -> [JSONValue]
    func replaceJSONL(_ records: [JSONValue], to path: URL) async throws
}

extension PersistenceCoreProtocol {
    /// Default tail: last 20 records, scanning up to 1 MiB from end of file.
    public func tailJSONL(_ path: URL) async throws -> [JSONValue] {
        try await tailJSONL(path, limit: 20, maxBytes: 1_048_576)
    }

    /// Default atomic JSONL replacement (op-log compaction truncate). Single
    /// rename via `Data.write(.atomic)` — no window where the file is
    /// partially written. `SwiftNativePersistenceCore` supplies its own
    /// implementation; shims that don't override inherit this one.
    public func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        try payload.write(to: path, options: .atomic)
        _ = chmod(path.path, 0o600)
    }
}

// MARK: - SwiftNative implementation

/// Native Swift implementation. Pure file IO — stateless and implicitly Sendable.
public final class SwiftNativePersistenceCore: PersistenceCoreProtocol {
    public init() {}

    public func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        guard let data = try? Data(contentsOf: path) else { return defaultValue }
        guard let parsed = try? JSONValue.parse(data) else { return defaultValue }
        return parsed
    }

    public func writeJSON(_ value: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try value.serializedData(pretty: true)
        try Self.atomicWrite(payload, to: path)
    }

    public func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var line = try record.serialize(pretty: false)
        line += "\n"
        let bytes = Data(line.utf8)
        try Self.appendBytes(bytes, to: path)
        _ = chmod(path.path, 0o600)
    }

    /// Append a known transaction of JSONL records with one file write. The
    /// caller must hold the feed's cross-process lock. This keeps a projection
    /// refresh from turning one logical transaction into dozens of vnode edges.
    public func appendJSONL(_ records: [JSONValue], to path: URL) async throws {
        guard !records.isEmpty else { return }
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        try Self.appendBytes(payload, to: path)
        _ = chmod(path.path, 0o600)
    }

    /// Atomically REPLACES a JSONL file's entire contents (single rename —
    /// no window where the file is partially written). An empty `records`
    /// truncates the feed. For op-log compaction; the caller is responsible
    /// for holding the cross-process `withFileLock` around this when shared.
    public func replaceJSONL(_ records: [JSONValue], to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var payload = Data()
        for record in records {
            payload.append(contentsOf: try record.serialize(pretty: false).utf8)
            payload.append(0x0A)
        }
        try Self.atomicWrite(payload, to: path)
        _ = chmod(path.path, 0o600)
    }

    /// JSONL append that does NOT chmod the target and creates with
    /// umask-derived permissions. Used for audit-style files where an existing
    /// 0644 mode must be preserved rather than tightened to 0600.
    /// Identical to `appendJSONL` otherwise. Callers that own the file
    /// exclusively should prefer `appendJSONL`. The caller is responsible for
    /// holding the cross-process `withFileLock` around this when shared.
    public func appendAuditLine(_ record: JSONValue, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var line = try record.serialize(pretty: false)
        line += "\n"
        try Self.appendBytes(Data(line.utf8), to: path, createMode: 0o666)
    }

    /// Append a pre-serialized JSON line (no re-encode) under the SAME file-mode
    /// posture as `appendAuditLine` (0o666 create-mode ⇒ umask-derived 0644,
    /// no chmod on an existing file).
    /// Used when the caller has already produced byte-exact output via
    /// `serializeOrderedObjectPython` and must NOT have it re-sorted by the
    /// `serialize` path. A trailing newline is appended (one row per line). The
    /// caller is responsible for holding `withFileLock` around this when the
    /// file has multiple writers.
    public func appendAuditLineRaw(_ jsonLine: String, to path: URL) async throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = jsonLine + "\n"
        try Self.appendBytes(Data(line.utf8), to: path, createMode: 0o666)
    }

    public func readJSONL(_ path: URL) async throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        return Self.decodeLines(data, dropFirstPartial: false).compactMap { line in
            try? JSONValue.parse(Data(line.utf8))
        }
    }

    public func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 { return [] }

        let toRead: Int
        let seekFromEnd: Bool
        if let maxBytes, size > maxBytes {
            toRead = maxBytes
            seekFromEnd = true
        } else {
            toRead = size
            seekFromEnd = false
        }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        if seekFromEnd {
            try handle.seek(toOffset: UInt64(size - toRead))
        }
        let data = handle.readData(ofLength: toRead)
        let lines = Self.decodeLines(data, dropFirstPartial: seekFromEnd)
        // Match Python's tail_jsonl: take the last N PHYSICAL lines first, then
        // parse and skip malformed entries. So when some of the trailing lines
        // are malformed the return count is < limit (matches Python).
        let tail = lines.suffix(limit)
        return tail.compactMap { try? JSONValue.parse(Data($0.utf8)) }
    }

    /// Decode utf-8 with replacement, split on `\n`, drop trailing empty line, and
    /// (when scanning from the middle of a file) drop the first possibly-partial
    /// line to match Python's `tail_jsonl` behavior.
    private static func decodeLines(_ data: Data, dropFirstPartial: Bool) -> [String] {
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Match Python's errors="replace" semantics for tail_jsonl.
            text = String(decoding: data, as: UTF8.self)
        }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        if dropFirstPartial && !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    /// Append bytes to a file, creating it if absent. Uses POSIX open(O_APPEND)
    /// so concurrent appenders interleave at line boundaries.
    private static func appendBytes(_ data: Data, to path: URL, createMode: mode_t = 0o600) throws {
        let fd = open(path.path, O_WRONLY | O_CREAT | O_APPEND, createMode)
        if fd < 0 {
            throw PersistenceCoreError.ioFailure("open(append) failed: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceCoreError.ioFailure("write failed: \(String(cString: strerror(errno)))")
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    /// Write `data` to `path` atomically via a side temp file + rename(2),
    /// using the NativeAgent temp-name convention and 0600 mode.
    private static func atomicWrite(_ data: Data, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        let pid = getpid()
        // pthread_self() returns an opaque pointer; take its raw bit pattern.
        let tidPtr = pthread_self()
        let tid = UInt64(UInt(bitPattern: OpaquePointer(tidPtr)))
        let uuid = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let tmpName = ".\(name).\(pid).\(tid).\(uuid).tmp"
        let tmpPath = dir.appendingPathComponent(tmpName)

        let fd = open(tmpPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 {
            throw PersistenceCoreError.ioFailure("open(tmp) failed: \(String(cString: strerror(errno)))")
        }
        var fdClosed = false
        var didRename = false
        defer {
            if !fdClosed {
                if close(fd) != 0 {
                    let err = String(cString: strerror(errno))
                    FileHandle.standardError.write(Data("PersistenceCore: close(tmp fd) failed: \(err)\n".utf8))
                }
            }
            if !didRename {
                _ = unlink(tmpPath.path)
            }
        }
        try data.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = String(cString: strerror(errno))
                    throw PersistenceCoreError.ioFailure("write(tmp) failed: \(err)")
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
        // Flush file data before rename — the Python _atomic_write_text this
        // layer mirrors fsync'd before renaming. Without it, power loss can
        // commit the rename before the data blocks, leaving the target
        // truncated with the OLD contents already gone (audit 2026-06-09).
        // A failed fsync/close means the data may NOT be durable — throwing
        // (instead of logging) keeps the old file intact and lets the defer
        // unlink the temp (gpt-5.5 review: never rename over good data after
        // the OS reported writeback failure).
        if fsync(fd) != 0 {
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("fsync(tmp) failed: \(err)")
        }
        if close(fd) != 0 {
            fdClosed = true
            let err = String(cString: strerror(errno))
            throw PersistenceCoreError.ioFailure("close(tmp) failed: \(err)")
        }
        fdClosed = true
        _ = chmod(tmpPath.path, 0o600)
        if rename(tmpPath.path, path.path) != 0 {
            throw PersistenceCoreError.ioFailure("rename failed: \(String(cString: strerror(errno)))")
        }
        didRename = true
        _ = chmod(path.path, 0o600)
        // fsyncing the temporary file makes its bytes durable; fsyncing the
        // parent directory makes the rename itself durable. Without the second
        // barrier a power loss may forget the new directory entry even though
        // the file contents reached storage. Callers receive an error on an
        // uncertain commit and can re-read the canonical path before retrying.
        let directoryFD = open(dir.path, O_RDONLY)
        if directoryFD < 0 {
            throw PersistenceCoreError.ioFailure(
                "open(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(directoryFD) }
        if fsync(directoryFD) != 0 {
            throw PersistenceCoreError.ioFailure(
                "fsync(parent directory) failed: \(String(cString: strerror(errno)))"
            )
        }
    }
}

// MARK: - JSONL line cap (U5 W-G, 2026-06-11)

/// Shared line-cap constants for append-only JSONL feeds.
public enum JSONLLineCaps {
    /// `<dataRoot>/activity/events.jsonl` — same budget traces/events.jsonl
    /// got in 12126ef2. Activity was the ownerless leftover with NO rotation
    /// anywhere post-daemon.
    public static let activityEvents = 5000
    /// Amortizes activity rotation: below this size append remains O(1). Once
    /// crossed, the newest line-cap is restored under the existing feed lock.
    public static let activityTrimTriggerBytes = 4 * 1024 * 1024

    // M6 (honesty sweep, 2026-07-09): six audit/receipt ledgers appended
    // forever with no rotation anywhere. Their sibling `workflows/runs.json`
    // WAS capped, so the intent existed — the sweep just never reached these.
    // Audit-class feeds keep a deeper history than receipt-class ones because
    // they are the record of what was allowed to touch the machine.

    /// `<dataRoot>/security/audit.jsonl` — SecurityCenter tool-policy receipts.
    public static let securityAudit = 20_000
    /// Security audit appends stay synchronous and durable, but line-cap
    /// evaluation is amortized behind this bounded byte trigger. Without it,
    /// every tool call rereads the entire multi-megabyte audit ledger merely to
    /// discover that it is still below `securityAudit`. Crossing the trigger
    /// performs the existing locked newest-20k trim; below it, append cost is
    /// independent of accumulated audit history.
    public static let securityAuditTrimTriggerBytes = 32 * 1024 * 1024
    /// `<dataRoot>/mac_control_audit.jsonl` — blocked Mac-control receipts.
    public static let macControlAudit = 20_000
    /// `<dataRoot>/native_power/browser/receipts.jsonl` and
    /// `<dataRoot>/native_power/actions/receipts.jsonl`.
    public static let actionReceipts = 5000
    /// `<dataRoot>/workflows/runs.jsonl`.
    public static let workflowRuns = 5000
    /// `<dataRoot>/logs/maintenance_sweep.jsonl` — one line per file the A5.5
    /// stale-artifact sweep removed (plus one per-pass summary). Audit-class:
    /// this is the ONLY record that a given backup or receipt ever existed, so
    /// it keeps a deeper history than the receipt-class feeds above. At the
    /// sweep's 200/tick cap this holds roughly two months of a fully-saturated
    /// sweep, and years of the steady state (a handful of files a week).
    public static let maintenanceSweep = 20_000
    /// `<dataRoot>/logs/background_loop_failures.jsonl` — operational loop
    /// failures surfaced through `LoopTickOutcome`.
    public static let backgroundLoopFailures = 5000
    /// `<dataRoot>/memory/retention_receipts.jsonl` — hard-bound evictions.
    public static let memoryRetentionReceipts = 5000
    /// `<dataRoot>/training/journal/audit_ledger.jsonl`.
    public static let trainingAudit = 5000
    /// `~/.config/claude-bridge/message-replies.jsonl` — best-effort bridge
    /// diagnostics; the canonical transcript and completion lifecycle live
    /// elsewhere and must not be duplicated without a bound.
    public static let bridgeMessageReplies = 5000
    /// `~/.config/claude-bridge/claude-inbox.jsonl` — Agent → Claude
    /// durable inbox rows (audit 2026-07-21: raw uncapped append; same
    /// budget as the other bridge feeds).
    public static let claudeBridgeInbox = 5000
    /// `<dataRoot>/slack/receipts.jsonl`, `errors.jsonl`, `ignored.jsonl` —
    /// Socket Mode loop ledgers (audit 2026-07-21: raw uncapped appends).
    public static let slackReceipts = 5000
    /// `<dataRoot>/telegram/receipts.jsonl` — per-turn Telegram reply/voice
    /// receipts. Two raw appenders (recordReceipt, recordVoiceTranscription)
    /// grew this unbounded (1.6MB live, tightness round 2 P-M1); route both
    /// through `appendJSONLCapped` at this budget, the sibling of the already
    /// capped `errors.jsonl` (TelegramErrorLog).
    public static let telegramReceipts = 5000
    /// `<dataRoot>/memory/<persona>/notes.jsonl` — Telegram `/note` captures
    /// (TelegramSessionStore.appendNote). Bare append until tightness round 2
    /// P-L4; a receipt-class ledger, same budget as the rest.
    public static let telegramNotes = 5000

    /// `<dataRoot>/desk/desk_archive.jsonl` — archived Desk item records
    /// (audit 2026-07-21): the module's last uncapped JSONL. The op-log's
    /// base+tail is the canonical truth; archive records are a receipt-class
    /// display/idempotency feed, so they take the standard receipt budget.
    public static let deskArchive = 5000

    /// `<dataRoot>/notifications/inbox.jsonl` — the LIVE inbox card feed the
    /// Mac UI and the iOS snapshot read (distinct from the already-capped
    /// legacy `inbox/items.jsonl` silo). 2026-07-21 audit (MED): every writer
    /// appended with no rotation; same budget as the daemon's items.jsonl
    /// surface cap. Status/read_at live per-line here (no index.json overlay),
    /// so the trim needs no index-prune pairing.
    public static let notificationInbox = 1000

    /// Byte threshold below which the turn-trace feed skips its line count
    /// entirely (see `enforceJSONLLineCap(trimWhenBytesExceed:)`). Sized so the
    /// per-turn append never reads a multi-megabyte file just to learn it is
    /// under the 20k-line cap.
    public static let turnTraceTrimTriggerBytes = 8 * 1024 * 1024
    /// Hard daily trace ceiling with hysteresis. Crossing 12 MiB retains the
    /// newest whole rows that fit in 8 MiB, avoiding an 8+ MiB rewrite on every
    /// subsequent append while bounding fourteen retained days to 168 MiB.
    public static let turnTraceMaximumBytes = 12 * 1024 * 1024
    public static let turnTraceTrimTargetBytes = 8 * 1024 * 1024
}

/// Trim a JSONL file to its newest `maxLines` lines. Returns the number of
/// lines dropped (0 when under the cap or the file is missing). The CALLER
/// must hold the file's flock — this helper is the trim step of an
/// append-then-cap sequence and does no locking of its own (mirrors the
/// notification-inbox 1000-line recipe). Never silent: callers log the
/// returned drop count.
///
/// H3/M6 (2026-07-09): the size check happens FIRST. This helper used to read
/// the entire file into memory on every append just to discover it was under the
/// cap — quadratic on an append-only feed, and it did that read while holding the
/// feed's flock on the chat turn path (a 20k-line trace file meant ~18MB read per
/// appended row). Two cheap `stat`-based early-outs now short-circuit it:
///   - `trimWhenBytesExceed`: an optional soft trigger. Below it the cap is not
///     evaluated at all, so appends are amortized O(1) and the file stays bounded
///     by that byte budget instead of being re-counted every row. Callers that
///     need the exact newest-`maxLines` invariant after EVERY append omit it.
///   - an exact lower bound: a file of `n` bytes holds at most `n` lines (every
///     line but the last carries a newline), so `size < maxLines` cannot be over
///     the cap. Sound for every caller, no semantic change.
@discardableResult
public func enforceJSONLLineCap(
    at path: URL,
    maxLines: Int,
    trimWhenBytesExceed: Int? = nil
) throws -> Int {
    guard maxLines > 0, FileManager.default.fileExists(atPath: path.path) else { return 0 }
    // An unstattable-but-present file falls through to the full read rather than
    // silently skipping the cap.
    if let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue {
        if size == 0 { return 0 }
        if let trigger = trimWhenBytesExceed, size < trigger { return 0 }
        if size < maxLines { return 0 }
    }
    let data = try Data(contentsOf: path)
    guard let s = String(data: data, encoding: .utf8) else {
        // U5 fix-round (2026-06-11, gpt-5.5 NIT): never silent — a non-UTF8
        // feed means the cap cannot run, which the state-lifecycle rule says
        // must be visible, not a quiet `return 0`.
        NSLog("enforceJSONLLineCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    guard lines.count > maxLines else { return 0 }
    let dropped = lines.count - maxLines
    let trimmed = lines.suffix(maxLines).joined(separator: "\n") + "\n"
    // Fixed-path tmp sibling; clean on every exit path (state-lifecycle
    // hygiene — same as the NotificationInbox cap).
    let tmp = path.appendingPathExtension("captmp")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try Data(trimmed.utf8).write(to: tmp, options: .atomic)
    _ = chmod(tmp.path, 0o600)
    _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
    _ = chmod(path.path, 0o600)
    return dropped
}

/// Trim a JSONL file to the newest whole rows that fit within `trimToBytes`
/// once it crosses `maxBytes`. The caller must hold the file's flock. The
/// lower target provides hysteresis so a busy feed does not reread/rewrite the
/// entire file on every append after reaching its ceiling.
@discardableResult
public func enforceJSONLByteCap(
    at path: URL,
    maxBytes: Int,
    trimToBytes: Int
) throws -> Int {
    guard maxBytes > 0,
          trimToBytes > 0,
          trimToBytes <= maxBytes,
          FileManager.default.fileExists(atPath: path.path) else {
        return 0
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
    guard size.map({ $0 > maxBytes }) != false else { return 0 }
    let data = try Data(contentsOf: path)
    guard data.count > maxBytes else { return 0 }
    guard let text = String(data: data, encoding: .utf8) else {
        NSLog("enforceJSONLByteCap: %@ is not valid UTF-8 (%d bytes) — cap skipped",
              path.path, data.count)
        return 0
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    var keptReversed: [Substring] = []
    var keptBytes = 0
    for line in lines.reversed() {
        let lineBytes = line.utf8.count + 1
        if !keptReversed.isEmpty, keptBytes + lineBytes > trimToBytes {
            break
        }
        // A single row should already be bounded by its owner. Preserve the
        // newest row even if a corrupt/legacy row exceeds the target so the
        // cap never replaces the feed with an empty file.
        keptReversed.append(line)
        keptBytes += lineBytes
        if keptBytes >= trimToBytes { break }
    }
    let kept = keptReversed.reversed()
    let dropped = max(0, lines.count - kept.count)
    guard dropped > 0 else { return 0 }
    let trimmed = kept.joined(separator: "\n") + "\n"
    let tmp = path.appendingPathExtension("bytecaptmp")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try Data(trimmed.utf8).write(to: tmp, options: .atomic)
    _ = chmod(tmp.path, 0o600)
    _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
    _ = chmod(path.path, 0o600)
    return dropped
}

/// U5 fix-round (2026-06-11, gpt-5.5 review): THE shared capped-append for
/// JSONL activity-style feeds. Appends `event` to `path`, then trims the file
/// to its newest `maxLines` lines, logging what the rotation dropped. Every
/// live `activity/events.jsonl` writer routes through here so no append path
/// can grow the feed unbounded again (PersonaEngine doc-save emit, Skills,
/// Missions, SchedulerDueJobRunner).
///
/// Locking: when `takeLock` is true (default) the append+cap runs under
/// `withFileLock(path)` — for EVERY conformer, not just the SwiftNative impl —
/// so the cap's read-trim-replace cannot race a concurrent capped writer. Callers
/// that already hold the events-feed flock pass `takeLock: false` to avoid
/// double-acquiring it.
public func appendJSONLCapped(
    _ event: JSONValue,
    to path: URL,
    using persistence: any PersistenceCoreProtocol,
    maxLines: Int = JSONLLineCaps.activityEvents,
    logLabel: String,
    takeLock: Bool = true,
    trimWhenBytesExceed: Int? = nil,
    maxBytes: Int? = nil,
    trimToBytes: Int? = nil
) async throws {
    let isActivityFeed = path.lastPathComponent == "events.jsonl"
        && path.deletingLastPathComponent().lastPathComponent == "activity"
        && maxLines == JSONLLineCaps.activityEvents
    let effectiveTrimTrigger = trimWhenBytesExceed
        ?? (isActivityFeed ? JSONLLineCaps.activityTrimTriggerBytes : nil)
    let work: @Sendable () async throws -> Void = {
        try await persistence.appendJSONL(event, to: path)
        let dropped = try enforceJSONLLineCap(
            at: path, maxLines: maxLines, trimWhenBytesExceed: effectiveTrimTrigger
        )
        if dropped > 0 {
            NSLog("%@: %@ cap dropped %d oldest line(s)",
                  logLabel, path.lastPathComponent, dropped)
        }
        if let maxBytes {
            let byteDropped = try enforceJSONLByteCap(
                at: path,
                maxBytes: maxBytes,
                trimToBytes: trimToBytes ?? maxBytes
            )
            if byteDropped > 0 {
                NSLog("%@: %@ byte cap dropped %d oldest line(s)",
                      logLabel, path.lastPathComponent, byteDropped)
            }
        }
    }
    if takeLock {
        // L7 (2026-08-01 audit): this used to downcast to
        // `SwiftNativePersistenceCore` and, on failure, append UNROTATED with no
        // log — a silent fallback that quietly disabled every line/byte cap for
        // any other conformer, letting the feed grow without bound while the
        // call still reported success. The downcast was also gratuitous:
        // `withFileLock` is a PersistenceCoreProtocol EXTENSION
        // (PersistenceCore+FileLock.swift:4), so every conformer already has it,
        // and it locks a local `<path>.lock` sidecar with flock independent of
        // the append backend. The `takeLock: false` branch below has always run
        // the cap for arbitrary conformers, so refusing to run it here was
        // internally inconsistent too. Now uniform: lock, append, cap — and a
        // lock-acquire failure THROWS rather than degrading in silence.
        try await persistence.withFileLock(path, work)
    } else {
        // Caller already holds the events-feed flock.
        try await work()
    }
}

// MARK: - Factory

/// Returns the SwiftNative impl unconditionally — persistence is the foundation
/// every other migrated subsystem builds on, so it migrates first and stays migrated.
public func makePersistenceCore() -> any PersistenceCoreProtocol {
    return SwiftNativePersistenceCore()
}

/// Append `record` to a JSONL feed ONLY if no existing row shares its
/// `idKey` value — the "idempotent inbox card" pattern extracted from the two
/// byte-identical MemoryV2 stagers (kind-backfill + consolidation gate), each of
/// which slurped the ENTIRE inbox (`tailJSONL` limit `Int.max`) under the lock
/// on every append.
///
/// SCAN BOUND: the existence check reads the newest `scanLimit` rows, not the
/// whole file. The dedup these stagers need is against a RECENT re-stage (a
/// crash/retry re-emitting the SAME approval id, which happens within a few
/// appends), and the card ids are pass-unique — so a same-id row older than
/// `scanLimit` newer rows does not occur in practice. kind-backfill additionally
/// guards re-staging with a durable stamp file, so this scan is a second layer.
/// The default (4096) dwarfs any realistic re-stage window while bounding the
/// per-append read on the uncapped, multi-writer inbox feed.
///
/// LOCKING: takes `withFileLock(path)` when `persistence` is the SwiftNative impl
/// (so the check-then-append is atomic against a concurrent unique-append);
/// no-op locking otherwise (tests / HTTP-backed persistence). A record with no
/// decodable `idKey` value is appended unconditionally (nothing to dedup on).
///
/// BOUNDED UNIQUENESS — a declared trade, not an oversight (gpt-5.5 review,
/// 2026-07-17): the existence check scans only the newest `scanLimit` rows, so
/// a duplicate id OLDER than the window can be re-appended. This replaced an
/// O(file) whole-inbox slurp per append. Safe for the current callers because
/// both carry their own primary re-stage guards (kind-backfill's durable stamp
/// file; consolidation's pending-proposal dedup) and re-stages land within a
/// few appends of the original. A caller that needs TRUE uniqueness over
/// unbounded history must not use this helper — use an id-index store instead.
public func appendUniqueById(
    _ record: JSONValue,
    to path: URL,
    idKey: String = "id",
    using persistence: any PersistenceCoreProtocol,
    scanLimit: Int = 4096
) async throws {
    let id: @Sendable (JSONValue) -> String? = { value in
        guard case .object(let obj) = value, case .string(let s)? = obj[idKey] else { return nil }
        return s
    }
    let work: @Sendable () async throws -> Void = {
        guard let targetId = id(record) else {
            try await persistence.appendJSONL(record, to: path)
            return
        }
        let recent = try await persistence.tailJSONL(path, limit: scanLimit, maxBytes: nil)
        if recent.contains(where: { id($0) == targetId }) { return }
        try await persistence.appendJSONL(record, to: path)
    }
    // Same L7 correction as `appendJSONLCapped`: `withFileLock` is a
    // PersistenceCoreProtocol extension, so the downcast that used to guard this
    // only had the effect of silently running the tail-then-append read-modify
    // -write UNLOCKED for every non-SwiftNative conformer — two racing callers
    // both see no match and both append, defeating the idempotency this function
    // exists to provide. Lock uniformly.
    try await persistence.withFileLock(path, work)
}

// MARK: - Data root resolution (single source of truth — Subsystem #1 owns this)

/// Marker files that prove a directory is a NativeAgent source repo.
/// MUST stay in sync with:
///   - the retired daemon::REPO_MARKER_FILES
///   - Sources/NativeAgentApp/NativeAgentPaths.swift::isValidRepoStamp
private let repoMarkerFiles: [String] = [
    "persona/SOUL.template.md",
    "script/init_persona.sh",
    // DAEMON KILLED 2026-06-02: was "the retired daemon" — that file no
    // longer exists, which broke the bundle-stamp validation and caused
    // defaultDataRoot() to silently fall through to AppSupport. The OAuth
    // tokens / provider configs live in the dev path (~/Projects/NativeAgent/
    // data/), so the LLM adapters couldn't find them → silent no-reply in
    // Mac chat. Replaced with Package.swift (matches the Swift-side
    // NativeAgentPaths.isValidRepoStamp marker list).
    "Package.swift",
]

/// Mirrors Python's `_path_inside_app_bundle` at the retired daemon.
/// True when any parent of `candidate` is named "Contents" and its parent
/// has a `.app` extension or name ending in ".app".
private func pathInsideAppBundle(_ candidate: URL) -> Bool {
    let resolved = candidate.resolvingSymlinksInPath()
    var url = resolved
    while url.path != "/" {
        if url.lastPathComponent == "Contents" {
            let grand = url.deletingLastPathComponent()
            if grand.pathExtension == "app" || grand.lastPathComponent.hasSuffix(".app") {
                return true
            }
        }
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { break }
        url = parent
    }
    return false
}

/// Resolve the daemon's data root using the same priority order as Python's
/// `_resolve_data_root`:
///
///   1. `NATIVE_AGENT_DATA_ROOT` env var, used as-is. `~` is NOT expanded
///      — Python does `Path(env)` with no expanduser, so a literal `~` in
///      the env var produces a literal `~` segment in the URL. Matches.
///   2. Stamped REPO_PATH (Resources/REPO_PATH inside the app bundle, written
///      by install_app.sh). The stamp target is canonicalized via
///      `resolvingSymlinksInPath` and validated against ALL THREE
///      `repoMarkerFiles` (matches `the retired daemon::validate_stamped_repo_path`
///      and `Sources/NativeAgentApp/NativeAgentPaths.swift::isValidRepoStamp`).
///      If valid AND `<stamped_repo>/data` exists, return that.
///   3. Walk up from the current working directory looking for a parent that
///      contains BOTH `Package.swift` AND `the retired daemon`. Also
///      requires `data/` to exist there (Python: `if repo_data.exists()`)
///      AND that the path is NOT inside a `.app` bundle (Python:
///      `_path_inside_app_bundle`). Returns `<repo>/data` on match.
///   4. Fallback: `~/Library/Application Support/NativeAgent` BARE — no
///      directory creation (Python just returns the Path; the caller
///      creates on first write). Matches Python's
///      `Path.home() / "Library" / "Application Support" / APP`.
///
/// Both `fileManager` and `environment` are injectable so tests can pin
/// CWD-walkup behavior (via a FileManager subclass overriding
/// `currentDirectoryPath`) and exercise the env var branch in isolation.
public func defaultDataRoot(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    // 1. Env var wins. Empty string is treated as unset (matches Python:
    //    `if env: return Path(env)` — Python treats "" as falsy). The env
    //    var is used LITERALLY — `~` is NOT expanded, to match Python.
    //
    //    GOTCHA: every `URL(fileURLWithPath:)` / `URL(fileURLWithFileSystem-
    //    Representation:)` variant on Darwin Foundation silently expands a
    //    leading `~` ("`~/foo`" → "`$HOME/foo`"). Python's `Path(env)` does
    //    NOT expand. The only Foundation constructor that preserves a leading
    //    tilde is `URLComponents(scheme: "file", path: raw)` — that path
    //    bypasses the implicit tilde expansion entirely. Validated by
    //    `defaultDataRoot_envVarPreservesLeadingTilde` in PersistenceCoreTests.
    if let raw = environment["NATIVE_AGENT_DATA_ROOT"], !raw.isEmpty {
        var components = URLComponents()
        components.scheme = "file"
        components.path = raw
        if let url = components.url {
            return url
        }
        // Defensive fallback if URLComponents.url returns nil for some edge
        // case (shouldn't happen for well-formed paths). Accepts the
        // tilde-expansion divergence rather than crashing.
        return URL(fileURLWithPath: raw)
    }

    // 2. Stamped REPO_PATH (bundle install). Look for a `REPO_PATH` text file
    //    next to Bundle.main's Resources hierarchy. Mirrors Python's
    //    `_bundle_repo_path` walk over `Path(__file__).parent`, etc.
    if let stamped = _stampedRepoFromBundle(fileManager: fileManager) {
        let dataDir = stamped.appendingPathComponent("data", isDirectory: true)
        if fileManager.fileExists(atPath: dataDir.path) {
            return dataDir
        }
    }

    // 3. Dev heuristic — walk up from CWD looking for a repo root.
    //    Differs from Python (which uses Path(__file__).resolve().parent.parent)
    //    because Swift package code has no equivalent of __file__ at runtime.
    //    Adds TWO checks Python also enforces: data/ subdir must EXIST,
    //    path must NOT be inside an .app bundle.
    //
    //    Tightness review round 2 (HIGH, 2026-07-17): the CWD walk is a DEV
    //    convenience and must never fire for an UNSTAMPED PUBLIC-RELEASE app
    //    bundle — a public .app launched with a checkout as its cwd would
    //    silently adopt the private repo's data/ AND bypass the app layer's
    //    blank-slate quarantine (which only runs on the AppSupport root).
    //    Guarded HERE in the canonical resolver — not just in the app-side
    //    NativeAgentPaths wrapper — because hundreds of call sites reach this
    //    function directly.
    if _isUnstampedPublicAppBundle(fileManager: fileManager) {
        return libraryAppSupportFallback(fileManager: fileManager)
    }
    let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    var dir = cwd
    for _ in 0..<8 {
        // W1.3: case-insensitive Package.swift probe so case-sensitive
        // filesystems (or a checkout where the manifest got lowercased)
        // still resolve the dev repo. Package.swift alone is the dev-repo
        // marker now, mirroring NativeAgentPaths.isValidRepoStamp.
        let pkg = dir.appendingPathComponent("Package.swift")
        let pkgLower = dir.appendingPathComponent("package.swift")
        let dataDir = dir.appendingPathComponent("data", isDirectory: true)
        let isRepo = fileManager.fileExists(atPath: pkg.path)
            || fileManager.fileExists(atPath: pkgLower.path)
        let hasData = fileManager.fileExists(atPath: dataDir.path)
        let isInAppBundle = pathInsideAppBundle(dataDir)
        if isRepo && hasData && !isInAppBundle {
            return dataDir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }

    // 4. AppSupport fallback (bare — no /data suffix, no dir creation;
    //    matches Python's `Path.home() / "Library" / ... / APP`).
    return libraryAppSupportFallback(fileManager: fileManager)
}

/// True only for a distributed public build: a real `.app` bundle carrying a
/// VERSION resource but NO REPO_PATH dev stamp. Dev installs from
/// install_app.sh are always stamped, and test/CLI processes are not `.app`
/// bundles, so both keep full dev resolution. Mirrors (and must stay in sync
/// with) `NativeAgentPaths.isPublicReleaseBundle` in the app layer.
private func _isUnstampedPublicAppBundle(fileManager: FileManager) -> Bool {
    guard Bundle.main.bundleURL.pathExtension == "app",
          let resourcesURL = Bundle.main.resourceURL else { return false }
    if fileManager.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
        return false
    }
    return fileManager.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
}

/// Resolve the Swift-native persona root.
///
/// Resolution priority:
///   1. `NATIVE_AGENT_PERSONA_ROOT` env var (literal; no tilde expansion).
///   2. `<dataRoot>/persona/<identity>` when it contains SOUL.md, otherwise
///      `<dataRoot>/persona` when SOUL.md lives directly there. These are the
///      installed-app user-editable canonical locations once fully seeded.
///   3. `<stamped_repo>/persona/Agent` when it contains SOUL.md; otherwise
///      `<stamped_repo>/persona` when that root contains SOUL.md. This handles
///      the current repo layout where `persona/Agent` is notes/workspace only.
///   4. `<repo>/persona` when `dataRoot` is `<repo>/data` and SOUL.md exists.
///   5. `<dataRoot>/memory` legacy cold-start fallback.
///
/// `dataRoot` is the caller's resolved data root; we accept it rather than
/// re-resolving so a test can pin a `tmpDir` without env vars leaking from
/// the host process.
public func defaultPersonaRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let raw = environment["NATIVE_AGENT_PERSONA_ROOT"], !raw.isEmpty {
        var components = URLComponents()
        components.scheme = "file"
        components.path = raw
        if let url = components.url {
            return url
        }
        return URL(fileURLWithPath: raw)
    }
    let canonicalPersonaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
    if let personaDir = firstPersonaSubdirWithSoul(in: canonicalPersonaRoot, fileManager: fileManager) {
        return personaDir
    }
    if fileManager.fileExists(
        atPath: canonicalPersonaRoot.appendingPathComponent("SOUL.md").path
    ) {
        return canonicalPersonaRoot
    }
    if let stamped = _stampedRepoFromBundle(fileManager: fileManager) {
        let personaRoot = stamped.appendingPathComponent("persona", isDirectory: true)
        if let personaDir = firstPersonaSubdirWithSoul(in: personaRoot, fileManager: fileManager) {
            return personaDir
        }
        if fileManager.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) {
            return personaRoot
        }
    }
    if let repoRoot = resolveSandboxRepoRoot(dataRoot: dataRoot, fileManager: fileManager) {
        let personaDir = repoRoot.appendingPathComponent("persona", isDirectory: true)
        if fileManager.fileExists(atPath: personaDir.appendingPathComponent("SOUL.md").path) {
            return personaDir
        }
    }
    return dataRoot.appendingPathComponent("memory", isDirectory: true)
}

private func firstPersonaSubdirWithSoul(in parent: URL, fileManager: FileManager) -> URL? {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { continue }
        if fileManager.fileExists(atPath: entry.appendingPathComponent("SOUL.md").path) {
            return entry
        }
    }
    return nil
}

/// `~/Library/Application Support/NativeAgent` BARE — no `/data` suffix, no
/// directory creation. Matches Python's fallback at the retired daemon.
/// Subsystems (ApprovalInbox, MCPDispatcher) used to duplicate this resolution;
/// they now delegate here.
public func libraryAppSupportFallback(
    fileManager: FileManager = .default
) -> URL {
    if let appSupport = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false
    ) {
        return appSupport.appendingPathComponent("NativeAgent", isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/NativeAgent")
}

/// Mirrors Python's `_bundle_repo_path`: look for a `REPO_PATH` stamp file in
/// the running bundle's Resources hierarchy and return its target as a URL.
/// Returns `nil` outside a stamped bundle (dev path, swift test runner) —
/// callers fall through to the next resolution step.
private func _stampedRepoFromBundle(fileManager: FileManager) -> URL? {
    let main = Bundle.main
    var bases: [URL] = []
    if let res = main.resourceURL { bases.append(res) }
    bases.append(main.bundleURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true))
    bases.append(main.bundleURL)
    return _stampedRepoFromBundleBases(bases, fileManager: fileManager)
}

/// Test seam for `_stampedRepoFromBundle` — accepts injected bundle bases so
/// tests can build a synthetic Resources/REPO_PATH layout without needing a
/// real .app bundle. Validates the stamp target against `repoMarkerFiles`
/// the same way Python's `validate_stamped_repo_path` does (all three files
/// must exist on the canonicalized path).
internal func _stampedRepoFromBundleBases(
    _ bases: [URL],
    fileManager: FileManager
) -> URL? {
    for base in bases {
        let stamp = base.appendingPathComponent("REPO_PATH")
        guard fileManager.fileExists(atPath: stamp.path) else { continue }
        guard let data = try? Data(contentsOf: stamp) else { continue }
        guard let text = String(data: data, encoding: .utf8) else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let raw = URL(fileURLWithPath: trimmed)
        // Canonicalize — follows symlinks like Python's Path.resolve().
        let canonical = raw.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: canonical.path) else { continue }
        var allMarkersExist = true
        for marker in repoMarkerFiles {
            let m = canonical.appendingPathComponent(marker)
            if !fileManager.fileExists(atPath: m.path) {
                allMarkersExist = false; break
            }
        }
        if allMarkersExist { return canonical }
    }
    return nil
}

/// True iff `candidate` is a NativeAgent source/install repo root — i.e. ALL
/// THREE `repoMarkerFiles` exist directly under it. Mirrors the validation
/// `_stampedRepoFromBundleBases` (and Python's
/// `the retired daemon::validate_stamped_repo_path`) apply to a stamped
/// REPO_PATH target, factored out so the dispatch-sandbox repo-root resolver
/// (`resolveSandboxRepoRoot`) can reuse the EXACT same proof of "this is a real
/// repo, not an arbitrary directory".
internal func isValidRepoRootDir(
    _ candidate: URL,
    fileManager: FileManager
) -> Bool {
    for marker in repoMarkerFiles {
        let m = candidate.appendingPathComponent(marker)
        if !fileManager.fileExists(atPath: m.path) { return false }
    }
    return true
}

/// Resolve the repo root to use as the IN-PROCESS dispatch sandbox's sole
/// always-allowed root, mirroring the daemon's `self.repo_root` (the explicit
/// `--repo-root` checkout/install path passed at boot — the retired daemon).
///
/// THE BUG THIS CLOSES (§6.240 round-2 reopen #2): the `_swiftDispatch`
/// file-system seam previously derived the sandbox repo root as
/// `defaultDataRoot().deletingLastPathComponent()` (the data root's PARENT).
/// That is correct ONLY when the data root is `<repo>/data` (dev walkup or
/// stamped-bundle install, where the parent is a validated repo). But the
/// data-root resolver's STEP-4 fallback returns `~/Library/Application
/// Support/NativeAgent` BARE (no `/data` suffix — see `defaultDataRoot`), whose
/// parent is `~/Library/Application Support` — the ENTIRE Application Support
/// tree. With the read sandbox engaged, that parent became the sole allowed
/// root, so a read of any path under `~/Library/Application Support/<any other
/// app>` would have resolved inside the sandbox. The env-var data-root branch
/// (step 1) has the same exposure: an arbitrary `NATIVE_AGENT_DATA_ROOT` whose
/// parent is an unrelated directory would widen the sandbox to that parent.
///
/// Fix (matches the brief's option (a) — "refuse if the path resolves to
/// AppSupport"): only return a repo root we can PROVE is a real NativeAgent
/// checkout/install — the data root's parent must carry ALL THREE
/// `repoMarkerFiles` (`isValidRepoRootDir`), exactly the daemon's stamped-repo
/// validation. If the parent is unproven — the bare AppSupport fallback, an
/// AppSupport-pattern path, or an env-var root pointing somewhere arbitrary —
/// return `nil`. The caller (`_swiftDispatch`) treats `nil` as "do NOT engage
/// the in-process sandbox": it forces the HTTP `/v1/dispatch` fallback, where
/// the daemon supplies its OWN validated `self.repo_root`. Refusing is strictly
/// safer than guessing a narrower root and is the conservative default-off
/// posture — no read ever executes against an overbroad in-process sandbox.
///
/// Returns the validated repo-root path string, or `nil` to signal "refuse the
/// in-process sandbox; fall back to HTTP".
public func resolveSandboxRepoRoot(
    dataRoot: URL = defaultDataRoot(),
    fileManager: FileManager = .default
) -> URL? {
    let parent = dataRoot.deletingLastPathComponent()
    // Defensive: a root-level or empty parent ("/" or "") is never a repo.
    if parent.path.isEmpty || parent.path == "/" { return nil }
    // Belt-and-suspenders against the named failure mode: if the data root is
    // the bare AppSupport fallback (its LAST component is the app dir and its
    // parent is "…/Application Support"), refuse outright even if — implausibly
    // — someone planted marker files in Application Support. The marker check
    // below already rejects this, but naming it makes the intent explicit and
    // immune to a future Application-Support layout that happens to look repo-y.
    if parent.lastPathComponent == "Application Support"
        || parent.path.hasSuffix("/Library/Application Support") {
        return nil
    }
    // The proof: the parent must be a real NativeAgent repo (all three markers),
    // mirroring the daemon's `self.repo_root` being a validated checkout.
    guard isValidRepoRootDir(parent, fileManager: fileManager) else { return nil }
    return parent
}
