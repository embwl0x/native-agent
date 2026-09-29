import Foundation

/// Selective reading for an attachment that does not fit its per-turn
/// allowance (third conversation pass, item 4).
///
/// The old behaviour was a blind prefix: "compare the termination clauses in
/// these three contracts" got three introductions and no clauses. This scores
/// fixed-size line windows against the turn's own words and hands over the
/// windows that match, in document order, each labelled with its line range so
/// the model can name what it still needs instead of asking for another upload.
///
/// PURE AND CHEAP. No clock, no I/O, one pass over the lines plus a bounded
/// sort; it runs once per over-long attachment, never on a keystroke or a
/// stream chunk. Nothing is added to any prompt when it declines (`nil` → the
/// caller keeps the prefix it always used).
enum DocumentExcerpt {
    /// Lines per scored window. Big enough that a clause or a paragraph lands
    /// in one window with its context, small enough that a 40k allowance holds
    /// several windows from different parts of a long document.
    static let windowLines = 24

    /// Returns nil when selection cannot beat a plain prefix: no usable query
    /// terms, or nothing in the document matched them.
    static func selected(text: String, query: String, allowance: Int) -> String? {
        guard allowance > 200 else { return nil }
        let terms = self.terms(query)
        guard !terms.isEmpty else { return nil }

        let lines = text.components(separatedBy: "\n")
        guard lines.count > windowLines else { return nil }

        var scored: [(start: Int, score: Int)] = []
        var start = 0
        while start < lines.count {
            let end = min(start + windowLines, lines.count)
            let hay = lines[start..<end].joined(separator: " ").lowercased()
            var score = 0
            for term in terms where hay.contains(term) { score += 1 }
            if score > 0 { scored.append((start, score)) }
            start = end
        }
        guard !scored.isEmpty else { return nil }

        // Best-matching windows first, ties broken by position so the choice is
        // deterministic; then re-ordered into document order for output.
        let ranked = scored.sorted {
            $0.score == $1.score ? $0.start < $1.start : $0.score > $1.score
        }
        var chosen: [Int] = []
        var used = 0
        for window in ranked {
            let end = min(window.start + windowLines, lines.count)
            let body = lines[window.start..<end].joined(separator: "\n")
            // Budget what is RENDERED, not just the body: the line-range label,
            // the omission marker that can precede this window, and the newline
            // each rendered part is joined with. A flat "+ 32" undercounted
            // those, so an excerpt near the limit came back LONGER than its
            // allowance and the caller's per-turn budget went negative.
            let cost = body.count
                + renderOverhead(start: window.start, end: end, total: lines.count)
            if used + cost > allowance {
                if chosen.isEmpty { break }
                continue
            }
            chosen.append(window.start)
            used += cost
        }
        guard !chosen.isEmpty else { return nil }

        // Clamp on the real thing. The per-window estimate cannot know which
        // windows end up adjacent (no marker between them) or how the joins
        // fall, so measure the rendered text and drop the weakest window until
        // it fits. The caller subtracts what comes back from its budget, so
        // "never longer than the allowance" has to be a fact, not an estimate.
        while !chosen.isEmpty {
            let rendered = render(chosen: chosen, lines: lines)
            if rendered.count <= allowance { return rendered }
            chosen.removeLast()  // `chosen` is in ranked order: weakest goes first
        }
        return nil
    }

    /// What one window costs beyond its body once rendered: its own line-range
    /// label and, at worst, an omission marker ahead of it — each with the
    /// newline the parts are joined with. Worst-case line numbers, so the
    /// estimate can only over-charge.
    private static func renderOverhead(start: Int, end: Int, total: Int) -> Int {
        let label = "[lines \(start + 1)–\(end)]\n"
        let marker = "[… lines \(start + 1)–\(total) not shown …]\n"
        return label.count + marker.count
    }

    /// The exact text the caller hands to the model for a set of windows.
    private static func render(chosen: [Int], lines: [String]) -> String {
        var out: [String] = []
        var previousEnd: Int?
        for windowStart in chosen.sorted() {
            let end = min(windowStart + windowLines, lines.count)
            if let previousEnd, previousEnd < windowStart {
                out.append("[… lines \(previousEnd + 1)–\(windowStart) not shown …]")
            }
            out.append("[lines \(windowStart + 1)–\(end)]")
            out.append(lines[windowStart..<end].joined(separator: "\n"))
            previousEnd = end
        }
        if let previousEnd, previousEnd < lines.count {
            out.append("[… lines \(previousEnd + 1)–\(lines.count) not shown …]")
        }
        return out.joined(separator: "\n")
    }

    /// Content words of the request, lowercased. Short and ultra-common words
    /// are dropped — they match every window and would rank the document's
    /// first pages back to the top, which is the behaviour this replaces.
    static func terms(_ query: String) -> [String] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
        var seen = Set<String>()
        var out: [String] = []
        for word in words where seen.insert(word).inserted {
            out.append(word)
            if out.count == 24 { break }
        }
        return out
    }

    private static let stopwords: Set<String> = [
        "about", "after", "again", "also", "attached", "attachment", "been",
        "before", "being", "between", "both", "could", "document", "documents",
        "does", "doing", "done", "each", "else", "file", "files", "from",
        "give", "have", "here", "into", "just", "know", "like", "look", "make",
        "more", "most", "much", "need", "only", "over", "please", "same",
        "should", "some", "such", "take", "tell", "than", "that", "their",
        "them", "then", "there", "these", "they", "thing", "this", "those",
        "through", "very", "want", "well", "what", "when", "where", "which",
        "while", "with", "would", "your",
    ]
}
