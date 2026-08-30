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
}
