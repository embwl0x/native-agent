import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |

/// What changed is input to the next round, never a replacement for the reply.
enum TurnObservation {
    enum Kind {
        /// A completed words-only round is followed by saved arrivals, so the turn reads them before ending.
        case arrival
        /// Hearing closed a generating round; its arrival may leave before the boundary reads it.
        case cut(arrivalRead: Bool)
        case lengthLimit(chars: Int)
        case boundary(LLMToolBoundaryReason)
        case malformedCall(why: String)
        /// Report exact started-call identities that lack receipts so recovery retains unknown outcomes.
        case restarted(stepsDone: Int, unknownStep: Int?, started: [String] = [])
        /// Turn-program recovery is reported after the turn, never injected into its own model input.
        case healed(from: String, to: String, why: String)
    }

    static func text(_ kind: Kind) -> String {
        let happened: String
        switch kind {
        case .arrival:
            happened = "New messages arrived while you were replying. Your completed reply is kept above; read the new messages and answer them next."
        case .cut(let arrivalRead):
            happened = """
                Hearing an arriving message ended that round before it finished. Any words you had said are kept above and none of its calls ran.
                """ + (arrivalRead
                    ? " Read the new messages above and answer them next."
                    : " No new message was read at the boundary; continue from the conversation you have.")
        case .lengthLimit(let chars):
            happened = """
                Your reply reached the provider's length limit after \(chars) characters; no calls from that reply ran. Continue with a shorter reply \
                or a complete call.
                """
        case .boundary(let reason):
            switch reason {
            case .outputLimit:
                happened = """
                    Your reply reached the provider's length limit; complete calls were kept and the unfinished suffix discarded. Read their results, \
                    then continue with a shorter reply.
                    """
            case .incompleteCall:
                happened = """
                    Your reply ended inside a call; complete calls were kept and the unfinished suffix discarded. Read their results, then supply \
                    only the unfinished call in full.
                    """
            case .interrupted:
                happened = """
                    The provider stream was interrupted; complete calls were kept and the unfinished suffix discarded. Read their results before \
                    continuing the unfinished work.
                    """
            case .repeatedBlock:
                happened = "Your reply repeated a call and was cut before it. Use the first call's result to choose the next step."
            case .repeatedAction:
                happened = """
                    Your reply repeated an earlier call and was cut before it. Check that call's receipt before deciding whether another action is \
                    needed.
                    """
            case .fabricatedResult:
                happened = "Your reply invented a tool result and was cut before it. Use only returned results; call the action if evidence is still needed."
            case .postCallProse:
                happened = "Your reply continued after a call without its result and was cut there. Read the result before continuing."
            case .refusal:
                happened = """
                    The provider's safety layer refused the reply; complete calls before it were kept and the rest discarded. Offer an allowed \
                    alternative if one serves the request; otherwise explain the refusal and stop. Do not rephrase or split calls to bypass it.
                    """
            }
        case .malformedCall(let why):
            happened = "The call was malformed: \(line(why)); no calls from that reply ran. Correct the call using this conversation's format."
        case .restarted(let steps, let unknown, let started):
            happened = "The app restarted after step \(steps); the recorded results are below"
                + (unknown.map { "; step \($0)'s effect is unknown" } ?? "") + "."
                + " Oversize tool-result pages from before the restart are unavailable."
                + (started.isEmpty ? "" : " Started without a receipt: " + started.joined(separator: "; ") + ".")
                + " Calls without receipts may have taken effect; inspect their affected state before repeating them."
        case .healed(let from, let to, let why):
            happened = "The agent's turn part \(from) failed (\(line(why))); the stem swapped in \(to) and replayed this turn's log through it."
        }
        return "[turn.observation reason=\(code(kind))] " + happened + " Do not repeat completed work or delivered prose."
    }

    private static func code(_ kind: Kind) -> String {
        switch kind {
        case .arrival, .cut: "turn_arrival"
        case .lengthLimit: "reply_length_limit"
        case .boundary(let reason):
            switch reason {
            case .outputLimit: "reply_output_limit"
            case .incompleteCall: "reply_incomplete_call"
            case .interrupted: "reply_interrupted"
            case .repeatedBlock: "reply_repeated_block"
            case .repeatedAction: "reply_repeated_action"
            case .fabricatedResult: "reply_fabricated_result"
            case .postCallProse: "reply_post_call_prose"
            case .refusal: "reply_safety_refusal"
            }
        case .malformedCall: "malformed_call"
        case .restarted: "turn_restarted"
        case .healed: "turn_part_healed"
        }
    }

    static func apply(_ kind: Kind, kept: String = "", to conversation: inout [LLMMessage], surface: String, turn: Turn) {
        if !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.append(.assistantText(kept))
        }
        SwiftNativeTurnEngine.appendStructuredUserNudge(text(kind), to: &conversation)
        record(kind, kept: kept, surface: surface, turn: turn)
    }

    static func record(_ kind: Kind, kept: String = "", surface: String, turn: Turn) {
        TurnTraceBus.fireFromContext(kind: "turn.observation", surface: surface, payload: .object([
            "reason": .string(code(kind)),
            "text": .string(text(kind)),
            "keptCharacters": .int(Int64(kept.count)),
        ]), turn: turn)
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
