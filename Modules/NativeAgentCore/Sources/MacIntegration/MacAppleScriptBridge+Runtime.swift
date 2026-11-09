import AuthoredCapabilities
import Foundation
import NativeAgentShared
import MacControl
import PersistenceCore
import NativeAgentCore
// Blueprint: | `MacAppleScriptBridge+Runtime.swift` | `MacAppleScriptBridge.clampedInt`: shared integer argument bounds |

extension MacAppleScriptBridge {
    package static func clampedInt(_ raw: JSONValue?, defaultValue: Int, min: Int, max: Int) throws -> Int {
        guard let raw else { return Swift.max(min, Swift.min(max, defaultValue)) }
        let value: Int?
        switch raw {
        case .int(let i):
            value = Int(exactly: i)
        case .double(let d):
            value = Int(exactly: d)
        case .string(let s):
            value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            value = nil
        }
        guard let value else { throw NSError(domain: "NativeAgentInput", code: -400,
            userInfo: [NSLocalizedDescriptionKey: """
                A supplied numeric limit, offset or duration is not an integer. Correct the argument; defaults apply only when omitted.
                """]) }
        return Swift.max(min, Swift.min(max, value))
    }
}
