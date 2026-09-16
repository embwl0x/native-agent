import Foundation
import NativeAgentShared

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

    /// Splits the rows a pass would carry through verbatim into the ones it
    /// keeps and the OLDEST ones it must fold anyway.
    ///
    /// Preserved cards are REINSERTED after the summary, so their bytes stay in
    /// the session. A session that accumulates unresolved (or `failed`) cards
    /// worth more than the budget can therefore never get under its threshold —
    /// every pass rewrites the prior summary and shrinks nothing. Past the cap
    /// the oldest cards are folded, each leaving a one-line receipt in the
    /// summary. The NEWEST card is never folded: a person is always left
    /// something to act on.
    public static func capPreserved(
        _ preserved: [JSONValue],
        maxCharacters: Int
    ) -> (kept: [JSONValue], folded: [JSONValue]) {
        guard maxCharacters > 0, preserved.count > 1 else { return (preserved, []) }
        let sizes = preserved.map(characterCount)
        var total = sizes.reduce(0, +)
        guard total > maxCharacters else { return (preserved, []) }
        // A card whose continuation can still start a turn is never folded,
        // whatever the budget says: the receipt is not resumable, and folding
        // it would destroy the request the person already paid for with a tap
        // (Sol, 2026-09-14). Only cards with no live continuation are eligible,
        // oldest first, and the newest card is always kept. If every card is
        // live, nothing folds and the session stays above threshold by exactly
        // the size of its open cards — bounded, and honest.
        var folded: [JSONValue] = []
        var kept: [JSONValue] = []
        for (index, row) in preserved.enumerated() {
            let isNewest = index == preserved.count - 1
            if total > maxCharacters, !isNewest, !hasLiveContinuation(row) {
                folded.append(row)
                total -= sizes[index]
            } else {
                kept.append(row)
            }
        }
        return (kept, folded)
    }

    /// True when the card's continuation is in a state that can still start
    /// or hand back a turn (`waiting`, `claimed`, `replaying`, or anything this
    /// build does not recognise).
    public static func hasLiveContinuation(_ row: JSONValue) -> Bool {
        guard case .object(let obj) = row,
              case .object(let metadata)? = obj["metadata"],
              case .object(let interaction)? = metadata[InlineInteractionWire.metadataKey],
              case .object(let continuation)? = interaction["continuation"]
        else { return false }
        guard case .string(let resumeState)? = continuation["state"] else { return true }
        return !spentContinuationStates.contains(resumeState)
    }

    /// The one line a folded card leaves behind: which card it was, what state
    /// it was in, and that it can no longer be acted on.
    public static func foldReceipt(_ row: JSONValue) -> String {
        guard case .object(let obj) = row else {
            return "inline card: folded during compaction; it can no longer be answered."
        }
        var identifier = "inline card"
        var state = "an unreadable state"
        var title: String?
        if case .object(let metadata)? = obj["metadata"],
           case .object(let interaction)? = metadata[InlineInteractionWire.metadataKey] {
            if case .string(let value)? = interaction["id"], !value.isEmpty {
                identifier = "inline card \(value)"
            }
            if case .object(let stateObject)? = interaction["state"],
               case .string(let name)? = stateObject["name"], !name.isEmpty {
                state = name
            }
            if case .string(let value)? = interaction["title"], !value.isEmpty { title = value }
        }
        let subject = title.map { " (\($0))" } ?? ""
        return "\(identifier)\(subject) was \(state) and has been folded; it can no longer be answered."
    }

    /// The clause the summary row carries for the cards it had to fold.
    public static func foldedClause(count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1
            ? " 1 older inline card was folded; its receipt is below."
            : " \(count) older inline cards were folded; their receipts are below."
    }

    /// Serialized length of a row — the stand-in for the bytes it costs the
    /// session. PersistenceCore cannot see the orchestration layer's renderer.
    private static func characterCount(_ row: JSONValue) -> Int {
        ((try? row.serialize(pretty: false)) ?? "").count
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
