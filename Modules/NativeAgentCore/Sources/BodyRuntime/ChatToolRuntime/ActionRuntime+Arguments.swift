import PersistenceCore
import Foundation
import NativeAgentCore
// Blueprint: | `ActionRuntime+Arguments.swift` | `SwiftToolDispatcher`: Boolean flag coercion |

// MARK: - Shared tool implementation helpers

extension SwiftToolDispatcher {
    func flag(_ input: [String: JSONValue], _ key: String) -> Bool {
        switch input[key] {
        case .some(.bool(let b)): return b
        case .some(.string(let s)): return ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: return false
        }
    }
}
