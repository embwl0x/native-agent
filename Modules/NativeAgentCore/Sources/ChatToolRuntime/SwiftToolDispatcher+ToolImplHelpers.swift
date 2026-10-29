import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+ToolImplHelpers.swift` | `SwiftToolDispatcher`: exact `jsonInt` |

// MARK: - Shared tool implementation helpers

extension SwiftToolDispatcher {
    func flag(_ input: [String: JSONValue], _ key: String) -> Bool {
        switch input[key] {
        case .some(.bool(let b)): return b
        case .some(.string(let s)): return ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: return false
        }
    }

    static func jsonInt(_ value: JSONValue?) -> Int? {
        if case .double(let number)? = value, number != number.rounded() { return nil }
        return value?.integerValue.flatMap(Int.init(exactly:))
    }
}
