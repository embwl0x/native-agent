// Clip at a sentence boundary, then a word boundary; hard-cap only a token longer than the cap.
// Clipping changes text length only, never ranking, row selection, decay or thresholds.

import Foundation
import NativeAgentCore

// Blueprint: | `MemoryV2+TextClip.swift` | `MemoryTextClip`: shared sentence/word-safe display clipping and bounded memory text presentation |

// MARK: - Caps

/// Max characters of full memory `content` returned per recall hit.
public let memoryRecallContentCap = 2000

/// Max characters of the sentence-clipped `preview` field on a recall hit.
public let memoryRecallPreviewCap = 200


// MARK: - MemoryTextClip

public enum MemoryTextClip {

    /// Return memory text as it should appear in prompts / USER.md / recall
    /// tool output. Durable storage may keep timestamps for sorting and audit,
    /// but ordinary memory prose should not start with machine chronology.
    ///
    /// Forward to `MemoryDisplayText` so USER.md, ContextFlow and MemoryV2 share one renderer.
    public static func memoryDisplayText(_ text: String, kind: String? = nil) -> String {
        MemoryDisplayText.display(text, kind: kind)
    }

    /// Clip `text` to at most `cap` characters without ever ending mid-word.
    ///
    /// Order of preference:
    ///   1. `text` unchanged when it already fits.
    ///   2. The longest prefix ending at a sentence boundary (`.`/`!`/`?`/`…`
    ///      followed by whitespace, a closing quote/bracket, or end-of-clip).
    ///   3. The longest prefix ending at a word boundary (whitespace).
    ///   4. A hard `prefix(cap)` only when the first `cap` characters contain
    ///      no whitespace at all (single giant token — nothing cleaner exists).
    public static func sentenceClip(_ text: String, cap: Int) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        let limit = text.index(text.startIndex, offsetBy: cap)
        if let boundary = lastSentenceBoundary(in: text, upTo: limit) {
            let clipped = String(text[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clipped.isEmpty { return clipped }
        }
        // Fall back on the ORIGINAL text (not the prefix): wordClip needs to
        // see the character AFTER the cap to know whether the cut lands
        // mid-word.
        return wordClip(text, cap: cap)
    }

    /// Clip `text` to at most `cap` characters at a word (whitespace)
    /// boundary. Falls back to the hard prefix only when no whitespace
    /// exists within the cap.
    public static func wordClip(_ text: String, cap: Int) -> String {
        guard cap > 0 else { return "" }
        guard text.count > cap else { return text }
        let prefix = String(text.prefix(cap))
        // The character AFTER the clip decides whether we cut mid-word: if
        // it is whitespace the prefix already ends on a whole word.
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


    /// Index just past the last sentence terminator (and any closing
    /// quotes/brackets that follow it), at or before `limit`, whose next
    /// character is whitespace or true end-of-text. Decimal points ("0.92")
    /// don't qualify because the following character is alphanumeric.
    ///
    /// Validate boundaries against the full text so clipping cannot turn a decimal point into a terminator.
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
                // `after <= limit`: trailing closers must still fit the cap.
                // The whitespace/end check runs against the FULL text so a
                // cap-edge "0." (next real char: "9") never qualifies.
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
