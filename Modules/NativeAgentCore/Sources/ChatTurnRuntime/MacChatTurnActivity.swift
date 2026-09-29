import Privacy
import Foundation
import NativeAgentCore
import PersistenceCore

/// Exact routing identity for live Mac turn activity. The session id selects
/// the AppModel slot; the turn id prevents late events from a prior stream
/// from entering a replacement turn in that same session.
public struct MacChatTurnIdentity: Sendable, Equatable {
    public let sessionId: String
    public let turnId: String

    public init(sessionId: String, turnId: String) {
        self.sessionId = sessionId
        self.turnId = turnId
    }
}

public enum MacChatTurnActivitySource: Sendable, Equatable {
    case toolUse
    case toolResult
    case notice(kind: String)
}

/// A boundary-sanitized reducer input. It deliberately has no field capable
/// of retaining tool arguments/results, provider payloads, model output, or
/// hidden reasoning.
public struct MacChatTurnActivity: Sendable, Equatable {
    public let identity: MacChatTurnIdentity
    public let source: MacChatTurnActivitySource
    public let phase: TurnPresentationPhase
    public let toolDisplayName: String?
    public let actionSummary: String?
    /// Existing toast copy, redacted and independently capped before crossing
    /// the boundary. The stored shared-kernel summary remains at its tighter
    /// 120-character detail limit.
    public let userVisibleNoticeText: String?
    public let delegateDisplayName: String?
    public let occurredAt: Date
}

/// Converts the existing ChatOrchestration stream vocabulary at the Mac
/// boundary. Raw JSON input/output is pattern-discarded in this switch before
/// an activity value can be constructed.
public enum MacChatTurnActivityBoundary {
    public static func activity(
        from event: TurnStreamEvent,
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity? {
        switch event {
        case .toolUse(let name, _):
            return toolUse(name: name, identity: identity, at: instant)
        case .toolResult(let name, _):
            return toolResult(name: name, identity: identity, at: instant)
        case .notice(let kind, let text):
            return notice(kind: kind, text: text, identity: identity, at: instant)
        case .delta, .final, .error, .replyTextSettled:
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
            toolDisplayName: nil,
            actionSummary: safeText,
            userVisibleNoticeText: boundedNoticeText(text),
            delegateDisplayName: delegateName(forNoticeKind: kind, text: text),
            occurredAt: instant
        )
    }

    private static func toolUse(
        name: String,
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity {
        let safeName = sanitized(name) ?? "Tool"
        return MacChatTurnActivity(
            identity: identity,
            source: .toolUse,
            phase: delegateName(forTool: name) == nil ? .tool : .delegation,
            toolDisplayName: safeName,
            actionSummary: sanitized("Using tool: \(safeName)"),
            userVisibleNoticeText: nil,
            delegateDisplayName: delegateName(forTool: name),
            occurredAt: instant
        )
    }

    private static func toolResult(
        name: String,
        identity: MacChatTurnIdentity,
        at instant: Date
    ) -> MacChatTurnActivity {
        let safeName = sanitized(name) ?? "Tool"
        return MacChatTurnActivity(
            identity: identity,
            source: .toolResult,
            phase: .working,
            toolDisplayName: safeName,
            actionSummary: sanitized("Finished tool: \(safeName)"),
            userVisibleNoticeText: nil,
            delegateDisplayName: nil,
            occurredAt: instant
        )
    }

    private static func noticePhase(kind: String) -> TurnPresentationPhase {
        let lower = kind.lowercased()
        if lower.contains("retry") || lower.contains("recovery") { return .retrying }
        if lower.contains("waiting") { return .waiting }
        if lower.contains("blocked") || lower.contains("approval") { return .blocked }
        if lower.contains("timeout") || lower.contains("stall") { return .stalled }
        if lower.hasPrefix("invoke_") { return .delegation }
        return .working
    }

    private static func delegateName(forTool name: String) -> String? {
        switch name.lowercased() {
        case "claude_message", "invoke_claude": return "Claude"
        case "codex_message", "invoke_codex": return "Codex"
        case "omp_message": return "OMP"
        case "agent_swarm": return "Worker swarm"
        default: return nil
        }
    }

    private static func delegateName(forNoticeKind kind: String, text: String) -> String? {
        let combined = "\(kind) \(text)".lowercased()
        if combined.contains("claude") || combined.contains("claude") { return "Claude" }
        if combined.contains("codex") { return "Codex" }
        if combined.contains(" omp") || combined.hasPrefix("omp") { return "OMP" }
        return nil
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
