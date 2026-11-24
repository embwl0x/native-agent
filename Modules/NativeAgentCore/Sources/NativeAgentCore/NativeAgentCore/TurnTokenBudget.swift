import Synchronization
import Foundation
// Blueprint: | `TurnTokenBudget.swift` | `TurnTokenBudget` class; `take`, `beginRequest` |

/// One output allowance shared by every provider request in a turn. UTF-8 bytes conservatively bound visible output tokens when an adapter has no tokenizer.
/// Providers with a wire cap also receive the remaining allowance.
public final class TurnTokenBudget: Sendable {
    private struct State {
        var remaining: Int
        var text = ""
        var stopped = false
    }
    private let state: Mutex<State>
    public init(tokens: Int) { state = Mutex(State(remaining: max(0, tokens))) }
    public var available: Int { state.withLock { $0.remaining } }
    public var exhausted: Bool { state.withLock { $0.stopped } }
    public var partialReply: String { state.withLock { $0.text } }
    public func take(_ value: String, visible: Bool = true) -> String {
        return state.withLock { state in
            var accepted = ""
            for character in value {
                let size = String(character).utf8.count
                guard size <= state.remaining else { state.stopped = true; break }
                state.remaining -= size
                accepted.append(character)
            }
            if visible { state.text += accepted }
            if state.remaining == 0 { state.stopped = true }
            return accepted
        }
    }
    public func beginRequest() -> Bool {
        return state.withLock { state in
            guard state.remaining > 0, !state.stopped else { state.stopped = true; return false }
            if !state.text.isEmpty { state.text += "\n\n" }
            return true
        }
    }
}
