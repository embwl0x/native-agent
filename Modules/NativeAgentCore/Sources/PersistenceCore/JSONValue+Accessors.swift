import Foundation
// Blueprint: | `JSONValue+Accessors.swift` | Typed JSON extraction, explicit defaults and coercion, and unknown-field handling. |

extension JSONValue {
    public var objectValue: [String: JSONValue]? { if case .object(let fields) = self { fields } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
    public var stringValue: String? { if case .string(let text) = self { text } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }

    package static func stringOrEmpty(_ value: JSONValue?) -> String {
        value?.stringValue ?? ""
    }

    package var trimmedString: String? {
        guard let text = stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    package static func trimmedStringOrEmpty(_ value: JSONValue?) -> String {
        value?.trimmedString ?? ""
    }

    /// Reject whitespace-only strings and keep the original spelling and whitespace.
    package var nonblankString: String? {
        trimmedString == nil ? nil : stringValue
    }

    package var nonemptyString: String? {
        guard let text = stringValue, !text.isEmpty else { return nil }
        return text
    }

    package static func objectOrEmpty(_ value: JSONValue?) -> [String: JSONValue] {
        value?.objectValue ?? [:]
    }

    package static func stringArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    package static func trimmedStringArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.trimmedString) ?? []
    }

    package static func objectArray(_ value: JSONValue?) -> [[String: JSONValue]] {
        value?.arrayValue?.compactMap(\.objectValue) ?? []
    }

    package var doubleValue: Double? {
        numberValue(coercingStrings: false, finiteOnly: false)
    }

    package var finiteDoubleValue: Double? {
        numberValue(coercingStrings: false, finiteOnly: true)
    }

    package var strictInt64: Int64? {
        if case .int(let number) = self { number } else { nil }
    }

    package var nonnegativeInt64: Int64? {
        guard let number = strictInt64, number >= 0 else { return nil }
        return number
    }

    package var strictInt: Int? {
        strictInt64.map { Int($0) }
    }

    package static func boolOrFalse(_ value: JSONValue?) -> Bool {
        value?.boolValue ?? false
    }

    package static func firstTrimmedString(_ fields: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let text = fields[key]?.trimmedString { return text }
        }
        return nil
    }

    public var scalarText: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    public static func trimmedScalarTextOrEmpty(_ value: JSONValue?) -> String {
        value?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    package static func trimmedScalarTextArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.map { trimmedScalarTextOrEmpty($0) }.filter { !$0.isEmpty } ?? []
    }

    public var integerValue: Int64? {
        switch self {
        case .int(let number): return number
        case .double(let number): return Int64(exactly: number.rounded(.towardZero))
        default: return nil
        }
    }
    /// Only integral, finite, representable JSON numbers; no string or Boolean coercion.
    public var exactIntegerValue: Int? {
        switch self {
        case .int(let number): return Int(exactly: number)
        case .double(let number): return Int(exactly: number)
        default: return nil
        }
    }
    public func numberValue(coercingStrings: Bool, finiteOnly: Bool) -> Double? {
        let number: Double?
        switch self {
        case .int(let value): number = Double(value)
        case .double(let value): number = value
        case .string(let value) where coercingStrings: number = Double(value)
        default: return nil
        }
        return number.flatMap { !finiteOnly || $0.isFinite ? $0 : nil }
    }
}

public struct JSONKey: CodingKey, Hashable {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { self.stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == JSONKey {
    public func unknownFields(excluding knownKeys: Set<String>) -> [String: JSONValue] {
        var unknown: [String: JSONValue] = [:]
        for key in allKeys where !knownKeys.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = value
            }
        }
        return unknown
    }
}

extension KeyedEncodingContainer where Key == JSONKey {
    public mutating func encodeUnknownFields(_ extras: JSONValue?, excluding knownKeys: Set<String>) throws {
        if case .object(let fields)? = extras {
            for (key, value) in fields where !knownKeys.contains(key) {
                try encode(value, forKey: JSONKey(key))
            }
        }
    }
}
