import Foundation
import PersistenceCore
// Blueprint: | `TolerantDisplayStringDecoding.swift` | `JSONValue.nextGenDisplayString` |

extension JSONValue {
    public var nextGenDisplayString: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            if let integer = Int(exactly: value) {
                return String(integer)
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            return values.map(\.nextGenDisplayString).joined(separator: ", ")
        case .object(let object):
            return object
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key): \($0.value.nextGenDisplayString)" }
                .joined(separator: ", ")
        }
    }
}
