import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `ToolResult.swift` | `ToolResult`: parse replies once for core decisions; retain the JSON payload for the model, transcript and trace |

/// A tool reply as the core reads it. The action's payload goes on unchanged to
/// the model, the transcript and the trace (the edges); every decision reads
/// these fields, parsed here once, never the payload's keys.
public struct ToolResult: Sendable {
    /// The action's own reply, for the edges.
    public let payload: JSONValue
    /// The shared exact classification: missing, pending, partial and ambiguous evidence stay unknown.
    public let outcome: ChatToolOutcome.ExactResultClass
    /// The owner's own status word (`status`, else `state`), trimmed and lowercased.
    public let status: String?
    /// What the call did to the world, as the owner declared it.
    public let effects: ToolFailureError.Effects?
    /// The failure's words, when the reply carries an error.
    public let failure: String?
    /// The owner's repair, person-decision or next-call remedy, as it arrived.
    public let remedy: JSONValue?
    /// The call is still running or its effect is unconfirmed: nothing final can be read from it.
    public let isOpen: Bool
    /// The call parked on the person through an inline interaction.
    public let isWaitingInteraction: Bool
    /// The reply carries failure evidence of its own (error, ok:false, failed outcome).
    public let carriesFailureEvidence: Bool

    public init(_ payload: JSONValue) {
        self.payload = payload
        let outcome = ChatToolOutcome.exactResultClass(payload)
        self.outcome = outcome
        let fields: [String: JSONValue] = if case .object(let fields) = payload { fields } else { [:] }
        status = (fields["status"] ?? fields["state"])?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        effects = fields["effects"]?.stringValue.flatMap(ToolFailureError.Effects.init(rawValue:))
        failure = switch fields["error"] {
        case .string(let text)? where !text.isEmpty: text
        case .object(let error)?: error["message"]?.stringValue ?? error["detail"]?.stringValue
        default: nil
        }
        remedy = fields["remedy"]
        isOpen = ChatToolOutcome.saysOutcomeOpen(payload)
        isWaitingInteraction = ChatToolOutcome.isWaitingInteraction(payload, verdict: outcome)
        carriesFailureEvidence = ChatToolOutcome.carriesFailureEvidence(payload)
    }

    /// The reply proves read evidence (complete when asked).
    public func hasReadEvidence(completeOnly: Bool = false) -> Bool {
        ChatToolOutcome.hasReadEvidence(payload, completeOnly: completeOnly, verdict: outcome)
    }

    /// The owner reported this status word.
    public func said(_ word: String) -> Bool { status == word }
}
