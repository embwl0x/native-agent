import Foundation

// Blueprint: | `NaturalExpressionGuidance.swift` | `NaturalExpressionGuidance.isSocialServe`: native requested-result settlement classification of the user-authored message head |

/// Native settlement classifiers. Authored expression guidance lives in turn.js.
struct NaturalExpressionGuidance {
    /// Still used by TurnSettle's requested-result obligation. The expression
    /// cues are gone; this classifier keeps that independent caller unchanged.
    static func isSocialServe(_ userMessage: String) -> Bool {
        // The live pipeline appends machine blocks to the user's text before
        // the history builder sees it (e.g. "\n\n[tool routing …]") — classify
        // only the user-AUTHORED head, or the newline guard rejects every real
        // serve (live-gap found 2026-08-11 via data/logs/nexpr_diag).
        let authored = userMessage.components(separatedBy: "\n\n[").first ?? userMessage
        let text = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 80,
              !text.contains("\n"), !text.contains("```"),
              !text.contains("/"), !text.contains("http") else { return false }
        let lower = text.lowercased()
        // Tasking exclusions run before the laugh/emoji fast paths:
        // "run it 😅" and "can you check CI? lol" are work.
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
        // Bare-words path: short and unpunctuated is NOT enough on its own
        // (gpt-5.5 review: "merge it" is short too) — require an explicit
        // social/greeting marker word.
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

    /// Tasking openers excluded by the shared social classifier above.
    static let workStarters: Set<Substring> = [
        "do", "go", "run", "fix", "check", "wipe", "install", "build",
        "commit", "push", "try", "test", "deploy", "restart", "update",
        "review", "read", "open", "merge", "ship", "release", "summarize",
        "can", "could", "please", "make", "add", "remove", "delete",
    ]

    /// The user-AUTHORED head of a delivered message: machine blocks appended
    /// by the pipeline (`"\n\n[tool routing …]"`) are cut, and a bridge prefix
    /// (`"[from: claude, via bridge] …"`) is stripped so first-word detection
    /// sees the human's opener. As-delivered, not as-typed.
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
