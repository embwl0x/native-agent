import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
// Blueprint: | `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias; canonical lifecycle adapter and native redaction; authored progress wording lives in telegram-progress.js |

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
        case .replyTextSettled:
            return state
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
            let action = TelegramPollLoop.progressMessage(for: event) ?? ToolActivityPresentation.progress(name)
            if let delegate = delegateName(forTool: name) {
                return reduce(
                    state,
                    lifecycle: .delegation(delegate: delegate, action: action),
                    at: instant
                )
            }
            return reduce(
                state,
                lifecycle: .tool(name: ToolActivityPresentation.title(name), action: action),
                at: instant
            )

        case .toolResult(let name, let output):
            return reduce(
                state,
                lifecycle: .working(action: ToolActivityPresentation.finished(name,
                    outcome: output.map(ChatToolOutcome.exactResultClass)?.rawValue ?? "unknown",
                    detail: [output.flatMap(ChatToolOutcome.explanation), output.flatMap(ChatToolOutcome.remedy)].compactMap { $0 }.joined(separator: " · "))),
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
