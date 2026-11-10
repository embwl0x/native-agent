import Foundation
import ChatToolParsing
import NativeAgentCore
import NativeAgentShared
import ChatSessionWork
import ChatTurnRuntime
// Blueprint: | `TelegramTurnPresentation.swift` | `TelegramTurnPresentationPhase`: canonical lifecycle semantics |

public typealias TelegramTurnPresentationPhase = TurnPresentationPhase
public typealias TelegramTurnPresentationLifecycleEvent = TurnPresentationLifecycleEvent
public typealias TelegramTurnPresentationState = TurnPresentationState

/// Keep lifecycle semantics, terminal immutability and stall classification owned by TurnPresentationReducer.
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
            return TurnPresentationReducer.reduce(
                state,
                lifecycle: .tool(name: ToolActivityPresentation.title(name), action: action),
                at: instant
            )

        case .toolResult(let name, let output):
            let reply = ToolResult(output)
            // The result ends the step its use started.
            return TurnPresentationReducer.recordActivity(
                state,
                phase: .working,
                detail: ToolActivityPresentation.finished(name,
                    outcome: reply.outcome.rawValue,
                    detail: [ChatToolOutcome.explanation(reply.payload), ChatToolOutcome.remedy(reply.payload)].compactMap { $0 }.joined(separator: " · ")),
                delegateName: nil,
                endsCall: ToolActivityPresentation.title(name),
                at: instant
            )

        case .notice(let kind, let text):
            let lowerKind = kind.lowercased()
            if lowerKind.contains("timeout") || lowerKind.contains("stall") {
                return TurnPresentationReducer.recordActivity(
                    state,
                    phase: .stalled,
                    detail: text,
                    delegateName: nil,
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
        case .writing(let writing):
            return TurnPresentationReducer.recordMovement(state, writing: writing, at: instant)
        }
    }
}
