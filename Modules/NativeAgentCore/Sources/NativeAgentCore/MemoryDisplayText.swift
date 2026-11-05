// Both sides of USER.md precoverage use `projectionJoinKey`, never independent normalization.

import Foundation

// Blueprint: | `MemoryDisplayText.swift` | `MemoryDisplayText`: prompt rendering and coverage keys |

public enum MemoryDisplayText {
    /// Author labels travel beside the fact, through every prompt projection.
    public static func attributed(_ text: String, sources: [String]) -> String {
        let names = sources.map { source in
            String(source.components(separatedBy: .controlCharacters).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
        }.filter { !$0.isEmpty }
        return names.isEmpty ? text : text + " — from " + names.joined(separator: ", ")
    }

    /// Memory text as it should appear in prompts / USER.md / recall output. Durable storage may keep timestamps for sorting and audit, but ordinary memory
    /// prose should not start with machine chronology. Date-critical kinds (`schedule`, `deadline`, …) keep their leading stamp — the date IS the fact.
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

    /// Precoverage requires the same core and, for date-critical facts, the same retained stamp; stripping is bounded.
    public struct Key: Hashable, Sendable, CustomStringConvertible {
        public let core: String
        public let stamp: String?

        public init(core: String, stamp: String?) {
            self.core = core
            self.stamp = stamp
        }

        public var isEmpty: Bool { core.isEmpty && (stamp?.isEmpty ?? true) }

        public var description: String {
            guard let stamp, !stamp.isEmpty else { return core }
            return core.isEmpty ? stamp : "\(stamp) \(core)"
        }

        /// A retained stamp requires an identical body stamp: a false match drops a fact, while a missed match safely keeps USER.md injected.
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
            // An unreduced key can only miss coverage, safely keeping USER.md injected when stripping is inconsistent.
            return Key(core: collapsed, stamp: nil)
        }
        let stamp = String(collapsed.dropLast(core.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Key(core: core, stamp: stamp.isEmpty ? nil : stamp)
    }

    /// Apply the same stamp strippers as display without its kind gate or all-stamp preservation so the join can observe an empty core.
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
