import Foundation

/// Presentation policy for a collapsed Observatory disclosure row. The compact
/// text is a status summary, not an unbounded diagnostic channel: preserve a
/// real state, normalize malformed whitespace, and expose the same bounded
/// summary to VoiceOver and the visible row.
enum CognitionObservatoryCollapsedRowPresentation {
    static let maximumVisibleHintCharacters = 96

    struct Hint: Equatable {
        let text: String
        let isTruncated: Bool
    }

    static func hint(raw: String?, isExpanded: Bool) -> Hint? {
        guard !isExpanded,
              let raw else { return nil }
        let normalized = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumVisibleHintCharacters else {
            return Hint(text: normalized, isTruncated: false)
        }
        return Hint(
            text: String(normalized.prefix(maximumVisibleHintCharacters)) + "…",
            isTruncated: true
        )
    }

    static func accessibilityLabel(
        title: String,
        count: Int?,
        pending: Int,
        hint: Hint?
    ) -> String {
        var parts = [title]
        if let badge = CognitionObservatoryCountBadgePresentation.badge(for: count) {
            let count = badge.count
            parts.append("\(count) item\(count == 1 ? "" : "s")")
        }
        if pending > 0 {
            parts.append("\(pending) pending")
        }
        if let hint {
            parts.append(hint.text)
        }
        return parts.joined(separator: ", ")
    }
}
