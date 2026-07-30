// U3 wave-1 item 1/2 (2026-06-10): sentence/word-safe text clipping.
//
// The felt "memory truncation" was READ-side: recall surfaced only
// `prefix(200)` previews that chopped mid-word, and the extraction regexes
// capped captures mid-phrase. This file owns the shared clipping helpers and
// the caps so every producer clips CLEANLY (sentence boundary first, then
// word boundary, hard cap only when a single token exceeds the cap).
//
// HARD CONSTRAINT (u3-memory-quality plan): these helpers shape how much
// text is RETURNED/STORED — they must never change ranking, which rows
// recall returns, or any decay/threshold semantics.

import Foundation
import NativeAgentCore

// MARK: - Caps

/// Max characters of full memory `content` returned per recall hit
/// (impl_recall_memory and the MemoryV2 recall surface). Generous on
/// purpose: the live store's median row is well under 300 chars, and the
/// daemon-era 200-char preview was the felt truncation. 2000 chars is
/// ~500 tokens worst-case per hit; at the default k=5 that is ~2.5k tokens
/// upper bound, paid only when rows are actually that long.
public let memoryRecallContentCap = 2000

/// Max characters of the compact `preview` field on a recall hit. Same
/// budget as the daemon-era prefix(200), but sentence-clipped instead of a
/// mid-word chop.
public let memoryRecallPreviewCap = 200

/// Cap for regex value-captures in the fact extractors
/// (RuleBasedFactExtractor / FoundationModelsRuleFallback). Generous so a
/// captured value runs to its natural sentence/clause boundary (the capture
/// classes already exclude `.,;:!?`) instead of chopping mid-phrase at the
/// old 40/60/80 caps; `MemoryTextClip.wordSafeCapture` then guarantees the
/// emitted row never ends mid-word.
public let memoryExtractionCaptureCap = 200

/// Rows the persona-starvation alarm pulls unfiltered before applying the
/// disclosure gate. Wide enough that one undisclosable top row cannot mask a
/// disclosable neighbour, small enough to stay a bounded one-off probe.
public let personaStarvationProbeTopK = 8

// MARK: - MemoryTextClip

public enum MemoryTextClip {

    /// Return memory text as it should appear in prompts / USER.md / recall
    /// tool output. Durable storage may keep timestamps for sorting and audit,
    /// but ordinary memory prose should not start with machine chronology.
    ///
    /// The implementation moved to `MemoryDisplayText` in the base target
    /// (2026-07-24) so the USER.md producer and the ContextFlow precoverage
    /// join share ONE renderer instead of two that could drift. This stays as
    /// the MemoryV2-facing spelling; it must remain a pure forwarder.
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

    /// Regex-capture guard for the fact extractors: returns the captured
    /// substring, trimmed back to its last whole word when the quantifier
    /// cap chopped the match mid-word (the source character immediately
    /// after the capture is still alphanumeric). Returns nil when nothing
    /// whole-word remains — the caller drops the candidate rather than
    /// storing a chopped fragment.
    public static func wordSafeCapture(_ source: NSString, range: NSRange) -> String? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        let captured = source.substring(with: range)
        let end = range.location + range.length
        var choppedMidWord = false
        if end < source.length {
            let nextUnit = source.character(at: end)
            if let next = Unicode.Scalar(nextUnit),
               CharacterSet.alphanumerics.contains(next),
               let last = captured.unicodeScalars.last,
               CharacterSet.alphanumerics.contains(last) {
                choppedMidWord = true
            }
        }
        guard choppedMidWord else { return captured }
        guard let lastSpace = captured.lastIndex(where: { $0.isWhitespace }) else { return nil }
        let trimmed = String(captured[..<lastSpace])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Index just past the last sentence terminator (and any closing
    /// quotes/brackets that follow it), at or before `limit`, whose next
    /// character is whitespace or true end-of-text. Decimal points ("0.92")
    /// don't qualify because the following character is alphanumeric.
    ///
    /// REVIEW BLOCKER FIX (gpt-5.5, 2026-06-10): the boundary scan runs over
    /// the FULL text, not the clipped prefix. The earlier prefix-only scan
    /// treated the prefix's end as end-of-string, so a cap landing right
    /// after the "0." of "threshold is 0.92…" minted a fake sentence
    /// boundary and the clip ended "…is 0.". The prefix-end pseudo-boundary
    /// must validate exactly like an interior one — against the character
    /// the ORIGINAL text carries at that position — else the caller falls
    /// back to a word boundary.
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
