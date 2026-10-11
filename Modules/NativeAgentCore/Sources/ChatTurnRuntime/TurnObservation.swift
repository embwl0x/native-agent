import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import TurnTrace

/// Recovery is input to the next round, never a replacement for the reply.
enum TurnObservation {
    enum Kind {
        case lengthLimit(chars: Int)
        case cut(seconds: Int, keptChars: Int)
        case boundary(LLMToolBoundaryReason)
        case malformedCall(why: String)
        case emptyReply
        case announcedNoCall
        case refused(reason: String)
        case contextFull
        case restarted(stepsDone: Int, unknownStep: Int?)
    }

    static func text(_ kind: Kind) -> String {
        let happened: String
        switch kind {
        case .lengthLimit(let chars):
            happened = "Your reply reached the provider's length limit after \(chars) characters; no calls from that reply ran."
        case .cut(let seconds, let chars):
            happened = "The stream was cut after \(seconds) seconds with \(chars) characters kept; no calls from that reply ran."
        case .boundary(let reason):
            switch reason {
            case .outputLimit:
                happened = "Your reply reached the provider's length limit; no calls from that reply ran."
            case .repeatedBlock:
                happened = "Your reply repeated a tool call and was cut before the repetition."
            case .repeatedAction:
                happened = "Your reply repeated an earlier call and was cut before the repetition."
            case .fabricatedResult:
                happened = "Your reply contained an invented tool result and was cut before it."
            case .postCallProse:
                happened = "Your reply continued with prose after a call before receiving results and was cut there."
            }
        case .malformedCall(let why):
            happened = "The tool call was malformed: \(line(why)); no calls from that reply ran."
        case .emptyReply:
            happened = "Nothing came back; answer or act."
        case .announcedNoCall:
            happened = "Your reply announced work without a tool call or an answer; answer or act."
        case .refused(let reason):
            happened = "The provider refused: \(line(reason)); give your answer from what you have."
        case .contextFull:
            happened = "The working context was full and has been trimmed; finish your answer from what you have."
        case .restarted(let steps, let unknown):
            happened = "The app restarted after step \(steps); the recorded results are below"
                + (unknown.map { "; step \($0)'s effect is unknown" } ?? "") + "."
                + " Oversize tool-result pages from before the restart are unavailable."
                + (unknown == nil ? "" : " Calls without a recorded receipt may have taken effect; check before repeating them.")
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
