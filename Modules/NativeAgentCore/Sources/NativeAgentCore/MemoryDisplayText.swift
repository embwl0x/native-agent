// The ONE canonical rendering of a MemoryV2 row's text.
//
// Two consumers used to own two independently-maintained renderers and then
// compare their outputs for byte equality:
//
//   * USER.md autogen lines  — MemoryTextClip.memoryDisplayText (kind-aware
//     leading-timestamp stripping)
//   * memory context atoms   — NativeMemoryContextProjection.normalizedText
//     (CRLF fold + trim, nothing else)
//
// ContextFlowCoordinator.generatedUserProjectionPrecoverage joins those two
// strings with `==`. Any row whose stored text carried a leading timestamp
// rendered differently on the two sides, and because the join is all-or-
// nothing, ONE such row silently disabled USER.md precoverage for the whole
// document — USER.md was then injected in full alongside the identical memory
// atoms, every turn, with no log line.
//
// This type is the single owner of that rendering. `display` is what a human
// reads (USER.md, recall output); `projectionJoinKey` is what the precoverage
// join compares. Both sides of the join MUST go through `projectionJoinKey` —
// neither side may normalize on its own.
//
// The join key is a (core, stamp) PAIR, not a reduced string, because a key
// that converges the renderers must not also merge records that genuinely
// differ — see `Key` and `projectionJoinKey`.
//
// This lives in the base `NativeAgentCore` target on purpose: MemoryV2 (the
// USER.md producer) and Context (the join) both depend on it, and neither
// depends on the other.

import Foundation

public enum MemoryDisplayText {

    /// Memory text as it should appear in prompts / USER.md / recall output.
    /// Durable storage may keep timestamps for sorting and audit, but ordinary
    /// memory prose should not start with machine chronology. Date-critical
    /// kinds (`schedule`, `deadline`, …) keep their leading stamp — the date IS
    /// the fact.
    public static func display(_ text: String, kind: String? = nil) -> String {
        var display = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return "" }
        guard !isDateCriticalKind(kind) else { return display }

        display = stripLeadingBracketedTimestamp(display)
        display = display
            .replacingOccurrences(
                of: #"(?i)^(?:createdAt|updatedAt|created|updated|recorded|saved|timestamp|ts|date)\s*(?:at|on)?\s*[:=]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        display = stripLeadingISODateStamp(display)
        return display.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : display
    }

    /// Canonical comparison key for the USER.md ⇄ memory-atom precoverage join.
    ///
    /// The join asserts: *every generated USER.md line is carried by an
    /// eligible memory atom*. Both sides derive from the SAME stored row, but
    /// they arrive in different shapes — a USER.md line has been through the
    /// kind-AWARE `display(_:kind:)`, an atom body is the raw stored text
    /// (CRLF fold + trim). The only lawful difference between them is therefore
    /// a leading machine stamp that one side stripped and the other kept.
    ///
    /// A key must do two things, and the earlier stamp-destroying reduction
    /// only did the first:
    ///
    ///   1. CONVERGE the two renderers — `"User likes X"` (fact) must match
    ///      `"[2026-07-30] User likes X"` (body).
    ///   2. Keep records that genuinely DIFFER distinguishable. Date-critical
    ///      rows keep their stamp on BOTH sides because the date IS the fact;
    ///      reducing them to a bare core collapsed
    ///      `"2026-08-01 09:00 Dentist appointment downtown."` and
    ///      `"2026-09-01 09:00 Dentist appointment downtown."` into one key, so
    ///      one admitted atom "covered" both facts and the unadmitted one was
    ///      silently deleted from the turn.
    ///
    /// So the key is a PAIR, not a reduced string: the stamp-stripped `core`
    /// plus the leading `stamp` that was removed (nil when there was none).
    /// `Key.covers(_:)` then encodes the asymmetry exactly — a stamp-LESS fact
    /// is covered by any body with the same core (that is case 1, the renderer
    /// convergence), while a fact that KEPT its stamp demands a body carrying
    /// the same stamp (case 2). No kind lookup is needed on either side: the
    /// presence of the stamp on the USER.md line is already the kind-aware
    /// renderer's verdict, carried in the data.
    ///
    /// Stripping runs to a FIXPOINT because it is not idempotent on stacked
    /// stamps ("2026-01-01 2026-01-02 foo" needs two passes); everything the
    /// passes removed becomes the stamp. Bounded to a handful of passes; the
    /// string strictly shrinks or the loop exits.
    public struct Key: Hashable, Sendable, CustomStringConvertible {
        /// Text with every leading machine stamp removed.
        public let core: String
        /// The leading stamp run that was removed, nil when there was none.
        public let stamp: String?

        public init(core: String, stamp: String?) {
            self.core = core
            self.stamp = stamp
        }

        public var isEmpty: Bool { core.isEmpty && (stamp?.isEmpty ?? true) }

        /// The key as a human reads it — what diagnostics name.
        public var description: String {
            guard let stamp, !stamp.isEmpty else { return core }
            return core.isEmpty ? stamp : "\(stamp) \(core)"
        }

        /// Does `body` (a memory atom) carry this (a USER.md fact)?
        ///
        /// Strict in the one direction that matters: a fact that kept its stamp
        /// is only covered by a body with the identical stamp. Getting this
        /// wrong in the lenient direction silently drops a fact from the turn;
        /// getting it wrong in the strict direction merely leaves USER.md
        /// injected in full, which is the safe failure.
        public func isCovered(by body: Key) -> Bool {
            guard core == body.core else { return false }
            guard let stamp, !stamp.isEmpty else { return true }
            return stamp == body.stamp
        }
    }

    public static func projectionJoinKey(_ text: String) -> Key {
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty else { return Key(core: "", stamp: nil) }
        var core = collapsed
        for _ in 0..<4 {
            let next = collapseWhitespace(stripLeadingStamp(core))
            if next == core || next.isEmpty { break }
            core = next
        }
        guard core != collapsed, collapsed.hasSuffix(core) else {
            // Nothing stripped, or the stripper did something other than remove
            // a leading run (it never should). Fall back to the whole string as
            // the core: an unreduced key can only ever fail the join, and a
            // failed join keeps USER.md injected.
            return Key(core: collapsed, stamp: nil)
        }
        let stamp = String(collapsed.dropLast(core.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Key(core: core, stamp: stamp.isEmpty ? nil : stamp)
    }

    /// One pass of leading-stamp removal — the same three strippers
    /// `display(_:kind:)` applies, minus the kind gate and minus display's
    /// "everything was a stamp, keep the original" fallback (the join key
    /// wants to SEE that case, not hide it).
    private static func stripLeadingStamp(_ text: String) -> String {
        var value = stripLeadingBracketedTimestamp(text)
        value = value
            .replacingOccurrences(
                of: #"(?i)^(?:createdAt|updatedAt|created|updated|recorded|saved|timestamp|ts|date)\s*(?:at|on)?\s*[:=]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripLeadingISODateStamp(value)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isDateCriticalKind(_ kind: String?) -> Bool {
        guard let kind else { return false }
        let normalized = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "schedule", "scheduled", "deadline", "appointment",
            "event", "dated_event", "milestone", "birthday", "anniversary",
        ].contains(normalized)
    }

    private static func stripLeadingBracketedTimestamp(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\[\s*\d{4}-\d{2}-\d{2}(?:[T\s]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\s*\]\s*(?:[·:\-—–]\s*)?"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingISODateStamp(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"^\d{4}-\d{2}-\d{2}(?:/\d{1,2})?(?:[T\s]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\s*(?:[·:\-—–]\s*)?"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
