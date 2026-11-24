// Clipping changes only presented length, never ranking, selection or decay; hard cuts are reserved for unbreakable tokens.

import Foundation
import NativeAgentCore

// Blueprint: | `MemoryV2+TextClip.swift` | `MemoryTextClip`: shared sentence/word-safe display clipping and bounded memory text presentation |

// MARK: - Caps

public let memoryRecallContentCap = 2000

public let memoryRecallPreviewCap = 200


// MARK: - MemoryTextClip

public enum MemoryTextClip {

    /// Share MemoryDisplayText across USER.md, Context and recall so machine chronology stays in storage rather than leading ordinary prose.
    public static func memoryDisplayText(_ text: String, kind: String? = nil) -> String {
        MemoryDisplayText.display(text, kind: kind)
    }

    /// Prefer sentence boundaries, then whole words; hard-cap only a token with no whitespace inside the limit.
    public static func sentenceClip(_ text: String, cap: Int) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        let limit = text.index(text.startIndex, offsetBy: cap)
        if let boundary = lastSentenceBoundary(in: text, upTo: limit) {
            let clipped = String(text[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clipped.isEmpty { return clipped }
        }
        // Pass the full original text so word clipping can inspect the character after the cap.
        return wordClip(text, cap: cap)
    }

    /// Use a hard prefix only when no whitespace boundary fits.
    public static func wordClip(_ text: String, cap: Int) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        let prefix = String(text.prefix(cap))
        // The character AFTER the clip decides whether we cut mid-word: if it is whitespace the prefix already ends on a whole word.
        let nextIndex = text.index(text.startIndex, offsetBy: cap)
        if text[nextIndex].isWhitespace {
            return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) else {
            return prefix // single unbroken token longer than the cap
        }
        let clipped = String(prefix[..<lastSpace])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? prefix : clipped
    }


    /// Validate sentence ends against full text so clipping cannot turn a decimal point into a terminator; trailing closers must fit.
    private static func lastSentenceBoundary(
        in text: String, upTo limit: String.Index
    ) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?", "…"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", "»"]
        var boundary: String.Index? = nil
        var idx = text.startIndex
        while idx < limit {
            if terminators.contains(text[idx]) {
                var after = text.index(after: idx)
                while after < text.endIndex, closers.contains(text[after]) {
                    after = text.index(after: after)
                }
                // Require closers to fit and check the full text after the terminator so cap-edge decimals cannot masquerade as sentences.
                if after <= limit,
                   after == text.endIndex || text[after].isWhitespace {
                    boundary = after
                }
            }
            idx = text.index(after: idx)
        }
        return boundary
    }
}
