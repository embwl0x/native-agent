import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Shared tool implementation helpers

extension SwiftToolDispatcher {
    /// Number coercion for confidence/importance (accepts double, int, or a
    /// numeric string). Mirrors optionalInt's tolerant shape.
    static func optionalNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .some(.double(let d)): return d
        case .some(.int(let i)): return Double(i)
        case .some(.string(let s)): return Double(s)
        default: return nil
        }
    }

    func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    func jsonInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .some(.int(let i)): return Int(i)
        case .some(.double(let d)): return Int(d)
        case .some(.string(let s)): return Int(s)
        default: return nil
        }
    }

}
