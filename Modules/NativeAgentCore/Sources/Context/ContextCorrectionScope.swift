import Foundation

/// Applicability is not authority. Existing corrections remain global unless
/// their canonical memory explicitly supplies topics; attention/utility cannot
/// make a topic-scoped correction apply to an unrelated conversation.
public enum ContextCorrectionScope {
    public static let entityKind = "context_topic"

    public static func applies(_ atom: ContextAtomDraft, message: String, recentTurns: [String]) -> Bool {
        guard atom.kind == .correction else { return true }
        let topics = atom.entities.filter { $0.kind == entityKind }.map(\.label)
        guard !topics.isEmpty else { return true }
        // Carry scope through a short referential follow-up, not through a
        // greeting or an unrelated topic simply because it follows work.
        let followup = isReferentialFollowup(message)
        let texts = [message] + (followup ? Array(recentTurns.suffix(2)) : [])
        return topics.contains { topic in
            let needle = words(topic)
            guard !needle.isEmpty else { return false }
            return texts.contains { text in
                let haystack = words(text)
                guard haystack.count >= needle.count else { return false }
                return (0...(haystack.count - needle.count)).contains {
                    Array(haystack[$0..<($0 + needle.count)]) == needle
                }
            }
        }
    }

    /// Deliberately conservative: an incidental "it" in "how is it going?"
    /// or "is it raining?" is not permission to bring prior work forward.
    public static func isReferentialFollowup(_ message: String) -> Bool {
        let tokens = words(message)
        guard !tokens.isEmpty, tokens.count <= 16 else { return false }
        if !Set(tokens).isDisjoint(with: ["that", "those", "them", "continue", "resume", "same"]) { return true }
        let normalized = " " + tokens.joined(separator: " ") + " "
        return ["do it", "fix it", "use it", "try it", "finish it", "change it", "go ahead", "keep going"]
            .contains { normalized.contains(" " + $0 + " ") }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
