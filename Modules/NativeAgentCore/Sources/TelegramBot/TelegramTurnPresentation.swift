import Foundation
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
import ChatTurnRuntime
// Blueprint: | `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase` typealias; canonical lifecycle adapter and native redaction; authored progress wording lives in telegram-progress.js |

// Telegram names the surface-neutral presentation values.
public typealias TelegramTurnPresentationPhase = TurnPresentationPhase
public typealias TelegramTurnPresentationLifecycleEvent = TurnPresentationLifecycleEvent
public typealias TelegramTurnPresentationState = TurnPresentationState

/// Thin Telegram adapter: it maps Telegram progress vocabulary into the shared
/// lifecycle kernel. Lifecycle semantics,
/// terminal immutability, movement, history bounds, and stall classification
/// remain owned by `TurnPresentationReducer`.
public enum TelegramTurnPresentationReducer {
    public static func reduce(
        _ state: TelegramTurnPresentationState,
        progress event: TurnStreamEvent,
        accumulatedUTF16Length: Int,
        at instant: Date
    ) -> TelegramTurnPresentationState {
        guard !state.isTerminal else { return state }

        switch event {
        case .replyTextSettled, .final, .error:
            return state
        case .toolUse(let name, _):
            let action = TelegramPollLoop.progressMessage(for: event) ?? ToolActivityPresentation.progress(name)
            if let delegate = delegateName(forTool: name) {
                return TurnPresentationReducer.reduce(
                    state,
                    lifecycle: .delegation(delegate: delegate, action: action),
                    at: instant
                )
            }
            return TurnPresentationReducer.reduce(
                state,
                lifecycle: .tool(name: ToolActivityPresentation.title(name), action: action),
                at: instant
            )

        case .toolResult(let name, let output):
            return TurnPresentationReducer.reduce(
                state,
                lifecycle: .working(action: ToolActivityPresentation.finished(name,
                    outcome: ChatToolOutcome.exactResultClass(output).rawValue,
                    detail: [ChatToolOutcome.explanation(output), ChatToolOutcome.remedy(output)].compactMap { $0 }.joined(separator: " · "))),
                at: instant
            )

        case .notice(let kind, let text):
            let lowerKind = kind.lowercased()
            let delegate = delegateName(forNotice: kind, text: text)
            if lowerKind.contains("timeout") || lowerKind.contains("stall") {
                return TurnPresentationReducer.recordActivity(
                    state,
                    phase: .stalled,
                    detail: text,
                    delegateName: delegate,
                    at: instant
                )
            }
            if lowerKind.contains("retry") || lowerKind.contains("recovery") {
                return TurnPresentationReducer.reduce(
                    state,
                    lifecycle: .retrying(action: text),
                    at: instant
                )
            }
            if lowerKind.contains("waiting") {
                return TurnPresentationReducer.reduce(
                    state,
                    lifecycle: .waiting(action: text),
                    at: instant
                )
            }
            if lowerKind.contains("blocked") || lowerKind.contains("approval") {
                return TurnPresentationReducer.reduce(
                    state,
                    lifecycle: .blocked(reason: text),
                    at: instant
                )
            }
            if lowerKind.hasPrefix("invoke_") || delegate != nil {
                return TurnPresentationReducer.recordActivity(
                    state,
                    phase: .delegation,
                    detail: text,
                    delegateName: delegate,
                    at: instant
                )
            }
            return TurnPresentationReducer.reduce(
                state,
                lifecycle: .working(action: text),
                at: instant
            )

        case .delta:
            return TurnPresentationReducer.recordStreamProgress(
                state,
                accumulatedUTF16Length: accumulatedUTF16Length,
                at: instant
            )
        }
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
