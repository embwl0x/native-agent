import Privacy
import ChatSessionWork
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ToolRegistry
import ChatToolParsing
// Blueprint: | `MacChatTurnActivity.swift` | `MacChatTurnActivity` struct |

public enum MacChatTurnActivitySource: Sendable, Equatable {
    case toolUse
    case toolResult
    case notice(kind: String)
}

/// Retain no payload-capable fields so the activity reducer cannot hold provider, tool, output or reasoning bodies.
public struct MacChatTurnActivity: Sendable, Equatable {
    public let identity: MacChatTurnIdentity
    public let source: MacChatTurnActivitySource
    public let phase: TurnPresentationPhase
    public let actionSummary: String?
    /// Redact and cap toast text independently; the shared kernel retains its tighter summary limit.
    public let userVisibleNoticeText: String?
    public let delegateDisplayName: String?
    public let outcome: TurnPresentationActivity.Outcome?
    public let occurredAt: Date
    /// The call a use starts or a result ends; results meet their use by this name in arrival order.
    public let callName: String?
}

/// Discard raw input and output before constructing activity; retain only bounded plain labels and exact outcome class.
public enum MacChatTurnActivityBoundary {
    /// Label `app` activity by the action actually run.
    public static func activity(
        from event: TurnStreamEvent,
        identity: MacChatTurnIdentity,
        shown: ShownToolNames,
        at instant: Date
    ) -> MacChatTurnActivity? {
        switch event {
        case .toolUse(let name, let input):
            let call = shown.use(name, input: input)
            return toolUse(name: call.name, args: call.input.stringFields, identity: identity, at: instant)
        case .toolResult(let name, let output):
            let reply = ToolResult(output)
            return toolResult(
                name: shown.result(name).name,
                result: reply.outcome,
                identity: identity,
                at: instant
            )
        case .notice(let kind, let text):
            return notice(kind: kind, text: text, identity: identity, at: instant)
        case .delta, .final, .error, .replyTextSettled, .writing:
            return nil
        }
    }

    public static func notice(
        kind: String,
        text: String,
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity {
        let safeKind = sanitized(kind) ?? "notice"
        let safeText = sanitized(text)
        return MacChatTurnActivity(
            identity: identity,
            source: .notice(kind: safeKind),
            phase: noticePhase(kind: kind),
            actionSummary: safeText,
            userVisibleNoticeText: boundedNoticeText(text),
            delegateDisplayName: nil,
            outcome: nil,
            occurredAt: instant,
            callName: nil
        )
    }

    public static func toolUse(
        name: String,
        args: [String: String],
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity {
        let delegate = delegateName(forTool: name, args: args)
        return MacChatTurnActivity(
            identity: identity,
            source: .toolUse,
            phase: delegate == nil ? .tool : .delegation,
            actionSummary: sanitized(ToolActivityPresentation.progress(name, args: args)),
            userVisibleNoticeText: nil,
            delegateDisplayName: delegate,
            outcome: nil,
            occurredAt: instant,
            callName: name
        )
    }

    /// Stopped and unconfirmed results carry no outcome: neither is a success
    /// nor a failure, and their words already say which they are.
    static func toolResult(
        name: String,
        result: ChatToolOutcome.ExactResultClass,
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity {
        let outcome: TurnPresentationActivity.Outcome? = switch result {
        case .succeeded: .ok
        case .refused: .refused
        case .failed, .timeout: .failed
        case .cancelled, .unknown: nil
        }
        return MacChatTurnActivity(
            identity: identity,
            source: .toolResult,
            phase: .working,
            actionSummary: sanitized(ToolActivityPresentation.finished(name, outcome: result.rawValue)),
            userVisibleNoticeText: nil,
            delegateDisplayName: nil,
            outcome: outcome,
            occurredAt: instant,
            callName: name
        )
    }

    private static func noticePhase(kind: String) -> TurnPresentationPhase {
        if kind == "provider.reconnecting" { return .retrying }
        let lower = kind.lowercased()
        if lower.contains("retry") || lower.contains("recovery") { return .retrying }
        if lower.contains("waiting") { return .waiting }
        if lower.contains("blocked") || lower.contains("approval") { return .blocked }
        if lower.contains("timeout") || lower.contains("stall") { return .stalled }
        return .working
    }

    private static func delegateName(forTool name: String, args: [String: String]) -> String? {
        switch name.lowercased() {
        case "agent_message":
            guard let agent = sanitized(args["agent"]),
                  !agent.hasPrefix("peer:"), !agent.hasPrefix("bot:") else { return "Agent" }
            return agent
        default: return nil
        }
    }

    private static func sanitized(_ raw: String?) -> String? {
        TurnPresentationReducer.sanitized(
            raw,
            additionalRedactor: { NativeAppSecretRedactor.redactText($0) }
        )
    }

    private static func boundedNoticeText(_ raw: String) -> String? {
        let redacted = NativeAppSecretRedactor.redactText(raw)
        let singleLine = redacted
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        let limit = 512
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit - 1)) + "…"
    }
}
