// Blueprint: | `RecallLexicalNormalization.swift` | `characterEditDistance`: pure Character comparison; `RecallLexicalNormalization`: shared retrieval-only inflections and question-word vocabulary; canonical text and authority remain verbatim |

/// Stable FNV-1a-64 over exact UTF-8; callers own seeds, normalization and formatting.
public func fnv1a64(_ text: String, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var hash = seed
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// Character insertion, deletion and substitution distance; callers own normalization.
public func characterEditDistance(_ a: [Character], _ b: [Character]) -> Int {
    var row = Array(0...b.count)
    for (i, character) in a.enumerated() {
        var next = [i + 1]
        for (j, other) in b.enumerated() {
            next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1)))
        }
        row = next
    }
    return row[b.count]
}

/// Lightweight English inflection normalization for retrieval only. Never use
/// this for canonical text, identifiers, authorization, or exact-match tools.
/// Both sides of lexical matching use the same form; embeddings stay verbatim.
public enum RecallLexicalNormalization {
    public static func term(_ token: String) -> String {
        guard token.count >= 5,
              token.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return token }
        if ["ches", "shes", "sses", "xes", "zes"].contains(where: token.hasSuffix) {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s"),
           !token.hasSuffix("ss"), !token.hasSuffix("us"), !token.hasSuffix("is") {
            return String(token.dropLast())
        }
        return token
    }

    /// Words that carry the SHAPE of a question, never its subject. Both the
    /// context router and MemoryV2's BM25 lane score against this one list.
    public static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "by", "for",
        "from", "has", "have", "he", "her", "hers", "him", "his", "i", "in",
        "is", "it", "its", "me", "my", "of", "on", "or", "our", "ours", "she",
        "that", "the", "their", "theirs", "them", "they", "this", "to", "was",
        "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "you", "your", "yours",
        // Auxiliary/modal verbs express the question, not its subject. A
        // question starting "should the agent ..." must not rank every
        // unrelated instruction containing "agent should" above the answer.
        "am", "being", "can", "could", "did", "do", "does", "had",
        "may", "might", "must", "shall", "should", "would",
    ]
}
