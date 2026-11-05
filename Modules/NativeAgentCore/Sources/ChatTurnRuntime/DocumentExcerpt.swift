import Foundation

// Blueprint: | `DocumentExcerpt.swift` | `DocumentExcerpt.selected`; Bounded query-scored passages; absence stays explicit |

/// Rank bounded line windows against the request so oversized attachments retain relevant clauses with source line ranges.
/// One pass and bounded sorting run only on oversized attachments; declined selection remains explicit and sends no guessed prefix.
enum DocumentExcerpt {
    enum Selection {
        case passages(String)
        case noMatch
        case unavailable(String)
    }
    /// Keep clauses and nearby context together while allowing several windows within a 40k allowance.
    static let windowLines = 24

    /// Preserve no-match separately from a query or budget that cannot be read.
    static func selected(text: String, query: String, allowance: Int) -> Selection {
        guard allowance > 200 else { return .unavailable("The remaining passage allowance is too small.") }
        let terms = self.terms(query)
        guard !terms.isEmpty else { return .unavailable("The request contains no usable passage-selection terms.") }

        let lines = text.components(separatedBy: "\n")

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
        guard !scored.isEmpty else { return .noMatch }

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
            // Charge rendered labels, omission markers and join newlines as well as body text so the caller's turn budget cannot go negative.
            let cost = body.count
                + renderOverhead(start: window.start, end: end, total: lines.count)
            if used + cost > allowance {
                if chosen.isEmpty { break }
                continue
            }
            chosen.append(window.start)
            used += cost
        }
        guard !chosen.isEmpty else { return .unavailable("The matching passage does not fit the remaining allowance.") }

        // Measure the final rendering and remove weakest windows until it fits; adjacency changes marker and newline costs.
        while !chosen.isEmpty {
            let rendered = render(chosen: chosen, lines: lines)
            if rendered.count <= allowance { return .passages(rendered) }
            chosen.removeLast()
        }
        return .unavailable("The matching passages do not fit the remaining allowance.")
    }

    /// Use worst-case line numbers and omission joins so the estimate can only overcharge rendered overhead.
    private static func renderOverhead(start: Int, end: Int, total: Int) -> Int {
        let label = "[lines \(start + 1)–\(end)]\n"
        let marker = "[… lines \(start + 1)–\(total) not shown …]\n"
        return label.count + marker.count
    }

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

    /// Drop short and common words so every window cannot tie and promote the document's opening by accident.
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
