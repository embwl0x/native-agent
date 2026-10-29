// Both sides of USER.md precoverage use `projectionJoinKey`, never independent normalization.

import Foundation

// Blueprint: | `MemoryDisplayText.swift` | `MemoryDisplayText`: canonical memory text, shared author suffix and USER.md coverage/join keys, preserving date-critical kinds |

public enum MemoryDisplayText {
    /// Author labels travel beside the fact, through every prompt projection.
    public static func attributed(_ text: String, sources: [String]) -> String {
        let names = sources.map { source in
            String(source.components(separatedBy: .controlCharacters).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
        }.filter { !$0.isEmpty }
        return names.isEmpty ? text : text + " — from " + names.joined(separator: ", ")
    }

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

        display = stripLeadingStamp(display)
        return display.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : display
    }

    /// Canonical comparison key for the USER.md ⇄ memory-atom precoverage join.
    ///
    /// Matching requires the same core; a stamped fact also requires the same stamp.
    /// A fact's retained stamp carries the kind-aware renderer's date-critical verdict.
    /// Removed stamps form the stamp; stripping reaches a fixed point or the pass limit.
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
