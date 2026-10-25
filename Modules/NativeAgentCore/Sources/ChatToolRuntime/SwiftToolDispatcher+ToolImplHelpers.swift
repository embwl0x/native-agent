import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: `optionalNumber`, `jsonString`, `jsonInt` |

// MARK: - Shared tool implementation helpers

extension SwiftToolDispatcher {
    /// Read a JSON number for confidence/importance.
    static func optionalNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .some(.double(let d)): return d
        case .some(.int(let i)): return Double(i)
        default: return nil
        }
    }

    func jsonString(_ value: JSONValue?) -> String? {
        guard case .string(let s)? = value else { return nil }
        return s
    }

    static func jsonInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .some(.int(let i)): return Int(exactly: i)
        case .some(.double(let d)): return Int(exactly: d)
        default: return nil
        }
    }

}
