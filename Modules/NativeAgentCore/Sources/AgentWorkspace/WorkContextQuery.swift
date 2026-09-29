import Foundation
import NativeAgentCore
import PersistenceCore
import Desk

package struct WorkContextQuery: Sendable {
    package let terms: [String]
    private let includesLocator: Bool

    package init(_ query: String) {
        let filler: Set<String> = [
            "a", "an", "the", "and", "or", "to", "of", "for", "with", "on", "in", "at", "from",
            "it", "its", "this", "that", "those", "these", "our", "my", "your", "we", "i", "me",
            "you", "us", "let", "lets", "s", "up", "back", "again", "please", "can", "could",
            "would", "should", "do", "did", "have", "has", "had", "was", "were", "been", "is",
            "are", "be", "about", "what", "where", "when", "how", "last", "latest", "previous",
            "continue", "continuing", "resume", "resuming", "pick", "remember", "recall", "work",
            "working", "worked", "project", "doing", "left", "off", "get", "bring", "find",
            "open", "show", "discussed"
        ]
        includesLocator = query.components(separatedBy: .whitespacesAndNewlines).contains(where: Self.isLocatorToken)
        var seen: Set<String> = []
        terms = Self.words(query).filter { !filler.contains($0) && seen.insert($0).inserted }
    }

    package var text: String { terms.joined(separator: " ") }

    /// Match a topic in a bounded passage, not scattered words across an
    /// entire status report. Incidental repository paths are not prose about
    /// the project. An explicitly requested locator remains searchable.
    package func matchedTerms(_ content: String) -> [String] {
        let searchable = includesLocator ? content : content.components(separatedBy: .whitespacesAndNewlines)
            .filter { !Self.isLocatorToken($0) }.joined(separator: " ")
        let words = Self.words(searchable, expandCompounds: true)
        guard !terms.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        var window = Array(repeating: [Int](), count: 64)
        var cursor = 0
        var best: Set<Int> = []
        for word in words {
            let matches = terms.indices.filter { terms[$0] == word || Self.simplePluralPair(terms[$0], word) }
            for index in window[cursor] {
                if counts[index] == 1 { counts.removeValue(forKey: index) }
                else { counts[index, default: 0] -= 1 }
            }
            window[cursor] = matches
            cursor = (cursor + 1) % window.count
            for index in matches { counts[index, default: 0] += 1 }
            if counts.count > best.count { best = Set(counts.keys) }
            if best.count == terms.count { break }
        }
        return terms.indices.filter { best.contains($0) }.map { terms[$0] }
    }

    package func score(_ content: String) -> Int {
        let matches = matchedTerms(content).count
        // Preserve the existing partial-topic allowance for natural phrasing.
        let required = max(1, Int(ceil(Double(terms.count) * 0.6)))
        guard !terms.isEmpty, matches >= required else { return 0 }
        return matches
    }

    private static func isLocatorToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]{}<>,;"))
        guard token.contains("/") else { return false }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./")
            || token.hasPrefix("../") || token.contains("://") { return true }
        let parts = token.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first, let last = parts.last, parts.count >= 2 else { return false }
        // Relative file references have a filename or a recognizable directory
        // root. Ordinary browser/research and Mac/Telegram topic pairs remain
        // prose, rather than being mistaken for filesystem paths.
        let roots: Set<String> = ["src", "sources", "modules", "docs", "data", "research", "script",
                                  "scripts", "tests", "users", "volumes", "applications", "library",
                                  "projects", "tmp", "var"]
        return roots.contains(first.lowercased()) || !(String(last) as NSString).pathExtension.isEmpty
    }

    // Local lexical equivalence, not a change to global memory matching.
    // Retain whole-word boundaries (especially X); allow bot/bots and the
    // existing conservative longer-word normalization on both sides.
    private static func simplePluralPair(_ lhs: String, _ rhs: String) -> Bool {
        let shorter = lhs.count < rhs.count ? lhs : rhs
        let longer = lhs.count < rhs.count ? rhs : lhs
        return shorter.count >= 3 && !shorter.hasSuffix("s")
            && shorter.utf8.allSatisfy { $0 >= 97 && $0 <= 122 }
            && longer == shorter + "s"
    }

    private static let compoundBoundary = try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])")

    private static func words(_ text: String, expandCompounds: Bool = false) -> [String] {
        let chunks = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return chunks.flatMap { chunk -> [String] in
            var spellings = [chunk]
            if expandCompounds, chunk.rangeOfCharacter(from: .uppercaseLetters) != nil,
               let boundary = compoundBoundary {
                let expanded = boundary.stringByReplacingMatches(in: chunk,
                    range: NSRange(chunk.startIndex..., in: chunk), withTemplate: "$1 $2")
                if expanded != chunk { spellings += expanded.components(separatedBy: " ") }
            }
            return spellings.map {
                RecallLexicalNormalization.term($0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")))
            }
        }
    }
}
