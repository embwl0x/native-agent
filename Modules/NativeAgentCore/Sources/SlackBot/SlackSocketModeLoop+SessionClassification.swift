import Foundation
import BackgroundLoops
// Blueprint: | `SlackSocketModeLoop+SessionClassification.swift` | `SlackSocketModeLoop`: one closure classifier for receive return, disconnect and transport error; fatal disconnects outrank planned recycling |

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

    /// Slack's `disconnect` reasons are not interchangeable. `link_disabled`
    /// and `too_many_connections` describe a condition a fast reconnect makes
    /// WORSE (a disabled app, or this loop already holding too many sockets),
    /// so they are failures at any session length — the point is to get into
    /// backoff. Every other reason (`refresh_requested`, `warning`, …) is
    /// Slack's routine connection rotation and is only a failure when the
    /// session was too short to have carried any traffic.
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
