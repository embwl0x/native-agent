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
        case "claude_message", "invoke_claude": return "Claude"
        case "codex_message", "invoke_codex": return "Codex"
        case "omp_message": return "OMP"
        case "agent_swarm": return "Worker swarm"
        default: return nil
        }
    }

    private static func delegateName(forNotice kind: String, text: String) -> String? {
        let combined = "\(kind) \(text)".lowercased()
        if combined.contains("claude") || combined.contains("claude") { return "Claude" }
        if combined.contains("codex") { return "Codex" }
        if combined.contains(" omp") || combined.hasPrefix("omp") { return "OMP" }
        return nil
    }
}

public enum TelegramTurnPresentationRenderer {
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

        var lines = [
            "\(title(for: phase)) · elapsed \(duration(elapsed)) · moved \(duration(sinceMovement)) ago"
        ]
        if let action = state.currentAction {
            lines.append("Action: \(action)")
        }
        if let delegate = state.delegateName {
            lines.append("Delegate: \(delegate)")
        }
        return lines.joined(separator: "\n")
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
            "Work details",
            "Phase: \(title(for: phase))",
            "Elapsed: \(duration(elapsed))",
            "Last movement: \(duration(sinceMovement)) ago",
        ]
        if let action = state.currentAction {
            lines.append("Current action: \(action)")
        }
        if let delegate = state.delegateName {
            lines.append("Delegate: \(delegate)")
        }
        return lines.joined(separator: "\n")
    }

    private static func title(for phase: TelegramTurnPresentationPhase) -> String {
        switch phase {
        case .acknowledged: return "Acknowledged"
        case .working: return "Working"
        case .tool: return "Using tool"
        case .delegation: return "Delegated work"
        case .retrying: return "Retrying"
        case .waiting: return "Waiting"
        case .blocked: return "Blocked"
        case .stalled: return "Stalled"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .outcomeUnknown: return "Outcome unknown"
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}
