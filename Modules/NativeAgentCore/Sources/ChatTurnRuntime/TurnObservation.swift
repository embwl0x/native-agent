import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace
// Blueprint: | `TurnObservation.swift` | `TurnObservation` enum; `text`, `apply`, shared trace emission in `record` |

/// Recovery is input to the next round, never a replacement for the reply.
enum TurnObservation {
    enum Kind {
        case lengthLimit(chars: Int)
        case boundary(LLMToolBoundaryReason)
        case malformedCall(why: String)
        case contextFull
        /// Working notes could not be written; the earlier steps stay as they were.
        case notesUnwritten(why: String)
        /// `started`: each call the part's log shows started without a receipt.
        case restarted(stepsDone: Int, unknownStep: Int?, started: [String] = [])
        /// Her turn part failed and the stem swapped it back; never model-visible.
        case healed(from: String, to: String, why: String)
        /// No helper could start to run her turn part; the stem retries. Never model-visible.
        case helperUnavailable(why: String, retryIn: Int)
    }

    static func text(_ kind: Kind) -> String {
        let happened: String
        switch kind {
        case .lengthLimit(let chars):
            happened = "Your reply reached the provider's length limit after \(chars) characters; no calls from that reply ran. Continue with a shorter reply or a complete call."
        case .boundary(let reason):
            switch reason {
            case .outputLimit:
                happened = "Your reply reached the provider's length limit; complete calls were kept and the unfinished suffix discarded. Read their results, then continue with a shorter reply."
            case .incompleteCall:
                happened = "Your reply ended inside a call; complete calls were kept and the unfinished suffix discarded. Read their results, then supply only the unfinished call in full."
            case .interrupted:
                happened = "The provider stream was interrupted; complete calls were kept and the unfinished suffix discarded. Read their results before continuing the unfinished work."
            case .repeatedBlock:
                happened = "Your reply repeated a call and was cut before it. Use the first call's result to choose the next step."
            case .repeatedAction:
                happened = "Your reply repeated an earlier call and was cut before it. Check that call's receipt before deciding whether another action is needed."
            case .fabricatedResult:
                happened = "Your reply invented a tool result and was cut before it. Use only returned results; call the action if evidence is still needed."
            case .postCallProse:
                happened = "Your reply continued after a call without its result and was cut there. Read the result before continuing."
            case .steered:
                happened = "The person spoke while you were replying. What you had said stays; their words follow; continue from there."
            case .refusal:
                happened = "The provider's safety layer refused the reply; complete calls before it were kept and the rest discarded. Offer an allowed alternative if one serves the request; otherwise explain the refusal and stop. Do not rephrase or split calls to bypass it."
            }
        case .malformedCall(let why):
            happened = "The call was malformed: \(line(why)); no calls from that reply ran. Correct the call using this conversation's format."
        case .contextFull:
            happened = "The working context was full and has been trimmed. Use the retained notes and results; pull missing dispatch receipts with app {action:\"trace.recent\",args:{kind:\"tool.dispatch\",view:\"receipts\"}} before relying on earlier effects."
        case .notesUnwritten(let why):
            happened = "Working notes could not be written: \(line(why)). Earlier steps remain. Continue from their results; do not treat missing notes as evidence of completed work."
        case .restarted(let steps, let unknown, let started):
            happened = "The app restarted after step \(steps); the recorded results are below"
                + (unknown.map { "; step \($0)'s effect is unknown" } ?? "") + "."
                + " Oversize tool-result pages from before the restart are unavailable."
                + (started.isEmpty ? "" : " Started without a receipt: " + started.joined(separator: "; ") + ".")
                + " Calls without receipts may have taken effect; inspect their affected state before repeating them."
        case .healed(let from, let to, let why):
            happened = "Her turn part \(from) failed (\(line(why))); the stem swapped in \(to) and replayed this turn's log through it."
        case .helperUnavailable(let why, let seconds):
            happened = "No helper could start to run her turn part (\(line(why))); the stem tries again in \(seconds) seconds."
        }
        return "[turn.observation reason=\(code(kind))] " + happened + " Do not repeat completed work or delivered prose."
    }

    private static func code(_ kind: Kind) -> String {
        switch kind {
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
            case .steered: "reply_steered"
            case .refusal: "reply_safety_refusal"
            }
        case .malformedCall: "malformed_call"
        case .contextFull: "context_compacted"
        case .notesUnwritten: "working_notes_unwritten"
        case .restarted: "turn_restarted"
        case .healed: "turn_part_healed"
        case .helperUnavailable: "turn_helper_unavailable"
        }
    }

    static func apply(_ kind: Kind, kept: String = "", to conversation: inout [LLMMessage], surface: String) {
        if !kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.append(.assistantText(kept))
        }
        SwiftNativeTurnEngine.appendStructuredUserNudge(text(kind), to: &conversation)
        record(kind, kept: kept, surface: surface)
    }

    static func record(_ kind: Kind, kept: String = "", surface: String) {
        TurnTraceBus.fireFromContext(kind: "turn.observation", surface: surface, payload: .object([
            "reason": .string(code(kind)),
            "text": .string(text(kind)),
            "keptCharacters": .int(Int64(kept.count)),
        ]))
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
