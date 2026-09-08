import Foundation
import NativeAgentCore

// Telegram keeps source-compatible names while the authoritative value model
// and lifecycle reducer live in the surface-neutral NativeAgentCore target.
public typealias TelegramTurnPresentationPhase = TurnPresentationPhase
public typealias TelegramTurnPresentationLifecycleEvent = TurnPresentationLifecycleEvent
public typealias TelegramTurnPresentationState = TurnPresentationState

/// Thin Telegram adapter: it maps Telegram progress vocabulary into the shared
/// lifecycle kernel and adds transport-token redaction. Lifecycle semantics,
/// terminal immutability, movement, history bounds, and stall classification
/// remain owned by `TurnPresentationReducer`.
public enum TelegramTurnPresentationReducer {
    public static let textLimit = TurnPresentationReducer.textLimit

    public static func initialState(at instant: Date) -> TelegramTurnPresentationState {
        TurnPresentationReducer.initialState(at: instant)
    }

    public static func reduce(
        _ state: TelegramTurnPresentationState,
        lifecycle event: TelegramTurnPresentationLifecycleEvent,
        at instant: Date
    ) -> TelegramTurnPresentationState {
        TurnPresentationReducer.reduce(
            state,
            lifecycle: event,
            at: instant,
            additionalRedactor: telegramTokenRedactor
        )
    }

    public static func reduce(
        _ state: TelegramTurnPresentationState,
        progress event: TelegramChatProgressEvent,
        at instant: Date
    ) -> TelegramTurnPresentationState {
        guard !state.isTerminal else { return state }

        switch event {
        case .status(let text):
            let lower = text.lowercased()
            if lower.contains("retry") || lower.contains("recover") {
                return reduce(
                    state,
                    lifecycle: .retrying(action: text),
                    at: instant
                )
            }
            if lower.contains("blocked") || lower.contains("approval") {
                return reduce(
                    state,
                    lifecycle: .blocked(reason: text),
                    at: instant
                )
            }
            if lower.contains("waiting") {
                return reduce(
                    state,
                    lifecycle: .waiting(action: text),
                    at: instant
                )
            }
            if lower.contains("stall") || lower.contains("timed out") {
                return reduce(
                    state,
                    lifecycle: .stalled(reason: text),
                    at: instant
                )
            }
            return reduce(
                state,
                lifecycle: .working(action: text),
                at: instant
            )

        case .toolUse(let name, _):
            let action = TelegramPollLoop.progressMessage(for: event) ?? "Using tool: \(name)"
            if let delegate = delegateName(forTool: name) {
                return reduce(
                    state,
                    lifecycle: .delegation(delegate: delegate, action: action),
                    at: instant
                )
            }
            return reduce(
                state,
                lifecycle: .tool(name: name, action: action),
                at: instant
            )

        case .toolResult(let name, _):
            return reduce(
                state,
                lifecycle: .working(action: "Finished tool: \(name)"),
                at: instant
            )

        case .notice(let kind, let text):
            let lowerKind = kind.lowercased()
            let delegate = delegateName(forNotice: kind, text: text)
            if lowerKind.contains("timeout") || lowerKind.contains("stall") {
                return recordActivity(
                    state,
                    phase: .stalled,
                    detail: text,
                    delegateName: delegate,
                    at: instant
                )
            }
            if lowerKind.contains("retry") || lowerKind.contains("recovery") {
                return reduce(
                    state,
                    lifecycle: .retrying(action: text),
                    at: instant
                )
            }
            if lowerKind.contains("waiting") {
                return reduce(
                    state,
                    lifecycle: .waiting(action: text),
                    at: instant
                )
            }
            if lowerKind.contains("blocked") || lowerKind.contains("approval") {
                return reduce(
                    state,
                    lifecycle: .blocked(reason: text),
                    at: instant
                )
            }
            if lowerKind.hasPrefix("invoke_") || delegate != nil {
                return recordActivity(
                    state,
                    phase: .delegation,
                    detail: text,
                    delegateName: delegate,
                    at: instant
                )
            }
            return reduce(
                state,
                lifecycle: .working(action: text),
                at: instant
            )

        case .textDelta(let accumulated):
            return TurnPresentationReducer.recordStreamProgress(
                state,
                accumulatedUTF16Length: accumulated.utf16.count,
                at: instant
            )
        }
    }

    static func sanitized(_ raw: String?) -> String? {
        TurnPresentationReducer.sanitized(
            raw,
            additionalRedactor: telegramTokenRedactor
        )
    }

    private static let telegramTokenRedactor: TurnPresentationReducer.AdditionalRedactor = {
        TelegramPollLoop._tgRedactToken($0)
    }

    private static func recordActivity(
        _ state: TelegramTurnPresentationState,
        phase: TelegramTurnPresentationPhase,
        detail: String?,
        delegateName: String?,
        at instant: Date
    ) -> TelegramTurnPresentationState {
        TurnPresentationReducer.recordActivity(
            state,
            phase: phase,
            detail: detail,
            delegateName: delegateName,
            at: instant,
            additionalRedactor: telegramTokenRedactor
        )
    }

    private static func delegateName(forTool name: String) -> String? {
        switch name.lowercased() {
        case "claude_message", "invoke_claude", "codex_message", "invoke_codex", "omp_message", "agent_swarm": return "Background work"
        default: return nil
        }
    }

    private static func delegateName(forNotice kind: String, text: String) -> String? {
        let combined = "\(kind) \(text)".lowercased()
        if combined.contains("claude") || combined.contains("claude") { return "Background work" }
        if combined.contains("codex") { return "Background work" }
        if combined.contains(" omp") || combined.hasPrefix("omp") { return "Background work" }
        return nil
    }
}

public enum TelegramTurnPresentationRenderer {
    static func userFacingProgress(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b(?:invoke_claude|claude_message|invoke_codex|codex_message|omp_message|agent_swarm|Claude|Claude|Codex|OMP)\b"#,
            with: "background work", options: .regularExpression
        )
    }
    public static let defaultStalledAfter = TurnPresentationReducer.defaultStalledAfter

    public static func render(
        _ state: TelegramTurnPresentationState,
        at now: Date,
        stalledAfter: TimeInterval = defaultStalledAfter
    ) -> String {
        let elapsedEnd = state.endedAt ?? max(now, state.startedAt)
        let elapsed = max(0, elapsedEnd.timeIntervalSince(state.startedAt))
        let sinceMovement = max(0, now.timeIntervalSince(state.lastMovementAt))
        let phase = TurnPresentationReducer.effectivePhase(
            state,
            secondsSinceMovement: sinceMovement,
            stalledAfter: stalledAfter
        )

        var line = sentence(
            phase: phase,
            action: state.currentAction,
            delegate: state.delegateName
        )
        if !phase.isTerminal {
            line += " (\(duration(elapsed)) so far)"
        }
        return userFacingProgress(line)
    }

    /// A bounded, presentation-only expansion for the same work card. It uses
    /// only reducer-sanitized state: never tool arguments, provider payloads,
    /// accumulated model text, or hidden reasoning.
    public static func renderDetails(
        _ state: TelegramTurnPresentationState,
        at now: Date,
        stalledAfter: TimeInterval = defaultStalledAfter
    ) -> String {
        let elapsedEnd = state.endedAt ?? max(now, state.startedAt)
        let elapsed = max(0, elapsedEnd.timeIntervalSince(state.startedAt))
        let sinceMovement = max(0, now.timeIntervalSince(state.lastMovementAt))
        let phase = TurnPresentationReducer.effectivePhase(
            state,
            secondsSinceMovement: sinceMovement,
            stalledAfter: stalledAfter
        )
        var lines = [
            sentence(
                phase: phase,
                action: state.currentAction,
                delegate: state.delegateName
            )
        ]
        lines.append("Started \(duration(elapsed)) ago; last update \(duration(sinceMovement)) back.")
        if let action = state.currentAction, !lines[0].contains(action) {
            lines.append("Right now: \(action)")
        }
        if let delegate = state.delegateName, !lines[0].contains(delegate) {
            lines.append("Task: \(delegate).")
        }
        return userFacingProgress(lines.joined(separator: "\n"))
    }

    /// What she is doing, in words. The phase enum stays exactly as it is —
    /// receipts, the card ledger and telemetry still read it — but User never
    /// sees a state-machine label, because a label makes him translate
    /// machinery into meaning every time he glances at the card.
    private static func sentence(
        phase: TelegramTurnPresentationPhase,
        action: String?,
        delegate: String?
    ) -> String {
        let detail = action.flatMap { text -> String? in
            let trimmed = userFacingProgress(text).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch phase {
        case .acknowledged:
            return "Got your message, starting now."
        case .working, .tool:
            return detail ?? "Still on it."
        case .delegation:
            return detail ?? "Working on a longer step…"
        case .retrying:
            return detail.map { "That hiccuped, trying again: \($0)" }
                ?? "That hiccuped, trying again."
        case .waiting:
            return detail ?? "Waiting before the task can continue."
        case .blocked:
            return detail.map { "Waiting on an approval from you: \($0)" }
                ?? "Waiting on an approval from you."
        case .stalled:
            return detail.map { "Still on it, but it's been quiet: \($0)" }
                ?? "Still on it, but it's been quiet for a while."
        case .completed:
            return "Done."
        case .failed:
            return detail.map { "That didn't work: \($0)" } ?? "That didn't work."
        case .canceled:
            return "Stopped."
        case .outcomeUnknown:
            return detail.map { "The outcome is unclear: \($0)" }
                ?? "The outcome is unclear."
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}
