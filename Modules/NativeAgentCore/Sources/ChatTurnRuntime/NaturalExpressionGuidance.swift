import Foundation

// Blueprint: | `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`; User-authored head classification |

/// TurnSettle owns native settlement classification; authored expression guidance belongs to turn.js.
struct NaturalExpressionGuidance {
    static func isSocialServe(_ userMessage: String) -> Bool {
        // Classify only the user-authored head, excluding appended machine blocks.
        let authored = userMessage.components(separatedBy: "\n\n[").first ?? userMessage
        let text = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80,
              !text.contains("\n"), !text.contains("```"),
              !text.contains("/"), !text.contains("http") else { return false }
        let lower = text.lowercased()
        // Exclude work before social fast paths so a laugh or emoji cannot turn a task into a greeting.
        guard !lower.contains("?") else { return false }
        let words = lower.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, !workStarters.contains(first) else { return false }
        if lower.contains("lol") || lower.contains("haha") || lower.contains("lmao") {
            return true
        }
        if text.unicodeScalars.contains(where: { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }) {
            return true
        }
        // Bare words require an explicit social or greeting marker.
        let socialMarkers: Set<Substring> = [
            "hey", "hi", "yo", "hiya", "morning", "gm", "night", "goodnight",
            "thanks", "thank", "ouch", "aww", "hehe", "babe", "baby",
            "miss", "love", "silly", "smooth",
        ]
        let bareWords = words.map { Substring($0.trimmingCharacters(in: .punctuationCharacters)) }
        return words.count <= 5
            && bareWords.contains(where: socialMarkers.contains)
            && lower.allSatisfy { $0.isLetter || $0.isWhitespace || "'’!,.".contains($0) }
    }

    /// Exclude tasking openers before classifying social text.
    static let workStarters: Set<Substring> = [
        "do", "go", "run", "fix", "check", "wipe", "install", "build",
        "commit", "push", "try", "test", "deploy", "restart", "update",
        "review", "read", "open", "merge", "ship", "release", "summarize",
        "can", "could", "please", "make", "add", "remove", "delete",
    ]

    /// Remove appended machine blocks and transport attribution so first-word detection reads the user's authored opener.
    static func authoredHead(_ userMessage: String) -> String {
        var authored = userMessage.components(separatedBy: "\n\n[").first ?? userMessage
        authored = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        if authored.hasPrefix("["), let close = authored.firstIndex(of: "]") {
            let remainder = authored[authored.index(after: close)...]
            return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return authored
    }
}
