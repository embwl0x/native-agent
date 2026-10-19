import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace

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
            happened = "Your reply reached the provider's length limit after \(chars) characters; no calls from that reply ran."
        case .boundary(let reason):
            switch reason {
            case .outputLimit:
                happened = "Your reply reached the provider's length limit; complete calls were kept and the unfinished suffix was discarded."
            case .incompleteCall:
                happened = "Your reply ended inside a tool call; complete calls were kept and the unfinished suffix was discarded."
            case .interrupted:
                happened = "The provider stream was interrupted; complete calls were kept and the unfinished suffix was discarded."
            case .repeatedBlock:
                happened = "Your reply repeated a tool call and was cut before the repetition."
            case .repeatedAction:
                happened = "Your reply repeated an earlier call and was cut before the repetition."
            case .fabricatedResult:
                happened = "Your reply contained an invented tool result and was cut before it."
            case .postCallProse:
                happened = "Your reply continued with prose after a call before receiving results and was cut there."
            case .steered:
                happened = "The person spoke while you were replying. What you had said stays; their words follow; continue from there."
            }
        case .malformedCall(let why):
            happened = "The tool call was malformed: \(line(why)); no calls from that reply ran."
        case .contextFull:
            happened = "The working context was full and has been trimmed; finish your answer from what you have."
        case .notesUnwritten(let why):
            happened = "Your working notes for this turn could not be written (\(line(why))); the earlier steps stay as they were."
        case .restarted(let steps, let unknown, let started):
            happened = "The app restarted after step \(steps); the recorded results are below"
                + (unknown.map { "; step \($0)'s effect is unknown" } ?? "") + "."
                + " Oversize tool-result pages from before the restart are unavailable."
                + (unknown == nil && started.isEmpty ? "" : " Calls without a recorded receipt may have taken effect; check before repeating them.")
                + (started.isEmpty ? "" : " Started without a receipt: " + started.joined(separator: "; ") + ".")
        case .healed(let from, let to, let why):
            happened = "Her turn part \(from) failed (\(line(why))); the stem swapped in \(to) and replayed this turn's log through it."
        case .helperUnavailable(let why, let seconds):
            happened = "No helper could start to run her turn part (\(line(why))); the stem tries again in \(seconds) seconds."
        }
        return happened + " Continue from here; do not repeat what was written or done."
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
            "text": .string(text(kind)),
            "keptCharacters": .int(Int64(kept.count)),
        ]))
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
