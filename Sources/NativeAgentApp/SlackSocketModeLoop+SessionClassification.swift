import Foundation
import BackgroundLoops

extension SlackSocketModeLoop {
    static func classifySessionClosure(
        _ closure: SlackSocketSessionClosure,
        sessionDuration: TimeInterval,
        recyclePlanned: Bool,
        recycleInterval: TimeInterval
    ) -> LoopTickOutcome {
        // A planned recycle only claims the closure when the socket did not
        // ALSO report a fatal condition. A `link_disabled`/`too_many_connections`
        // disconnect racing the recycle timer must still fail the tick, or
        // backoff is suppressed on a genuinely broken socket.
        if recyclePlanned,
           case .disconnect(let reason) = closure,
           disconnectDisposition(forReason: reason) == .fatal {
            return .failed(
                error: "Slack socket reported \(reason) during a planned recycle"
            )
        }
        if recyclePlanned {
            return .completed(
                result: "Slack socket session recycled after \(Int(recycleInterval))s"
            )
        }
        switch closure {
        case .disconnect(let reason):
            let rounded = Int(sessionDuration.rounded())
            let message = "Slack socket disconnected after \(rounded)s (\(reason))"
            switch disconnectDisposition(forReason: reason) {
            case .fatal:
                return .failed(error: message)
            case .routine:
                guard sessionDuration < shortLivedSessionFloor else {
                    return .completed(result: message)
                }
                return .failed(error: message)
            }
        }
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

    /// A session whose receive loop returned with no `disconnect` frame. The
    /// planned recycle stays success; anything shorter than the floor is churn.
    static func classifyReceiveLoopReturn(
        sessionDuration: TimeInterval,
        recyclePlanned: Bool,
        recycleInterval: TimeInterval
    ) -> LoopTickOutcome {
        if recyclePlanned {
            return .completed(
                result: "Slack socket session recycled after \(Int(recycleInterval))s"
            )
        }
        let rounded = Int(sessionDuration.rounded())
        guard sessionDuration >= shortLivedSessionFloor else {
            return .failed(error: "Slack socket receive loop ended after \(rounded)s")
        }
        return .completed(result: "Slack socket receive loop ended after \(rounded)s")
    }
}
