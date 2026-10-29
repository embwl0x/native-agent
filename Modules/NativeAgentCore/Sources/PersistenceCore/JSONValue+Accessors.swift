import Foundation
import CryptoKit
import Darwin
// Blueprint: | `JSONValue+Accessors.swift` | JSONValue primitive accessors with explicit numeric coercion/finite policy; JSONKey and unknown-field Codable container operations |

extension JSONValue {
    public var objectValue: [String: JSONValue]? { if case .object(let fields) = self { fields } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
    public var stringValue: String? { if case .string(let text) = self { text } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var scalarText: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
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
