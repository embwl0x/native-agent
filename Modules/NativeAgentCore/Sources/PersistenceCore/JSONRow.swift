import Foundation
// Blueprint: | `JSONRow.swift` | `JSONRow` checked stored-object reads; required/optional typed fields and named malformed-row errors |

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
    public func optionalStrings(_ key: String) throws -> [String]? { try optional(key, Self.strings) }
    public func array(_ key: String) throws -> [JSONValue] {
        try required(key) { if case .array(let values) = $0 { return values }; return nil }
    }
    public func optionalBool(_ key: String) throws -> Bool? {
        try optional(key) { if case .bool(let value) = $0 { return value }; return nil }
    }
    public func optionalInt(_ key: String) throws -> Int? {
        try optional(key) { $0.exactIntegerValue }
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
