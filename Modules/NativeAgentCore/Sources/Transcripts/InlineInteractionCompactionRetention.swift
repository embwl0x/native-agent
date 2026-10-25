import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `InlineInteractionCompactionRetention.swift` | `InlineInteractionCompactionRetention`: preserves live/suspended card handles during destructive transcript compaction |

/// WHICH inline-interaction rows a destructive transcript pass is allowed to
/// fold away.
///
/// An inline card is not transcript colour: it is the handle a person answers a
/// need with, and — when it carries a continuation — the only record of a
/// request that is still suspended. Agent's session 644D65F1 compacted 223 rows
/// on 2026-09-14 and took 8 cards with them, two of them `failed` cards whose
/// continuation was still `waiting`: a retryable ask vanished under her, and the
/// suspended request behind it became unresumable.
///
/// So compaction may drop a card ONLY when both halves are finished with:
/// the interaction reached a terminal state nobody is expected to act on
/// (`settled` / `declined` / `superseded`), AND its continuation is not
/// resumable (`resumed` / `invalidated`, or there is no continuation at all).
/// `failed` is never dropped — the card keeps a retry control and the person
/// may still use it. Anything this build cannot read is preserved: an
/// unrecognised state is not evidence that the card is finished.
public enum InlineInteractionCompactionRetention {
    /// Result delivery is still owed even when the conversation ages. Keep
    /// its source row outside the card and summary budgets until acknowledged.
    public static func splitPendingResults(_ rows: [JSONValue]) -> (pending: [JSONValue], remaining: [JSONValue]) {
        var pending: [JSONValue] = [], remaining: [JSONValue] = []
        for row in rows {
            if case .object(let fields) = row, case .object(let metadata)? = fields["metadata"],
               case .object(let intent)? = metadata["resultDelivery"], intent["state"] != .string("delivered") {
                pending.append(row)
            } else { remaining.append(row) }
        }
        return (pending, remaining)
    }

    /// Interaction states that nobody is waiting on any more.
    private static let finishedStates: Set<String> = ["settled", "declined", "superseded"]
    /// Continuation resume states that can never start a turn again.
    private static let spentContinuationStates: Set<String> = ["resumed", "invalidated"]

    /// True when the row is a persisted inline-interaction card.
    public static func isInlineInteractionRow(_ row: JSONValue) -> Bool {
        guard case .object(let obj) = row else { return false }
        return isInlineInteractionRow(obj)
    }

    public static func isInlineInteractionRow(_ obj: [String: JSONValue]) -> Bool {
        guard case .object(let metadata)? = obj["metadata"],
              case .string(let kind)? = metadata["kind"]
        else { return false }
        return kind == InlineInteractionWire.transcriptKind
    }

    /// True when a destructive pass must keep this row verbatim.
    public static func mustPreserve(_ row: JSONValue) -> Bool {
        guard case .object(let obj) = row else { return false }
        return mustPreserve(obj)
    }

    public static func mustPreserve(_ obj: [String: JSONValue]) -> Bool {
        guard isInlineInteractionRow(obj) else { return false }
        guard case .object(let metadata)? = obj["metadata"],
              case .object(let interaction)? = metadata[InlineInteractionWire.metadataKey]
        else {
            // A card row we cannot read is a card we cannot judge. Keep it.
            return true
        }
        guard case .object(let state)? = interaction["state"],
              case .string(let name)? = state["name"],
              finishedStates.contains(name)
        else { return true }
        guard case .object(let continuation)? = interaction["continuation"] else {
            // Terminal, and there is no suspended request behind it.
            return false
        }
        guard case .string(let resumeState)? = continuation["state"] else { return true }
        return !spentContinuationStates.contains(resumeState)
    }

    /// Splits a prefix a pass intends to replace into the rows it must carry
    /// forward verbatim and the rows it may fold into the summary.
    public static func split(_ rows: [JSONValue]) -> (preserved: [JSONValue], removable: [JSONValue]) {
        var preserved: [JSONValue] = []
        var removable: [JSONValue] = []
        for row in rows {
            if mustPreserve(row) { preserved.append(row) } else { removable.append(row) }
        }
        return (preserved, removable)
    }

    /// The clause the summary row carries so the kept cards are accounted for
    /// in the text a person (and the distiller) reads.
    public static func summaryClause(preservedCount: Int) -> String {
        guard preservedCount > 0 else { return "" }
        return preservedCount == 1
            ? " 1 unresolved inline card was kept below, verbatim."
            : " \(preservedCount) unresolved inline cards were kept below, verbatim."
    }

    /// `metadata` key recording how many cards this pass carried through.
    public static let preservedMetadataKey = "inline_cards_preserved"
}
