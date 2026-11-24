import Foundation
// Blueprint: | `SlackSocketModeSupport.swift` | Checked socket errors |

enum SlackSocketModeError: Error, CustomStringConvertible {
    case api(String)

    var description: String {
        switch self {
        case .api(let message): return message
        }
    }
}
