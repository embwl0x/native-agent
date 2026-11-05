import Foundation
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: fatal disconnects outrank recycling |

extension SlackSocketModeLoop {
    static func classifySessionClosure(
        _ error: Error?,
        sessionDuration: TimeInterval,
        recyclePlanned: Bool,
        recycleInterval: TimeInterval
    ) -> LoopTickOutcome {
        let closure = error as? SlackSocketSessionClosure
        let rounded = Int(sessionDuration.rounded())
        // Fatal disconnect evidence outranks planned recycling.
        if case .disconnect(let reason)? = closure,
           disconnectDisposition(forReason: reason) == .fatal {
            return .failed(error: recyclePlanned
                ? "Slack socket reported \(reason) during a planned recycle"
                : "Slack socket disconnected after \(rounded)s (\(reason))")
        }
        if recyclePlanned {
            return .completed(
                result: "Slack socket session recycled after \(Int(recycleInterval))s"
            )
        }
        if let error, closure == nil {
            return .failed(error: Self.redact(String(describing: error)))
        }
        let message: String
        if case .disconnect(let reason)? = closure {
            message = "Slack socket disconnected after \(rounded)s (\(reason))"
        } else { message = "Slack socket receive loop ended after \(rounded)s" }
        return sessionDuration < shortLivedSessionFloor ? .failed(error: message) : .completed(result: message)
    }

    /// `link_disabled` and `too_many_connections` always need backoff: fast reconnects worsen them. Other reasons describe routine rotation and fail only when
    /// the session was too short to carry traffic.
    enum SlackDisconnectDisposition: Sendable, Equatable {
        case routine
        case fatal
    }

    static func disconnectDisposition(forReason reason: String) -> SlackDisconnectDisposition {
        switch reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "link_disabled", "too_many_connections", "too_many_websockets":
            return .fatal
        default:
            return .routine
        }
    }

}
