import Foundation
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+SessionClassification.swift` | Protocol disconnect reason owns session closure; elapsed time decides nothing |

extension SlackSocketModeLoop {
    static func classifySessionClosure(_ error: Error?) -> LoopTickOutcome {
        if case .disconnect(let reason)? = error as? SlackSocketSessionClosure {
            switch reason {
            case "warning", "refresh_requested":
                return .completed(result: "Slack requested connection refresh (\(reason))")
            default:
                return .failed(error: "Slack socket disconnected (\(Self.redact(reason)))")
            }
        }
        if let error { return .failed(error: Self.redact(String(describing: error))) }
        return .skipped(reason: "Slack receive ended without a terminal reason", healthNeutral: true)
    }

}
