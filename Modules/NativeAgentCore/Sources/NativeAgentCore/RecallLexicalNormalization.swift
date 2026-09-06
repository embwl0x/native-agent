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
    ///
    /// 2026-09-06: the router filtered these before ranking; recall's BM25 lane
    /// did not, so "What does User call me?" spent three of its five query terms
    /// on `what`/`does`/`me`. BM25 normalizes by the best candidate's raw
    /// score, so whichever row happened to accumulate the most filler mass took
    /// the whole lexical boost away from the row that actually answered.
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
